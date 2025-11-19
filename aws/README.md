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
- **Active AWS Account**: You need an AWS account where you have permissions to create IAM resources
- **Permissions**: You need IAM admin permissions to create roles/users and attach policies

### Installing AWS CLI

If you don't have AWS CLI installed:
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
  --wif frugal-console@staging-467615.iam.gserviceaccount.com:413415524379
```

This sets up Workload Identity Federation, allowing Frugal's GCP-based infrastructure to securely access your AWS resources without long-lived credentials.

**Get the GCP service account email and project number from**: Frugal UI → Setup → AWS Integration

**Note**: The format is `service-account-email:project-number`. AWS requires the GCP project number (not project ID) for OIDC authentication.

### Multi-Account Setup

To grant access across multiple AWS accounts:

```bash
./frugal-aws-setup.sh <role-name> <primary-account-id> \
  --wif <gcp-service-account>:<project-number> \
  --additional-accounts "account2:profile2,account3:profile3"
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012 \
  --wif frugal-console@staging-467615.iam.gserviceaccount.com:413415524379 \
  --additional-accounts "210987654321:prod-account,135792468013:dev-account"
```

This creates IAM roles with the same name and permissions in all specified accounts.

**Prerequisites for multi-account setup**:
- AWS CLI profiles configured for each additional account
- IAM permissions in each account to create roles and attach policies

**Configure AWS profiles**:
```bash
# Configure a named profile for an additional account
aws configure --profile prod-account
# Enter credentials for the second account

# Verify profile works
aws sts get-caller-identity --profile prod-account
```

### Traditional IAM User with Access Keys

```bash
./frugal-aws-setup.sh <user-name> <account-id>
```

Example:
```bash
./frugal-aws-setup.sh frugal-readonly 123456789012
```

This creates an IAM user and generates access keys saved to a JSON file.

**Note**: IAM user mode only supports single-account setup. Use WIF mode for multi-account access.

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

### 2. Assigns Read-Only Policies

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