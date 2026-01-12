#!/bin/bash

# Frugal Datadog Setup Script using jq + curl
# Usage: ./frugal-datadog-setup.sh [--validate-only|--undo|--automated]

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Configuration
readonly CREDENTIALS_FILE="frugal-datadog-credentials.json"
readonly REQUIRED_PERMISSIONS=(
    "usage_read|Read usage metering and consumption data"
    "billing_read|Read billing information and cost data"
    "logs_read_data|Read log data and perform searches"
    "logs_read_index_data|Read log index data and configurations"
    "logs_read_config|Read log configuration settings and index configs"
    "monitors_read|Read monitor configurations and states"
    "apm_read|Read APM traces and service performance data"
    "dashboards_read|Read dashboard configurations and widgets"
    "user_app_keys|Manage application keys for key rotation and maintenance"
)

# Print helpers
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Check dependencies
check_dependencies() {
    local missing=()

    command -v curl >/dev/null || missing+=("curl")
    command -v jq >/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo "Install with:"
        [[ " ${missing[*]} " =~ " curl " ]] && echo "  macOS: brew install curl | Linux: apt-get install curl"
        [[ " ${missing[*]} " =~ " jq " ]] && echo "  macOS: brew install jq | Linux: apt-get install jq"
        exit 1
    fi
}

# Unified API helper using curl
api_call() {
    local method=$1 endpoint=$2 data=${3:-}
    local args=(-s -X "$method" "$endpoint" -H "DD-API-KEY: $API_KEY" -H "DD-APPLICATION-KEY: $APP_KEY")
    [[ -n $data ]] && args+=(-H "Content-Type: application/json" -d "$data")

    local response=$(curl "${args[@]}" -w "HTTPSTATUS:%{http_code}")
    local body=$(echo "$response" | sed 's/HTTPSTATUS:[0-9]*$//')
    local status=$(echo "$response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)

    # Store for caller
    HTTP_STATUS=$status
    HTTP_BODY=$body

    if [[ $status -ge 400 ]]; then
        local error_msg=$(echo "$body" | jq -r '.errors[0].detail // .message // "Unknown error"' 2>/dev/null || echo "HTTP $status")
        print_error "API Error ($status): $error_msg"
        return 1
    fi

    echo "$body"
}

# Test authentication using API validation endpoint
test_authentication() {
    print_info "Testing API authentication..."
    if api_call GET "$DATADOG_API_BASE/api/v1/validate" >/dev/null; then
        print_info "✅ API authentication successful"
        return 0
    else
        print_error "❌ API authentication failed"
        return 1
    fi
}

# Get Datadog region selection
select_region() {
    echo ""
    print_info "Datadog Region Selection"
    echo "1. US1 (default): api.datadoghq.com"
    echo "2. US3: us3.datadoghq.com"
    echo "3. US5: us5.datadoghq.com"
    echo "4. EU1: api.datadoghq.eu"
    echo "5. AP1: api.ap1.datadoghq.com"
    echo "6. Custom endpoint"

    read -p "Select region (1-6) [1]: " region_choice
    region_choice=${region_choice:-1}

    case "$region_choice" in
        1) DATADOG_API_BASE="https://api.datadoghq.com" ;;
        2) DATADOG_API_BASE="https://us3.datadoghq.com" ;;
        3) DATADOG_API_BASE="https://us5.datadoghq.com" ;;
        4) DATADOG_API_BASE="https://api.datadoghq.eu" ;;
        5) DATADOG_API_BASE="https://api.ap1.datadoghq.com" ;;
        6) read -p "Enter custom endpoint: " DATADOG_API_BASE ;;
        *) print_error "Invalid choice"; exit 1 ;;
    esac

    print_info "Using: $DATADOG_API_BASE"
}

# Prompt for credentials
prompt_credentials() {
    echo ""
    print_info "Enter your Datadog credentials:"

    while true; do
        read -p "API Key (32 chars): " -s api_key
        echo ""
        if [[ ${#api_key} -eq 32 && $api_key =~ ^[a-f0-9]{32}$ ]]; then
            print_info "✅ API Key format valid"
            break
        fi
        print_error "Invalid API key format (need 32 hex chars)"
    done

    while true; do
        read -p "Application Key (40 chars): " -s app_key
        echo ""
        if [[ ${#app_key} -eq 40 && $app_key =~ ^[a-f0-9]{40}$ ]]; then
            print_info "✅ Application Key format valid"
            break
        fi
        print_error "Invalid Application key format (need 40 hex chars)"
    done

    API_KEY=$api_key
    APP_KEY=$app_key
}

# Create custom role
create_role() {
    print_info "Creating frugal-integration role..." >&2

    # Check if role exists
    local roles_response
    if roles_response=$(api_call GET "$DATADOG_API_BASE/api/v2/roles"); then
        local existing_role_id=$(echo "$roles_response" | jq -r '.data[] | select(.attributes.name=="frugal-integration") | .id')
        if [[ -n $existing_role_id && $existing_role_id != "null" ]]; then
            print_info "✅ Role 'frugal-integration' already exists (ID: $existing_role_id)" >&2
            echo "$existing_role_id:existing"
            return 0
        fi
    fi

    # Create role
    local role_payload=$(jq -n '{
        data: {
            type: "roles",
            attributes: {
                name: "frugal-integration",
                description: "Read-only role for Frugal cost monitoring integration"
            }
        }
    }')

    # Use direct curl to avoid api_call wrapper issues
    local role_response
    role_response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
        -X POST "$DATADOG_API_BASE/api/v2/roles" \
        -H "DD-API-KEY: $API_KEY" \
        -H "DD-APPLICATION-KEY: $APP_KEY" \
        -H "Content-Type: application/json" \
        -d "$role_payload")

    local http_code=$(echo "$role_response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
    local role_body=$(echo "$role_response" | sed 's/HTTPSTATUS:[0-9]*$//')

    if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
        local role_id=$(echo "$role_body" | jq -r '.data.id')
        if [[ -n $role_id && $role_id != "null" ]]; then
            print_info "✅ Role created (ID: $role_id)" >&2
            echo "$role_id:new"
        else
            # API returned success but no role ID - this indicates insufficient permissions
            print_error "❌ Your API keys lack admin permissions to create roles" >&2
            echo "" >&2
            print_info "Solutions:" >&2
            echo "  1. Use API keys from a user with 'Datadog Admin Role'" >&2
            echo "  2. Ask your Datadog admin to create the 'frugal-integration' role manually" >&2
            echo "  3. Run: ./frugal-datadog-setup.sh --validate-only (to test existing setup)" >&2
            return 1
        fi
    else
        # API call failed - check if it's a permission issue
        if [[ $http_code -eq 403 ]]; then
            print_error "❌ Your API keys lack admin permissions to create roles" >&2
            echo "" >&2
            print_info "Solutions:" >&2
            echo "  1. Use API keys from a user with 'Datadog Admin Role'" >&2
            echo "  2. Ask your Datadog admin to create the 'frugal-integration' role manually" >&2
            echo "  3. Run: ./frugal-datadog-setup.sh --validate-only (to test existing setup)" >&2
        else
            print_error "Failed to create role (HTTP $http_code)" >&2
        fi
        return 1
    fi
}

# Assign permissions to role
assign_permissions() {
    local role_id=$1
    local is_existing=${2:-false}

    if [[ $is_existing == "true" ]]; then
        print_warning "Role 'frugal-integration' already exists"
        echo ""
        read -p "Do you want to update the existing role permissions? (y/N): " update_role
        echo ""

        if [[ ! $update_role =~ ^[Yy]$ ]]; then
            print_info "Cannot proceed without updating role permissions"
            exit 1
        fi
        print_info "Updating permissions for existing role..."
    else
        print_info "Assigning permissions to role..."
    fi

    # Get all permissions
    local perms_response
    if ! perms_response=$(api_call GET "$DATADOG_API_BASE/api/v2/permissions"); then
        print_error "Failed to fetch permissions"
        return 1
    fi

    local assigned=0
    for permission_info in "${REQUIRED_PERMISSIONS[@]}"; do
        local permission_name=$(echo "$permission_info" | cut -d'|' -f1)
        local perm_id=$(echo "$perms_response" | jq -r ".data[] | select(.attributes.name==\"$permission_name\") | .id")

        if [[ -n $perm_id && $perm_id != "null" ]]; then
            local perm_payload=$(jq -n --arg id "$perm_id" '{data: {type: "permissions", id: $id}}')
            if api_call POST "$DATADOG_API_BASE/api/v2/roles/$role_id/permissions" "$perm_payload" >/dev/null; then
                ((assigned++))
            fi
        else
            print_warning "Permission not found: $permission_name"
        fi
    done

    print_info "✅ Assigned $assigned permissions"
}

# Create service account
create_service_account() {
    local role_id=$1
    print_info "Creating service account..." >&2

    # Create new service account
    local sa_payload=$(jq -n '{
        data: {
            type: "users",
            attributes: {
                name: "Frugal Service Account",
                email: "frugal-service-account@placeholder.local",
                service_account: true
            }
        }
    }')

    local sa_response
    if sa_response=$(api_call POST "$DATADOG_API_BASE/api/v2/service_accounts" "$sa_payload"); then
        local sa_id=$(echo "$sa_response" | jq -r '.data.id')
        print_info "✅ Service account created (ID: $sa_id)" >&2

        # Assign role to service account
        if [[ -n $role_id ]]; then
            local role_payload=$(jq -n --arg id "$sa_id" '{data: {type: "users", id: $id}}')
            if api_call POST "$DATADOG_API_BASE/api/v2/roles/$role_id/users" "$role_payload" >/dev/null; then
                print_info "✅ Role assigned to service account" >&2
            else
                print_warning "⚠️  Failed to assign role to service account" >&2
            fi
        fi

        echo "$sa_id"
    else
        print_error "Failed to create service account" >&2
        return 1
    fi
}

# Create API and Application keys
create_keys() {
    local sa_id=$1
    print_info "Creating API and Application keys..."

    # Check for existing API keys first
    print_info "Checking for existing 'frugal-api-key'..."
    local existing_keys_response
    if existing_keys_response=$(api_call GET "$DATADOG_API_BASE/api/v1/api_key"); then
        local matching_keys=$(echo "$existing_keys_response" | jq -r '.api_keys[]? | select(.name == "frugal-api-key") | .key')

        if [[ -n $matching_keys && $matching_keys != "null" ]]; then
            local key_count=$(echo "$matching_keys" | wc -l | tr -d ' ')
            print_warning "Found $key_count existing API key(s) named 'frugal-api-key'"
            echo ""

            read -p "Do you want to delete existing 'frugal-api-key' entries and create a new one? (y/N): " overwrite

            if [[ $overwrite =~ ^[Yy]$ ]]; then
                print_info "Deleting existing 'frugal-api-key' entries..."
                echo "$matching_keys" | while read -r key_hash; do
                    if [[ -n $key_hash && $key_hash != "null" ]]; then
                        echo -n "  Deleting API key $key_hash... "
                        if api_call DELETE "$DATADOG_API_BASE/api/v1/api_key/$key_hash" >/dev/null; then
                            echo "✅"
                        else
                            echo "❌"
                        fi
                    fi
                done
            else
                print_info "Keeping existing API keys. Setup cancelled."
                return 1
            fi
        fi
    fi

    # Create API key
    local api_key_payload='{"name": "frugal-api-key"}'
    local api_response
    if api_response=$(api_call POST "$DATADOG_API_BASE/api/v1/api_key" "$api_key_payload"); then
        NEW_API_KEY=$(echo "$api_response" | jq -r '.api_key.key // .key')
        print_info "✅ API Key created"
    else
        print_error "Failed to create API key"
        return 1
    fi

    # Create Application key for service account
    # Build scopes array combining hardcoded permissions with role permissions (like original script)
    local scopes_json="\"metrics_read\", \"timeseries_query\", \"hosts_read\""

    # Add all permissions from REQUIRED_PERMISSIONS array
    for permission_info in "${REQUIRED_PERMISSIONS[@]}"; do
        local permission_name=$(echo "$permission_info" | cut -d'|' -f1)
        scopes_json="$scopes_json, \"$permission_name\""
    done

    local app_key_payload=$(cat <<EOF
{
  "data": {
    "type": "application_keys",
    "attributes": {
      "name": "frugal-app-key",
      "scopes": [
        $scopes_json
      ]
    }
  }
}
EOF
)

    # Check for existing application keys first
    print_info "Checking for existing 'frugal-app-key'..."
    local existing_app_keys_response
    if existing_app_keys_response=$(api_call GET "$DATADOG_API_BASE/api/v2/application_keys"); then
        local matching_app_keys=$(echo "$existing_app_keys_response" | jq -r '.data[]? | select(.attributes.name == "frugal-app-key") | .id')

        if [[ -n $matching_app_keys && $matching_app_keys != "null" ]]; then
            local app_key_count=$(echo "$matching_app_keys" | wc -l | tr -d ' ')
            print_warning "Found $app_key_count existing application key(s) named 'frugal-app-key'"
            echo ""

            read -p "Do you want to delete existing 'frugal-app-key' entries and create a new one? (y/N): " overwrite_app

            if [[ $overwrite_app =~ ^[Yy]$ ]]; then
                print_info "Deleting existing 'frugal-app-key' entries..."
                echo "$matching_app_keys" | while read -r app_key_id; do
                    if [[ -n $app_key_id && $app_key_id != "null" ]]; then
                        echo -n "  Deleting application key $app_key_id... "
                        if api_call DELETE "$DATADOG_API_BASE/api/v2/application_keys/$app_key_id" >/dev/null; then
                            echo "✅"
                        else
                            echo "❌"
                        fi
                    fi
                done
            else
                print_info "Keeping existing application keys. Setup cancelled."
                return 1
            fi
        fi
    fi

    local app_response
    if [[ -n $sa_id ]]; then
        # Create for service account
        print_info "Creating application key for service account..."

        # Use direct curl like the original script to avoid any api_call issues
        local app_key_response
        app_key_response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
            -X POST "$DATADOG_API_BASE/api/v2/service_accounts/$sa_id/application_keys" \
            -H "DD-API-KEY: $API_KEY" \
            -H "DD-APPLICATION-KEY: $APP_KEY" \
            -H "Content-Type: application/json" \
            -d "$app_key_payload")

        local app_key_http_code=$(echo "$app_key_response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
        local app_key_body=$(echo "$app_key_response" | sed 's/HTTPSTATUS:[0-9]*$//')


        if [[ $app_key_http_code -eq 201 ]]; then
            NEW_APP_KEY=$(echo "$app_key_body" | jq -r '.data.attributes.key')
            if [[ -n $NEW_APP_KEY && $NEW_APP_KEY != "null" ]]; then
                print_info "✅ Application Key created for service account"
            else
                print_error "Application key was null or empty in response"
                return 1
            fi
        else
            print_error "Failed to create Application key (HTTP $app_key_http_code)"
            print_error "Response: $app_key_body"
            return 1
        fi
    else
        print_warning "No service account ID - using provided Application key"
    fi

    return 0
}

# Test API endpoints (comprehensive like original script)
test_endpoints() {
    print_info "Testing access to Datadog API endpoints..."
    echo ""

    # Build endpoint URLs with proper parameters (matching original script)
    local from_timestamp=$(date -d '1 hour ago' +%s 2>/dev/null || date -v-1H +%s)

    # Usage API parameters (matching original complex format)
    local start_hour end_hour
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date syntax
        start_hour=$(date -v-24H +%Y-%m-%dT%H)
        end_hour=$(date +%Y-%m-%dT%H)
        local usage_month=$(date -v-1m +%Y-%m)
    else
        # Linux date syntax
        start_hour=$(date -d '1 day ago' +%Y-%m-%dT%H)
        end_hour=$(date +%Y-%m-%dT%H)
        local usage_month=$(date -d '1 month ago' +%Y-%m)
    fi

    local endpoints=(
        "$DATADOG_API_BASE/api/v1/validate|Authentication"
        "$DATADOG_API_BASE/api/v1/metrics?from=${from_timestamp}|Metrics API"
        "$DATADOG_API_BASE/api/v1/monitor|Monitors API"
        "$DATADOG_API_BASE/api/v1/usage/billable-summary?month=${usage_month}|Usage API"
        "$DATADOG_API_BASE/api/v2/usage/hourly_usage?filter%5Btimestamp%5D%5Bstart%5D=${start_hour}&filter%5Btimestamp%5D%5Bend%5D=${end_hour}&filter%5Bproduct_families%5D=infra_hosts|Cost/Billing API"
        "$DATADOG_API_BASE/api/v1/hosts|Infrastructure API"
        "$DATADOG_API_BASE/api/v1/service_dependencies?env=prod|APM Services API"
        "$DATADOG_API_BASE/api/v1/dashboard|Dashboards API"
    )

    local success=0 total=${#endpoints[@]}

    for endpoint_info in "${endpoints[@]}"; do
        IFS='|' read -r url name <<< "$endpoint_info"
        printf "  Testing %-20s " "$name..."

        # Use direct curl with timeout (like original script)
        local response_body
        response_body=$(curl -s -m 10 -w "HTTPSTATUS:%{http_code}" \
            -X GET "$url" \
            -H "DD-API-KEY: $API_KEY" \
            -H "DD-APPLICATION-KEY: $APP_KEY" \
            -H "Content-Type: application/json" 2>/dev/null)

        local http_code=$(echo "$response_body" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)

        if [[ $http_code -ge 200 && $http_code -lt 300 ]]; then
            echo "✅"
            ((success++))
        elif [[ $http_code -eq 403 ]]; then
            echo "❌ (Permission Denied)"
        elif [[ $http_code -eq 404 ]]; then
            echo "❌ (Not Found)"
        else
            echo "❌ (HTTP $http_code)"
        fi
    done

    echo ""
    if [[ $success -eq $total ]]; then
        print_info "✅ All $total endpoints accessible"
        return 0
    else
        print_warning "⚠️  $success/$total endpoints accessible"
        if [[ $success -lt 4 ]]; then
            print_warning "Less than 50% of endpoints accessible. Please check permissions."
        fi
        return 0
    fi
}

# Save credentials to file
save_credentials() {
    print_info "Saving credentials..."

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local creds=$(jq -n \
        --arg api_key "${NEW_API_KEY:-$API_KEY}" \
        --arg app_key "${NEW_APP_KEY:-$APP_KEY}" \
        --arg endpoint "$DATADOG_API_BASE" \
        --arg timestamp "$timestamp" \
        '{
            api_key: $api_key,
            application_key: $app_key,
            api_key_type: "service_account",
            service_account: "Frugal Service Account",
            role: "frugal-integration",
            datadog_endpoint: $endpoint,
            created_at: $timestamp
        }')

    echo "$creds" > "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    print_info "✅ Credentials saved to $CREDENTIALS_FILE"
}

# Load existing credentials
load_credentials() {
    if [[ ! -f $CREDENTIALS_FILE ]]; then
        print_error "Credentials file not found: $CREDENTIALS_FILE"
        return 1
    fi

    local creds=$(cat "$CREDENTIALS_FILE")
    API_KEY=$(echo "$creds" | jq -r '.api_key')
    APP_KEY=$(echo "$creds" | jq -r '.application_key')
    DATADOG_API_BASE=$(echo "$creds" | jq -r '.datadog_endpoint // "https://api.datadoghq.com"')

    if [[ $API_KEY == "null" || $APP_KEY == "null" ]]; then
        print_error "Invalid credentials in file"
        return 1
    fi

    print_info "✅ Loaded credentials from $CREDENTIALS_FILE"
}

# Cleanup
cleanup() {
    print_info "Cleaning up..."
    [[ -f $CREDENTIALS_FILE ]] && rm -f "$CREDENTIALS_FILE" && print_info "✅ Removed $CREDENTIALS_FILE"

    echo ""
    print_info "To complete cleanup, manually remove from Datadog UI:"
    echo "• Service Account: Frugal Service Account"
    echo "• Role: frugal-integration"
    echo "• API Keys: frugal-api-key, frugal-app-key"
}

# Show usage
show_usage() {
    cat << 'EOF'
Usage: ./frugal-datadog-setup.sh [OPTIONS]

OPTIONS:
    --validate-only    Test existing credentials without changes
    --undo            Remove local credentials and show cleanup steps
    --automated       Create service account and keys automatically (default)
    --help           Show this help

EXAMPLES:
    ./frugal-datadog-setup.sh                    # Interactive automated setup
    ./frugal-datadog-setup.sh --validate-only    # Test existing setup
    ./frugal-datadog-setup.sh --undo             # Clean up

REQUIREMENTS:
    - curl, jq
    - Admin API keys for automated setup
EOF
}

# Main function
main() {
    local mode="automated"

    case "${1:-}" in
        --validate-only) mode="validate" ;;
        --undo) mode="undo" ;;
        --automated) mode="automated" ;;
        --help|-h) show_usage; exit 0 ;;
        "") mode="automated" ;;
        *) print_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac

    echo "========================================="
    echo "    Frugal Datadog Setup"
    echo "========================================="

    check_dependencies

    case "$mode" in
        undo)
            cleanup
            exit 0
            ;;
        validate)
            if ! load_credentials; then
                exit 1
            fi
            test_authentication
            test_endpoints
            print_info "✅ Validation complete"
            ;;
        automated)
            select_region
            prompt_credentials
            if test_authentication; then
                print_info "Starting automated setup..."

                if role_result=$(create_role); then
                    local role_id=$(echo "$role_result" | cut -d':' -f1)
                    local role_status=$(echo "$role_result" | cut -d':' -f2)

                    if [[ $role_status == "existing" ]]; then
                        assign_permissions "$role_id" true
                    else
                        assign_permissions "$role_id" false
                    fi

                    if sa_id=$(create_service_account "$role_id"); then
                        if create_keys "$sa_id"; then
                            # Switch to using the newly created service account credentials
                            API_KEY=${NEW_API_KEY:-$API_KEY}
                            APP_KEY=${NEW_APP_KEY:-$APP_KEY}

                            test_endpoints
                            save_credentials

                            echo ""
                            print_info "✅ Setup complete! Credentials configured."
                        else
                            print_error "Failed to create API keys"
                            print_error "Cannot complete setup without service account credentials"
                            exit 1
                        fi
                    else
                        print_error "Failed to create or find service account"
                        print_error "Cannot complete automated setup without service account"
                        exit 1
                    fi
                else
                    echo "" >&2
                    print_error "Automated setup cannot continue without role creation" >&2
                    exit 1
                fi
            else
                print_error "Authentication failed - check your credentials"
                exit 1
            fi
            ;;
    esac
}

# Global variables
declare API_KEY APP_KEY NEW_API_KEY NEW_APP_KEY DATADOG_API_BASE HTTP_STATUS HTTP_BODY

# Run main
main "$@"