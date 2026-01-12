# Frugal GitLab Setup

This script helps you configure GitLab API access with read-only permissions for repository monitoring and cost analysis purposes.

## Overview

The `frugal-gitlab-setup.sh` script automates the process of:
- Setting up Personal Access Tokens with comprehensive read-only permissions
- Validating token access and testing key API endpoints
- Providing secure credential storage and management
- Offering easy cleanup and token revocation guidance
- Supporting both GitLab.com and self-hosted GitLab instances

## Prerequisites

- **curl**: Required for API communication
- **jq**: Recommended for improved JSON parsing (optional but helpful)
- **Active GitLab Account**: Personal or group account with appropriate permissions

### Installing Dependencies

```bash
# macOS
brew install curl jq

# Linux (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install curl jq

# Linux (RHEL/CentOS)
sudo yum install curl jq
```

## Quick Start

### For GitLab.com

```bash
./frugal-gitlab-setup.sh <username-or-group>
```

Example:
```bash
./frugal-gitlab-setup.sh myusername
```

### For Self-Hosted GitLab

```bash
export GITLAB_URL=https://gitlab.example.com
./frugal-gitlab-setup.sh <username-or-group>
```

### Validate Existing Token

```bash
./frugal-gitlab-setup.sh <username-or-group> --validate-only
```

### Remove Credentials

```bash
./frugal-gitlab-setup.sh <username-or-group> --undo
```

## What the Script Does

### 1. Initial Setup
- Validates curl is installed and jq is available
- Detects GitLab instance URL (GitLab.com or self-hosted)
- Prompts for Personal Access Token creation

### 2. Personal Access Token Setup

The script guides you through creating a Personal Access Token with these **read-only** scopes:

| Scope | Access Granted |
|-------|----------------|
| `read_api` | Read access to the API (projects, issues, merge requests, pipelines) |
| `read_repository` | Read repository code and files via Git-over-HTTP |
| `read_user` | Read user profile information |

### 3. Validation and Testing

The script automatically:
- Tests token authentication
- Verifies user/group existence
- Lists accessible projects
- Tests key API endpoints:
  - Repository files and tree
  - Issues (read-only)
  - Merge requests (read-only)
  - CI/CD pipelines (read-only)

### 4. Credential Storage

Saves credentials securely in JSON format with:
- Secure file permissions (600)
- GitLab instance URL
- Token scopes and permissions
- API endpoint information

## Creating a Personal Access Token

### Step-by-Step Guide

1. **Navigate to Personal Access Tokens**
   - GitLab.com: https://gitlab.com/-/user_settings/personal_access_tokens
   - Self-hosted: `https://your-gitlab.com/-/user_settings/personal_access_tokens`

2. **Click "Add new token"**

3. **Configure Token Settings**
   - **Token name**: `Frugal Integration` (or any descriptive name)
   - **Expiration date**: Set to 1 year from now (recommended)

4. **Select Read-Only Scopes**
   - ☑️ `read_api`
   - ☑️ `read_repository`
   - ☑️ `read_user`
   - ⚠️ **Do NOT select write scopes** (api, write_repository, etc.)

5. **Create Token**
   - Click "Create personal access token"
   - **Copy the token immediately** (you won't be able to see it again!)

6. **Use Token in Script**
   - Run the script and paste the token when prompted
   - The token will be validated before being saved

## Security Features

### Read-Only Access
- Only viewer permissions are granted
- No ability to create, modify, or delete anything
- Cannot push code or create branches
- Cannot create issues or merge requests
- Cannot modify CI/CD configuration

### Token Security
- Tokens start with `glpat-` (Personal Access Token)
- Credentials saved with restricted file permissions (600)
- Token validation before storage
- Automatic expiration after configured period
- Easy revocation through GitLab UI

### What the Token CAN Do
✅ View repository files and commit history
✅ Read issues and comments
✅ Read merge requests and reviews
✅ View CI/CD pipelines and job logs
✅ Access project metadata and settings
✅ Read user and group information

### What the Token CANNOT Do
❌ Create, update, or delete anything
❌ Push code or create branches
❌ Create issues or merge requests
❌ Modify CI/CD configuration
❌ Change project settings
❌ Add or remove users

## Using with Frugal

After running the script successfully:

1. The script creates a credentials file (e.g., `frugal-gitlab-myusername-credentials.json`)
2. View the credentials:
   ```bash
   cat frugal-gitlab-myusername-credentials.json
   ```
3. Copy the entire JSON content
4. Paste it into the Frugal GitLab Setup interface

## Token Management

### Monitoring Expiration

1. Check your tokens regularly:
   - GitLab.com: https://gitlab.com/-/user_settings/personal_access_tokens
   - Self-hosted: `https://your-gitlab.com/-/user_settings/personal_access_tokens`

2. Set a calendar reminder to rotate tokens before expiration

3. GitLab will send email notifications before token expiration

### Rotating Tokens

When your token is about to expire:

1. Create a new token following the same steps above
2. Run the script again with the new token
3. Revoke the old token from GitLab settings

### Revoking Access

To completely revoke access:

1. **Remove local credentials**:
   ```bash
   ./frugal-gitlab-setup.sh <username-or-group> --undo
   ```

2. **Revoke token in GitLab**:
   - Go to Personal Access Tokens settings
   - Find the "Frugal Integration" token
   - Click "Revoke" to delete it

## Self-Hosted GitLab Instances

The script supports self-hosted GitLab instances:

### Setup for Self-Hosted GitLab

```bash
# Set your GitLab instance URL
export GITLAB_URL=https://gitlab.example.com

# Run the script
./frugal-gitlab-setup.sh <username-or-group>
```

### Persistent Configuration

To avoid setting `GITLAB_URL` every time, add it to your shell profile:

```bash
# Add to ~/.bashrc or ~/.zshrc
export GITLAB_URL=https://gitlab.example.com
```

## Troubleshooting

### Authentication Errors

**Error**: `Token authentication failed`

**Solution**:
- Verify the token was copied correctly (no extra spaces)
- Ensure the token hasn't expired
- Check that the token has the required scopes
- For self-hosted GitLab, verify the `GITLAB_URL` is correct

### No Projects Found

**Error**: `No projects found or accessible`

**Solution**:
- Ensure you're a member of at least one project
- For group access, verify you're a member of the group
- Check that the token has `read_api` scope

### API Endpoint Errors

**Error**: `API endpoint limited or inaccessible`

**Solution**:
- Verify the token has all three required scopes
- Ensure the project/repository exists and you have access
- For private projects, confirm your group/project membership

### Self-Hosted GitLab Issues

**Error**: `Failed to connect to GitLab API`

**Solution**:
- Verify the `GITLAB_URL` is correct (no trailing slash)
- Ensure your GitLab instance is accessible from your network
- Check for any firewall or VPN requirements
- Confirm the API is enabled on your instance

### Token Format Warning

**Warning**: `Token doesn't start with 'glpat-'`

**Explanation**:
- GitLab Personal Access Tokens should start with `glpat-`
- Other token types (project, group, OAuth) have different formats
- You can continue, but ensure you're using the correct token type

## API Endpoints Tested

The script validates access to these GitLab API endpoints:

| Endpoint | Purpose | Required Scope |
|----------|---------|----------------|
| `GET /user` | Authenticate and get user info | `read_user` |
| `GET /users?username=X` | Find user by username | `read_api` |
| `GET /groups?search=X` | Search for groups | `read_api` |
| `GET /projects?membership=true` | List accessible projects | `read_api` |
| `GET /projects/:id/repository/tree` | Access repository files | `read_repository` |
| `GET /projects/:id/issues` | View issues | `read_api` |
| `GET /projects/:id/merge_requests` | View merge requests | `read_api` |
| `GET /projects/:id/pipelines` | View CI/CD pipelines | `read_api` |

## Advanced Usage

### Using Different Credentials Files

```bash
# The script automatically names files based on username/group
# For example:
./frugal-gitlab-setup.sh alice
# Creates: frugal-gitlab-alice-credentials.json

./frugal-gitlab-setup.sh mycompany
# Creates: frugal-gitlab-mycompany-credentials.json
```

### Testing Multiple Tokens

Use `--validate-only` to test tokens without saving:

```bash
./frugal-gitlab-setup.sh <username> --validate-only
```

This is useful for:
- Testing token permissions before committing
- Verifying token functionality
- Troubleshooting access issues

## Best Practices

1. **Use Descriptive Token Names**
   - Name tokens clearly (e.g., "Frugal Production Integration")
   - Include the purpose in the name for easy identification

2. **Set Appropriate Expiration**
   - Recommended: 1 year maximum
   - Set calendar reminders for renewal
   - Rotate regularly for security

3. **Minimum Required Scopes**
   - Only use the three read-only scopes listed above
   - Never grant write permissions unless absolutely necessary
   - Follow the principle of least privilege

4. **Secure Storage**
   - Never commit credentials to version control
   - Use secure secret management for production
   - Rotate tokens if they may have been exposed

5. **Monitor Usage**
   - Regularly review active tokens in GitLab settings
   - Revoke unused or old tokens
   - Check for unusual API activity

## Script Options Reference

```bash
# Normal setup mode
./frugal-gitlab-setup.sh <username-or-group>

# Validate existing token
./frugal-gitlab-setup.sh <username-or-group> --validate-only

# Remove credentials and show revocation instructions
./frugal-gitlab-setup.sh <username-or-group> --undo

# Self-hosted GitLab
export GITLAB_URL=https://gitlab.example.com
./frugal-gitlab-setup.sh <username-or-group>
```

## Support

For issues or questions:
- Verify prerequisites are installed (curl, jq)
- Check that you have appropriate GitLab permissions
- Ensure token has all required scopes
- Review GitLab's Personal Access Token documentation
- Check the script output for detailed error messages

## Next Steps

After successful setup:
1. Verify the credentials file was created
2. Test the token using `--validate-only` mode
3. Share the credentials with Frugal
4. Set a reminder for token expiration
5. Document the token in your team's secret management system
