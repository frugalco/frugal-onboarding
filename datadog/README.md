# Frugal Datadog Setup

This script helps you configure Datadog API access with read-only permissions for monitoring and observability data collection.

## Overview

The `frugal-datadog-setup.sh` script guides you through setting up API access to your Datadog account using service account-based authentication for secure, least-privilege access.

## Key Features

- **Service Account-Based**: Uses dedicated service accounts for better security isolation
- **Least Privilege**: Creates custom roles with minimal read-only permissions
- **API Key Management**: Secure handling of both API Keys and Application Keys
- **Comprehensive Testing**: Validates access to all required Datadog APIs
- **Secure Credential Storage**: Saves credentials with restricted permissions

## Prerequisites

- **Datadog Account**: Active Datadog account with appropriate permissions
- **Admin Access**: You need admin permissions to create service accounts and roles
- **curl**: Command-line tool for API requests
- **jq**: JSON processor for API response parsing

### Installing Prerequisites

```bash
# macOS
brew install curl jq

# Ubuntu/Debian
sudo apt-get install curl jq

# CentOS/RHEL
sudo yum install curl jq
```

## Usage

### Default Setup (Recommended)

```bash
./frugal-datadog-setup.sh
```

The script automatically creates all required Datadog resources, tests API access, and saves credentials securely.

### Additional Options

```bash
# Validate existing keys without saving credentials
./frugal-datadog-setup.sh --validate-only

# Remove saved credentials and get revocation instructions
./frugal-datadog-setup.sh --undo
```

## Setup Options

### Automated Setup (Default)

The script automatically handles all setup steps:

**What gets created:**
1. **Service account**: `Frugal Service Account`
2. **Custom role**: `frugal-integration` with minimal read-only permissions
3. **Permission assignment**: Assigns only required permissions to the role
4. **Role assignment**: Links the role to the service account
5. **API Keys**: Generates both API Key and Application Key for the service account

**Requirements:**
- Existing admin API Key and Application Key
- `user_access_manage` permission (required to create service accounts)
- `application_keys_write` permission (required to create application keys)

**Benefits:**
- No manual steps in Datadog UI
- Consistent configuration every time
- Handles existing resources gracefully
- Follows security best practices automatically

**Note:** Running the script multiple times will create additional service accounts. You can clean up unused service accounts in the Datadog UI under Settings → Access Management → Service Accounts.

### Manual Setup (Fallback)

If automated setup fails, follow these steps in the Datadog UI:

#### 1. Create a Service Account
1. Go to **Settings → Access Management → Service Accounts**
2. Click **"Create Service Account"**
3. Name it **"Frugal Service Account"**
4. Email: **"frugal-service-account@placeholder.local"**

#### 2. Create a Custom Role
1. Go to **Settings → Access Management → Roles**
2. Click **"New Role"** named **"frugal-integration"**
3. Grant these read-only permissions:
   - **Billing and Usage → Usage Read** (`usage_read`)
   - **Billing and Usage → Billing Read** (`billing_read`)
   - **Log Management → Logs Read Data** (`logs_read_data`)
   - **Log Management → Logs Read Index Data** (`logs_read_index_data`)
   - **Log Management → Logs Read Config** (`logs_read_config`)
   - **Monitors → Monitors Read** (`monitors_read`)
   - **Infrastructure → Hosts Read** (`hosts_read`)
   - **APM → APM Read** (`apm_read`)
   - **Dashboards → Dashboards Read** (`dashboards_read`)
   - **Access Management → User App Keys** (`user_app_keys`)

**Note**: The `user_app_keys` permission allows Frugal to perform key rotation and credential maintenance for enhanced security.

#### 3. Assign Role and Create Keys
1. Assign **frugal-integration** role to the service account
2. Create Application Key from the service account with required scopes
3. Create dedicated API Key named **"frugal-api-key"**

#### 4. Test Access
```bash
curl -X GET "https://api.datadoghq.com/api/v1/validate" \
  -H "DD-API-KEY: YOUR_API_KEY" \
  -H "DD-APPLICATION-KEY: YOUR_APP_KEY"
```

#### 5. Create Credentials File
```json
{
  "api_key": "YOUR_API_KEY",
  "application_key": "YOUR_APPLICATION_KEY",
  "api_key_type": "service_account",
  "service_account": "Frugal Service Account",
  "role": "frugal-integration",
  "datadog_endpoint": "https://us5.datadoghq.com",
  "created_at": "2024-01-15T10:30:00Z"
}
```

## Supported Features

The setup grants **READ-ONLY** access to:

### Core Monitoring
- **Metrics**: Time-series data, custom metrics, historical data
- **Monitors**: Configurations, status, alert conditions, downtime schedules
- **Infrastructure**: Host metrics, container data, network performance
- **APM**: Service maps, trace data, error tracking, profiling

### Logs and Analytics
- **Logs**: Search, aggregation, indexes, pipelines, archives
- **Dashboards**: Configurations, widgets, shared dashboards, custom visualizations
- **Usage & Billing**: Data volumes, feature usage, cost breakdowns, billing summaries

## Security

### Built-in Security Features
- **Read-only access**: Only viewer permissions are granted
- **Service account isolation**: Uses dedicated service accounts, not personal credentials
- **Minimal permissions**: Custom role with only required permissions
- **Secure credential handling**: Keys are saved with restricted file permissions (600)
- **Transparent operations**: Shows all API tests and validations

### Best Practices
1. **Use Service Accounts**: Don't share personal API keys
2. **Regular Rotation**: Rotate keys every 90 days
3. **Monitor Usage**: Track API key usage in Datadog settings
4. **Principle of Least Privilege**: Only grant necessary permissions
5. **Secure Storage**: Never commit keys to version control

### Revoking Access

To fully remove Frugal's access:

1. **Delete Application Key**: Go to service account settings and delete the Frugal application key
2. **Delete API Key**: Go to Settings → Access Management → API Keys and delete the Frugal API key
3. **Remove Service Account** (optional): Delete the Frugal Service Account
4. **Clean up local files**: Run `./frugal-datadog-setup.sh --undo`

## Using with Frugal

After successful setup:

1. **Locate the credentials file**: `ls frugal-datadog-credentials.json`
2. **View the credentials**: `cat frugal-datadog-credentials.json`
3. **Copy the entire JSON content** and paste it into the Frugal Datadog Setup interface

## Troubleshooting

For successful automated setup, ensure:

1. **Use admin credentials**: Your API Key and Application Key must be from a user with **Datadog Admin Role** permissions
2. **Select correct endpoint**: Choose the right Datadog region (US1, US3, US5, EU1, etc.) that matches your organization

## Support

For issues or questions:

1. **Check the script output** for detailed error messages
2. **Verify prerequisites** are met (curl, jq, valid Datadog account)
3. **Review Datadog documentation** for the latest API changes
4. **Test with basic curl commands** to isolate issues

## Next Steps

After successful setup:
1. Verify the service account can access your Datadog data
2. Set up log index restrictions if needed for data privacy
3. Monitor API usage in Datadog settings
4. Schedule regular key rotation reminders