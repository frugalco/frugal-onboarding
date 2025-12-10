# Frugal GCP Setup

This script helps you create a Google Cloud Platform (GCP) service account with read-only access to various services for monitoring and cost analysis purposes.

## Overview

The `frugal-gcp-setup.sh` script automates the process of:
- Creating a GCP service account with read-only permissions
- Setting up service account impersonation for secure access from Frugal's infrastructure
- Configuring access to billing data, logs, metrics, and other GCP resources

## Prerequisites

### Required Tools

- **gcloud CLI**: The Google Cloud SDK must be installed and authenticated
  - Install: https://cloud.google.com/sdk/docs/install
  - Verify installation: `gcloud --version`
  - Authenticate: `gcloud auth login`
  - Set default project: `gcloud config set project PROJECT_ID`

### Required Permissions

The user running this script needs the following permissions in the primary project (and all additional projects if using `--additional-projects`):

**Minimum Required Roles:**
- `roles/iam.serviceAccountAdmin` - Create and manage service accounts
- `roles/iam.roleAdmin` - Create custom IAM roles
- `roles/resourcemanager.projectIamAdmin` - Grant IAM roles to service accounts

**OR**

- `roles/owner` - Full project access (includes all required permissions)

**How to check your permissions:**
```bash
# Check your current roles in a project
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:user:$(gcloud config get-value account)" \
  --format="value(bindings.role)"
```

### Multi-Project Setup Requirements

If using `--additional-projects`, you need:
- The same IAM permissions listed above in **each additional project**
- Ability to list and access each project
- Projects must have billing enabled to access billing export data

### Optional Tools

These tools improve functionality but are not required:
- **jq** - JSON processor for better billing table detection
  - Install: `brew install jq` (macOS) or `apt-get install jq` (Linux)
- **bq** - BigQuery CLI (part of gcloud SDK)
  - The script will fall back to `gcloud alpha bq` if `bq` is not available

## Quick Start

### For Frugal Integration (Recommended)

```bash
./frugal-gcp-setup.sh <service-account-name> <project-id> --impersonate <frugal-service-account>
```

Example:
```bash
./frugal-gcp-setup.sh frugal-gcp-readonly my-project-123 --impersonate frugal-console@sample-123456.iam.gserviceaccount.com
```

This sets up service account impersonation, allowing Frugal's infrastructure to securely access your GCP resources without requiring service account keys.

**Get the Frugal service account email from**: Frugal UI → Setup → GCP Integration

### Multi-Project Setup

To grant access across multiple GCP projects:

```bash
./frugal-gcp-setup.sh <service-account-name> <primary-project-id> \
  --impersonate <frugal-service-account> \
  --additional-projects "project-2,project-3,project-4"
```

Example:
```bash
./frugal-gcp-setup.sh frugal-readonly my-primary-project \
  --impersonate frugal-console@sample-123456.iam.gserviceaccount.com \
  --additional-projects "dev-project,staging-project,prod-project"
```

This grants the service account read-only access to the primary project and all additional projects listed.

### Traditional Key-Based Authentication

```bash
./frugal-gcp-setup.sh <service-account-name> <project-id>
```

This creates a service account and downloads a JSON key file.

### Removing a Service Account

```bash
./frugal-gcp-setup.sh <service-account-name> <project-id> --undo
```

This removes the service account and all associated permissions.

## What the Script Does

### 1. Initial Setup
- Validates gcloud CLI is installed and authenticated
- Sets the correct GCP project
- Enables required APIs:
  - IAM API (`iam.googleapis.com`) for service account management
  - Cloud Billing API (`cloudbilling.googleapis.com`) for billing export detection
  - Cloud Resource Manager API (`cloudresourcemanager.googleapis.com`) for project-level IAM management
  - Vertex AI API (`aiplatform.googleapis.com`) for AI/ML resource access

### 2. Creates Custom Roles
- **storage.metadata.reader**: Allows listing GCS buckets and viewing metadata without accessing file contents
- Custom roles are created in the primary project and each additional project (if specified)

### 3. Assigns Read-Only Roles

The following roles are granted in the primary project and all additional projects:

| Service | Role | Access Granted |
|---------|------|----------------|
| **Logging** | `roles/logging.viewer` | View logs and log-based metrics |
| **Monitoring** | `roles/monitoring.viewer` | View metrics, dashboards, and alerting policies |
| **Cloud Storage** | `storage.metadata.reader` (custom) | List buckets and view metadata only |
| **BigQuery** | `roles/bigquery.metadataViewer` | View dataset/table structure |
| | `roles/bigquery.resourceViewer` | View job history and performance stats |
| | `roles/bigquery.dataViewer` | View and query table data |
| | `roles/bigquery.jobUser` | Run BigQuery queries |
| **Cloud Spanner** | `roles/spanner.viewer` | View instances and schemas |
| **Pub/Sub** | `roles/pubsub.viewer` | View topics and subscriptions |
| **Vertex AI** | `roles/viewer` | Read-only access to Vertex AI resources |
| **General** | `roles/viewer` | Read-only access to all project resources |

### 4. Authentication Setup

#### Impersonation Mode (--impersonate)
- Grants Frugal's service account permission to impersonate your service account
- No key files needed - uses short-lived tokens
- Most secure option for production use

#### Service Account Key Mode (Default)
- Creates a JSON key file with secure permissions (600)
- Use by setting: `export GOOGLE_APPLICATION_CREDENTIALS='path/to/key.json'`

### 5. Billing Export Detection
The script automatically:
- Checks if BigQuery billing export is configured
- Searches for billing export tables in the primary project and all additional projects
- Identifies tables matching common billing export patterns (e.g., `gcp_billing_export_v1_*`)
- Displays found billing tables in an easy-to-copy format for use in Frugal
- Provides guidance if billing export needs to be set up

## Security Features

- **Read-only access**: Only viewer permissions are granted
- **No data modification**: Cannot create, update, or delete resources
- **Impersonation support**: Eliminates the need for long-lived credentials
- **Secure key handling**: Key files (if used) are created with restricted permissions
- **Confirmation prompts**: Shows all changes before applying them

## Using with Frugal

After running the script with `--impersonate`, you'll see output like this:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Next steps: Copy and paste the following into the Frugal GCP Setup:

Service Account Email:
  frugal-gcp-readonly@my-project-123.iam.gserviceaccount.com

Primary Project ID:
  my-project-123

BigQuery Billing Export Table(s) Found:
  my-project-123.billing_dataset.gcp_billing_export_v1_01C382_962BAA_264210

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

To complete the setup:

1. Copy the **Service Account Email** and paste it into the Frugal GCP Setup interface
2. Copy the **Primary Project ID** and paste it into Frugal
3. If billing tables are found, copy the **BigQuery Billing Export Table** name(s) and paste into Frugal
4. Frugal will use secure impersonation to access your GCP resources

**Note**: If multiple billing tables are found across different projects, you can configure them all in Frugal for comprehensive cost tracking.

## Troubleshooting

### Permission Errors
- Ensure you have the necessary IAM permissions in your GCP project
- Check that the project ID is correct
- You need permissions to create service accounts and assign roles

### API Not Enabled
- The script will attempt to enable required APIs automatically
- If it fails, you may need to enable them manually in the GCP Console

### Billing Export Not Found
- The script checks for BigQuery billing export tables in all configured projects
- If not found, you'll need to configure billing export in the GCP Console
- Visit: https://console.cloud.google.com/billing/YOUR_BILLING_ACCOUNT_ID/export
- Billing exports can be in any of your projects - use `--additional-projects` to search multiple projects

## Adding More Permissions

To add additional read-only roles:
1. Edit the script's `READONLY_ROLES_WITH_DESC` array
2. Add your role in the format: `"roles/service.viewer|Description"`
3. Run the script again - it will add only the new roles

## Best Practices

1. **Use impersonation mode** for production environments (more secure than key files)
2. **Enable billing export** to BigQuery for cost analysis
3. **Review permissions regularly** to ensure least privilege access
4. **Monitor usage** through GCP audit logs