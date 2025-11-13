#!/bin/bash

# Script to configure AWS with read-only access to various services for monitoring and cost analysis
# Supports both IAM user with access keys and Workload Identity Federation (WIF)
# Usage: ./frugal-aws-setup.sh <role-name> <account-id> [options]

set -euo pipefail

# Frugal GCP Workload Identity Federation configuration
# GCP service account will be passed as parameter
# Get this from the Frugal UI: Setup → GCP Integration → Copy the trusted service account
FRUGAL_OIDC_PROVIDER_URL="accounts.google.com"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to display usage
show_usage() {
    echo "Usage: $0 <role-name> <account-id> [options]"
    echo ""
    echo "Options:"
    echo "  --wif <sa-email:project-number>  Set up Workload Identity Federation (recommended)"
    echo "  --additional-accounts <specs>    Comma-separated account IDs or account:profile pairs"
    echo "  --undo                            Remove IAM role/user and associated resources"
    echo "  [credentials-file]                Path for credentials file (IAM user mode)"
    echo ""
    echo "WIF format:"
    echo "  service-account@project.iam.gserviceaccount.com:PROJECT_NUMBER"
    echo "  Example: frugal-sa@staging-467615.iam.gserviceaccount.com:413415524379"
    echo ""
    echo "Additional accounts format:"
    echo "  - Account ID only:        123456789012"
    echo "  - With profile:           123456789012:my-profile"
    echo "  - Multiple:               '123456789012:prod,210987654321:staging'"
    echo ""
    echo "Examples:"
    echo "  Single account with WIF:"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:413415524379"
    echo ""
    echo "  Multiple accounts with WIF (using profiles):"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:413415524379 \\"
    echo "       --additional-accounts '210987654321:account2,135792468013:account3'"
    echo ""
    echo "  IAM user with access keys:"
    echo "    $0 frugal-readonly 123456789012 /path/to/credentials.json"
    echo ""
    echo "  Undo (remove resources):"
    echo "    $0 frugal-readonly 123456789012 --undo"
    echo ""
    echo "Get service account email and project number from: Frugal UI → Setup → AWS Integration"
    echo "Configure AWS profiles with: aws configure --profile PROFILE_NAME"
}

# Check if required arguments are provided
if [ $# -lt 2 ]; then
    print_error "Insufficient arguments"
    show_usage
    exit 1
fi

ROLE_NAME="$1"
ACCOUNT_ID="$2"

# Validate account ID (should be 12 digits)
if ! [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    print_error "Invalid AWS account ID. Must be 12 digits."
    exit 1
fi

# Initialize variables
FRUGAL_GCP_SERVICE_ACCOUNT=""
FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID=""
FRUGAL_OIDC_AUDIENCE=""
ADDITIONAL_ACCOUNTS=()
ADDITIONAL_ACCOUNT_PROFILES=()
UNDO_MODE=false
WIF_MODE=false
CREDENTIALS_FILE=""
CONFIGURED_ROLE_ARNS=()

# Parse arguments
shift 2  # Remove first two args (role-name and account-id)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --undo)
            UNDO_MODE=true
            CREDENTIALS_FILE="${ROLE_NAME}-credentials.json"
            shift
            ;;
        --wif)
            WIF_MODE=true
            wif_param="$2"

            if [[ -z "$wif_param" ]]; then
                print_error "GCP service account required after --wif"
                print_error "Get this from the Frugal UI: Setup → AWS Integration"
                show_usage
                exit 1
            fi

            # Check if format includes service account subject ID (email:subject-id)
            if [[ "$wif_param" =~ ^(.+@.+\.iam\.gserviceaccount\.com):([0-9]+)$ ]]; then
                # Format: email:subject-id (required for WIF)
                FRUGAL_GCP_SERVICE_ACCOUNT="${BASH_REMATCH[1]}"
                FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID="${BASH_REMATCH[2]}"
                FRUGAL_OIDC_AUDIENCE="${FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID}"
            elif [[ "$wif_param" =~ ^.+@.+\.iam\.gserviceaccount\.com$ ]]; then
                # Format: email only (backward compatibility - try to extract subject ID)
                FRUGAL_GCP_SERVICE_ACCOUNT="$wif_param"
                # Try old extraction method for legacy service accounts
                if [[ "$FRUGAL_GCP_SERVICE_ACCOUNT" =~ ^([0-9]+)- ]]; then
                    FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID="${BASH_REMATCH[1]}"
                    FRUGAL_OIDC_AUDIENCE="${FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID}"
                else
                    print_error "Could not extract subject ID from service account: $FRUGAL_GCP_SERVICE_ACCOUNT"
                    print_error "Please use format: service-account-email:subject-id"
                    print_error "Example: frugal-sa@project.iam.gserviceaccount.com:107454444650754356467"
                    print_error ""
                    print_error "Get both values from the Frugal UI: Setup → AWS Integration"
                    exit 1
                fi
            else
                print_error "Invalid service account format: $wif_param"
                print_error "Expected format: service-account@project.iam.gserviceaccount.com:project-number"
                print_error "Example: frugal-sa@project.iam.gserviceaccount.com:123456789012"
                exit 1
            fi
            shift 2
            ;;
        --additional-accounts)
            IFS=',' read -ra account_specs <<< "$2"
            # Parse each account specification (format: account-id or account-id:profile)
            for spec in "${account_specs[@]}"; do
                if [[ "$spec" =~ ^([0-9]{12}):(.+)$ ]]; then
                    # Format: account-id:profile
                    acc_id="${BASH_REMATCH[1]}"
                    profile="${BASH_REMATCH[2]}"
                    ADDITIONAL_ACCOUNTS+=("$acc_id")
                    ADDITIONAL_ACCOUNT_PROFILES+=("$profile")
                elif [[ "$spec" =~ ^([0-9]{12})$ ]]; then
                    # Format: account-id only (use default profile)
                    acc_id="${BASH_REMATCH[1]}"
                    ADDITIONAL_ACCOUNTS+=("$acc_id")
                    ADDITIONAL_ACCOUNT_PROFILES+=("default")
                else
                    print_error "Invalid additional account specification: $spec"
                    print_error "Expected format: 123456789012 or 123456789012:profile-name"
                    exit 1
                fi
            done
            shift 2
            ;;
        *)
            # Assume it's a credentials file path (IAM user mode)
            CREDENTIALS_FILE="$1"
            shift
            ;;
    esac
done

# Set default credentials path if not specified and not in WIF mode
if [[ "$WIF_MODE" = false ]] && [[ -z "$CREDENTIALS_FILE" ]]; then
    CREDENTIALS_FILE="${ROLE_NAME}-credentials.json"
fi

# Define read-only AWS managed policies with descriptions
# Format: "policy_arn|description"
# Both WIF and IAM user modes get the same base permissions
READONLY_POLICIES_WITH_DESC=(
    # Comprehensive read-only access (includes most AWS services)
    "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess|Read-only access to EC2, S3, RDS, Lambda, CloudWatch, and most AWS services"
    # Bedrock AI/ML read-only access
    "arn:aws:iam::aws:policy/AmazonBedrockReadOnly|Read-only access to AWS Bedrock AI models, configuration, and diagnostics"
)

# Extract just the policy ARNs for easy access
READONLY_POLICIES=()
for policy_desc in "${READONLY_POLICIES_WITH_DESC[@]}"; do
    READONLY_POLICIES+=("${policy_desc%%|*}")
done

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first:"
        echo "  https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        exit 1
    fi
    
    # Disable pagination to prevent interactive prompts
    export AWS_PAGER=""
}

# Function to check if user is authenticated
check_auth() {
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured or authenticated. Please run:"
        echo "  aws configure"
        echo "or set AWS credentials via environment variables"
        exit 1
    fi
    
    # Verify we're operating on the correct account
    local current_account=$(aws sts get-caller-identity --query Account --output text)
    if [ "$current_account" != "$ACCOUNT_ID" ]; then
        print_error "Current AWS account ($current_account) doesn't match specified account ($ACCOUNT_ID)"
        print_info "Please configure AWS CLI for the correct account"
        exit 1
    fi
}

# Function to check if AWS profile exists
check_aws_profile() {
    local profile="$1"

    if [ "$profile" = "default" ]; then
        # Default profile always exists (uses default credentials)
        return 0
    fi

    if aws configure list --profile "$profile" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to verify access to an account with a profile
verify_account_access() {
    local account_id="$1"
    local profile="$2"

    local profile_arg=""
    if [ "$profile" != "default" ]; then
        profile_arg="--profile $profile"
    fi

    # Try to get caller identity
    local current_account=$(aws sts get-caller-identity $profile_arg --query Account --output text 2>/dev/null)

    if [ $? -ne 0 ]; then
        print_error "Cannot access account $account_id with profile '$profile'"
        print_error "Please configure AWS CLI profile: aws configure --profile $profile"
        return 1
    fi

    if [ "$current_account" != "$account_id" ]; then
        print_error "Profile '$profile' is configured for account $current_account, not $account_id"
        return 1
    fi

    return 0
}

# Function to check if a resource exists
resource_exists() {
    local resource_type="$1"
    local resource_name="$2"
    local profile="${3:-}"

    local profile_arg=""
    if [ -n "$profile" ] && [ "$profile" != "default" ]; then
        profile_arg="--profile $profile"
    fi

    case "$resource_type" in
        "role")
            aws iam get-role --role-name "$resource_name" $profile_arg &> /dev/null
            ;;
        "user")
            aws iam get-user --user-name "$resource_name" $profile_arg &> /dev/null
            ;;
        "oidc-provider")
            aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$resource_name" $profile_arg &> /dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to create trust policy for WIF
# AWS has built-in support for Google's accounts.google.com OIDC provider
# Token claim mapping:
#   accounts.google.com:oaud -> matches token's aud field (service account email)
#   accounts.google.com:aud  -> matches token's azp field (numeric subject ID)
#   accounts.google.com:sub  -> matches token's sub field (numeric subject ID)
create_wif_trust_policy() {
    cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "accounts.google.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "accounts.google.com:oaud": "${FRUGAL_GCP_SERVICE_ACCOUNT}",
          "accounts.google.com:aud": "${FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID}",
          "accounts.google.com:sub": "${FRUGAL_GCP_SERVICE_ACCOUNT_SUBJECT_ID}"
        }
      }
    }
  ]
}
EOF
}

# Function to create IAM role for WIF
create_iam_role_wif() {
    print_info "Creating IAM role '${ROLE_NAME}' for Workload Identity Federation..."
    
    if resource_exists "role" "$ROLE_NAME"; then
        print_info "IAM role '${ROLE_NAME}' already exists - will check and add missing policies"
        return 0
    fi
    
    # Create trust policy file
    local trust_policy_file="/tmp/frugal-trust-policy-$$.json"
    create_wif_trust_policy > "$trust_policy_file"
    
    if aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$trust_policy_file" \
        --description "Read-only access for Frugal monitoring and cost analysis via WIF" \
        --tags "Key=Purpose,Value=FrugalIntegration" "Key=CreatedBy,Value=frugal-aws-setup"; then
        print_info "IAM role created successfully"
        rm -f "$trust_policy_file"
    else
        print_error "Failed to create IAM role"
        rm -f "$trust_policy_file"
        return 1
    fi
}

# Function to create IAM user
create_iam_user() {
    print_info "Creating IAM user '${ROLE_NAME}'..."
    
    if resource_exists "user" "$ROLE_NAME"; then
        print_info "IAM user '${ROLE_NAME}' already exists - will check and add missing policies"
        return 0
    fi
    
    if aws iam create-user \
        --user-name "$ROLE_NAME" \
        --tags "Key=Purpose,Value=FrugalIntegration" "Key=CreatedBy,Value=frugal-aws-setup"; then
        print_info "IAM user created successfully"
    else
        print_error "Failed to create IAM user"
        return 1
    fi
}

# Function to get current policies for a role or user
get_current_policies() {
    local resource_type="$1"  # "role" or "user"
    local resource_name="$2"
    
    if [ "$resource_type" = "role" ]; then
        aws iam list-attached-role-policies \
            --role-name "$resource_name" \
            --query 'AttachedPolicies[*].PolicyArn' \
            --output text 2>/dev/null | tr '\t' '\n'
    else
        aws iam list-attached-user-policies \
            --user-name "$resource_name" \
            --query 'AttachedPolicies[*].PolicyArn' \
            --output text 2>/dev/null | tr '\t' '\n'
    fi
}

# Function to attach policies
attach_policies() {
    local resource_type="$1"  # "role" or "user"
    local resource_name="$2"
    
    print_info "Checking and attaching read-only policies..."
    
    # Get current policies
    local current_policies=$(get_current_policies "$resource_type" "$resource_name")
    local policies_added=0
    local policies_skipped=0
    
    for policy in "${READONLY_POLICIES[@]}"; do
        if echo "$current_policies" | grep -q "^${policy}$"; then
            print_info "Policy already attached: ${policy##*/} (skipping)"
            ((policies_skipped++))
        else
            print_info "Attaching new policy: ${policy##*/}"
            if [ "$resource_type" = "role" ]; then
                if aws iam attach-role-policy \
                    --role-name "$resource_name" \
                    --policy-arn "$policy"; then
                    ((policies_added++))
                else
                    print_error "Failed to attach policy ${policy##*/}"
                fi
            else
                if aws iam attach-user-policy \
                    --user-name "$resource_name" \
                    --policy-arn "$policy"; then
                    ((policies_added++))
                else
                    print_error "Failed to attach policy ${policy##*/}"
                fi
            fi
        fi
    done
    
    print_info "Summary: ${policies_added} new policies added, ${policies_skipped} existing policies skipped"
}

# Function to create access keys for IAM user
create_access_keys() {
    print_info "Creating access keys for IAM user..."
    
    # Check if credentials file already exists
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_warning "Credentials file '${CREDENTIALS_FILE}' already exists."
        read -p "Do you want to create new access keys and overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping access key creation"
            return
        fi
    fi
    
    # Create access key
    local key_output=$(aws iam create-access-key --user-name "$ROLE_NAME" --output json)
    
    if [ $? -eq 0 ]; then
        # Extract credentials
        local access_key_id=$(echo "$key_output" | jq -r '.AccessKey.AccessKeyId')
        local secret_access_key=$(echo "$key_output" | jq -r '.AccessKey.SecretAccessKey')
        
        # Save to file
        cat > "$CREDENTIALS_FILE" << EOF
{
  "AccessKeyId": "${access_key_id}",
  "SecretAccessKey": "${secret_access_key}",
  "Region": "us-east-1",
  "AccountId": "${ACCOUNT_ID}",
  "UserName": "${ROLE_NAME}",
  "CreatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
        
        # Set secure permissions
        chmod 600 "$CREDENTIALS_FILE"
        print_info "Access keys saved to: ${CREDENTIALS_FILE}"
    else
        print_error "Failed to create access keys"
        return 1
    fi
}

# Function to create custom extended permissions policy
create_extended_policy() {
    local policy_name="FrugalExtendedReadOnly"
    local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"

    print_info "Checking for custom extended permissions policy..."

    # Check if policy already exists
    if aws iam get-policy --policy-arn "$policy_arn" &>/dev/null; then
        print_info "Custom extended permissions policy already exists"
        # Add to arrays even if already exists so attach_policies can attach it
        READONLY_POLICIES+=("$policy_arn")
        READONLY_POLICIES_WITH_DESC+=("${policy_arn}|Extended permissions for billing and CloudWatch Logs")
        return 0
    fi

    print_info "Creating custom extended permissions policy..."

    # Create policy document with billing and CloudWatch Logs permissions
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "CostExplorerAndBilling",
                "Effect": "Allow",
                "Action": [
                    "ce:Describe*",
                    "ce:Get*",
                    "ce:List*",
                    "account:GetAccountInformation",
                    "billing:Get*",
                    "organizations:Describe*",
                    "organizations:List*"
                ],
                "Resource": "*"
            },
            {
                "Sid": "CloudWatchLogsExtended",
                "Effect": "Allow",
                "Action": [
                    "logs:FilterLogEvents"
                ],
                "Resource": "*"
            }
        ]
    }'

    if aws iam create-policy \
        --policy-name "$policy_name" \
        --policy-document "$policy_document" \
        --description "Extended read-only permissions for Cost Explorer, billing, and CloudWatch Logs" \
        --tags "Key=Purpose,Value=FrugalIntegration" "Key=CreatedBy,Value=frugal-aws-setup"; then
        print_info "Custom extended permissions policy created successfully"

        # Add the custom policy to our lists
        READONLY_POLICIES+=("$policy_arn")
        READONLY_POLICIES_WITH_DESC+=("${policy_arn}|Extended permissions for billing and CloudWatch Logs")
    else
        print_error "Failed to create custom extended permissions policy"
        return 1
    fi
}

# Function to print a formatted table row
print_table_row() {
    local status="$1"
    local policy="$2"
    local desc="$3"
    printf "│ %-2s │ %-40s │ %-50s │\n" "$status" "$policy" "$desc"
}

# Function to print table header
print_table_header() {
    echo "┌────┬──────────────────────────────────────────┬────────────────────────────────────────────────────┐"
    echo "│    │ Policy                                   │ Description                                        │"
    echo "├────┼──────────────────────────────────────────┼────────────────────────────────────────────────────┤"
}

# Function to print table footer
print_table_footer() {
    echo "└────┴──────────────────────────────────────────┴────────────────────────────────────────────────────┘"
}

# Function to display plan and get confirmation
display_plan() {
    echo
    print_info "=== AWS IAM Setup Plan ==="
    echo
    echo "Primary Account ID: ${ACCOUNT_ID}"
    echo "Role/User Name: ${ROLE_NAME}"

    if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
        echo "Additional Accounts (${#ADDITIONAL_ACCOUNTS[@]}):"
        for i in "${!ADDITIONAL_ACCOUNTS[@]}"; do
            local acc_id="${ADDITIONAL_ACCOUNTS[$i]}"
            local profile="${ADDITIONAL_ACCOUNT_PROFILES[$i]}"
            echo "  - ${acc_id} (AWS profile: ${profile})"
        done
    fi

    if [ "$WIF_MODE" = true ]; then
        echo "Authentication Method: Workload Identity Federation (WIF)"
        echo "OIDC Provider: ${FRUGAL_OIDC_PROVIDER_URL}"
        echo "GCP Service Account: ${FRUGAL_GCP_SERVICE_ACCOUNT}"
        echo "Resource Type: IAM Role"
    else
        echo "Authentication Method: IAM User with Access Keys"
        echo "Credentials File: ${CREDENTIALS_FILE}"
        echo "Resource Type: IAM User"
    fi
    echo
    
    # Check what needs to be created
    if [ "$WIF_MODE" = true ]; then
        # Check OIDC provider
        local provider_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${FRUGAL_OIDC_PROVIDER_URL}"
        if resource_exists "oidc-provider" "$provider_arn"; then
            print_info "OIDC provider already exists"
        else
            print_info "OIDC provider will be created for Google accounts"
        fi
        
        # Check role
        if resource_exists "role" "$ROLE_NAME"; then
            print_info "IAM role already exists - will check for missing policies"
            local current_policies=$(get_current_policies "role" "$ROLE_NAME")
        else
            print_info "IAM role will be created"
            local current_policies=""
        fi
    else
        # Check user
        if resource_exists "user" "$ROLE_NAME"; then
            print_info "IAM user already exists - will check for missing policies"
            local current_policies=$(get_current_policies "user" "$ROLE_NAME")
        else
            print_info "IAM user will be created"
            local current_policies=""
        fi
    fi
    
    echo
    echo "Policies to be checked/attached:"
    print_table_header
    
    # Show managed policies
    for policy_desc in "${READONLY_POLICIES_WITH_DESC[@]}"; do
        local policy="${policy_desc%%|*}"
        local desc="${policy_desc#*|}"
        local policy_name="${policy##*/}"
        if echo "$current_policies" | grep -q "^${policy}$"; then
            print_table_row "✓" "$policy_name" "$desc"
        else
            print_table_row "+" "$policy_name" "$desc"
        fi
    done
    
    # Show custom policy for both WIF and IAM user modes
    local custom_policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/FrugalExtendedReadOnly"
    if echo "$current_policies" | grep -q "^${custom_policy_arn}$"; then
        print_table_row "✓" "FrugalExtendedReadOnly (custom)" "Cost Explorer, billing, and CloudWatch Logs filtering"
    else
        print_table_row "+" "FrugalExtendedReadOnly (custom)" "Cost Explorer, billing, and CloudWatch Logs filtering"
    fi
    
    print_table_footer
    
    echo
    echo "Legend: ✓ = already attached, + = will be attached"
    echo
    read -p "Do you want to proceed with this setup? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled by user"
        exit 0
    fi
}

# Function to display summary
display_summary() {
    echo
    print_info "=== Setup Complete ==="

    if [ "$WIF_MODE" = true ]; then
        echo "Authentication Method: Workload Identity Federation"
        echo "IAM Role ARN: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
        echo "OIDC Provider: ${FRUGAL_OIDC_PROVIDER_URL}"
        echo "GCP Service Account: ${FRUGAL_GCP_SERVICE_ACCOUNT}"
    else
        echo "Authentication Method: IAM User with Access Keys"
        echo "IAM User: ${ROLE_NAME}"
        echo "Credentials File: ${CREDENTIALS_FILE}"
    fi

    echo
    echo "Accounts configured:"
    echo "  PRIMARY: ${ACCOUNT_ID}"
    if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
        for acc_id in "${ADDITIONAL_ACCOUNTS[@]}"; do
            echo "  ADDITIONAL: ${acc_id}"
        done
    fi

    echo
    echo "Policies attached in PRIMARY account:"
    local resource_type=$( [ "$WIF_MODE" = true ] && echo "role" || echo "user" )
    local current_policies=$(get_current_policies "$resource_type" "$ROLE_NAME")
    if [ -n "$current_policies" ]; then
        echo "$current_policies" | while read -r policy; do
            echo "  - ${policy##*/}"
        done
    else
        echo "  (none)"
    fi
    
    # Note about extended permissions
    echo
    print_info "Extended Permissions:"
    echo "  Custom policy 'FrugalExtendedReadOnly' provides access to:"
    echo "  - AWS Cost Explorer for cost analysis"
    echo "  - Billing dashboards and reports"
    echo "  - Budget and cost allocation data"
    echo "  - CloudWatch Logs FilterLogEvents for downloading log samples"
    
    # Show next steps
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_info "Next steps: Copy and paste the following into the Frugal AWS Setup:"
    echo

    if [ "$WIF_MODE" = true ]; then
        echo "IAM Role ARN:"
        echo "  arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    else
        echo "Credentials file: ${CREDENTIALS_FILE}"
        echo
        echo "To display the credentials:"
        echo "  cat ${CREDENTIALS_FILE}"
    fi

    echo
    echo "Primary Account ID:"
    echo "  ${ACCOUNT_ID}"

    # Display additional role ARNs if multi-account setup was used
    if [[ ${#CONFIGURED_ROLE_ARNS[@]} -gt 1 ]]; then
        echo
        echo "Additional Account Role ARNs:"
        for arn in "${CONFIGURED_ROLE_ARNS[@]:1}"; do
            echo "  ${arn}"
        done
    fi

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to remove policies
remove_policies() {
    local resource_type="$1"  # "role" or "user"
    local resource_name="$2"
    
    print_info "Removing attached policies..."
    
    local current_policies=$(get_current_policies "$resource_type" "$resource_name")
    local policies_removed=0
    
    if [ -n "$current_policies" ]; then
        echo "$current_policies" | while read -r policy; do
            print_info "Detaching policy: ${policy##*/}"
            if [ "$resource_type" = "role" ]; then
                if aws iam detach-role-policy \
                    --role-name "$resource_name" \
                    --policy-arn "$policy"; then
                    ((policies_removed++))
                else
                    print_warning "Failed to detach policy ${policy##*/}"
                fi
            else
                if aws iam detach-user-policy \
                    --user-name "$resource_name" \
                    --policy-arn "$policy"; then
                    ((policies_removed++))
                else
                    print_warning "Failed to detach policy ${policy##*/}"
                fi
            fi
        done
    else
        print_info "No policies found to remove"
    fi
}

# Function to delete access keys
delete_access_keys() {
    print_info "Checking for access keys..."
    
    # List all access keys for the user
    local access_keys=$(aws iam list-access-keys --user-name "$ROLE_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")
    
    if [ -n "$access_keys" ]; then
        echo "$access_keys" | tr '\t' '\n' | while read -r key_id; do
            [ -z "$key_id" ] && continue
            print_info "Deleting access key: ${key_id}"
            if aws iam delete-access-key --user-name "$ROLE_NAME" --access-key-id "$key_id"; then
                print_info "Access key deleted"
            else
                print_warning "Failed to delete access key ${key_id}"
            fi
        done
    else
        print_info "No access keys found"
    fi
}

# Function to delete IAM role
delete_iam_role() {
    print_info "Deleting IAM role '${ROLE_NAME}'..."
    
    if aws iam delete-role --role-name "$ROLE_NAME"; then
        print_info "IAM role deleted successfully"
    else
        print_error "Failed to delete IAM role"
        return 1
    fi
}

# Function to delete IAM user
delete_iam_user() {
    print_info "Deleting IAM user '${ROLE_NAME}'..."
    
    if aws iam delete-user --user-name "$ROLE_NAME"; then
        print_info "IAM user deleted successfully"
    else
        print_error "Failed to delete IAM user"
        return 1
    fi
}

# Function to cleanup credential files
cleanup_credential_files() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_info "Removing credentials file: ${CREDENTIALS_FILE}"
        rm -f "$CREDENTIALS_FILE"
    fi
    
    # Also look for other potential credential files
    local cred_pattern="${ROLE_NAME}-credentials*.json"
    local other_creds=$(ls ${cred_pattern} 2>/dev/null | grep -v "^${CREDENTIALS_FILE}$" || true)
    
    if [ -n "$other_creds" ]; then
        print_warning "Found other credential files for this user:"
        echo "$other_creds"
        read -p "Do you want to remove these as well? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f ${cred_pattern}
            print_info "Credential files removed"
        fi
    fi
}

# Function to display undo plan
display_undo_plan() {
    echo
    print_warning "=== AWS IAM Removal Plan ==="
    echo
    echo "Account ID: ${ACCOUNT_ID}"
    
    # Determine what type of resource we're removing
    local found_role=false
    local found_user=false
    
    if resource_exists "role" "$ROLE_NAME"; then
        found_role=true
        echo "IAM Role found: ${ROLE_NAME}"
    fi
    
    if resource_exists "user" "$ROLE_NAME"; then
        found_user=true
        echo "IAM User found: ${ROLE_NAME}"
    fi
    
    if [ "$found_role" = false ] && [ "$found_user" = false ]; then
        print_error "Neither IAM role nor user '${ROLE_NAME}' exists"
        exit 1
    fi
    
    echo
    if [ "$found_role" = true ]; then
        echo "Role policies that will be removed:"
        local role_policies=$(get_current_policies "role" "$ROLE_NAME")
        if [ -n "$role_policies" ]; then
            echo "$role_policies" | while read -r policy; do
                echo "  - ${policy##*/}"
            done
        else
            echo "  (none)"
        fi
    fi
    
    if [ "$found_user" = true ]; then
        echo "User policies that will be removed:"
        local user_policies=$(get_current_policies "user" "$ROLE_NAME")
        if [ -n "$user_policies" ]; then
            echo "$user_policies" | while read -r policy; do
                echo "  - ${policy##*/}"
            done
        else
            echo "  (none)"
        fi
        
        echo
        echo "Access keys that will be deleted:"
        local access_keys=$(aws iam list-access-keys --user-name "$ROLE_NAME" --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null || echo "")
        if [ -n "$access_keys" ]; then
            echo "$access_keys" | tr '\t' '\n' | while read -r key_id; do
                [ -z "$key_id" ] && continue
                echo "  - ${key_id}"
            done
        else
            echo "  (none)"
        fi
    fi
    
    echo
    echo "Credential files that will be removed:"
    if [ -f "$CREDENTIALS_FILE" ]; then
        echo "  - ${CREDENTIALS_FILE}"
    fi
    local cred_pattern="${ROLE_NAME}-credentials*.json"
    local other_creds=$(ls ${cred_pattern} 2>/dev/null || true)
    if [ -n "$other_creds" ]; then
        echo "  - Other matching files: ${other_creds}"
    fi
    
    if [ "$found_role" = true ]; then
        local provider_arn="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${FRUGAL_OIDC_PROVIDER_URL}"
        if resource_exists "oidc-provider" "$provider_arn"; then
            echo
            echo "OIDC provider found (will ask about removal): ${FRUGAL_OIDC_PROVIDER_URL}"
        fi
    fi
    
    echo
    print_warning "This action cannot be undone!"
    read -p "Are you sure you want to remove these resources? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Removal cancelled by user"
        exit 0
    fi
}

# Undo/cleanup main function
undo_main() {
    print_info "Starting AWS resource removal process..."
    
    check_aws_cli
    check_auth
    display_undo_plan
    
    # Remove resources based on what exists
    if resource_exists "role" "$ROLE_NAME"; then
        remove_policies "role" "$ROLE_NAME"
        delete_iam_role
    fi
    
    if resource_exists "user" "$ROLE_NAME"; then
        delete_access_keys
        remove_policies "user" "$ROLE_NAME"
        delete_iam_user
    fi
    
    cleanup_credential_files

    echo
    print_info "=== Cleanup Complete ==="
    echo "All resources for '${ROLE_NAME}' have been removed"
}

# Function to setup resources in a single account
setup_single_account() {
    local target_account_id="$1"
    local aws_profile="$2"
    local is_primary="${3:-false}"

    # Set AWS profile if not default
    local original_profile="${AWS_PROFILE:-}"
    if [ "$aws_profile" != "default" ]; then
        export AWS_PROFILE="$aws_profile"
    fi

    if [[ "$is_primary" = true ]]; then
        print_info "Setting up resources in PRIMARY account: ${target_account_id}..."
    else
        print_info "Setting up resources in additional account: ${target_account_id} (profile: ${aws_profile})..."
    fi

    # Verify access to this account
    if ! verify_account_access "$target_account_id" "$aws_profile"; then
        print_error "Skipping account ${target_account_id} - cannot verify access"
        # Restore original profile
        if [ -n "$original_profile" ]; then
            export AWS_PROFILE="$original_profile"
        else
            unset AWS_PROFILE
        fi
        return 1
    fi

    # Setup resources based on mode
    if [ "$WIF_MODE" = true ]; then
        # Update ACCOUNT_ID temporarily for functions that use it
        local saved_account_id="$ACCOUNT_ID"
        ACCOUNT_ID="$target_account_id"

        create_iam_role_wif
        create_extended_policy
        attach_policies "role" "$ROLE_NAME"

        # Store the role ARN
        local role_arn="arn:aws:iam::${target_account_id}:role/${ROLE_NAME}"
        CONFIGURED_ROLE_ARNS+=("$role_arn")

        # Restore ACCOUNT_ID
        ACCOUNT_ID="$saved_account_id"
    else
        # For IAM user mode, only create in primary account
        if [[ "$is_primary" = true ]]; then
            create_iam_user
            create_extended_policy
            attach_policies "user" "$ROLE_NAME"
            create_access_keys
        else
            print_warning "IAM user mode only supports primary account. Skipping additional account: ${target_account_id}"
        fi
    fi

    print_info "✓ Setup complete for account ${target_account_id}"
    echo

    # Restore original profile
    if [ -n "$original_profile" ]; then
        export AWS_PROFILE="$original_profile"
    else
        unset AWS_PROFILE
    fi
}

# Main execution
main() {
    if [ "$UNDO_MODE" = true ]; then
        undo_main
    else
        print_info "Starting AWS IAM setup..."

        check_aws_cli
        check_auth
        display_plan

        # Setup primary account
        setup_single_account "$ACCOUNT_ID" "default" true

        # Setup additional accounts (WIF mode only)
        if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
            if [ "$WIF_MODE" = false ]; then
                print_warning "IAM user mode does not support multi-account setup"
                print_info "Additional accounts will be skipped"
            else
                echo
                print_info "Processing ${#ADDITIONAL_ACCOUNTS[@]} additional account(s)..."
                for i in "${!ADDITIONAL_ACCOUNTS[@]}"; do
                    local acc_id="${ADDITIONAL_ACCOUNTS[$i]}"
                    local profile="${ADDITIONAL_ACCOUNT_PROFILES[$i]}"
                    setup_single_account "$acc_id" "$profile" false
                done
            fi
        fi

        display_summary
    fi
}

# Run the main function
main