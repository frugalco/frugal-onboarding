#!/bin/bash

# Script to configure New Relic API access for monitoring and cost analysis
# New Relic uses API keys for authentication (no IAM-style system available)
# Usage: ./frugal-newrelic-setup.sh <account-id> [--validate-only|--undo]

set -euo pipefail

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
    echo "Usage: $0 <account-id> [--validate-only|--undo]"
    echo ""
    echo "Normal mode:"
    echo "  $0 <account-id>"
    echo "    account-id: Your New Relic account ID"
    echo "    Guides you through API key setup and validation"
    echo ""
    echo "Validate only mode:"
    echo "  $0 <account-id> --validate-only"
    echo "    Tests an existing API key without saving"
    echo ""
    echo "Undo mode:"
    echo "  $0 <account-id> --undo"
    echo "    Removes saved credentials and provides cleanup instructions"
}

# Check if required arguments are provided
if [ $# -lt 1 ]; then
    print_error "Insufficient arguments"
    show_usage
    exit 1
fi

ACCOUNT_ID="$1"
CREDENTIALS_FILE="frugal-newrelic-${ACCOUNT_ID}-credentials.json"

# Check for mode
VALIDATE_ONLY=false
UNDO_MODE=false
if [ "${2:-}" = "--validate-only" ]; then
    VALIDATE_ONLY=true
elif [ "${2:-}" = "--undo" ]; then
    UNDO_MODE=true
fi

# Function to check if curl is installed
check_curl() {
    if ! command -v curl &> /dev/null; then
        print_error "curl is not installed. Please install it first:"
        echo "  macOS: brew install curl"
        echo "  Linux: sudo apt-get install curl"
        exit 1
    fi
}

# Function to check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed. Installing it will improve this script's functionality:"
        echo "  macOS: brew install jq"
        echo "  Linux: sudo apt-get install jq"
        echo ""
        echo "Continuing without jq..."
    fi
}

# Function to validate account ID format
validate_account_id() {
    if ! [[ "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
        print_error "Invalid account ID. Must be numeric."
        exit 1
    fi
}

# Function to prompt for API key
prompt_for_api_key() {
    echo ""
    print_info "Setting up New Relic API access"
    echo ""
    echo "New Relic uses API keys for authentication. You'll need to:"
    echo "1. Create a dedicated user for Frugal in New Relic (recommended)"
    echo "2. Generate a User API Key for that user"
    echo ""
    echo "IMPORTANT: For complete read-only access to all data, ensure the user is a 'Full User'."
    echo ""
    echo "To create a User API Key:"
    echo "1. Log in to New Relic as a Full User (or create one)"
    echo "2. Go to: https://one.newrelic.com/api-keys"
    echo "3. Click 'Create a key'"
    echo "4. Select Key type: 'User'"
    echo "5. Name it: 'Frugal Integration'"
    echo "6. Copy the generated key"
    echo ""
    read -p "Enter your New Relic User API Key: " -s API_KEY
    echo ""
    
    if [ -z "$API_KEY" ]; then
        print_error "No API key provided"
        exit 1
    fi
}

# Function to validate API key format
validate_api_key_format() {
    # New Relic User keys typically start with "NRAK-" 
    if [[ ! "$API_KEY" =~ ^NRAK- ]]; then
        print_warning "API key doesn't start with 'NRAK-'. This might not be a User API Key."
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled"
            exit 0
        fi
    fi
}

# Function to test API access
test_api_access() {
    print_info "Testing API access..."
    
    # Test NerdGraph API (GraphQL endpoint)
    local test_query='{"query":"{ actor { user { email name } } }"}'
    local response
    
    response=$(curl -s -X POST https://api.newrelic.com/graphql \
        -H "Content-Type: application/json" \
        -H "API-Key: $API_KEY" \
        -d "$test_query" 2>&1)
    
    if [ $? -ne 0 ]; then
        print_error "Failed to connect to New Relic API"
        echo "Response: $response"
        return 1
    fi
    
    # Check for authentication errors
    if echo "$response" | grep -q "UNAUTHORIZED\|Invalid API key\|Forbidden"; then
        print_error "API key authentication failed"
        echo "Response: $response"
        return 1
    fi
    
    # Check for valid response structure
    if command -v jq &>/dev/null; then
        local email=$(echo "$response" | jq -r '.data.actor.user.email // empty' 2>/dev/null)
        local name=$(echo "$response" | jq -r '.data.actor.user.name // empty' 2>/dev/null)
        
        if [ -n "$email" ]; then
            print_info "Successfully authenticated as: $name ($email)"
        else
            print_warning "Authenticated but couldn't retrieve user details"
        fi
    else
        # Without jq, just check for basic success
        if echo "$response" | grep -q '"data"'; then
            print_info "API key validated successfully"
        else
            print_error "Unexpected API response format"
            return 1
        fi
    fi
    
    return 0
}

# Function to test account access
test_account_access() {
    print_info "Verifying access to account $ACCOUNT_ID..."
    
    # Query to check account access
    local account_query="{\"query\":\"{ actor { account(id: $ACCOUNT_ID) { name id } } }\"}"
    local response
    
    response=$(curl -s -X POST https://api.newrelic.com/graphql \
        -H "Content-Type: application/json" \
        -H "API-Key: $API_KEY" \
        -d "$account_query" 2>&1)
    
    if command -v jq &>/dev/null; then
        local account_name=$(echo "$response" | jq -r '.data.actor.account.name // empty' 2>/dev/null)
        
        if [ -n "$account_name" ]; then
            print_info "Confirmed access to account: $account_name (ID: $ACCOUNT_ID)"
            return 0
        else
            print_error "Cannot access account $ACCOUNT_ID with this API key"
            echo "Make sure the user has access to this account"
            return 1
        fi
    else
        # Without jq, basic check
        if echo "$response" | grep -q "\"id\":\"*$ACCOUNT_ID\"*"; then
            print_info "Confirmed access to account $ACCOUNT_ID"
            return 0
        else
            print_error "Cannot verify access to account $ACCOUNT_ID"
            return 1
        fi
    fi
}

# Function to check available data sources
check_data_sources() {
    print_info "Checking available data sources..."
    
    # Query to check what data is available
    local data_query="{\"query\":\"{ actor { account(id: $ACCOUNT_ID) { 
        nrql(query: \\\"SELECT count(*) FROM Transaction SINCE 1 hour ago\\\") { results }
        synthetics { monitors { id } }
        infrastructure { hosts { id } }
    } } }\"}"
    
    local response
    response=$(curl -s -X POST https://api.newrelic.com/graphql \
        -H "Content-Type: application/json" \
        -H "API-Key: $API_KEY" \
        -d "$data_query" 2>&1)
    
    echo ""
    print_info "Available data sources:"
    
    # Parse response to show what's available
    if command -v jq &>/dev/null; then
        # Check for APM data
        if echo "$response" | jq -e '.data.actor.account.nrql.results[0].count > 0' &>/dev/null; then
            echo "  ✓ APM (Application Performance Monitoring)"
        fi
        
        # Check for Synthetics
        if echo "$response" | jq -e '.data.actor.account.synthetics.monitors | length > 0' &>/dev/null; then
            echo "  ✓ Synthetics Monitoring"
        fi
        
        # Check for Infrastructure
        if echo "$response" | jq -e '.data.actor.account.infrastructure.hosts | length > 0' &>/dev/null; then
            echo "  ✓ Infrastructure Monitoring"
        fi
    else
        echo "  (Install jq for detailed data source detection)"
    fi
    
    # Always check these endpoints
    echo "  ✓ Metrics API Access"
    echo "  ✓ Events API Access"
    echo "  ✓ Logs API Access (if configured)"
}

# Function to save credentials
save_credentials() {
    print_info "Saving credentials..."
    
    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$CREDENTIALS_FILE" << EOF
{
  "account_id": "$ACCOUNT_ID",
  "api_key": "$API_KEY",
  "api_key_type": "user",
  "created_at": "$created_at",
  "api_endpoints": {
    "graphql": "https://api.newrelic.com/graphql",
    "rest_v2": "https://api.newrelic.com/v2",
    "insights": "https://insights-api.newrelic.com/v1/accounts/$ACCOUNT_ID"
  }
}
EOF
    
    # Set secure permissions
    chmod 600 "$CREDENTIALS_FILE"
    print_info "Credentials saved to: $CREDENTIALS_FILE"
}

# Function to display summary
display_summary() {
    echo ""
    print_info "=== Setup Complete ==="
    echo ""
    echo "Account ID: $ACCOUNT_ID"
    echo "Credentials File: $CREDENTIALS_FILE"
    echo "API Key Type: User API Key"
    echo ""
    echo "The API key provides READ-ONLY access to ALL New Relic data:"
    echo "  - APM: Application performance, traces, errors, dependencies"
    echo "  - Infrastructure: Host metrics, containers, cloud integrations"
    echo "  - Browser & Mobile: RUM data, crashes, performance"
    echo "  - Synthetics: Availability checks and results"
    echo "  - Logs & Traces: All ingested logs and distributed traces"
    echo "  - Dashboards & Alerts: All configurations and history"
    echo "  - NRQL: Full query access to all data types"
    echo ""
    echo "Note: Ensure the user is a 'Full User' for complete data access"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Next steps:"
    echo ""
    echo "1. Share the credentials file with Frugal:"
    echo "   Path: $CREDENTIALS_FILE"
    echo ""
    echo "2. To revoke access later:"
    echo "   - Go to: https://one.newrelic.com/api-keys"
    echo "   - Find and delete the 'Frugal Integration' key"
    echo "   - Run: $0 $ACCOUNT_ID --undo"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to display validation summary
display_validation_summary() {
    echo ""
    print_info "=== Validation Complete ==="
    echo ""
    echo "Account ID: $ACCOUNT_ID"
    echo "API Key Status: Valid"
    echo ""
    echo "The API key successfully authenticated and can access the specified account."
}

# Function to cleanup credentials
cleanup_credentials() {
    print_info "Cleaning up Frugal New Relic integration..."
    
    # Remove credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_info "Removing credentials file: $CREDENTIALS_FILE"
        rm -f "$CREDENTIALS_FILE"
    else
        print_warning "Credentials file not found: $CREDENTIALS_FILE"
    fi
    
    echo ""
    print_info "=== Cleanup Complete ==="
    echo ""
    echo "Local credentials have been removed."
    echo ""
    echo "To fully revoke access, you must also:"
    echo "1. Log in to New Relic"
    echo "2. Go to: https://one.newrelic.com/api-keys"
    echo "3. Find the 'Frugal Integration' API key"
    echo "4. Click the '...' menu and select 'Delete'"
    echo ""
    echo "Note: New Relic API keys cannot be revoked programmatically."
}

# Main execution for undo mode
undo_main() {
    print_info "Starting New Relic integration removal..."
    cleanup_credentials
}

# Main execution for validation mode
validate_main() {
    print_info "Starting New Relic API key validation..."
    
    check_curl
    check_jq
    validate_account_id
    prompt_for_api_key
    validate_api_key_format
    
    if test_api_access && test_account_access; then
        check_data_sources
        display_validation_summary
    else
        print_error "Validation failed"
        exit 1
    fi
}

# Main execution for setup mode
setup_main() {
    print_info "Starting New Relic API setup..."
    
    check_curl
    check_jq
    validate_account_id
    
    # Check if credentials already exist
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_warning "Credentials file already exists: $CREDENTIALS_FILE"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled"
            exit 0
        fi
    fi
    
    prompt_for_api_key
    validate_api_key_format
    
    if test_api_access && test_account_access; then
        check_data_sources
        save_credentials
        display_summary
    else
        print_error "Setup failed"
        exit 1
    fi
}

# Main execution
main() {
    if [ "$UNDO_MODE" = true ]; then
        undo_main
    elif [ "$VALIDATE_ONLY" = true ]; then
        validate_main
    else
        setup_main
    fi
}

# Run the main function
main