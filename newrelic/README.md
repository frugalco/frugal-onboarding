# Frugal New Relic Setup

This script helps you configure New Relic API access for monitoring and observability data collection.

## Overview

The `frugal-newrelic-setup.sh` script guides you through setting up API access to your New Relic account. Unlike AWS and GCP, New Relic uses API key-based authentication rather than IAM-style role-based access.

## Key Differences from Cloud Providers

- **No IAM System**: New Relic doesn't have service accounts or role-based authentication
- **API Keys Only**: Authentication is done via User API Keys tied to individual users  
- **Manual Revocation**: Keys must be manually revoked through the New Relic UI
- **User-Based Access**: Permissions are inherited from the user who creates the API key

## Prerequisites

- **New Relic Account**: Active New Relic account with appropriate permissions
- **Account ID**: Your numeric New Relic account ID
- **curl**: Command-line tool for API requests
- **jq** (optional): JSON processor for better output formatting

### Installing Prerequisites

```bash
# macOS
brew install curl jq

# Ubuntu/Debian
sudo apt-get install curl jq

# CentOS/RHEL
sudo yum install curl jq
```

## Quick Start

### Standard Setup

```bash
./frugal-newrelic-setup.sh <account-id>
```

Example:
```bash
./frugal-newrelic-setup.sh 1234567
```

This will:
1. Guide you through creating a New Relic User API Key
2. Validate the key and test API access
3. Check access to your account and available data sources
4. Save credentials securely for Frugal integration

### Validate Existing Key

```bash
./frugal-newrelic-setup.sh <account-id> --validate-only
```

Tests an API key without saving credentials.

### Remove Credentials

```bash
./frugal-newrelic-setup.sh <account-id> --undo
```

Removes saved credentials and provides instructions for revoking API access.

## Creating a Dedicated User (Recommended)

For better security and access control, we recommend creating a dedicated New Relic user for Frugal:

1. **Create a New User**
   - Log in to New Relic as an Admin
   - Go to: **User Management** → **Users**
   - Click **Add User**
   - Name: `frugal-integration@yourcompany.com`
   - User Type: **Full User** (required for complete data access)

2. **Assign Appropriate Permissions**
   - **Recommended**: Full User with all available permissions
   - **Why Full User?**: Ensures read access to ALL data sources and features
   - **Important**: Even as Full User, the API key will only have read access via the API
   
   Available User Types:
   - **Basic User**: Limited to 1000 queries/month, some features restricted
   - **Core User**: More queries, but still some limitations
   - **Full User**: Unlimited queries and access to all features (RECOMMENDED)

3. **Generate API Key**
   - Log in as the new user (or impersonate)
   - Go to: https://one.newrelic.com/api-keys
   - Create a **User Key** named "Frugal Integration"

## What the Script Does

### 1. API Key Validation
- Verifies the key format (should start with `NRAK-`)
- Tests authentication against New Relic's GraphQL API
- Confirms the key is active and valid

### 2. Account Access Verification
- Checks that the API key can access the specified account ID
- Retrieves account name to confirm correct account
- Validates permissions are sufficient

### 3. Data Source Detection
- Identifies available monitoring data:
  - APM (Application Performance Monitoring)
  - Infrastructure Monitoring
  - Synthetics Monitoring
  - Metrics, Events, and Logs

### 4. Credential Storage
- Saves credentials in JSON format
- Sets secure file permissions (600)
- Includes all necessary API endpoints

## API Access Provided

The User API Key from a Full User account grants READ-ONLY access to:

### Monitoring Data
- **APM (Application Performance Monitoring)**
  - Transaction traces and metrics
  - Error rates and details
  - Service maps and dependencies
  - Database query analysis
  - External service calls
  
- **Infrastructure Monitoring**
  - Host metrics (CPU, memory, disk, network)
  - Process information
  - Container metrics (Docker, Kubernetes)
  - Cloud integrations (AWS, Azure, GCP)
  
- **Browser Monitoring**
  - Real User Monitoring (RUM) data
  - Page load performance
  - JavaScript errors
  - Session traces
  
- **Mobile Monitoring**
  - Mobile app performance
  - Crash analytics
  - Network request data
  - Device metrics
  
- **Synthetics Monitoring**
  - Synthetic check results
  - Availability and response times
  - Script execution details
  
- **Serverless Monitoring**
  - Lambda function metrics
  - Invocation details
  - Cold start analysis

### Logs and Distributed Tracing
- **Log Management**
  - All ingested logs
  - Log patterns and parsing rules
  - Log-metric correlations
  
- **Distributed Tracing**
  - End-to-end transaction traces
  - Service interaction maps
  - Trace analytics

### Analytics and Insights
- **NRQL (New Relic Query Language)**
  - Custom queries on all data
  - Aggregations and calculations
  - Time-series analysis
  
- **Dashboards and Visualizations**
  - All dashboard configurations
  - Custom visualizations
  - Shared dashboards

### Configuration and Settings
- **Alert Configurations**
  - Alert policies and conditions
  - Notification channels
  - Incident history
  
- **Service Level Objectives (SLOs)**
  - SLO definitions
  - Compliance metrics
  - Error budgets
  
- **Workloads**
  - Workload definitions
  - Entity relationships
  - Health scores

### Account and User Data
- **Account Information**
  - Account settings
  - Usage metrics
  - Data retention settings
  
- **User and Role Information**
  - User lists
  - Permission configurations
  - API key metadata

Note: The API provides read-only access. Write operations (creating alerts, modifying dashboards, etc.) are not permitted via the Frugal integration.

## Security Considerations

### API Key Security
- **Treat as Sensitive**: API keys are like passwords
- **Use Dedicated Users**: Don't share personal API keys
- **Regular Rotation**: Rotate keys periodically
- **Minimal Permissions**: Use Basic User type when possible

### Access Control
- API key permissions match the creating user's permissions
- No way to create keys with reduced permissions
- Consider using New Relic's RBAC for fine-grained control

### Revocation Process
1. Log in to New Relic
2. Go to: https://one.newrelic.com/api-keys  
3. Find the key to revoke
4. Click "..." → "Delete"

Note: There's no API endpoint to revoke keys programmatically.

## Troubleshooting

### Authentication Errors
- Verify the API key starts with `NRAK-`
- Ensure the key hasn't been revoked
- Check the user still has active access

### Account Access Issues
- Confirm the account ID is correct
- Verify the user has access to the account
- Check if the account is active

### No Data Sources Found
- Ensure monitoring agents are installed and reporting
- Verify the user has permissions to view data
- Check if data retention policies are active

### API Rate Limits
New Relic enforces rate limits on API calls:
- NerdGraph: 25 requests per second
- REST API: 1000 requests per minute
- Adjust query frequency accordingly

## Manual API Access

If you can't run the script, here's how to set up manually:

### 1. Create API Key
```bash
# Go to: https://one.newrelic.com/api-keys
# Click "Create a key"
# Select type: "User"
# Name: "Frugal Integration"
# Copy the key (starts with NRAK-)
```

### 2. Test the Key
```bash
# Test with curl
curl -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: YOUR_API_KEY" \
  -d '{"query":"{ actor { user { email } } }"}'
```

### 3. Create Credentials File
```json
{
  "account_id": "YOUR_ACCOUNT_ID",
  "api_key": "YOUR_API_KEY",
  "api_key_type": "user",
  "created_at": "2024-01-15T10:30:00Z",
  "api_endpoints": {
    "graphql": "https://api.newrelic.com/graphql",
    "rest_v2": "https://api.newrelic.com/v2",
    "insights": "https://insights-api.newrelic.com/v1/accounts/YOUR_ACCOUNT_ID"
  }
}
```

### 4. Secure the File
```bash
chmod 600 frugal-newrelic-credentials.json
```

## Integration with Frugal

After running the script:

1. **Locate Credentials**: Find the generated credentials file
2. **Share with Frugal**: Provide the JSON file to your Frugal representative
3. **Monitor Usage**: Track API usage in New Relic's API Keys page
4. **Maintain Access**: Ensure the user account remains active

## Ensuring Complete Read-Only Access

To guarantee Frugal has read access to ALL your New Relic data:

### 1. Use a Full User Account
- **Required**: The user MUST be a "Full User" type
- Basic/Core users have query limits and restricted feature access
- Only Full Users can access all data types without restrictions

### 2. Verify Account Access
- Ensure the user has access to ALL accounts you want to monitor
- In multi-account organizations, explicitly grant access to each account
- Check: User Management → Select User → Account Access

### 3. Check Feature Flags
Some features may require explicit enablement:
- **Logs**: Ensure log management is enabled for the account
- **Distributed Tracing**: Verify tracing is enabled
- **Synthetics**: Check synthetic monitoring is active
- **Mobile/Browser**: Ensure these are configured if used

### 4. API Query Limits
Full Users have:
- **Unlimited NRQL queries** via the API
- **No rate limiting** on data access (within reason)
- **Access to all retention periods** configured

### 5. Testing Complete Access
After setup, verify access to all data types:
```bash
# The script will automatically check for:
# - APM transactions
# - Infrastructure hosts  
# - Synthetics monitors
# - Available data sources
```

## Best Practices

1. **Use Dedicated Integration Users**
   - Create separate users for each integration
   - Easier to track and revoke access
   - Better security isolation

2. **Monitor API Usage**
   - Check API key usage regularly
   - Set up alerts for unusual activity
   - Review access logs

3. **Regular Key Rotation**
   - Rotate keys every 90 days
   - Update Frugal with new keys
   - Delete old keys after rotation

4. **Principle of Least Privilege**
   - Use Basic User type when possible
   - Only grant necessary permissions
   - Review and adjust as needed

## Next Steps

1. Run the setup script with your account ID
2. Follow the prompts to create and validate an API key
3. Share the generated credentials file with Frugal
4. Monitor the integration for proper data collection

For support or questions, contact your Frugal representative.