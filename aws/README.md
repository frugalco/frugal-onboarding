# Frugal AWS Setup

This script helps you configure Amazon Web Services (AWS) with read-only access to various services for monitoring and cost analysis purposes.

## Overview

The `frugal-aws-setup.sh` script automates the process of:
- Creating IAM roles or users with comprehensive read-only permissions
- Setting up Workload Identity Federation (WIF) for secure cross-cloud access from GCP
- Configuring access to cost data via Cost Explorer
- Providing ViewOnlyAccess to monitor resources across all AWS services

## Prerequisites

- **AWS CLI**: The AWS Command Line Interface must be installed and configured
- **jq**: Command-line JSON processor (required for parsing AWS API responses)
- **Active AWS Account**: You need an AWS account where you have permissions to create IAM resources
- **Permissions**: You need IAM admin permissions to create roles/users and attach policies

### Installing Required Tools

**AWS CLI:**
```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Windows
# Download and run the MSI installer from https://awscli.amazonaws.com/AWSCLIV2.msi
```

**jq (JSON processor):**
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq

# CentOS/RHEL
sudo yum install jq

# Windows
# Download from https://jqlang.github.io/jq/download/
```

### Configuring AWS CLI

```bash
aws configure
# Enter your:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region name (e.g., us-east-1)
# - Default output format (json)
```

## Quick Start

### For Frugal Integration with WIF (Recommended)

```bash
./frugal-aws-setup.sh <role-name> <account-id> --wif <gcp-service-account>:< project-number>
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000
```

This sets up Workload Identity Federation, allowing Frugal's GCP-based infrastructure to securely access your AWS resources without long-lived credentials.

**Get the GCP service account email and project number from**: Frugal UI → Setup → AWS Integration

**Note**: The format is `service-account-email:project-number`. AWS requires the GCP project number (not project ID) for OIDC authentication.

### Multi-Account Setup

Frugal supports monitoring multiple AWS accounts from a single integration. You have three approaches depending on your AWS organization structure:

> **⚠️ IMPORTANT: Cost Visibility Across Accounts**
>
> For **organization-wide cost visibility**, you MUST run this script from your **AWS Organizations management account** (formerly called "master account").
>
> - **Management account**: Can see consolidated billing and costs for ALL accounts in the organization
> - **Member accounts**: Can ONLY see costs for their own individual account
>
> If you run the script from a member account, Frugal will only be able to access that account's costs, even if you configure access to other accounts.
>
> To check if you're in the management account:
> ```bash
> aws organizations describe-organization --query 'Organization.MasterAccountId' --output text
> # Compare with your current account:
> aws sts get-caller-identity --query Account --output text
> ```

#### Option 1: Selective Monitoring (Manually Specify Accounts)

Best for: Organizations with many accounts but only monitoring a subset

```bash
./frugal-aws-setup.sh <role-name> <primary-account-id> \
  --wif <gcp-service-account>:<project-number> \
  --additional-accounts "111111111111,222222222222,333333333333"
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --additional-accounts "210987654321,135792468013,975318024680"
```

#### Option 2: Organization-Wide Monitoring (Auto-Discover All Accounts)

Best for: Organizations with < 10 accounts or monitoring all accounts

```bash
./frugal-aws-setup.sh <role-name> <primary-account-id> \
  --wif <gcp-service-account>:<project-number> \
  --org-accounts all
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --org-accounts all
```

#### Option 3: Filtered Monitoring (Pattern-Based Discovery)

Best for: Organized AWS setups where you want to monitor accounts matching specific criteria

**Filter by account name pattern:**
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --org-accounts 'Name=*-prod*'
```

**Filter by Organizational Unit:**
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --org-accounts 'ou:ou-abcd-12345678'
```

**Filter by account status:**
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --org-accounts 'Status=ACTIVE'
```

**Available organization filters:**
- `all` - All active accounts in the organization
- `ou:ou-xxxx-yyyyyyyy` - Accounts in a specific Organizational Unit
- `Name=*pattern*` - Filter by account name (supports wildcards)
- `Status=ACTIVE` - Filter by account status

#### Multi-Account Prerequisites

**For --additional-accounts (Manual List):**
- Trust relationship must be configured in each additional account
- Primary account needs permission to assume the role in additional accounts
- Script uses `OrganizationAccountAccessRole` by default (customize with `--assume-role`)
- **Recommended**: Run from the management account to access consolidated billing data across all accounts
- If run from a member account, only that account's costs will be visible (not organization-wide costs)

**For --org-accounts (Organization Discovery):**
- **Must run from the AWS Organizations management account** for both account discovery AND consolidated cost visibility
- `organizations:ListAccounts` permission required
- `organizations:DescribeOrganization` permission required
- Trust relationship must exist in member accounts (typically via `OrganizationAccountAccessRole`)
- Note: Only the management account has access to consolidated billing data across all member accounts

**Setting up cross-account access:**
```bash
# Run this in each additional account to create the trust role
# (This is often already configured via AWS Organizations)
# Replace 123456789012 with your PRIMARY/management account ID
aws iam create-role \
  --role-name OrganizationAccountAccessRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::123456789012:root"},
      "Action": "sts:AssumeRole"
    }]
  }'
```

#### Adding Accounts Later

The script is idempotent - just re-run with the new account:

```bash
# Add a new account to existing setup
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@sample-123456.iam.gserviceaccount.com:123456789000 \
  --additional-accounts "210987654321,999888777666"  # New account added
```

### Traditional IAM User with Access Keys

**Single Account:**
```bash
./frugal-aws-setup.sh <user-name> <account-id>
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012
```

**Multi-Account (Now Supported!):**
```bash
./frugal-aws-setup.sh <user-name> <account-id> \
  --additional-accounts "111111111111,222222222222"
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --additional-accounts "210987654321,135792468013"
```

This creates an IAM user in the primary account with access keys, and creates IAM roles in additional accounts that trust the primary IAM user. The access keys can then be used to assume roles in all accounts.

**Note**: While IAM user mode now supports multi-account, WIF mode is still recommended for production use due to better security with temporary credentials.

### Removing Resources

```bash
./frugal-aws-setup.sh <role-or-user-name> <account-id> --undo
```

This removes all created resources including roles, users, policies, and credentials.

## What the Script Does

### 1. Initial Setup
- Validates AWS CLI is installed and authenticated
- Verifies you're operating on the correct AWS account
- Shows a detailed plan of what will be created/modified

### 2. Resources Created Per Account

**In each monitored AWS account, the script creates:**
- 1 IAM Role (e.g., `frugal-readonly`)
- 1 Custom IAM Policy (`FrugalExtendedReadOnly`)
- 3 Policy Attachments:
  - `ViewOnlyAccess` (AWS managed)
  - `AmazonBedrockReadOnly` (AWS managed)
  - `FrugalExtendedReadOnly` (custom)
- Trust relationships for cross-account access

**Cost Impact**: These IAM resources are free. AWS does not charge for IAM roles, policies, or policy attachments.

**Resource Efficiency**:
- If you have 30 accounts but only need to monitor 5, use `--additional-accounts` to specify only those 5
- This avoids creating unused resources in the other 25 accounts
- Use organization-wide `--org-accounts all` only when monitoring most/all accounts

### 3. Assigns Read-Only Policies

The script uses a minimal set of policies to provide comprehensive access:

#### For Both IAM Roles (WIF) and IAM Users

Both authentication methods receive identical permissions:

| Policy | Access Granted |
|--------|----------------|
| `ViewOnlyAccess` (AWS managed) | Read-only access to EC2, S3, RDS, Lambda, CloudWatch, and most AWS services |
| `AmazonBedrockReadOnly` (AWS managed) | Read-only access to AWS Bedrock AI models, configuration, and diagnostics |
| `FrugalExtendedReadOnly` (custom) | Cost Explorer, billing, budgets, and CloudWatch Logs filtering |

**Extended Permissions Details:**
- **Cost Explorer & Billing**: View cost trends, analyze spending by service/region/tags, access budget alerts
- **CloudWatch Logs**: `logs:FilterLogEvents` permission for downloading log samples and analysis
- **Organizations**: View organizational structure and accounts
- **Bedrock AI**: View foundation models, custom models, guardrails, knowledge bases, agents, and invocation logging

Note: The `ViewOnlyAccess` policy includes read permissions for EC2, S3, RDS, Lambda, CloudWatch, and most other AWS services.

### 3. Authentication Methods

#### Workload Identity Federation (--wif) - Recommended
- Uses AWS's built-in support for Google's `accounts.google.com` OIDC provider
- Creates an IAM role with a trust policy allowing Frugal's GCP service account
- No long-lived credentials - uses short-lived tokens
- Most secure option for cross-cloud access

**Benefits of WIF:**
- No credential rotation needed
- Automatic token refresh
- Better security through temporary credentials
- Simplified credential management

#### IAM User with Access Keys (Default)
- Creates an IAM user with programmatic access
- Generates access key and secret key
- Saves credentials to a JSON file with secure permissions (600)
- Use by configuring AWS CLI or SDK with the credentials

### 4. Extended Permissions

The custom `FrugalExtendedReadOnly` policy provides access to:

**Cost Explorer & Billing**:
- View cost trends and forecasts
- Analyze spending by service, region, or tags
- Access budget alerts and recommendations
- No additional setup required - works immediately after script completion

**CloudWatch Logs**:
- `logs:FilterLogEvents` permission for downloading log samples
- Enables log analysis and troubleshooting
- Available in both WIF and IAM user modes

## Security Features

- **Read-only access**: Only viewer and read permissions are granted
- **No data modification**: Cannot create, update, or delete any resources
- **Temporary credentials with WIF**: Eliminates long-lived credential risks
- **Secure credential handling**: Access keys (if used) are saved with restricted file permissions
- **Confirmation prompts**: Shows all changes before applying them
- **Account verification**: Ensures operations happen on the intended account

## Using with Frugal

### With Workload Identity Federation

After running the script with `--wif`:

1. The script displays your IAM role ARN
2. Copy this ARN:
   ```
   arn:aws:iam::123456789012:role/frugal-readonly
   ```
3. Paste it into the Frugal AWS Setup interface
4. Frugal will use secure token exchange to access your AWS resources

### With Access Keys

After running the script without `--wif`:

1. The script creates a credentials file
2. View the credentials:
   ```bash
   cat frugal-readonly-credentials.json
   ```
3. Copy the entire JSON content
4. Paste it into the Frugal AWS Setup interface

## Troubleshooting

### Permission Errors

If you encounter permission errors:

1. Ensure your AWS user has these permissions:
   - `iam:CreateRole` or `iam:CreateUser`
   - `iam:AttachRolePolicy` or `iam:AttachUserPolicy`
   - `iam:CreateOpenIDConnectProvider` (for WIF)
   - `iam:CreateAccessKey` (for access keys)

2. Check your AWS CLI is configured correctly:
   ```bash
   aws sts get-caller-identity
   ```

### WIF Setup Issues

If IAM role creation fails:
- Verify you have permission to create IAM roles and attach policies
- Ensure the GCP service account email and project number are correct
- Check that the account ID is correct
- Verify the format: `service-account@project.iam.gserviceaccount.com:PROJECT_NUMBER`

### Cost Explorer Access

If Cost Explorer data isn't accessible:
- Ensure Cost Explorer is activated in your AWS account (one-time setup)
- Verify the custom `FrugalExtendedReadOnly` policy was created and attached
- Check the policy includes billing permissions (`ce:*`, `billing:*`)
- Available for both WIF and IAM user modes

### Access Key Issues

If using access keys:
- Ensure the credentials file has proper permissions (600)
- Don't commit credentials to version control
- Rotate keys regularly for security

## Best Practices

1. **Use Workload Identity Federation** for production environments
   - More secure than long-lived access keys
   - Automatic credential rotation
   - No credential storage needed

2. **Enable Cost Explorer**
   - Activate Cost Explorer if not already enabled
   - Set up cost allocation tags for detailed tracking
   - Configure budget alerts for cost control

3. **Review permissions regularly**
   - Ensure least privilege access
   - Remove unused roles/users
   - Monitor access through CloudTrail

4. **Monitor usage**
   - Check CloudTrail logs for API activity
   - Set up CloudWatch alarms for unusual access patterns
   - Review cost anomalies in Cost Explorer

## Adding Custom Permissions

If you need to add additional read-only policies:

1. Edit the script's `READONLY_POLICIES_WITH_DESC` array
2. Add your policy in the format:
   ```bash
   "arn:aws:iam::aws:policy/PolicyName|Description of what it grants"
   ```
3. Run the script again - it will add only the new policies

Example:
```bash
"arn:aws:iam::aws:policy/AmazonRedshiftReadOnlyAccess|View Redshift clusters and query history"
```

## Script Options Reference

```bash
# Create IAM user with access keys
./frugal-aws-setup.sh <name> <account-id> [credentials-file]

# Create IAM role with WIF (recommended)
./frugal-aws-setup.sh <name> <account-id> --wif

# Remove all created resources
./frugal-aws-setup.sh <name> <account-id> --undo
```

## Support

For issues or questions:
- Check the script output for detailed error messages
- Verify prerequisites are met
- Ensure proper AWS permissions
- Review AWS CloudTrail logs for API errors

## Next Steps

After successful setup:
1. Verify the role/user can access your AWS resources
2. Configure Cost and Usage Reports if not already done
3. Set up any additional monitoring or alerting
4. Document the setup for your team