# Frugal GitHub Setup

This script helps you configure GitHub API access with read-only permissions for repository monitoring and cost analysis purposes.

## Overview

The `frugal-github-setup.sh` script automates the process of:
- Setting up Personal Access Tokens with comprehensive read-only permissions
- Supporting both fine-grained (recommended) and classic token types
- Validating token access and testing key API endpoints
- Providing secure credential storage and management
- Offering easy cleanup and token revocation guidance

## Prerequisites

- **curl**: Required for API communication
- **jq**: Recommended for improved JSON parsing (optional but helpful)
- **Active GitHub Account**: Personal or organization account with appropriate permissions

### Installing Dependencies

```bash
# macOS
brew install curl jq

# Linux (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install curl jq

# Linux (RHEL/CentOS)
sudo yum install curl jq
```

## Authentication Methods

### Fine-Grained Personal Access Tokens (Recommended)

Fine-grained tokens offer enhanced security and are the recommended approach:

**Benefits:**
- Repository-specific access (choose exactly which repos to grant access to)
- Granular permissions (select specific read-only permissions)
- Automatic expiration (90 days by default, renewable)
- Organization owner approval for organization repositories
- Enhanced security through limited scope

**Limitations:**
- Cannot access public repositories you don't own (unless you're a collaborator)
- May not work with all GitHub features yet
- Requires explicit repository selection

### Classic Personal Access Tokens

Classic tokens provide broader access but are less secure:

**Use Cases:**
- Need to access public repositories you don't own
- Require access to GitHub Packages
- Need broader scope across all accessible repositories
- Working with legacy integrations

**Considerations:**
- Access to all repositories you can access
- Broader permission scopes
- Manual expiration management required
- Less granular control

## Quick Start

### For Fine-Grained Tokens (Recommended)

```bash
./frugal-github-setup.sh <username-or-org>
```

Example:
```bash
./frugal-github-setup.sh myusername
./frugal-github-setup.sh myorg
```

### For Classic Tokens

```bash
./frugal-github-setup.sh <username-or-org> --classic
```

Example:
```bash
./frugal-github-setup.sh myusername --classic
```

### Validating an Existing Token

```bash
./frugal-github-setup.sh <username-or-org> --validate-only
```

### Removing Integration

```bash
./frugal-github-setup.sh <username-or-org> --undo
```

## What the Script Does

### 1. Token Setup Guidance
- Provides step-by-step instructions for creating the appropriate token type
- Explains required permissions and scopes
- Validates token format and type

### 2. Comprehensive Testing
- Tests basic authentication
- Verifies user/organization access
- Checks repository access permissions
- Tests key API endpoints (Issues, Pull Requests, Actions, Contents)
- Reports rate limit status

### 3. Permission Validation

#### For Fine-Grained Tokens
The script requires these READ-ONLY permissions:

| Permission | Description |
|------------|-------------|
| **Actions** | View workflow runs, artifacts, and secrets |
| **Contents** | Access repository files and directories |
| **Discussions** | View repository and organization discussions |
| **Issues** | View issues, comments, and labels |
| **Metadata** | View repository metadata (required for all tokens) |
| **Pull requests** | View pull requests, reviews, and comments |
| **Repository security advisories** | View security advisories |

#### For Classic Tokens
The script requires these scopes:

| Scope | Description |
|-------|-------------|
| **repo** (read) | Full read access to public and private repositories |
| **read:org** | Read organization membership and teams |
| **read:user** | Read user profile information |
| **read:project** | Read access to user and organization projects |
| **read:discussion** | Read discussions in repositories and organizations |

## Creating Personal Access Tokens

### Fine-Grained Token Creation

1. Go to [GitHub Fine-Grained Tokens](https://github.com/settings/personal-access-tokens/new)
2. Click **"Generate new token"**
3. Configure the token:
   - **Token name**: "Frugal Integration"
   - **Expiration**: 90 days (or your preferred duration)
   - **Resource owner**: Select your username or organization
   - **Repository access**: Choose "Selected repositories" and select the repos you want to monitor
4. Set **Repository permissions** (all READ-ONLY):
   - Actions: **Read**
   - Contents: **Read**
   - Discussions: **Read**
   - Issues: **Read**
   - Metadata: **Read** (required)
   - Pull requests: **Read**
   - Repository security advisories: **Read**
5. Click **"Generate token"** and copy the token immediately

### Classic Token Creation

1. Go to [GitHub Tokens (Classic)](https://github.com/settings/tokens)
2. Click **"Generate new token (classic)"**
3. Configure the token:
   - **Note**: "Frugal Integration"
   - **Expiration**: 1 year (or your preferred duration)
4. Select **scopes**:
   - **repo** (this gives read access to repositories)
   - **read:org** (read organization data)
   - **read:user** (read user profile data)
   - **read:project** (read project data)
   - **read:discussion** (read discussion data)
5. Click **"Generate token"** and copy the token immediately

## Security Features

- **Read-only access**: Only viewer permissions are granted across all APIs
- **No data modification**: Cannot create, update, or delete any resources
- **Secure credential storage**: Tokens are saved with restricted file permissions (600)
- **Transparent operations**: Shows all API tests and validations
- **Easy revocation**: Clear instructions for removing access
- **Token validation**: Comprehensive testing of permissions and access

## API Coverage

The setup provides read-only access to:

### Core Repository Data
- Repository metadata, settings, and configuration
- File contents, directory structure, and history
- Branches, tags, and releases
- Repository topics and languages

### Issues and Pull Requests
- Issues, comments, labels, and milestones
- Pull requests, reviews, and review comments
- Draft pull requests and review threads
- Issue and PR timeline events

### GitHub Actions
- Workflow definitions and configurations
- Workflow runs, jobs, and steps
- Action artifacts and logs
- Repository secrets metadata (not values)

### Projects and Planning
- Repository and organization projects
- Project items, columns, and cards
- Project automation and workflows

### Security and Insights
- Security advisories and vulnerability alerts
- Dependabot alerts and dependency graphs
- Repository insights and traffic analytics
- Code scanning alerts (if enabled)

### Discussions and Community
- Repository and organization discussions
- Discussion comments and reactions
- Community health files and metrics

## Using with Frugal

After successful setup:

1. **Locate the credentials file**:
   ```bash
   # File will be named: frugal-github-<username-or-org>-credentials.json
   ls frugal-github-*.json
   ```

2. **View the credentials** (for sharing with Frugal):
   ```bash
   cat frugal-github-myusername-credentials.json
   ```

3. **Copy the entire JSON content** and paste it into the Frugal GitHub Setup interface

## Token Management

### Expiration and Renewal

#### Fine-Grained Tokens
- **Default expiration**: 90 days
- **Renewal**: Create a new token before expiration
- **Monitoring**: GitHub will email you before expiration
- **Management**: [Fine-Grained Tokens Settings](https://github.com/settings/personal-access-tokens/fine-grained)

#### Classic Tokens
- **Set expiration**: Choose appropriate duration (max 1 year)
- **Calendar reminder**: Set reminder before expiration
- **Management**: [Classic Tokens Settings](https://github.com/settings/tokens)

### Revoking Access

To fully remove Frugal's access:

1. **Delete the token from GitHub**:
   - Go to your token settings (links above)
   - Find the "Frugal Integration" token
   - Click the delete/revoke option

2. **Clean up local files**:
   ```bash
   ./frugal-github-setup.sh <username-or-org> --undo
   ```

## Troubleshooting

### Common Issues

#### "Bad credentials" Error
- **Cause**: Token is invalid, expired, or has insufficient permissions
- **Solution**: Create a new token with the correct permissions

#### "Repository not found" Error
- **Cause**: Token doesn't have access to the specified repository
- **Solution**: For fine-grained tokens, ensure the repository is selected in token settings

#### Rate Limit Exceeded
- **Cause**: Too many API requests in a short time
- **Solution**: Wait for rate limit reset (check `X-RateLimit-Reset` header)

#### Organization Access Issues
- **Cause**: Organization may require approval for fine-grained tokens
- **Solution**: Contact organization owner to approve the token, or use classic token

### Permission Errors

If you encounter permission errors:

1. **Verify token type**: Ensure you're using the correct token type for your needs
2. **Check repository selection**: For fine-grained tokens, verify the repository is selected
3. **Review organization settings**: Organization owners may need to approve fine-grained tokens
4. **Validate permissions**: Ensure all required permissions are granted

### API Access Issues

If specific APIs aren't working:

1. **Check token permissions**: Verify the token has the required permissions for that API
2. **Test with curl**: Use the GitHub API directly to isolate issues
3. **Review rate limits**: Ensure you haven't exceeded API rate limits
4. **Check GitHub status**: Visit [GitHub Status](https://www.githubstatus.com/) for service issues

### Organization Repositories

For organization repositories:

1. **Fine-grained tokens**: Organization owners must approve token requests
2. **Classic tokens**: Work immediately if you have access to the organization
3. **Member permissions**: Ensure your organization membership allows the required access

## Best Practices

### Security
1. **Use fine-grained tokens** whenever possible for enhanced security
2. **Set appropriate expiration** - don't create tokens that never expire
3. **Regular rotation** - Rotate tokens periodically even if not expired
4. **Minimal permissions** - Only grant the permissions actually needed
5. **Secure storage** - Never commit tokens to version control

### Token Management
1. **Descriptive names** - Use clear, descriptive names for tokens
2. **Document usage** - Keep track of where tokens are used
3. **Monitor activity** - Regularly check token usage in GitHub settings
4. **Remove unused tokens** - Delete tokens that are no longer needed

### Organization Management
1. **Approval workflow** - Establish clear approval process for organization tokens
2. **Audit regularly** - Review approved tokens and their permissions
3. **Policy enforcement** - Consider organization policies for token creation
4. **Member training** - Educate members on secure token practices

## Limitations and Considerations

### Fine-Grained Token Limitations
- Cannot contribute to public repositories you don't own
- Limited to selected repositories and organizations
- Some GitHub features may not yet support fine-grained tokens
- Require organization owner approval for org repositories

### Classic Token Considerations
- Broader scope than typically needed
- Access to all repositories you can access
- Less granular permission control
- Higher security risk if compromised

### API Limitations
- Rate limits apply (5,000 requests/hour for authenticated users)
- Some endpoints may have additional restrictions
- Large organizations may have specific API policies
- Beta features may not be available through all token types

## Support

For issues or questions:

1. **Check the script output** for detailed error messages
2. **Verify prerequisites** are met (curl, valid GitHub account)
3. **Review GitHub documentation** for the latest API changes
4. **Test with basic curl commands** to isolate issues
5. **Check GitHub Status** for service-wide issues

## Changelog

### Version 1.0.0
- Initial release with fine-grained and classic token support
- Comprehensive API endpoint testing
- Secure credential storage and management
- Organization and personal repository support
- Token validation and cleanup functionality