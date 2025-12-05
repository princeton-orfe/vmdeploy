# Azure VM Deployment

A reusable Azure deployment script for Linux VMs with Entra ID authentication, Serial Console access, and metric alerts.

## Overview

This deployment script provisions:
- Ubuntu 22.04 VM with configurable size
- Premium SSD data disk
- Network security (SSH blocked, configurable port access)
- Entra ID (Azure AD) authentication for Serial Console
- Metric alerts (availability, CPU, memory)
- Auto-updates with unattended-upgrades

## Prerequisites

- Azure CLI installed (`az`)
- jq installed (for parsing deployment output)
- Logged in to Azure (`az login`)

## Quick Start

```bash
# Deploy with required parameters
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com

# With Entra ID access (recommended)
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    --entra-admin admin@example.com \
    --entra-user user1@example.com \
    --entra-user user2@example.com

# With custom VM options
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    -l westus2 \
    -s Standard_D4s_v5 \
    -d 128 \
    --entra-admin admin@example.com

# With custom templates (for reuse in other projects)
./deploy.sh \
    -g my-project \
    -n my-vm \
    -e alerts@example.com \
    --bicep /path/to/custom.bicep \
    --cloud-init /path/to/custom-cloud-init.yaml \
    --role-definition /path/to/custom-role.json

# Dry run to preview deployment
./deploy.sh \
    -g my-resource-group \
    -n my-vm \
    -e alerts@example.com \
    --dry-run
```

The script will prompt for an admin password (used for Serial Console access).

## Deploy Options

| Option | Description |
|--------|-------------|
| `-g, --resource-group` | Azure resource group name (required) |
| `-n, --name` | VM name (required for deploy) |
| `-e, --email` | Email for failure notifications (required) |
| `-l, --location` | Azure region (default: canadacentral) |
| `-s, --size` | VM size (default: Standard_D8s_v5) |
| `-d, --disk-size` | Data disk size in GB (default: 64) |
| `--entra-admin` | Entra ID user with admin/sudo access |
| `--entra-user` | Entra ID user with standard access (repeatable) |
| `--dry-run` | Show what would happen without making changes |
| `--destroy` | Tear down all resources |
| `--bicep FILE` | Custom Bicep template (default: ./main.bicep) |
| `--cloud-init FILE` | Custom cloud-init YAML (default: ./cloud-init.yaml) |
| `--parameters FILE` | Parameters JSON for ports, project name, etc. |
| `--role-definition FILE` | Custom role definition JSON for `--entra-user` |

## Tear Down

```bash
# Remove all resources
./deploy.sh -g my-resource-group --destroy
```

## What Gets Deployed

| Resource | Purpose |
|----------|---------|
| Ubuntu 22.04 VM | D8s_v5 (8 vCPU, 32GB RAM) by default |
| Premium SSD | Data disk (64GB default) |
| NSG | Network security rules |
| Public IP | Static IP with DNS name |
| Action Group | Email alerts for failures |
| Metric Alerts | VM availability, CPU, memory |
| AADSSHLoginForLinux | Entra ID authentication (if `--entra-admin` or `--entra-user` specified) |

## Security

- **SSH Port**: Blocked at firewall level by default
- **Console Access**: Azure Portal Serial Console or Run Command (RBAC-authenticated)
- **Entra ID Login**: Optional - allows users to authenticate with their Entra credentials

## Console Access

**Serial Console** - Interactive terminal via Azure Portal:
1. Navigate to: VM > Help > Serial console
2. Login with `azureuser` + password (set during deploy)
3. Or with Entra ID email + password (if `--entra-admin` or `--entra-user` was specified)

**Run Command** - Execute scripts without credentials:
```bash
az vm run-command invoke \
    --resource-group my-resource-group \
    --name my-vm \
    --command-id RunShellScript \
    --scripts 'hostname && uptime'
```

## Granting User Access

### During Deployment (recommended)

Use `--entra-admin` and `--entra-user` flags to grant access during deployment:

```bash
./deploy.sh -g my-resource-group -n my-vm -e alerts@example.com \
    --entra-admin admin@example.com \
    --entra-user user1@example.com \
    --entra-user user2@example.com
```

- `--entra-admin`: Grants "Virtual Machine Administrator Login" role (has sudo)
- `--entra-user`: Grants custom "Serial Console User" role (minimum permissions for Serial Console only)

Users can then login at Serial Console with their Entra ID email and password.

### Post-Deployment

To add users after deployment:

```bash
# Standard user access
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine User Login" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"

# Admin access (sudo)
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine Administrator Login" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"
```

**For Run Command access only (no Serial Console login):**
```bash
az role assignment create \
    --assignee "user@yourdomain.com" \
    --role "Virtual Machine Contributor" \
    --scope "/subscriptions/<sub-id>/resourceGroups/my-rg/providers/Microsoft.Compute/virtualMachines/my-vm"
```

## Automated Features

The deployment configures:

**Auto-Updates (unattended-upgrades)**
- Daily security updates
- Weekly full updates
- Automatic reboot at 3:00 AM if required
- Email notifications on update activity

**Failure Notifications**
- Email alerts when VM availability drops
- Email alerts for high CPU (>90%) or low memory (<2GB)

## Configuring Email Notifications

The VM uses postfix for sending alert emails. Configure SMTP relay:

```bash
# Using SendGrid (free tier available in Azure Marketplace)
sudo cat > /etc/postfix/sasl_passwd << 'EOF'
[smtp.sendgrid.net]:587 apikey:YOUR_SENDGRID_API_KEY
EOF

sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd
sudo systemctl restart postfix

# Test
echo "Test alert" | mail -s "VM Test" your-email@example.com
```

See `SMTP-SETUP.md` for detailed instructions.

## VM Sizing Guide

| Size | vCPU | RAM | Monthly Cost (Est.) |
|------|------|-----|---------------------|
| Standard_D4s_v5 | 4 | 16GB | ~$140 |
| Standard_D8s_v5 | 8 | 32GB | ~$280 |
| Standard_D16s_v5 | 16 | 64GB | ~$560 |

## Moving Between Subscriptions

To move resources between subscriptions in the same tenant:

```bash
# Dry run
./move-subscription.sh -g my-resource-group -t "Target-Subscription-Name" --dry-run

# Perform move
./move-subscription.sh -g my-resource-group -t "00000000-0000-0000-0000-000000000000"
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Main deployment script |
| `main.bicep` | Infrastructure as Code (VM, network, alerts) |
| `cloud-init.yaml` | Generic OS configuration (auto-updates, notifications) |
| `parameters.json` | Template parameters file (customize for your project) |
| `serial-console-user-role.json` | Custom role template for minimum Serial Console permissions |
| `move-subscription.sh` | Script to move resources between subscriptions |
| `SMTP-SETUP.md` | Email configuration guide |

## Parameters File

The `--parameters` option allows you to configure project-specific settings like inbound ports, service user, and project naming. This keeps the deployment script generic and reusable.

### Parameters JSON Structure

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "projectName": {
      "value": "myapp",
      "metadata": { "description": "Short name for storage account (lowercase, no special chars)" }
    },
    "inboundPorts": {
      "value": [
        {
          "name": "Web-Traffic",
          "portRange": "443",
          "sourceAddressPrefixes": ["*"],
          "priority": 1010
        },
        {
          "name": "API-VPN-Only",
          "portRange": "8080-8089",
          "sourceAddressPrefixes": ["10.0.0.0/8", "172.16.0.0/12"],
          "priority": 1020
        }
      ],
      "metadata": { "description": "NSG inbound port rules" }
    },
    "serviceUser": {
      "value": "appuser",
      "metadata": { "description": "Linux user for running the service" }
    },
    "servicePorts": {
      "value": "443, 8080-8089",
      "metadata": { "description": "Ports shown in deployment output" }
    }
  }
}
```

### Inbound Port Rules

Each rule in `inboundPorts` creates an NSG (Network Security Group) rule:

| Field | Description | Example |
|-------|-------------|---------|
| `name` | Rule name (must be unique) | `"Web-Traffic"` |
| `portRange` | Single port or range | `"443"` or `"6000-6007"` |
| `sourceAddressPrefixes` | Array of allowed CIDRs | `["*"]` or `["10.0.0.0/8"]` |
| `priority` | Rule priority (1010+, lower = higher priority) | `1010` |

### Example: Web Application

```json
{
  "parameters": {
    "projectName": { "value": "webapp" },
    "inboundPorts": {
      "value": [
        { "name": "HTTPS", "portRange": "443", "sourceAddressPrefixes": ["*"], "priority": 1010 }
      ]
    },
    "serviceUser": { "value": "www-data" },
    "servicePorts": { "value": "443" }
  }
}
```

## Custom Templates

The deploy script supports custom templates for reuse across projects:

```bash
./deploy.sh \
    -g my-project \
    -n my-vm \
    -e alerts@example.com \
    --bicep ./my-custom.bicep \
    --cloud-init ./my-cloud-init.yaml \
    --parameters ./my-parameters.json \
    --role-definition ./my-role.json
```

This allows you to:
- Use different Bicep templates for different VM configurations
- Customize cloud-init for application-specific setup
- Configure ports and network rules via parameters file
- Define custom RBAC roles with specific permissions
