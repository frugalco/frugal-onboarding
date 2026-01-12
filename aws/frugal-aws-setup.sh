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
    echo "  --wif <sa-email:project-number>    Set up Workload Identity Federation (recommended)"
    echo "  --additional-accounts <ids>        Comma-separated account IDs"
    echo "  --assume-role <role-name>          Role to assume in additional accounts"
    echo "                                     (default: OrganizationAccountAccessRole)"
    echo "  --org-accounts <filter>            Auto-discover accounts from AWS Organizations"
    echo "  --undo                             Remove IAM role/user and associated resources"
    echo "  [credentials-file]                 Path for credentials file (IAM user mode)"
    echo ""
    echo "WIF format:"
    echo "  service-account@project.iam.gserviceaccount.com:PROJECT_NUMBER"
    echo "  Example: frugal-sa@sample-123456.iam.gserviceaccount.com:123456789000"
    echo ""
    echo "Additional accounts format (simplified):"
    echo "  - Just account IDs:       '123456789012,210987654321,135792468013'"
    echo "  - Uses AssumeRole for authentication (no manual profile configuration needed)"
    echo ""
    echo "Organizations discovery filters:"
    echo "  - all                     All accounts in organization"
    echo "  - ou:ou-xxxx-yyyyyyyy     Specific organizational unit"
    echo "  - Name=*pattern*          Filter by account name (supports wildcards)"
    echo "  - Status=ACTIVE           Filter by account status"
    echo ""
    echo "Examples:"
    echo "  Single account with WIF:"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:123456789000"
    echo ""
    echo "  Multiple accounts with WIF (manual list):"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:123456789000 \\"
    echo "       --additional-accounts '210987654321,135792468013'"
    echo ""
    echo "  All accounts via AWS Organizations:"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:123456789000 \\"
    echo "       --org-accounts all"
    echo ""
    echo "  Production accounts only:"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --wif frugal-sa@project.iam.gserviceaccount.com:123456789000 \\"
    echo "       --org-accounts 'Name=*-prod*'"
    echo ""
    echo "  IAM user with access keys (now supports multi-account):"
    echo "    $0 frugal-readonly 123456789012 \\"
    echo "       --additional-accounts '210987654321,135792468013'"
    echo ""
    echo "  Undo (remove resources):"
    echo "    $0 frugal-readonly 123456789012 --undo"
    echo ""
    echo "Get service account email and project number from: Frugal UI → Setup → AWS Integration"
    echo "Prerequisites: Trust relationships must be set up in additional accounts"
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
ASSUME_ROLE_NAME="OrganizationAccountAccessRole"
ORG_FILTER=""
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
        --assume-role)
            ASSUME_ROLE_NAME="$2"
            shift 2
            ;;
        --org-accounts)
            ORG_FILTER="$2"
            shift 2
            ;;
        --additional-accounts)
            IFS=',' read -ra account_specs <<< "$2"
            # Parse each account specification (format: account-id only)
            for spec in "${account_specs[@]}"; do
                # Trim whitespace
                spec=$(echo "$spec" | xargs)

                if [[ "$spec" =~ ^([0-9]{12})$ ]]; then
                    # Format: account-id only
                    acc_id="${BASH_REMATCH[1]}"
                    ADDITIONAL_ACCOUNTS+=("$acc_id")
                else
                    print_error "Invalid additional account specification: $spec"
                    print_error "Expected format: 123456789012 (12-digit account ID)"
                    print_error "Multiple accounts: '123456789012,210987654321,135792468013'"
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

# Function to check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed. This script requires jq for JSON parsing."
        echo ""
        echo "Install jq:"
        echo "  macOS:   brew install jq"
        echo "  Ubuntu:  sudo apt-get install jq"
        echo "  CentOS:  sudo yum install jq"
        echo "  Windows: Download from https://jqlang.github.io/jq/download/"
        echo ""
        echo "Or visit: https://jqlang.github.io/jq/download/"
        exit 1
    fi
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

# Function to check if running from AWS Organizations management account
check_management_account() {
    # Only check if we're doing multi-account setup
    if [[ ${#ADDITIONAL_ACCOUNTS[@]} -eq 0 ]] && [[ -z "$ORG_FILTER" ]]; then
        return 0  # Single account setup, no need to check
    fi

    # Try to get organization info
    local org_info=$(aws organizations describe-organization 2>/dev/null)
    if [ $? -ne 0 ]; then
        # Can't access Organizations API - likely not in management account
        print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_warning "⚠️  WARNING: Cannot access AWS Organizations API"
        print_warning ""
        print_warning "You appear to be running from a MEMBER account, not the MANAGEMENT account."
        print_warning ""
        print_warning "IMPACT:"
        print_warning "  • You can still configure access to multiple accounts"
        print_warning "  • BUT: Only THIS account's costs will be visible to Frugal"
        print_warning "  • Member accounts CANNOT see organization-wide consolidated billing"
        print_warning ""
        print_warning "RECOMMENDATION:"
        print_warning "  • For full organization cost visibility, re-run from the management account"
        print_warning "  • The management account is the one that pays the consolidated bill"
        print_warning ""
        print_warning "To find your management account:"
        print_warning "  • Log into AWS Console → Organizations → Organization Details"
        print_warning "  • Or ask your AWS administrator"
        print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        read -p "Do you want to continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled. Please re-run from the management account."
            exit 0
        fi
        echo
        return 0
    fi

    # We can access Organizations - check if we're the management account
    local management_account=$(echo "$org_info" | jq -r '.Organization.MasterAccountId')
    local current_account=$(aws sts get-caller-identity --query Account --output text)

    if [ "$management_account" != "$current_account" ]; then
        print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_warning "⚠️  WARNING: You are NOT in the AWS Organizations management account"
        print_warning ""
        print_warning "Current account:     $current_account"
        print_warning "Management account:  $management_account"
        print_warning ""
        print_warning "IMPACT:"
        print_warning "  • You can still configure access to multiple accounts"
        print_warning "  • BUT: Only THIS account's costs will be visible to Frugal"
        print_warning "  • Member accounts CANNOT see organization-wide consolidated billing"
        print_warning ""
        print_warning "RECOMMENDATION:"
        print_warning "  • Re-run this script from the management account (${management_account})"
        print_warning "  • The management account is required for full cost visibility"
        print_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        read -p "Do you want to continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled. Please re-run from the management account."
            exit 0
        fi
        echo
    else
        print_info "✓ Confirmed: Running from AWS Organizations management account"
        echo
    fi
}

# Function to assume a role in another account and set credentials
assume_role_for_account() {
    local target_account_id="$1"
    local role_name="$2"

    # Construct role ARN
    local role_arn="arn:aws:iam::${target_account_id}:role/${role_name}"
    local session_name="frugal-setup-$(date +%s)"

    print_info "Assuming role: $role_arn"

    # Assume role and get temporary credentials
    local credentials=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "$session_name" \
        --duration-seconds 3600 \
        --query 'Credentials' \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Failed to assume role: $role_arn"
        print_error "$credentials"
        print_error ""
        print_error "Ensure the role exists and trusts this account:"
        print_error "  Role ARN: $role_arn"
        print_error "  Must trust: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo 'current identity')"
        return 1
    fi

    # Extract credentials
    local access_key=$(echo "$credentials" | jq -r '.AccessKeyId')
    local secret_key=$(echo "$credentials" | jq -r '.SecretAccessKey')
    local session_token=$(echo "$credentials" | jq -r '.SessionToken')

    # Export as environment variables for this account's operations
    export AWS_ACCESS_KEY_ID="$access_key"
    export AWS_SECRET_ACCESS_KEY="$secret_key"
    export AWS_SESSION_TOKEN="$session_token"

    return 0
}

# Function to restore primary account credentials
restore_primary_credentials() {
    # Unset temporary credentials to return to primary account
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
    unset AWS_PROFILE
}

# Function to discover accounts from AWS Organizations
discover_org_accounts() {
    local filter="$1"
    local discovered_accounts=()

    # Send info messages to stderr so they don't interfere with the account list output
    print_info "Discovering accounts from AWS Organizations..." >&2

    # Check if Organizations is accessible
    if ! aws organizations describe-organization &>/dev/null; then
        print_error "Cannot access AWS Organizations" >&2
        print_error "Ensure you have organizations:Describe* permissions" >&2
        print_error "and are running from the management account" >&2
        return 1
    fi

    # Fetch all accounts based on filter
    case "$filter" in
        all)
            # All active accounts
            print_info "Discovering all active accounts in organization..." >&2
            discovered_accounts=($(aws organizations list-accounts \
                --query 'Accounts[?Status==`ACTIVE`].Id' \
                --output text))
            ;;
        ou:*)
            # Specific organizational unit
            local ou_id="${filter#ou:}"
            print_info "Discovering accounts in OU: $ou_id..." >&2
            discovered_accounts=($(aws organizations list-accounts-for-parent \
                --parent-id "$ou_id" \
                --query 'Accounts[?Status==`ACTIVE`].Id' \
                --output text))
            ;;
        Name=*)
            # Filter by account name pattern
            local pattern="${filter#Name=}"
            print_info "Discovering accounts matching name pattern: $pattern..." >&2
            # Convert wildcard to regex
            pattern="${pattern//\*/.*}"
            local accounts_json=$(aws organizations list-accounts \
                --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
                --output json)
            discovered_accounts=($(echo "$accounts_json" | \
                jq -r ".[] | select(.[1] | test(\"$pattern\")) | .[0]"))
            ;;
        Status=*)
            # Filter by status
            local status="${filter#Status=}"
            print_info "Discovering accounts with status: $status..." >&2
            discovered_accounts=($(aws organizations list-accounts \
                --query "Accounts[?Status==\`$status\`].Id" \
                --output text))
            ;;
        *)
            print_error "Invalid organization filter: $filter" >&2
            print_error "Valid formats: all, ou:ou-xxx, Name=pattern, Status=ACTIVE" >&2
            return 1
            ;;
    esac

    if [ $? -ne 0 ]; then
        print_error "Failed to discover organization accounts" >&2
        return 1
    fi

    # Filter out the current account (it's the primary)
    local current_account=$(aws sts get-caller-identity --query Account --output text)
    discovered_accounts=($(printf '%s\n' "${discovered_accounts[@]}" | grep -v "^${current_account}$"))

    if [ ${#discovered_accounts[@]} -eq 0 ]; then
        print_warning "No additional accounts discovered" >&2
        return 0
    fi

    print_info "Discovered ${#discovered_accounts[@]} additional account(s)" >&2

    # Get account names for display
    local accounts_json=$(aws organizations list-accounts \
        --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
        --output json)
    for acc_id in "${discovered_accounts[@]}"; do
        local acc_name=$(echo "$accounts_json" | jq -r ".[] | select(.[0] == \"$acc_id\") | .[1]")
        print_info "  - $acc_id ($acc_name)" >&2
    done

    # Return via echo to stdout (only account IDs, everything else went to stderr)
    echo "${discovered_accounts[@]}"
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

# Function to create IAM role for cross-account IAM user access
create_iam_role_for_user_mode() {
    local primary_account_id="$1"

    print_info "Creating IAM role '${ROLE_NAME}' for cross-account IAM user access..."

    if resource_exists "role" "$ROLE_NAME"; then
        print_info "IAM role '${ROLE_NAME}' already exists - will check and add missing policies"
        return 0
    fi

    # Create trust policy that trusts the IAM user from primary account
    local trust_policy_file="/tmp/frugal-trust-policy-user-$$.json"
    cat > "$trust_policy_file" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${primary_account_id}:user/${ROLE_NAME}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    if aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$trust_policy_file" \
        --description "Read-only access for Frugal monitoring via IAM user from account $primary_account_id" \
        --tags "Key=Purpose,Value=FrugalIntegration" "Key=CreatedBy,Value=frugal-aws-setup"; then
        print_info "IAM role created successfully"
        rm -f "$trust_policy_file"
    else
        print_error "Failed to create IAM role"
        rm -f "$trust_policy_file"
        return 1
    fi
}

# Function to create IAM role for cross-account WIF access (trusts primary role)
create_iam_role_wif_cross_account() {
    local primary_account_id="$1"

    print_info "Creating IAM role '${ROLE_NAME}' for cross-account access (trusts primary role)..."

    if resource_exists "role" "$ROLE_NAME"; then
        print_info "IAM role '${ROLE_NAME}' already exists - will check and add missing policies"
        return 0
    fi

    # Create trust policy that trusts the PRIMARY role (not GCP directly)
    local trust_policy_file="/tmp/frugal-trust-policy-cross-account-$$.json"
    cat > "$trust_policy_file" << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${primary_account_id}:role/${ROLE_NAME}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    if aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$trust_policy_file" \
        --description "Read-only access for Frugal monitoring via role chaining from account $primary_account_id" \
        --tags "Key=Purpose,Value=FrugalIntegration" "Key=CreatedBy,Value=frugal-aws-setup"; then
        print_info "IAM role created successfully"
        rm -f "$trust_policy_file"
    else
        print_error "Failed to create IAM role"
        rm -f "$trust_policy_file"
        return 1
    fi
}

# Function to add AssumeRole permissions to primary role for accessing additional accounts
add_assume_role_permissions() {
    local role_name="$1"
    local policy_name="FrugalCrossAccountAssumeRole"

    print_info "Adding AssumeRole permissions to primary role for cross-account access..."

    # Check if inline policy already exists
    if aws iam get-role-policy --role-name "$role_name" --policy-name "$policy_name" &>/dev/null; then
        print_info "AssumeRole policy already exists on primary role"
        return 0
    fi

    # Create inline policy that allows assuming the same role name in any account
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "sts:AssumeRole",
                "Resource": "arn:aws:iam::*:role/'$role_name'"
            }
        ]
    }'

    if aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "$policy_name" \
        --policy-document "$policy_document"; then
        print_info "AssumeRole permissions added to primary role"
    else
        print_error "Failed to add AssumeRole permissions to primary role"
        return 1
    fi
}

# Function to add AssumeRole permissions to primary IAM user for accessing additional accounts
add_assume_role_permissions_to_user() {
    local user_name="$1"
    local policy_name="FrugalCrossAccountAssumeRole"

    print_info "Adding AssumeRole permissions to IAM user for cross-account access..."

    # Check if inline policy already exists
    if aws iam get-user-policy --user-name "$user_name" --policy-name "$policy_name" &>/dev/null; then
        print_info "AssumeRole policy already exists on IAM user"
        return 0
    fi

    # Create inline policy that allows assuming the same role name in any account
    local policy_document='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "sts:AssumeRole",
                "Resource": "arn:aws:iam::*:role/'$user_name'"
            }
        ]
    }'

    if aws iam put-user-policy \
        --user-name "$user_name" \
        --policy-name "$policy_name" \
        --policy-document "$policy_document"; then
        print_info "AssumeRole permissions added to IAM user"
    else
        print_error "Failed to add AssumeRole permissions to IAM user"
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
    local key_output=$(aws iam create-access-key --user-name "$ROLE_NAME" --output json 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Extract credentials
        local access_key_id=$(echo "$key_output" | jq -r '.AccessKey.AccessKeyId' 2>/dev/null)
        local secret_access_key=$(echo "$key_output" | jq -r '.AccessKey.SecretAccessKey' 2>/dev/null)

        # Validate we got valid credentials
        if [ -z "$access_key_id" ] || [ "$access_key_id" = "null" ] || [ -z "$secret_access_key" ] || [ "$secret_access_key" = "null" ]; then
            print_error "Failed to extract credentials from AWS response"
            print_error "Response: $key_output"
            return 1
        fi

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
        echo
        print_info "Access Key ID: ${access_key_id}"
    else
        # Check if it's a LimitExceeded error
        if echo "$key_output" | grep -q "LimitExceeded"; then
            print_error "Cannot create access key: AWS limit of 2 access keys per user already reached"
            print_error "Please delete an existing access key first:"
            print_error "  aws iam list-access-keys --user-name $ROLE_NAME"
            print_error "  aws iam delete-access-key --user-name $ROLE_NAME --access-key-id <KEY_ID>"
            print_error ""
            print_error "Or use the existing credentials file if you have it"
        else
            print_error "Failed to create access keys: $key_output"
        fi
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
        # Don't add to global array - will be attached separately per account
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
        # Don't add to global array - will be attached separately per account
    else
        print_error "Failed to create custom extended permissions policy"
        return 1
    fi
}

# Function to attach custom extended policy for current account
attach_custom_policy() {
    local resource_type="$1"  # "role" or "user"
    local resource_name="$2"
    local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/FrugalExtendedReadOnly"

    # Check if already attached
    local current_policies=$(get_current_policies "$resource_type" "$resource_name")
    if echo "$current_policies" | grep -q "^${policy_arn}$"; then
        print_info "Custom policy already attached: FrugalExtendedReadOnly (skipping)"
        return 0
    fi

    print_info "Attaching custom policy: FrugalExtendedReadOnly"
    if [ "$resource_type" = "role" ]; then
        if aws iam attach-role-policy \
            --role-name "$resource_name" \
            --policy-arn "$policy_arn"; then
            return 0
        else
            print_error "Failed to attach custom policy FrugalExtendedReadOnly"
            return 1
        fi
    else
        if aws iam attach-user-policy \
            --user-name "$resource_name" \
            --policy-arn "$policy_arn"; then
            return 0
        else
            print_error "Failed to attach custom policy FrugalExtendedReadOnly"
            return 1
        fi
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
        echo "  AssumeRole: ${ASSUME_ROLE_NAME}"
        echo

        # Try to get account names from Organizations if available
        local accounts_json=""
        if aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output json &>/dev/null 2>&1; then
            accounts_json=$(aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output json 2>/dev/null)
        fi

        for acc_id in "${ADDITIONAL_ACCOUNTS[@]}"; do
            if [ -n "$accounts_json" ]; then
                local acc_name=$(echo "$accounts_json" | jq -r ".[] | select(.[0] == \"$acc_id\") | .[1]" 2>/dev/null)
                if [ -n "$acc_name" ]; then
                    echo "  - ${acc_id} (${acc_name})"
                else
                    echo "  - ${acc_id}"
                fi
            else
                echo "  - ${acc_id}"
            fi
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
        echo "IAM Role ARN (this is the ONLY thing you need to provide):"
        echo "  arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
    else
        echo "AWS Credentials (paste these into your product):"
        echo
        if [ -f "$CREDENTIALS_FILE" ]; then
            # Extract and display individual fields
            local access_key=$(jq -r '.AccessKeyId' "$CREDENTIALS_FILE" 2>/dev/null)
            local secret_key=$(jq -r '.SecretAccessKey' "$CREDENTIALS_FILE" 2>/dev/null)
            local region=$(jq -r '.Region' "$CREDENTIALS_FILE" 2>/dev/null)

            if [ -n "$access_key" ] && [ "$access_key" != "null" ]; then
                echo "  Access Key ID:"
                echo "    ${access_key}"
                echo
                echo "  Secret Access Key:"
                echo "    ${secret_key}"
                echo
                echo "  Region:"
                echo "    ${region}"
            else
                echo "  (Access keys not available - see credentials file: ${CREDENTIALS_FILE})"
            fi
        else
            echo "  (Credentials file not found: ${CREDENTIALS_FILE})"
        fi
    fi

    echo
    echo "Primary Account ID:"
    echo "  ${ACCOUNT_ID}"

    # Display additional account info if any were configured
    if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
        echo
        echo "Additional Accounts Configured:"
        for acc_id in "${ADDITIONAL_ACCOUNTS[@]}"; do
            echo "  - ${acc_id}"
        done
    fi

    echo
    print_info "How Multi-Account Access Works:"
    echo "  1. Your product authenticates using the primary role/credentials above"
    echo "  2. Use organizations:ListAccounts to discover all available accounts"
    echo "  3. For each account, assume: arn:aws:iam::{ACCOUNT_ID}:role/${ROLE_NAME}"
    echo "  4. All roles have the same name (${ROLE_NAME}), so you can construct ARNs dynamically"

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
    local is_primary="${2:-false}"

    if [[ "$is_primary" = true ]]; then
        print_info "Setting up resources in PRIMARY account: ${target_account_id}..."
        # Primary account uses current credentials (no switching needed)
    else
        print_info "Setting up resources in additional account: ${target_account_id}..."
        # Assume role in additional account
        if ! assume_role_for_account "$target_account_id" "$ASSUME_ROLE_NAME"; then
            print_error "Skipping account ${target_account_id} - AssumeRole failed"
            restore_primary_credentials
            return 1
        fi
    fi

    # Setup resources based on mode
    local saved_account_id="$ACCOUNT_ID"
    ACCOUNT_ID="$target_account_id"

    if [ "$WIF_MODE" = true ]; then
        # WIF mode
        if [[ "$is_primary" = true ]]; then
            # Primary account: Role trusts GCP service account
            create_iam_role_wif
            create_extended_policy
            attach_policies "role" "$ROLE_NAME"
            attach_custom_policy "role" "$ROLE_NAME"

            # Add permission to assume roles in additional accounts (for role chaining)
            if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
                add_assume_role_permissions "$ROLE_NAME"
            fi
        else
            # Additional account: Role trusts PRIMARY role (not GCP directly)
            create_iam_role_wif_cross_account "$saved_account_id"
            create_extended_policy
            attach_policies "role" "$ROLE_NAME"
            attach_custom_policy "role" "$ROLE_NAME"
        fi

        # Store the role ARN
        local role_arn="arn:aws:iam::${target_account_id}:role/${ROLE_NAME}"
        CONFIGURED_ROLE_ARNS+=("$role_arn")
    else
        # IAM user mode
        if [[ "$is_primary" = true ]]; then
            # Primary account: Create IAM user
            create_iam_user
            create_extended_policy
            attach_policies "user" "$ROLE_NAME"
            attach_custom_policy "user" "$ROLE_NAME"

            # Add permission to assume roles in additional accounts (for role chaining)
            if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
                add_assume_role_permissions_to_user "$ROLE_NAME"
            fi

            create_access_keys
        else
            # Additional account: Create IAM role that trusts the IAM user from primary account
            print_info "Creating cross-account IAM role for IAM user access"
            create_iam_role_for_user_mode "$saved_account_id"
            create_extended_policy
            attach_policies "role" "$ROLE_NAME"
            attach_custom_policy "role" "$ROLE_NAME"

            # Store the role ARN
            local role_arn="arn:aws:iam::${target_account_id}:role/${ROLE_NAME}"
            CONFIGURED_ROLE_ARNS+=("$role_arn")
        fi
    fi

    # Restore ACCOUNT_ID
    ACCOUNT_ID="$saved_account_id"

    print_info "✓ Setup complete for account ${target_account_id}"
    echo

    # Clean up credentials if this was an additional account
    if [[ "$is_primary" != true ]]; then
        restore_primary_credentials
    fi
}

# Main execution
main() {
    if [ "$UNDO_MODE" = true ]; then
        undo_main
    else
        print_info "Starting AWS IAM setup..."

        check_aws_cli
        check_jq
        check_auth

        # Check if running from management account for multi-account setup
        check_management_account

        # Discover accounts from AWS Organizations if specified
        if [[ -n "$ORG_FILTER" ]]; then
            print_info "Discovering accounts from AWS Organizations with filter: $ORG_FILTER"
            local org_accounts=($(discover_org_accounts "$ORG_FILTER"))
            if [ $? -eq 0 ] && [ ${#org_accounts[@]} -gt 0 ]; then
                # Add discovered accounts to ADDITIONAL_ACCOUNTS
                ADDITIONAL_ACCOUNTS+=("${org_accounts[@]}")
                print_info "Added ${#org_accounts[@]} account(s) from organization"
            fi
            echo
        fi

        display_plan

        # Setup primary account
        setup_single_account "$ACCOUNT_ID" true

        # Setup additional accounts
        if [[ ${#ADDITIONAL_ACCOUNTS[@]} -gt 0 ]]; then
            echo
            print_info "Processing ${#ADDITIONAL_ACCOUNTS[@]} additional account(s)..."
            print_info "Using AssumeRole with role name: ${ASSUME_ROLE_NAME}"
            for acc_id in "${ADDITIONAL_ACCOUNTS[@]}"; do
                setup_single_account "$acc_id" false
            done
        fi

        display_summary
    fi
}

# Run the main function
main