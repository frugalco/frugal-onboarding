#!/bin/bash

# Script to configure GitHub API access for repository monitoring and analysis
# Supports both fine-grained and classic Personal Access Tokens
# Usage: ./frugal-github-setup.sh <username-or-org> [options]

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
    echo "Usage: $0 <username-or-org> [--fine-grained|--classic|--validate-only|--undo]"
    echo ""
    echo "Normal mode (fine-grained token - recommended):"
    echo "  $0 <username-or-org> [--fine-grained]"
    echo "    username-or-org: GitHub username or organization name"
    echo "    Creates fine-grained Personal Access Token with repository-specific permissions"
    echo "    More secure, repository-scoped, automatically expires"
    echo ""
    echo "Classic token mode:"
    echo "  $0 <username-or-org> --classic"
    echo "    Creates classic Personal Access Token with broader permissions"
    echo "    Required for some features like public repository access"
    echo ""
    echo "Validate only mode:"
    echo "  $0 <username-or-org> --validate-only"
    echo "    Tests an existing token without saving credentials"
    echo ""
    echo "Undo mode:"
    echo "  $0 <username-or-org> --undo"
    echo "    Removes saved credentials and provides token cleanup instructions"
}

# Check if required arguments are provided
if [ $# -lt 1 ]; then
    print_error "Insufficient arguments"
    show_usage
    exit 1
fi

USERNAME_OR_ORG="$1"
CREDENTIALS_FILE="frugal-github-${USERNAME_OR_ORG}-credentials.json"

# Check for mode
FINE_GRAINED_MODE=true
CLASSIC_MODE=false
VALIDATE_ONLY=false
UNDO_MODE=false

if [ "${2:-}" = "--classic" ]; then
    FINE_GRAINED_MODE=false
    CLASSIC_MODE=true
elif [ "${2:-}" = "--fine-grained" ]; then
    FINE_GRAINED_MODE=true
    CLASSIC_MODE=false
elif [ "${2:-}" = "--validate-only" ]; then
    VALIDATE_ONLY=true
elif [ "${2:-}" = "--undo" ]; then
    UNDO_MODE=true
fi

# Required read-only permissions for fine-grained tokens
FINE_GRAINED_PERMISSIONS=(
    "Actions:read|View workflow runs, artifacts, and secrets"
    "Contents:read|Access repository files and directories"
    "Discussions:read|View repository and organization discussions"
    "Issues:read|View issues, comments, and labels"
    "Metadata:read|View repository metadata (required for all tokens)"
    "Pull requests:read|View pull requests, reviews, and comments"
    "Repository security advisories:read|View security advisories"
)

# Required scopes for classic tokens
CLASSIC_SCOPES=(
    "repo:read|Full read access to public and private repositories"
    "read:org|Read organization membership and teams"
    "read:user|Read user profile information"
    "read:project|Read access to user and organization projects"
    "read:discussion|Read discussions in repositories and organizations"
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

# Function to validate username/org format
validate_username() {
    if ! [[ "$USERNAME_OR_ORG" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        print_error "Invalid GitHub username/organization format"
        exit 1
    fi
}

# Function to prompt for token based on mode
prompt_for_token() {
    echo ""
    if [ "$FINE_GRAINED_MODE" = true ]; then
        print_info "Setting up Fine-grained Personal Access Token (Recommended)"
        echo ""
        echo "Fine-grained tokens offer enhanced security with:"
        echo "• Repository-specific access (choose which repos to grant access to)"
        echo "• Granular permissions (only the permissions you specify)"
        echo "• Automatic expiration (90 days by default, renewable)"
        echo "• Organization owner approval (if targeting org repositories)"
        echo ""
        echo "To create a fine-grained Personal Access Token:"
        echo "1. Go to: https://github.com/settings/personal-access-tokens/"
        echo "2. Click 'Generate new token'"
        echo "3. Set expiration (90 days recommended)"
        echo "4. Resource owner: Select '${USERNAME_OR_ORG}'"
        echo "5. Repository access: Choose 'Selected repositories' and select the repos you want to monitor"
        echo "6. Permissions: Select the following READ-ONLY permissions:"
        
        for perm_desc in "${FINE_GRAINED_PERMISSIONS[@]}"; do
            local perm="${perm_desc%%|*}"
            echo "   • ${perm}"
        done
        
        echo "7. Click 'Generate token' and copy the generated token"
    else
        print_info "Setting up Classic Personal Access Token"
        echo ""
        echo "Classic tokens provide broader access but are less secure:"
        echo "• Access to all repositories you can access"
        echo "• Broader permission scopes"
        echo "• No automatic expiration (not recommended)"
        echo "• Required for some features (public repo contributions, packages)"
        echo ""
        echo "To create a classic Personal Access Token:"
        echo "1. Go to: https://github.com/settings/tokens"
        echo "2. Click 'Generate new token (classic)'"
        echo "3. Set expiration (1 year maximum recommended)"
        echo "4. Select the following scopes:"
        
        for scope_desc in "${CLASSIC_SCOPES[@]}"; do
            local scope="${scope_desc%%|*}"
            echo "   • ${scope}"
        done
        
        echo "5. Click 'Generate token' and copy the generated token"
    fi
    
    echo ""
    read -p "Enter your GitHub Personal Access Token: " -s TOKEN
    echo ""
    
    if [ -z "$TOKEN" ]; then
        print_error "No token provided"
        exit 1
    fi
}

# Function to validate token format
validate_token_format() {
    if [ "$FINE_GRAINED_MODE" = true ]; then
        # Fine-grained tokens start with "github_pat_"
        if [[ ! "$TOKEN" =~ ^github_pat_ ]]; then
            print_warning "Token doesn't start with 'github_pat_'. This might not be a fine-grained token."
            read -p "Do you want to continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Setup cancelled"
                exit 0
            fi
        fi
    else
        # Classic tokens start with "ghp_"
        if [[ ! "$TOKEN" =~ ^ghp_ ]]; then
            print_warning "Token doesn't start with 'ghp_'. This might not be a classic token."
            read -p "Do you want to continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Setup cancelled"
                exit 0
            fi
        fi
    fi
}

# Function to test basic token authentication
test_token_auth() {
    print_info "Testing token authentication..."
    
    local response
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/user 2>&1)
    
    if [ $? -ne 0 ]; then
        print_error "Failed to connect to GitHub API"
        echo "Response: $response"
        return 1
    fi
    
    # Check for authentication errors
    if echo "$response" | grep -q "Bad credentials\|Unauthorized\|Forbidden"; then
        print_error "Token authentication failed"
        echo "Response: $response"
        return 1
    fi
    
    # Extract user information
    if command -v jq &>/dev/null; then
        local username=$(echo "$response" | jq -r '.login // empty' 2>/dev/null)
        local name=$(echo "$response" | jq -r '.name // empty' 2>/dev/null)
        
        if [ -n "$username" ]; then
            print_info "Successfully authenticated as: ${name:-$username} (@${username})"
        else
            print_warning "Authenticated but couldn't retrieve user details"
        fi
    else
        # Without jq, just check for basic success
        if echo "$response" | grep -q '"login"'; then
            print_info "Token authentication successful"
        else
            print_error "Unexpected API response format"
            return 1
        fi
    fi
    
    return 0
}

# Function to check if user/org exists and get type
check_user_or_org() {
    print_info "Checking if '${USERNAME_OR_ORG}' exists and determining type..."
    
    local response
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/users/${USERNAME_OR_ORG}" 2>&1)
    
    if command -v jq &>/dev/null; then
        local user_type=$(echo "$response" | jq -r '.type // empty' 2>/dev/null)
        local name=$(echo "$response" | jq -r '.name // empty' 2>/dev/null)
        
        if [ "$user_type" = "User" ]; then
            print_info "Found user: ${name:-$USERNAME_OR_ORG} (@${USERNAME_OR_ORG})"
            return 0
        elif [ "$user_type" = "Organization" ]; then
            print_info "Found organization: ${name:-$USERNAME_OR_ORG} (@${USERNAME_OR_ORG})"
            return 0
        else
            print_error "User or organization '${USERNAME_OR_ORG}' not found"
            return 1
        fi
    else
        # Without jq, basic check
        if echo "$response" | grep -q '"login"'; then
            print_info "Found GitHub user/organization: ${USERNAME_OR_ORG}"
            return 0
        else
            print_error "User or organization '${USERNAME_OR_ORG}' not found"
            return 1
        fi
    fi
}

# Function to list and test repository access
test_repository_access() {
    print_info "Testing repository access..."
    
    local response
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/users/${USERNAME_OR_ORG}/repos?type=all&per_page=10" 2>&1)
    
    if command -v jq &>/dev/null; then
        local repo_count=$(echo "$response" | jq '. | length' 2>/dev/null)
        
        if [ "$repo_count" -gt 0 ]; then
            print_info "Successfully accessed ${repo_count} repositories (showing up to 10)"
            echo ""
            echo "Sample repositories:"
            echo "$response" | jq -r '.[] | "  • \(.name) (\(.visibility // "public")) - \(.description // "No description")"' 2>/dev/null | head -5
        else
            print_info "No repositories found or accessible"
        fi
    else
        # Without jq, basic check
        if echo "$response" | grep -q '"name"'; then
            print_info "Successfully accessed repositories"
        else
            print_warning "No repositories found or accessible"
        fi
    fi
    
    return 0
}

# Function to test specific API endpoints
test_api_endpoints() {
    print_info "Testing access to key API endpoints..."
    
    # Test a known public repository for basic API functionality
    local test_repo="octocat/Hello-World"
    echo ""
    echo "Testing API endpoints with public repository: ${test_repo}"
    
    # Test Issues API
    local issues_response
    issues_response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${test_repo}/issues?state=all&per_page=1" 2>&1)
    
    if echo "$issues_response" | grep -q -v "API rate limit exceeded\|Bad credentials"; then
        echo "  ✓ Issues API - accessible"
    else
        echo "  ✗ Issues API - limited or inaccessible"
    fi
    
    # Test Pull Requests API
    local pr_response
    pr_response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${test_repo}/pulls?state=all&per_page=1" 2>&1)
    
    if echo "$pr_response" | grep -q -v "API rate limit exceeded\|Bad credentials"; then
        echo "  ✓ Pull Requests API - accessible"
    else
        echo "  ✗ Pull Requests API - limited or inaccessible"
    fi
    
    # Test Actions API
    local actions_response
    actions_response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${test_repo}/actions/runs?per_page=1" 2>&1)
    
    if echo "$actions_response" | grep -q -v "API rate limit exceeded\|Bad credentials"; then
        echo "  ✓ Actions API - accessible"
    else
        echo "  ✗ Actions API - limited or inaccessible"
    fi
    
    # Test Repository Contents API
    local contents_response
    contents_response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${test_repo}/contents" 2>&1)
    
    if echo "$contents_response" | grep -q -v "API rate limit exceeded\|Bad credentials"; then
        echo "  ✓ Repository Contents API - accessible"
    else
        echo "  ✗ Repository Contents API - limited or inaccessible"
    fi
    
    return 0
}

# Function to check rate limits
check_rate_limits() {
    print_info "Checking API rate limits..."
    
    local response
    response=$(curl -s -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        https://api.github.com/rate_limit 2>&1)
    
    if command -v jq &>/dev/null; then
        local core_limit=$(echo "$response" | jq -r '.resources.core.limit // empty' 2>/dev/null)
        local core_remaining=$(echo "$response" | jq -r '.resources.core.remaining // empty' 2>/dev/null)
        local core_reset=$(echo "$response" | jq -r '.resources.core.reset // empty' 2>/dev/null)
        
        if [ -n "$core_limit" ]; then
            echo ""
            echo "Rate limit status:"
            echo "  Core API: ${core_remaining}/${core_limit} remaining"
            if [ -n "$core_reset" ]; then
                local reset_time=$(date -d "@${core_reset}" 2>/dev/null || date -r "$core_reset" 2>/dev/null || echo "N/A")
                echo "  Resets at: ${reset_time}"
            fi
        fi
    else
        print_info "Rate limit information available (install jq for details)"
    fi
    
    return 0
}

# Function to save credentials
save_credentials() {
    print_info "Saving credentials..."
    
    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local token_type=$( [ "$FINE_GRAINED_MODE" = true ] && echo "fine-grained" || echo "classic" )
    
    cat > "$CREDENTIALS_FILE" << EOF
{
  "username_or_org": "$USERNAME_OR_ORG",
  "token": "$TOKEN",
  "token_type": "$token_type",
  "created_at": "$created_at",
  "api_endpoints": {
    "base_url": "https://api.github.com",
    "graphql_url": "https://api.github.com/graphql"
  },
  "permissions": {
    "repositories": "read",
    "issues": "read",
    "pull_requests": "read",
    "actions": "read",
    "contents": "read",
    "discussions": "read",
    "projects": "read"
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
    echo "Username/Organization: $USERNAME_OR_ORG"
    echo "Token Type: $( [ "$FINE_GRAINED_MODE" = true ] && echo "Fine-grained Personal Access Token" || echo "Classic Personal Access Token" )"
    echo "Credentials File: $CREDENTIALS_FILE"
    echo ""
    echo "The token provides READ-ONLY access to:"
    echo "  • Repository metadata, files, and structure"
    echo "  • Issues, comments, and labels"
    echo "  • Pull requests, reviews, and discussions"
    echo "  • GitHub Actions workflows and runs"
    echo "  • Projects and project items"
    echo "  • Security advisories and vulnerability alerts"
    echo "  • Repository insights and analytics"
    echo ""
    
    if [ "$FINE_GRAINED_MODE" = true ]; then
        echo "Fine-grained token benefits:"
        echo "  • Repository-specific access (only selected repos)"
        echo "  • Automatic expiration (90 days by default)"
        echo "  • Granular permission control"
        echo "  • Organization owner approval for org repos"
    else
        echo "Classic token scope:"
        echo "  • Access to all repositories you can access"
        echo "  • Broader permission scopes"
        echo "  • Manual expiration management required"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Next steps:"
    echo ""
    echo "1. Share the credentials file with Frugal:"
    echo "   Path: $CREDENTIALS_FILE"
    echo ""
    echo "2. Monitor token expiration:"
    if [ "$FINE_GRAINED_MODE" = true ]; then
        echo "   - Fine-grained tokens expire automatically (check GitHub settings)"
        echo "   - Renew at: https://github.com/settings/personal-access-tokens/new"
    else
        echo "   - Set calendar reminder to rotate token before expiration"
        echo "   - Manage at: https://github.com/settings/tokens"
    fi
    echo ""
    echo "3. To revoke access:"
    echo "   - Delete the token from your GitHub settings"
    echo "   - Run: $0 $USERNAME_OR_ORG --undo"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to display validation summary
display_validation_summary() {
    echo ""
    print_info "=== Validation Complete ==="
    echo ""
    echo "Username/Organization: $USERNAME_OR_ORG"
    echo "Token Type: $( [ "$FINE_GRAINED_MODE" = true ] && echo "Fine-grained" || echo "Classic" )"
    echo "Status: Valid and functional"
    echo ""
    echo "The token successfully authenticated and can access GitHub APIs."
}

# Function to cleanup credentials
cleanup_credentials() {
    print_info "Cleaning up Frugal GitHub integration..."
    
    # Remove credentials file
    if [ -f "$CREDENTIALS_FILE" ]; then
        print_info "Removing credentials file: $CREDENTIALS_FILE"
        rm -f "$CREDENTIALS_FILE"
    else
        print_warning "Credentials file not found: $CREDENTIALS_FILE"
    fi
    
    # Look for other potential credential files
    local cred_pattern="frugal-github-${USERNAME_OR_ORG}*.json"
    local other_creds=$(ls ${cred_pattern} 2>/dev/null || true)
    
    if [ -n "$other_creds" ]; then
        print_warning "Found other credential files for this user/org:"
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
    echo "To fully revoke access, you must also delete the token from GitHub:"
    echo "1. Log in to GitHub"
    if [ "$FINE_GRAINED_MODE" = true ]; then
        echo "2. Go to: https://github.com/settings/personal-access-tokens/fine-grained"
    else
        echo "2. Go to: https://github.com/settings/tokens"
    fi
    echo "3. Find the 'Frugal Integration' token"
    echo "4. Click 'Delete' to revoke the token"
}

# Main execution for undo mode
undo_main() {
    print_info "Starting GitHub integration removal..."
    cleanup_credentials
}

# Main execution for validation mode
validate_main() {
    print_info "Starting GitHub token validation..."
    
    check_curl
    check_jq
    validate_username
    prompt_for_token
    validate_token_format
    
    if test_token_auth && check_user_or_org; then
        test_repository_access
        test_api_endpoints
        check_rate_limits
        display_validation_summary
    else
        print_error "Validation failed"
        exit 1
    fi
}

# Main execution for setup mode
setup_main() {
    print_info "Starting GitHub API setup..."
    
    check_curl
    check_jq
    validate_username
    
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
    
    if test_token_auth && check_user_or_org; then
        test_repository_access
        test_api_endpoints
        check_rate_limits
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