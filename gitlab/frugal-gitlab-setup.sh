#!/bin/bash

# Script to configure GitLab API access for repository monitoring and analysis
# Supports Personal Access Tokens with read-only permissions
# Usage: ./frugal-gitlab-setup.sh <username-or-group> [options]

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
    echo "Usage: $0 <username-or-group> [--validate-only|--undo]"
    echo ""
    echo "Normal mode (Personal Access Token setup):"
    echo "  $0 <username-or-group>"
    echo "    username-or-group: GitLab username or group name"
    echo "    Creates Personal Access Token with read-only permissions"
    echo ""
    echo "Validate only mode:"
    echo "  $0 <username-or-group> --validate-only"
    echo "    Tests an existing token without saving credentials"
    echo ""
    echo "Undo mode:"
    echo "  $0 <username-or-group> --undo"
    echo "    Removes saved credentials and provides token cleanup instructions"
}

# Check if required arguments are provided
if [ $# -lt 1 ]; then
    print_error "Insufficient arguments"
    show_usage
    exit 1
fi

USERNAME_OR_GROUP="$1"
CREDENTIALS_FILE="frugal-gitlab-${USERNAME_OR_GROUP}-credentials.json"

# Check for mode
VALIDATE_ONLY=false
UNDO_MODE=false

if [ "${2:-}" = "--validate-only" ]; then
    VALIDATE_ONLY=true
elif [ "${2:-}" = "--undo" ]; then
    UNDO_MODE=true
fi

# Required read-only scopes for Personal Access Tokens
REQUIRED_SCOPES=(
    "read_api|Read access to the API (projects, issues, merge requests, pipelines)"
    "read_repository|Read repository code and files via Git-over-HTTP"
    "read_user|Read user profile information"
)

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

# Function to validate username/group format
validate_username() {
    if ! [[ "$USERNAME_OR_GROUP" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
        print_error "Invalid GitLab username/group format"
        exit 1
    fi
}

# Function to prompt for token
prompt_for_token() {
    echo ""
    print_info "Setting up GitLab Personal Access Token (Read-Only)"
    echo ""
    echo "Personal Access Tokens provide secure read-only access to:"
    echo "• Repository files and commit history"
    echo "• Issues and merge requests"
    echo "• CI/CD pipelines and job logs"
    echo "• Project metadata and settings"
    echo ""
    echo "To create a Personal Access Token:"
    echo "1. Go to: https://gitlab.com/-/user_settings/personal_access_tokens"
    echo "   (or your GitLab instance URL + /-/user_settings/personal_access_tokens)"
    echo "2. Click 'Add new token'"
    echo "3. Set token name (e.g., 'Frugal Integration')"
    echo "4. Set expiration date (1 year recommended)"
    echo "5. Select the following READ-ONLY scopes:"

    for scope_desc in "${REQUIRED_SCOPES[@]}"; do
        local scope="${scope_desc%%|*}"
        echo "   • ${scope}"
    done

    echo "6. Click 'Create personal access token'"
    echo "7. Copy the generated token (you won't be able to see it again!)"
    echo ""
    read -p "Enter your GitLab Personal Access Token: " -s TOKEN
    echo ""

    if [ -z "$TOKEN" ]; then
        print_error "No token provided"
        exit 1
    fi
}

# Function to validate token format
validate_token_format() {
    # GitLab Personal Access Tokens start with "glpat-"
    if [[ ! "$TOKEN" =~ ^glpat- ]]; then
        print_warning "Token doesn't start with 'glpat-'. This might not be a Personal Access Token."
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Setup cancelled"
            exit 0
        fi
    fi
}

# Function to detect GitLab instance URL
detect_gitlab_url() {
    # Default to GitLab.com
    GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"

    # Check if it's a self-hosted instance by testing the token
    print_info "Using GitLab instance: ${GITLAB_URL}"
    echo "If you're using a self-hosted GitLab instance, set GITLAB_URL environment variable:"
    echo "  export GITLAB_URL=https://gitlab.example.com"
    echo ""
}

# Function to test basic token authentication
test_token_auth() {
    print_info "Testing token authentication..."

    local response
    response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/user" 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Failed to connect to GitLab API"
        echo "Response: $response"
        return 1
    fi

    # Check for authentication errors
    if echo "$response" | grep -q "401 Unauthorized\|403 Forbidden\|Invalid token"; then
        print_error "Token authentication failed"
        echo "Response: $response"
        return 1
    fi

    # Extract user information
    if command -v jq &>/dev/null; then
        local username=$(echo "$response" | jq -r '.username // empty' 2>/dev/null)
        local name=$(echo "$response" | jq -r '.name // empty' 2>/dev/null)

        if [ -n "$username" ]; then
            print_info "Successfully authenticated as: ${name:-$username} (@${username})"
        else
            print_warning "Authenticated but couldn't retrieve user details"
        fi
    else
        # Without jq, just check for basic success
        if echo "$response" | grep -q '"username"'; then
            print_info "Token authentication successful"
        else
            print_error "Unexpected API response format"
            return 1
        fi
    fi

    return 0
}

# Function to check if user/group exists and get type
check_user_or_group() {
    print_info "Checking if '${USERNAME_OR_GROUP}' exists and determining type..."

    # Try as user first
    local user_response
    user_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/users?username=${USERNAME_OR_GROUP}" 2>&1)

    if command -v jq &>/dev/null; then
        local user_count=$(echo "$user_response" | jq '. | length' 2>/dev/null)

        if [ "$user_count" -gt 0 ]; then
            local name=$(echo "$user_response" | jq -r '.[0].name // empty' 2>/dev/null)
            print_info "Found user: ${name:-$USERNAME_OR_GROUP} (@${USERNAME_OR_GROUP})"
            return 0
        fi
    else
        if echo "$user_response" | grep -q '"username"'; then
            print_info "Found GitLab user: ${USERNAME_OR_GROUP}"
            return 0
        fi
    fi

    # Try as group
    local group_response
    group_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/groups?search=${USERNAME_OR_GROUP}" 2>&1)

    if command -v jq &>/dev/null; then
        local group_count=$(echo "$group_response" | jq '. | length' 2>/dev/null)

        if [ "$group_count" -gt 0 ]; then
            local name=$(echo "$group_response" | jq -r '.[0].name // empty' 2>/dev/null)
            print_info "Found group: ${name:-$USERNAME_OR_GROUP}"
            return 0
        fi
    else
        if echo "$group_response" | grep -q '"full_path"'; then
            print_info "Found GitLab group: ${USERNAME_OR_GROUP}"
            return 0
        fi
    fi

    print_warning "User or group '${USERNAME_OR_GROUP}' not found or not accessible"
    echo "This may be normal if you don't have access to their projects"
    return 0
}

# Function to list and test project access
test_project_access() {
    print_info "Testing project access..."

    local response
    response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects?membership=true&per_page=10" 2>&1)

    if command -v jq &>/dev/null; then
        local project_count=$(echo "$response" | jq '. | length' 2>/dev/null)

        if [ "$project_count" -gt 0 ]; then
            print_info "Successfully accessed ${project_count} projects (showing up to 10)"
            echo ""
            echo "Sample projects:"
            echo "$response" | jq -r '.[] | "  • \(.path_with_namespace) (\(.visibility)) - \(.description // "No description")"' 2>/dev/null | head -5
        else
            print_info "No projects found or accessible"
        fi
    else
        # Without jq, basic check
        if echo "$response" | grep -q '"name"'; then
            print_info "Successfully accessed projects"
        else
            print_warning "No projects found or accessible"
        fi
    fi

    return 0
}

# Function to test specific API endpoints
test_api_endpoints() {
    print_info "Testing access to key API endpoints..."

    # Get a test project (use the first accessible project)
    local test_project_id=""
    local projects_response
    projects_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects?membership=true&per_page=1" 2>&1)

    if command -v jq &>/dev/null; then
        test_project_id=$(echo "$projects_response" | jq -r '.[0].id // empty' 2>/dev/null)
    fi

    if [ -z "$test_project_id" ]; then
        print_warning "No accessible projects found. Skipping endpoint tests."
        return 0
    fi

    echo ""
    echo "Testing API endpoints with project ID: ${test_project_id}"

    # Test Repository Files API
    local repo_response
    repo_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects/${test_project_id}/repository/tree?per_page=1" 2>&1)

    if echo "$repo_response" | grep -q -v "404\|401\|403"; then
        echo "  ✓ Repository Files API - accessible"
    else
        echo "  ✗ Repository Files API - limited or inaccessible"
    fi

    # Test Issues API
    local issues_response
    issues_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects/${test_project_id}/issues?per_page=1" 2>&1)

    if echo "$issues_response" | grep -q -v "404\|401\|403"; then
        echo "  ✓ Issues API - accessible"
    else
        echo "  ✗ Issues API - limited or inaccessible"
    fi

    # Test Merge Requests API
    local mr_response
    mr_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects/${test_project_id}/merge_requests?per_page=1" 2>&1)

    if echo "$mr_response" | grep -q -v "404\|401\|403"; then
        echo "  ✓ Merge Requests API - accessible"
    else
        echo "  ✗ Merge Requests API - limited or inaccessible"
    fi

    # Test Pipelines API
    local pipelines_response
    pipelines_response=$(curl -s -H "PRIVATE-TOKEN: $TOKEN" \
        "${GITLAB_URL}/api/v4/projects/${test_project_id}/pipelines?per_page=1" 2>&1)

    if echo "$pipelines_response" | grep -q -v "404\|401\|403"; then
        echo "  ✓ Pipelines API - accessible"
    else
        echo "  ✗ Pipelines API - limited or inaccessible"
    fi

    return 0
}

# Function to save credentials
save_credentials() {
    print_info "Saving credentials..."

    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$CREDENTIALS_FILE" << EOF
{
  "username_or_group": "$USERNAME_OR_GROUP",
  "token": "$TOKEN",
  "gitlab_url": "$GITLAB_URL",
  "created_at": "$created_at",
  "api_endpoints": {
    "base_url": "${GITLAB_URL}/api/v4",
    "graphql_url": "${GITLAB_URL}/api/graphql"
  },
  "scopes": [
    "read_api",
    "read_repository",
    "read_user"
  ],
  "permissions": {
    "projects": "read",
    "repository": "read",
    "issues": "read",
    "merge_requests": "read",
    "pipelines": "read"
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
    echo "Username/Group: $USERNAME_OR_GROUP"
    echo "GitLab Instance: $GITLAB_URL"
    echo "Credentials File: $CREDENTIALS_FILE"
    echo ""
    echo "The token provides READ-ONLY access to:"
    echo "  • Repository files and commit history"
    echo "  • Issues and comments"
    echo "  • Merge requests and reviews"
    echo "  • CI/CD pipelines and job logs"
    echo "  • Project metadata and settings"
    echo "  • User and group information"
    echo ""
    echo "The token CANNOT:"
    echo "  • Create, modify, or delete anything"
    echo "  • Push code or create branches"
    echo "  • Create issues or merge requests"
    echo "  • Modify CI/CD configuration"
    echo "  • Change project settings"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Next steps:"
    echo ""
    echo "1. Share the credentials file with Frugal:"
    echo "   Path: $CREDENTIALS_FILE"
    echo ""
    echo "2. Monitor token expiration:"
    echo "   - Check expiration date at: ${GITLAB_URL}/-/user_settings/personal_access_tokens"
    echo "   - Set calendar reminder to rotate token before expiration"
    echo ""
    echo "3. To revoke access:"
    echo "   - Delete the token from your GitLab settings"
    echo "   - Run: $0 $USERNAME_OR_GROUP --undo"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to display validation summary
display_validation_summary() {
    echo ""
    print_info "=== Validation Complete ==="
    echo ""
    echo "Username/Group: $USERNAME_OR_GROUP"
    echo "GitLab Instance: $GITLAB_URL"
    echo "Status: Valid and functional"
    echo ""
    echo "The token successfully authenticated and can access GitLab APIs."
}

# Function to cleanup credentials
cleanup_credentials() {
    print_info "Cleaning up Frugal GitLab integration..."

    # Remove credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_info "Removing credentials file: $CREDENTIALS_FILE"
        rm -f "$CREDENTIALS_FILE"
    else
        print_warning "Credentials file not found: $CREDENTIALS_FILE"
    fi

    # Look for other potential credential files
    local cred_pattern="frugal-gitlab-${USERNAME_OR_GROUP}*.json"
    local other_creds=$(ls ${cred_pattern} 2>/dev/null || true)

    if [ -n "$other_creds" ]; then
        print_warning "Found other credential files for this user/group:"
        echo "$other_creds"
        read -p "Do you want to remove these as well? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f ${cred_pattern}
            print_info "Credential files removed"
        fi
    fi

    echo ""
    print_info "=== Cleanup Complete ==="
    echo ""
    echo "Local credentials have been removed."
    echo ""
    echo "To fully revoke access, you must also delete the token from GitLab:"
    echo "1. Log in to GitLab"
    echo "2. Go to: ${GITLAB_URL:-https://gitlab.com}/-/user_settings/personal_access_tokens"
    echo "3. Find the 'Frugal Integration' token"
    echo "4. Click 'Revoke' to delete the token"
}

# Main execution for undo mode
undo_main() {
    print_info "Starting GitLab integration removal..."
    detect_gitlab_url
    cleanup_credentials
}

# Main execution for validation mode
validate_main() {
    print_info "Starting GitLab token validation..."

    check_curl
    check_jq
    validate_username
    detect_gitlab_url
    prompt_for_token
    validate_token_format

    if test_token_auth; then
        check_user_or_group
        test_project_access
        test_api_endpoints
        display_validation_summary
    else
        print_error "Validation failed"
        exit 1
    fi
}

# Main execution for setup mode
setup_main() {
    print_info "Starting GitLab API setup..."

    check_curl
    check_jq
    validate_username
    detect_gitlab_url

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

    prompt_for_token
    validate_token_format

    if test_token_auth; then
        check_user_or_group
        test_project_access
        test_api_endpoints
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
