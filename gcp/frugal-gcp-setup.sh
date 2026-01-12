#!/bin/bash

# Script to generate Google Cloud credentials with read-only access to various services
# Supports both service account key creation and service account impersonation
# Usage: ./frugal-gcp-credentials-simple.sh <service-account-name> <project-id> [options]

set -euo pipefail

# Frugal GCP source service account for impersonation will be passed as parameter
# Get this from the Frugal UI: Setup → GCP Integration → Copy the trusted service account

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
    echo "Usage: $0 <service-account-name> <project-id> [options]"
    echo ""
    echo "Options:"
    echo "  --impersonate <frugal-service-account>  Set up impersonation (recommended)"
    echo "  --additional-projects <project-ids>     Comma-separated list of additional project IDs"
    echo "  --undo                                   Remove service account and permissions"
    echo "  [key-file-path]                          Path for service account key (direct auth mode)"
    echo ""
    echo "Examples:"
    echo "  Single project with impersonation:"
    echo "    $0 readonly-monitor my-project --impersonate frugal-sa@project.iam.gserviceaccount.com"
    echo ""
    echo "  Multiple projects with impersonation:"
    echo "    $0 readonly-monitor my-project --impersonate frugal-sa@project.iam.gserviceaccount.com \\"
    echo "       --additional-projects 'project-2,project-3,project-4'"
    echo ""
    echo "  Direct authentication with key:"
    echo "    $0 readonly-monitor my-project /path/to/key.json"
    echo ""
    echo "  Undo (remove service account):"
    echo "    $0 readonly-monitor my-project --undo"
    echo ""
    echo "Get the Frugal service account from: Frugal UI → Setup → GCP Integration"
}

# Check if required arguments are provided
if [ $# -lt 2 ]; then
    print_error "Insufficient arguments"
    show_usage
    exit 1
fi

SERVICE_ACCOUNT_NAME="$1"
PROJECT_ID="$2"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Initialize variables
GCP_SOURCE_SA=""
ADDITIONAL_PROJECTS=()
UNDO_MODE=false
IMPERSONATE_MODE=false
KEY_FILE_PATH=""

# Parse arguments
shift 2  # Remove first two args (sa-name and project-id)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --undo)
            UNDO_MODE=true
            KEY_FILE_PATH="${SERVICE_ACCOUNT_NAME}-key.json"
            shift
            ;;
        --impersonate)
            IMPERSONATE_MODE=true
            GCP_SOURCE_SA="$2"
            if [[ -z "$GCP_SOURCE_SA" ]]; then
                print_error "Frugal service account required after --impersonate"
                print_error "Get this from the Frugal UI: Setup → GCP Integration"
                show_usage
                exit 1
            fi
            # Validate service account email format
            if [[ ! "$GCP_SOURCE_SA" =~ ^.+@.+\.iam\.gserviceaccount\.com$ ]]; then
                print_error "Invalid service account format: $GCP_SOURCE_SA"
                print_error "Expected format: name@project.iam.gserviceaccount.com"
                exit 1
            fi
            shift 2
            ;;
        --additional-projects)
            IFS=',' read -ra ADDITIONAL_PROJECTS <<< "$2"
            shift 2
            ;;
        *)
            # Assume it's a key file path (direct auth mode)
            KEY_FILE_PATH="$1"
            shift
            ;;
    esac
done

# Set default key path if not specified and not in impersonate mode
if [[ "$IMPERSONATE_MODE" = false ]] && [[ -z "$KEY_FILE_PATH" ]]; then
    KEY_FILE_PATH="${SERVICE_ACCOUNT_NAME}-key.json"
fi

# Define read-only roles for various services with descriptions
# Format: "role|description"
READONLY_ROLES_WITH_DESC=(
    # Logging
    "roles/logging.viewer|View logs and log-based metrics"
    
    # Monitoring/Metrics
    "roles/monitoring.viewer|View metrics, dashboards, and alerting policies"
    
    # Cloud Storage (metadata only) - using custom role
    "projects/${PROJECT_ID}/roles/storage.metadata.reader|List buckets and view metadata (no object content access)"
    
    # BigQuery
    "roles/bigquery.metadataViewer|View dataset/table metadata and structure (no data access)"
    "roles/bigquery.resourceViewer|View BigQuery job history, costs, and performance stats"
    "roles/bigquery.dataViewer|View and query datasets, tables, and table data"
    "roles/bigquery.jobUser|Run BigQuery jobs and queries"
    
    # Cloud Spanner
    "roles/spanner.viewer|View Spanner instances, databases, and schemas (no data)"
    
    # Pub/Sub
    "roles/pubsub.viewer|View topics, subscriptions, and snapshots (no messages)"
    
    # General project viewer
    "roles/viewer|Read-only access to all project resources"
)

# Extract just the role names for easy access
READONLY_ROLES=()
for role_desc in "${READONLY_ROLES_WITH_DESC[@]}"; do
    READONLY_ROLES+=("${role_desc%%|*}")
done

# Function to check if gcloud is installed
check_gcloud() {
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud CLI is not installed. Please install it first:"
        echo "  https://cloud.google.com/sdk/docs/install"
        exit 1
    fi
}

# Function to check if user is authenticated
check_auth() {
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        print_error "No active gcloud authentication found. Please run:"
        echo "  gcloud auth login"
        exit 1
    fi
}

# Function to set the project
set_project() {
    print_info "Setting project to ${PROJECT_ID}..."
    if ! gcloud config set project "${PROJECT_ID}" 2>/dev/null; then
        print_error "Failed to set project. Make sure the project ID is correct."
        exit 1
    fi
}

# Function to check and enable required APIs
check_and_enable_apis() {
    local required_apis=("iam.googleapis.com" "cloudbilling.googleapis.com" "cloudresourcemanager.googleapis.com" "aiplatform.googleapis.com")
    
    print_info "Checking required APIs..."
    
    for api in "${required_apis[@]}"; do
        # Check if API is enabled
        if gcloud services list --enabled --filter="config.name:${api}" --format="value(config.name)" | grep -q "${api}"; then
            print_info "API ${api} is already enabled"
        else
            print_info "Enabling API ${api}..."
            if gcloud services enable "${api}"; then
                print_info "API ${api} enabled successfully"
                # Wait a bit for the API to be fully enabled
                sleep 5
            else
                print_error "Failed to enable API ${api}"
                print_info "You may need to enable this API manually:"
                echo "  gcloud services enable ${api}"
                exit 1
            fi
        fi
    done
}

# Global variable to store found billing tables
FOUND_BILLING_TABLES=()

# Function to search for billing tables in a specific project
search_billing_tables_in_project() {
    local target_project="$1"
    local found_tables=()

    # Check if BigQuery API is enabled in this project
    if ! gcloud services list --enabled --project="${target_project}" --filter="config.name:bigquery.googleapis.com" --format="value(config.name)" 2>/dev/null | grep -q "bigquery.googleapis.com"; then
        print_info "  BigQuery API is not enabled in project ${target_project}"
        return
    fi

    print_info "  Searching for billing export tables in project ${target_project}..."

    # Try to list all datasets in the project
    local all_datasets=""
    if command -v bq &>/dev/null; then
        all_datasets=$(bq ls --project_id="${target_project}" --format=json 2>/dev/null | jq -r '.[].datasetReference.datasetId' 2>/dev/null || echo "")
    else
        all_datasets=$(gcloud alpha bq datasets list --project="${target_project}" --format="value(datasetReference.datasetId)" 2>/dev/null || echo "")
    fi

    if [ -z "${all_datasets}" ]; then
        print_info "    No datasets found in project ${target_project}"
        return
    fi

    # Check each dataset for billing tables
    while IFS= read -r dataset; do
        [ -z "${dataset}" ] && continue

        # Try to list tables in the dataset
        local tables=""
        if command -v bq &>/dev/null; then
            tables=$(bq ls --project_id="${target_project}" --dataset_id="${dataset}" --format=json 2>/dev/null | jq -r '.[].tableReference.tableId' 2>/dev/null || echo "")
        else
            tables=$(gcloud alpha bq tables list --project="${target_project}" --dataset="${dataset}" --format="value(tableReference.tableId)" 2>/dev/null || echo "")
        fi

        [ -z "${tables}" ] && continue

        # Check for billing export tables
        while IFS= read -r table; do
            [ -z "${table}" ] && continue
            local table_lower=$(echo "${table}" | tr '[:upper:]' '[:lower:]')

            # Check if this looks like a billing export table
            if [[ "${table_lower}" == *"billing_export"* ]] || [[ "${table_lower}" == *"billing"* && "${table_lower}" == *"export"* ]]; then
                local full_table_name="${target_project}.${dataset}.${table}"
                found_tables+=("${full_table_name}")

                echo
                print_info "    Found BigQuery billing export table:"
                echo "      Full table name: ${full_table_name}"
                echo "      Project: ${target_project}"
                echo "      Dataset: ${dataset}"
                echo "      Table: ${table}"

                # Check if table name contains a billing account ID
                if [[ "${table}" =~ [0-9A-F]{6}_[0-9A-F]{6}_[0-9A-F]{6} ]]; then
                    echo "      Billing Account ID in table name: ${BASH_REMATCH[0]}"
                fi

                # Add to global array
                FOUND_BILLING_TABLES+=("${full_table_name}")
            fi
        done <<< "${tables}"
    done <<< "${all_datasets}"

    if [ ${#found_tables[@]} -eq 0 ]; then
        print_info "    No billing export tables found in project ${target_project}"
    fi
}

# Function to check BigQuery billing export
check_billing_export() {
    print_info "Checking BigQuery billing export configuration..."

    # Check if cloudbilling API is enabled
    if ! gcloud services list --enabled --filter="config.name:cloudbilling.googleapis.com" --format="value(config.name)" | grep -q "cloudbilling.googleapis.com"; then
        print_warning "Cloud Billing API is not enabled. Skipping billing export check."
        return
    fi

    # Get the billing account for this project
    local billing_account=$(gcloud billing projects describe "${PROJECT_ID}" --format="value(billingAccountName)" 2>/dev/null || echo "")

    if [ -z "${billing_account}" ]; then
        print_warning "No billing account associated with this project."
        return
    fi

    local billing_account_id="${billing_account##*/}"
    print_info "Found billing account: ${billing_account_id}"

    # Check if the user has permission to view billing exports
    if ! gcloud billing accounts describe "${billing_account_id}" &>/dev/null; then
        print_warning "No permission to view billing account details. Skipping billing export check."
        return
    fi

    echo
    echo "To check BigQuery billing export configuration:"
    echo "  Visit: https://console.cloud.google.com/billing/${billing_account_id}/export"
    echo

    # Reset global array
    FOUND_BILLING_TABLES=()

    # Search in primary project
    search_billing_tables_in_project "${PROJECT_ID}"

    # Search in additional projects
    if [[ ${#ADDITIONAL_PROJECTS[@]} -gt 0 ]]; then
        for additional_project in "${ADDITIONAL_PROJECTS[@]}"; do
            search_billing_tables_in_project "${additional_project}"
        done
    fi

    # Summary
    echo
    if [ ${#FOUND_BILLING_TABLES[@]} -gt 0 ]; then
        print_info "Summary: Found ${#FOUND_BILLING_TABLES[@]} billing export table(s) across all projects"
        echo "The service account has been granted BigQuery Data Viewer role to access these tables."
    else
        print_info "No billing export tables found in any configured project."
        echo "Billing exports might be configured in a different project."
        echo "Check the billing export configuration at:"
        echo "  https://console.cloud.google.com/billing/${billing_account_id}/export"
    fi
}

# Function to create custom storage metadata reader role
create_custom_storage_role() {
    local target_project="${1:-${PROJECT_ID}}"
    local role_name="storage.metadata.reader"
    local role_id="projects/${target_project}/roles/${role_name}"

    print_info "Checking for custom storage metadata reader role in project ${target_project}..."

    # Check if custom role already exists
    if gcloud iam roles describe "${role_name}" --project="${target_project}" &>/dev/null; then
        print_info "Custom role 'storage.metadata.reader' already exists in ${target_project}"
    else
        print_info "Creating custom role 'storage.metadata.reader' in ${target_project}..."
        if gcloud iam roles create "${role_name}" \
            --project="${target_project}" \
            --title="Storage Metadata Reader" \
            --description="Read GCS bucket and object metadata without content access" \
            --permissions="storage.buckets.get,storage.buckets.list,storage.objects.list,storage.objects.get" \
            --quiet; then
            print_info "Custom role created successfully in ${target_project}"
        else
            print_error "Failed to create custom storage role in ${target_project}"
            print_info "You may need to manually create this role or use an alternative"
        fi
    fi
}

# Function to create service account
create_service_account() {
    print_info "Checking service account '${SERVICE_ACCOUNT_NAME}'..."
    
    # Check if service account already exists
    if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" &>/dev/null; then
        print_info "Service account '${SERVICE_ACCOUNT_NAME}' already exists - will check and add missing roles"
    else
        # Create the service account
        print_info "Creating new service account '${SERVICE_ACCOUNT_NAME}'..."
        if ! gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
            --display-name="Read-only monitoring service account" \
            --description="Service account with read-only access to logs, metrics, storage metadata, BigQuery, and Spanner"; then
            print_error "Failed to create service account"
            exit 1
        fi
        print_info "Service account created successfully"
    fi
}

# Function to get current roles for service account
get_current_roles() {
    gcloud projects get-iam-policy "${PROJECT_ID}" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
        --format="value(bindings.role)" 2>/dev/null || echo ""
}

# Function to grant roles to service account in a specific project
grant_roles_to_project() {
    local target_project="$1"
    local is_primary="${2:-false}"

    if [[ "$is_primary" = true ]]; then
        print_info "Granting roles in PRIMARY project: ${target_project}..."
    else
        print_info "Granting roles in additional project: ${target_project}..."
        # Create custom storage role in additional project if needed
        create_custom_storage_role "${target_project}"
    fi

    # Get current roles for this project
    local current_roles=$(gcloud projects get-iam-policy "${target_project}" \
        --flatten="bindings[].members" \
        --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
        --format="value(bindings.role)" 2>/dev/null || echo "")

    local roles_added=0
    local roles_skipped=0

    for role in "${READONLY_ROLES[@]}"; do
        # Replace the primary PROJECT_ID with the target project ID for custom roles
        # This handles the case where custom roles are scoped to specific projects
        local expanded_role="$role"
        if [[ "$role" == projects/${PROJECT_ID}/roles/* ]]; then
            # This is a custom role in the primary project, adapt it for the target project
            local role_suffix="${role#projects/${PROJECT_ID}/roles/}"
            expanded_role="projects/${target_project}/roles/${role_suffix}"
        fi

        if echo "${current_roles}" | grep -q "^${expanded_role}$"; then
            print_info "  ✓ ${expanded_role} (already assigned)"
            ((roles_skipped++))
        else
            print_info "  + Granting ${expanded_role}..."
            if gcloud projects add-iam-policy-binding "${target_project}" \
                --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
                --role="${expanded_role}" \
                --quiet &>/dev/null; then
                ((roles_added++))
            else
                print_error "  ✗ Failed to grant ${expanded_role}"
            fi
        fi
    done

    print_info "  Summary: ${roles_added} new, ${roles_skipped} existing"
}

# Function to grant roles to service account
grant_roles() {
    print_info "Checking and granting read-only roles to service account..."
    echo

    # Grant roles in primary project
    grant_roles_to_project "${PROJECT_ID}" true

    # Grant roles in additional projects
    if [[ ${#ADDITIONAL_PROJECTS[@]} -gt 0 ]]; then
        echo
        print_info "Processing ${#ADDITIONAL_PROJECTS[@]} additional project(s)..."
        for additional_project in "${ADDITIONAL_PROJECTS[@]}"; do
            # Verify project exists and is accessible
            if gcloud projects describe "${additional_project}" &>/dev/null; then
                grant_roles_to_project "${additional_project}" false
            else
                print_error "Cannot access project: ${additional_project}"
                print_warning "Skipping this project. Check project ID and permissions."
            fi
        done
    fi
}

# Function to create and download key
create_key() {
    print_info "Creating service account key..."
    
    # Check if key file already exists
    if [ -f "${KEY_FILE_PATH}" ]; then
        print_warning "Key file '${KEY_FILE_PATH}' already exists."
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping key creation"
            return
        fi
    fi
    
    # Create the key
    if ! gcloud iam service-accounts keys create "${KEY_FILE_PATH}" \
        --iam-account="${SERVICE_ACCOUNT_EMAIL}"; then
        print_error "Failed to create service account key"
        exit 1
    fi
    
    # Set appropriate permissions on the key file
    chmod 600 "${KEY_FILE_PATH}"
    
    print_info "Service account key saved to: ${KEY_FILE_PATH}"
}

# Function to setup service account impersonation for GCP-to-GCP
setup_service_account_impersonation() {
    print_info "Setting up Service Account Impersonation..."
    
    # Grant the Frugal source SA permission to impersonate the target SA
    print_info "Granting impersonation permission to ${GCP_SOURCE_SA}..."
    print_info "Target service account: ${SERVICE_ACCOUNT_EMAIL}"
    
    if ! gcloud iam service-accounts add-iam-policy-binding "${SERVICE_ACCOUNT_EMAIL}" \
        --member="serviceAccount:${GCP_SOURCE_SA}" \
        --role="roles/iam.serviceAccountTokenCreator"; then
        print_error "Failed to grant impersonation permission"
        exit 1
    fi
    
    print_info "Service Account Impersonation setup complete"
}

# Function to display summary
display_summary() {
    echo
    print_info "=== Setup Complete ==="
    echo "Service Account: ${SERVICE_ACCOUNT_EMAIL}"

    if [ "${IMPERSONATE_MODE}" = true ]; then
        echo "Authentication Method: Service Account Impersonation"
        echo "Frugal Service Account: ${GCP_SOURCE_SA}"
    else
        echo "Authentication Method: Service Account Key"
        echo "Key File: ${KEY_FILE_PATH}"
    fi

    echo
    echo "Projects configured:"
    echo "  PRIMARY: ${PROJECT_ID}"
    if [[ ${#ADDITIONAL_PROJECTS[@]} -gt 0 ]]; then
        for proj in "${ADDITIONAL_PROJECTS[@]}"; do
            echo "  ADDITIONAL: ${proj}"
        done
    fi

    echo
    echo "Roles assigned to service account in PRIMARY project:"
    local current_roles=$(get_current_roles)
    if [ -n "${current_roles}" ]; then
        echo "${current_roles}" | while read -r role; do
            echo "  - ${role}"
        done
    else
        echo "  (none)"
    fi
    echo
    echo "To add more roles, edit the READONLY_ROLES array in this script and run again."
    
    # Check billing export configuration
    echo
    check_billing_export
    
    # Show next steps
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    print_info "Next steps: Copy and paste the following into the Frugal GCP Setup:"
    echo

    if [ "${IMPERSONATE_MODE}" = true ]; then
        echo "Service Account Email:"
        echo "  ${SERVICE_ACCOUNT_EMAIL}"
    else
        echo "Key file location: ${KEY_FILE_PATH}"
        echo
        echo "To display the contents:"
        echo "  cat ${KEY_FILE_PATH}"
    fi

    echo
    echo "Primary Project ID:"
    echo "  ${PROJECT_ID}"

    # Display found billing tables if any
    if [ ${#FOUND_BILLING_TABLES[@]} -gt 0 ]; then
        echo
        echo "BigQuery Billing Export Table(s) Found:"
        for table in "${FOUND_BILLING_TABLES[@]}"; do
            echo "  ${table}"
        done
    fi

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to print a formatted table row
print_table_row() {
    local status="$1"
    local role="$2"
    local desc="$3"
    printf "│ %-4s │ %-60s │ %-60s │\n" "$status" "$role" "$desc"
}

# Function to print table header
print_table_header() {
    echo "┌────┬──────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────────┐"
    echo "│    │ Role                                                         │ Description                                                  │"
    echo "├────┼──────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────┤"
}

# Function to print table footer
print_table_footer() {
    echo "└────┴──────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────────┘"
}

# Function to display plan and get confirmation
display_plan() {
    echo
    print_info "=== Google Cloud Service Account Setup Plan ==="
    echo
    echo "Primary Project: ${PROJECT_ID}"
    echo "Service Account Name: ${SERVICE_ACCOUNT_NAME}"
    echo "Service Account Email: ${SERVICE_ACCOUNT_EMAIL}"

    if [[ ${#ADDITIONAL_PROJECTS[@]} -gt 0 ]]; then
        echo "Additional Projects (${#ADDITIONAL_PROJECTS[@]}):"
        for proj in "${ADDITIONAL_PROJECTS[@]}"; do
            echo "  - ${proj}"
        done
    fi

    if [ "${IMPERSONATE_MODE}" = true ]; then
        echo "Authentication Method: Service Account Impersonation"
        echo "Frugal Service Account: ${GCP_SOURCE_SA}"
    else
        echo "Authentication Method: Service Account Key"
        echo "Key File Path: ${KEY_FILE_PATH}"
    fi
    echo
    
    # Check if service account exists
    if gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" &>/dev/null; then
        print_warning "Service account already exists"
        local current_roles=$(get_current_roles)
        echo
        echo "Roles to be checked/added:"
        print_table_header
        for role_desc in "${READONLY_ROLES_WITH_DESC[@]}"; do
            local role="${role_desc%%|*}"
            local desc="${role_desc#*|}"
            # Replace PROJECT_ID variable for comparison
            local expanded_role="${role//\$\{PROJECT_ID\}/${PROJECT_ID}}"
            if echo "${current_roles}" | grep -q "^${expanded_role}$"; then
                print_table_row "✓" "$expanded_role" "$desc"
            else
                print_table_row "+" "$expanded_role" "$desc"
            fi
        done
        print_table_footer
    else
        print_info "Service account will be created"
        echo
        echo "Roles to be assigned:"
        print_table_header
        for role_desc in "${READONLY_ROLES_WITH_DESC[@]}"; do
            local role="${role_desc%%|*}"
            local desc="${role_desc#*|}"
            # Replace PROJECT_ID variable
            local expanded_role="${role//\$\{PROJECT_ID\}/${PROJECT_ID}}"
            print_table_row "+" "$expanded_role" "$desc"
        done
        print_table_footer
    fi
    
    echo
    echo "Legend: ✓ = already assigned, + = will be added"
    echo
    read -p "Do you want to proceed with this setup? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled by user"
        exit 0
    fi
}

# Function to remove all role bindings for the service account
remove_role_bindings() {
    print_info "Removing role bindings for service account..."

    # Remove from primary project
    print_info "Removing bindings from PRIMARY project: ${PROJECT_ID}"
    local current_roles=$(get_current_roles)
    local roles_removed=0

    if [ -n "${current_roles}" ]; then
        echo "${current_roles}" | while read -r role; do
            print_info "  Removing role: ${role}"
            if gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
                --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
                --role="${role}" \
                --quiet &>/dev/null; then
                ((roles_removed++))
            else
                print_warning "  Failed to remove role ${role}"
            fi
        done
    else
        print_info "  No roles found to remove in primary project"
    fi

    # Remove from additional projects if they were specified
    if [[ ${#ADDITIONAL_PROJECTS[@]} -gt 0 ]]; then
        echo
        for additional_project in "${ADDITIONAL_PROJECTS[@]}"; do
            print_info "Removing bindings from additional project: ${additional_project}"
            local proj_roles=$(gcloud projects get-iam-policy "${additional_project}" \
                --flatten="bindings[].members" \
                --filter="bindings.members:serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
                --format="value(bindings.role)" 2>/dev/null || echo "")

            if [[ -n "${proj_roles}" ]]; then
                echo "${proj_roles}" | while read -r role; do
                    print_info "  Removing role: ${role}"
                    gcloud projects remove-iam-policy-binding "${additional_project}" \
                        --member="serviceAccount:${SERVICE_ACCOUNT_EMAIL}" \
                        --role="${role}" \
                        --quiet &>/dev/null || print_warning "  Failed to remove ${role}"
                done
            else
                print_info "  No roles found in this project"
            fi
        done
    fi
}

# Function to remove impersonation binding
remove_impersonation_binding() {
    print_info "Checking for impersonation bindings..."
    
    # Check if the Frugal SA has impersonation permission
    if gcloud iam service-accounts get-iam-policy "${SERVICE_ACCOUNT_EMAIL}" \
        --format="json" | jq -r '.bindings[]? | select(.role == "roles/iam.serviceAccountTokenCreator") | .members[]?' | \
        grep -q "serviceAccount:${FRUGAL_GCP_SOURCE_SA}"; then
        
        print_info "Removing impersonation permission for ${FRUGAL_GCP_SOURCE_SA}..."
        if gcloud iam service-accounts remove-iam-policy-binding "${SERVICE_ACCOUNT_EMAIL}" \
            --member="serviceAccount:${FRUGAL_GCP_SOURCE_SA}" \
            --role="roles/iam.serviceAccountTokenCreator" \
            --quiet; then
            print_info "Impersonation permission removed"
        else
            print_warning "Failed to remove impersonation permission"
        fi
    else
        print_info "No impersonation binding found"
    fi
}

# Function to delete service account
delete_service_account() {
    print_info "Deleting service account '${SERVICE_ACCOUNT_NAME}'..."
    
    if gcloud iam service-accounts delete "${SERVICE_ACCOUNT_EMAIL}" \
        --quiet; then
        print_info "Service account deleted successfully"
    else
        print_error "Failed to delete service account"
        return 1
    fi
}

# Function to cleanup key files
cleanup_key_files() {
    if [ -f "${KEY_FILE_PATH}" ]; then
        print_info "Removing key file: ${KEY_FILE_PATH}"
        rm -f "${KEY_FILE_PATH}"
    fi
    
    # Also look for other potential key files
    local key_pattern="${SERVICE_ACCOUNT_NAME}-key*.json"
    local other_keys=$(ls ${key_pattern} 2>/dev/null | grep -v "^${KEY_FILE_PATH}$" || true)
    
    if [ -n "${other_keys}" ]; then
        print_warning "Found other key files for this service account:"
        echo "${other_keys}"
        read -p "Do you want to remove these as well? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f ${key_pattern}
            print_info "Key files removed"
        fi
    fi
}

# Function to display undo plan
display_undo_plan() {
    echo
    print_warning "=== Service Account Removal Plan ==="
    echo
    echo "Project ID: ${PROJECT_ID}"
    echo "Service Account Email: ${SERVICE_ACCOUNT_EMAIL}"
    echo
    
    # Check if service account exists
    if ! gcloud iam service-accounts describe "${SERVICE_ACCOUNT_EMAIL}" &>/dev/null; then
        print_error "Service account does not exist"
        exit 1
    fi
    
    echo "Current roles that will be removed:"
    local current_roles=$(get_current_roles)
    if [ -n "${current_roles}" ]; then
        echo "${current_roles}" | while read -r role; do
            echo "  - ${role}"
        done
    else
        echo "  (none)"
    fi
    
    echo
    echo "Key files that will be removed:"
    if [ -f "${KEY_FILE_PATH}" ]; then
        echo "  - ${KEY_FILE_PATH}"
    fi
    local key_pattern="${SERVICE_ACCOUNT_NAME}-key*.json"
    local other_keys=$(ls ${key_pattern} 2>/dev/null || true)
    if [ -n "${other_keys}" ]; then
        echo "  - Other matching files: ${other_keys}"
    fi
    
    echo
    echo "Impersonation bindings that will be checked:"
    echo "  - ${FRUGAL_GCP_SOURCE_SA} → ${SERVICE_ACCOUNT_EMAIL}"
    
    echo
    print_warning "This action cannot be undone!"
    read -p "Are you sure you want to remove this service account and all its permissions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Removal cancelled by user"
        exit 0
    fi
}

# Function to optionally delete custom role
delete_custom_role() {
    local role_name="storage.metadata.reader"
    
    # Check if custom role exists
    if gcloud iam roles describe "${role_name}" --project="${PROJECT_ID}" &>/dev/null; then
        echo
        read -p "Do you also want to delete the custom 'storage.metadata.reader' role? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting custom role..."
            if gcloud iam roles delete "${role_name}" --project="${PROJECT_ID}" --quiet; then
                print_info "Custom role deleted successfully"
            else
                print_warning "Failed to delete custom role"
            fi
        else
            print_info "Custom role kept (may be used by other service accounts)"
        fi
    fi
}

# Undo/cleanup main function
undo_main() {
    print_info "Starting service account removal process..."
    
    check_gcloud
    check_auth
    set_project
    display_undo_plan
    remove_role_bindings
    remove_impersonation_binding
    delete_service_account
    cleanup_key_files
    delete_custom_role
    
    echo
    print_info "=== Cleanup Complete ==="
    echo "Service account ${SERVICE_ACCOUNT_EMAIL} has been removed"
    echo "All role bindings have been removed"
    echo "Key files have been cleaned up"
    echo "Impersonation bindings have been removed"
}

# Main execution
main() {
    if [ "${UNDO_MODE}" = true ]; then
        undo_main
    else
        print_info "Starting Google Cloud service account setup..."
        
        check_gcloud
        check_auth
        set_project
        check_and_enable_apis
        display_plan
        create_custom_storage_role
        create_service_account
        grant_roles
        
        if [ "${IMPERSONATE_MODE}" = true ]; then
            setup_service_account_impersonation
        else
            create_key
        fi
        
        display_summary
    fi
}

# Run the main function
main