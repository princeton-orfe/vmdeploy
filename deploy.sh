#!/bin/bash
set -euo pipefail

# Azure VM Deployment Script
# Deploys VM with automated setup, auto-updates, and failure notifications
# Console access via Azure Portal (Serial Console / Run Command) - no SSH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
RESOURCE_GROUP=""
LOCATION="canadacentral"
VM_NAME=""
VM_SIZE="Standard_D8s_v5"
ALERT_EMAIL=""
DATA_DISK_SIZE=64
DESTROY=false
DRY_RUN=false
ADMIN_USERNAME="azureuser"
ENTRA_ADMIN=""
ENTRA_USERS=()
ENABLE_ENTRA_LOGIN=false
SERVICE_ADMINS=()
AUTO_UPDATE=false
AUTO_YES=false
NO_PUBLIC_IP=false
ENABLE_CMK=true

# Template files (defaults to files in same directory as script)
BICEP_FILE="$SCRIPT_DIR/main.bicep"
CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-init.yaml"
PARAMETERS_FILE=""
CUSTOM_ROLE_FILE=""

# Project-specific settings (loaded from parameters file or defaults)
PROJECT_NAME="vm"
SERVICE_USER="appuser"
SERVICE_PORTS=""
INBOUND_PORTS_JSON="[]"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Required:
  -g, --resource-group NAME    Azure resource group name
  -n, --name NAME              VM name (required for deploy, optional for destroy)
  -e, --email ADDRESS          Email for failure notifications (required for deploy)

Actions:
  --destroy                    Tear down all resources in the resource group
  --dry-run                    Show what would happen without making changes
  --update                     In-place update (skip interactive prompt if RG exists)
  -y, --yes                    Skip confirmation prompts

VM Options:
  -l, --location LOCATION      Azure region (default: canadacentral)
  -s, --size SIZE              VM size (default: Standard_D8s_v5)
  -d, --disk-size GB           Data disk size in GB (default: 64)
  -u, --admin-user USERNAME    Local admin username (default: azureuser)
  --no-public-ip               Don't create a public IP (access via VPN/private network only)
  --no-cmk                     Disable customer-managed key encryption (CMK enabled by default)

Template Options:
  --bicep FILE                 Custom Bicep template (default: ./main.bicep)
  --cloud-init FILE            Custom cloud-init YAML (default: ./cloud-init.yaml)
  --parameters FILE            Parameters JSON for ports, project name, etc.
  --role-definition FILE       Custom role definition JSON for --entra-user

Entra ID Access (enables Serial Console login with Entra credentials):
  --entra-admin EMAIL          Entra ID user with admin/sudo access
  --entra-user EMAIL           Entra ID user with standard access (repeatable)
  --service-admin EMAIL        Entra ID user who can act as service user (repeatable)
                               Grants: sudo su - <serviceUser>, systemctl control

Other:
  -h, --help                   Show this help message

Examples:
  Deploy (basic):
    $0 -g myapp-prod -n myapp-vm -e alerts@example.com

  Deploy with parameters file:
    $0 -g myapp-prod -n myapp-vm -e alerts@example.com \\
       --parameters ./parameters.json

  Deploy with Entra ID access:
    $0 -g myapp-prod -n myapp-vm -e alerts@example.com \\
       --parameters ./parameters.json \\
       --entra-admin admin@example.com \\
       --entra-user user1@example.com

  Deploy with custom templates:
    $0 -g myapp-prod -n myapp-vm -e alerts@example.com \\
       --bicep ./myapp/infra.bicep \\
       --cloud-init ./myapp/setup.yaml \\
       --parameters ./myapp/parameters.json

  Destroy:
    $0 -g myapp-prod --destroy

EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -e|--email)
            ALERT_EMAIL="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -s|--size)
            VM_SIZE="$2"
            shift 2
            ;;
        -d|--disk-size)
            DATA_DISK_SIZE="$2"
            shift 2
            ;;
        -u|--admin-user)
            ADMIN_USERNAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --destroy)
            DESTROY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --update)
            AUTO_UPDATE=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --no-public-ip)
            NO_PUBLIC_IP=true
            shift
            ;;
        --no-cmk)
            ENABLE_CMK=false
            shift
            ;;
        --entra-admin)
            ENTRA_ADMIN="$2"
            ENABLE_ENTRA_LOGIN=true
            shift 2
            ;;
        --entra-user)
            ENTRA_USERS+=("$2")
            ENABLE_ENTRA_LOGIN=true
            shift 2
            ;;
        --service-admin)
            SERVICE_ADMINS+=("$2")
            ENABLE_ENTRA_LOGIN=true
            shift 2
            ;;
        --bicep)
            BICEP_FILE="$2"
            shift 2
            ;;
        --cloud-init)
            CLOUD_INIT_FILE="$2"
            shift 2
            ;;
        --parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        --role-definition)
            CUSTOM_ROLE_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "Error: Resource group is required"
    usage
fi

# Check for Azure CLI
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed"
    echo "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

# Check Azure login
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

# Check EncryptionAtHost feature if CMK is enabled
if [[ "$ENABLE_CMK" == "true" ]]; then
    ENCRYPTION_FEATURE_STATE=$(az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv 2>/dev/null || echo "Unknown")
    if [[ "$ENCRYPTION_FEATURE_STATE" != "Registered" ]]; then
        echo ""
        echo "Warning: CMK encryption requires the 'EncryptionAtHost' feature."
        echo "Current status: $ENCRYPTION_FEATURE_STATE"
        echo ""
        read -p "Register the EncryptionAtHost feature now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Registering EncryptionAtHost feature..."
            az feature register --namespace Microsoft.Compute --name EncryptionAtHost --output none
            echo "Propagating provider registration..."
            az provider register -n Microsoft.Compute --output none
            echo -n "Waiting for registration to complete"
            while [[ "$(az provider show -n Microsoft.Compute --query registrationState -o tsv)" != "Registered" ]]; do
                sleep 5
                echo -n "."
            done
            echo " Done!"
            echo ""
        else
            echo ""
            echo "You can either:"
            echo "  1. Run with --no-cmk to disable encryption at host"
            echo "  2. Manually register: az feature register --namespace Microsoft.Compute --name EncryptionAtHost"
            exit 1
        fi
    fi
fi

# Handle destroy mode
if [[ "$DESTROY" == "true" ]]; then
    RG_EXISTS=false
    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        RG_EXISTS=true
    fi

    echo "========================================"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Azure VM Tear Down (DRY RUN)"
    else
        echo "Azure VM Tear Down"
    fi
    echo "========================================"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Resource Group Exists: $RG_EXISTS"
    echo ""
    echo "This will DELETE all resources in the group:"
    echo "  - Virtual Machine"
    echo "  - Disks (OS and data)"
    echo "  - Network resources"
    echo "  - Storage account"
    echo "  - Key Vault (if CMK enabled)"
    echo "  - Alerts and action groups"
    echo "========================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        if [[ "$RG_EXISTS" == "true" ]]; then
            echo "DRY RUN: Would delete resource group '$RESOURCE_GROUP'"
        else
            echo "DRY RUN: Resource group '$RESOURCE_GROUP' does not exist, nothing to delete"
        fi
        exit 0
    fi

    if [[ "$RG_EXISTS" == "false" ]]; then
        echo ""
        echo "Resource group '$RESOURCE_GROUP' does not exist."
        exit 0
    fi

    echo ""
    read -p "Are you sure you want to destroy all resources? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Destroy cancelled"
        exit 0
    fi

    # Find any Key Vaults in the resource group before deletion (for purging)
    KEY_VAULTS=$(az keyvault list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || echo "")

    echo ""
    echo "Deleting resource group '$RESOURCE_GROUP'..."
    echo "(This may take a few minutes)"
    az group delete --name "$RESOURCE_GROUP" --yes

    # Purge soft-deleted Key Vaults to allow immediate redeployment
    if [[ -n "$KEY_VAULTS" ]]; then
        echo ""
        echo "Purging soft-deleted Key Vault(s) to allow redeployment..."
        for kv in $KEY_VAULTS; do
            echo "  Purging: $kv"
            az keyvault purge --name "$kv" 2>/dev/null || echo "    (already purged or not found)"
        done
    fi

    echo ""
    echo "========================================"
    echo "Tear down complete!"
    echo "========================================"
    exit 0
fi

# For deploy mode, validate additional required arguments
if [[ -z "$VM_NAME" ]]; then
    echo "Error: VM name is required"
    usage
fi

if [[ -z "$ALERT_EMAIL" ]]; then
    echo "Error: Alert email is required"
    usage
fi

# Validate template files exist
if [[ ! -f "$BICEP_FILE" ]]; then
    echo "Error: Bicep template not found: $BICEP_FILE"
    exit 1
fi

if [[ ! -f "$CLOUD_INIT_FILE" ]]; then
    echo "Error: Cloud-init file not found: $CLOUD_INIT_FILE"
    exit 1
fi

if [[ -n "$CUSTOM_ROLE_FILE" && ! -f "$CUSTOM_ROLE_FILE" ]]; then
    echo "Error: Custom role definition not found: $CUSTOM_ROLE_FILE"
    exit 1
fi

if [[ -n "$PARAMETERS_FILE" && ! -f "$PARAMETERS_FILE" ]]; then
    echo "Error: Parameters file not found: $PARAMETERS_FILE"
    exit 1
fi

# Load parameters from file if specified
if [[ -n "$PARAMETERS_FILE" ]]; then
    echo "Loading parameters from: $PARAMETERS_FILE"
    PROJECT_NAME=$(jq -r '.parameters.projectName.value // "vm"' "$PARAMETERS_FILE")
    SERVICE_USER=$(jq -r '.parameters.serviceUser.value // "appuser"' "$PARAMETERS_FILE")
    SERVICE_PORTS=$(jq -r '.parameters.servicePorts.value // ""' "$PARAMETERS_FILE")
    INBOUND_PORTS_JSON=$(jq -c '.parameters.inboundPorts.value // []' "$PARAMETERS_FILE")
fi

# Check if resource group exists
RG_EXISTS=false
if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    RG_EXISTS=true
fi

echo "========================================"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Azure VM Deployment (DRY RUN)"
else
    echo "Azure VM Deployment"
fi
echo "========================================"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "VM Name: $VM_NAME"
echo "VM Size: $VM_SIZE"
echo "Alert Email: $ALERT_EMAIL"
echo "Data Disk: ${DATA_DISK_SIZE}GB"
if [[ "$NO_PUBLIC_IP" == "true" ]]; then
echo "Public IP: No (private network only)"
else
echo "Public IP: Yes"
fi
echo "Local Admin: $ADMIN_USERNAME"
echo ""
echo "Templates:"
echo "  Bicep: $BICEP_FILE"
echo "  Cloud-init: $CLOUD_INIT_FILE"
if [[ -n "$PARAMETERS_FILE" ]]; then
echo "  Parameters: $PARAMETERS_FILE"
fi
if [[ -n "$CUSTOM_ROLE_FILE" ]]; then
echo "  Role definition: $CUSTOM_ROLE_FILE"
fi
echo ""
echo "Project Settings:"
echo "  Project Name: $PROJECT_NAME"
echo "  Service User: $SERVICE_USER"
if [[ -n "$SERVICE_PORTS" ]]; then
echo "  Service Ports: $SERVICE_PORTS"
fi
echo ""
echo "Security:"
if [[ "$ENABLE_CMK" == "true" ]]; then
echo "  - Encryption: Customer-Managed Keys (CMK) enabled"
echo "    - Disk encryption at host"
echo "    - OS and data disks encrypted with CMK"
else
echo "  - Encryption: Platform-managed keys only"
fi
echo "  - SSH: BLOCKED"
if [[ "$INBOUND_PORTS_JSON" != "[]" ]]; then
echo "  - Inbound Ports: (from parameters file)"
echo "$INBOUND_PORTS_JSON" | jq -r '.[] | "    - \(.name): \(.portRange) from \(.sourceAddressPrefixes | join(", "))"'
fi
echo "  - Console: Azure Portal Serial Console / Run Command"
if [[ "$ENABLE_ENTRA_LOGIN" == "true" ]]; then
echo ""
echo "Entra ID Access:"
if [[ -n "$ENTRA_ADMIN" ]]; then
echo "  - Admin (sudo): $ENTRA_ADMIN"
fi
if [[ ${#ENTRA_USERS[@]} -gt 0 ]]; then
for user in "${ENTRA_USERS[@]}"; do
echo "  - User: $user"
done
fi
if [[ ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
for user in "${SERVICE_ADMINS[@]}"; do
echo "  - Service Admin: $user (can act as $SERVICE_USER)"
done
fi
fi
echo "========================================"

# Handle dry run for deploy
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Actions that would be performed:"
    echo ""
    if [[ "$RG_EXISTS" == "true" ]]; then
        echo "  1. DELETE existing resource group '$RESOURCE_GROUP'"
        echo "  2. CREATE new resource group '$RESOURCE_GROUP' in $LOCATION"
    else
        echo "  1. CREATE resource group '$RESOURCE_GROUP' in $LOCATION"
    fi
    echo "  2. DEPLOY infrastructure via Bicep ($BICEP_FILE):"
    echo "       - Virtual Machine: $VM_NAME ($VM_SIZE)"
    echo "       - OS: Ubuntu 22.04 LTS"
    echo "       - Data Disk: ${DATA_DISK_SIZE}GB Premium SSD"
    if [[ "$NO_PUBLIC_IP" == "true" ]]; then
    echo "       - Network: VNet, Subnet, NSG (no public IP)"
    else
    echo "       - Network: VNet, Subnet, NSG, Public IP"
    fi
    echo "       - Storage Account (for diagnostics)"
    echo "       - Metric Alerts (availability, CPU, memory)"
    if [[ "$ENABLE_CMK" == "true" ]]; then
        echo "       - Key Vault (for encryption keys)"
        echo "       - Disk Encryption Set (CMK)"
        echo "       - Encryption at host enabled"
    fi
    if [[ "$ENABLE_ENTRA_LOGIN" == "true" ]]; then
        echo "       - AADSSHLoginForLinux extension"
    fi
    echo "  3. CONFIGURE cloud-init ($CLOUD_INIT_FILE)"
    if [[ "$ENABLE_ENTRA_LOGIN" == "true" ]]; then
        echo "  4. ASSIGN Azure RBAC roles:"
        if [[ -n "$ENTRA_ADMIN" ]]; then
            echo "       - $ENTRA_ADMIN: Virtual Machine Administrator Login (sudo)"
        fi
        if [[ ${#ENTRA_USERS[@]} -gt 0 || ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
            echo "       - CREATE custom role: 'Serial Console User - $VM_NAME'"
            if [[ -n "$CUSTOM_ROLE_FILE" ]]; then
                echo "         (using custom definition: $CUSTOM_ROLE_FILE)"
            else
                echo "         (scoped to this VM and its storage account only)"
            fi
            if [[ ${#ENTRA_USERS[@]} -gt 0 ]]; then
                for user in "${ENTRA_USERS[@]}"; do
                    echo "       - $user: Serial Console User (no sudo, no Run Command, no other VMs)"
                done
            fi
        fi
        if [[ ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
            echo "       - CREATE sudoers rules for service admins:"
            for user in "${SERVICE_ADMINS[@]}"; do
                # Extract username from email (part before @)
                local_user="${user%%@*}"
                echo "       - $user ($local_user): can sudo as $SERVICE_USER, control systemd"
            done
        fi
    fi
    echo ""
    echo "No changes were made."
    exit 0
fi

echo ""

# Check for existing resource group first (affects password prompt)
UPDATE_MODE=false
if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "Resource group '$RESOURCE_GROUP' already exists."

    # Handle --update flag for non-interactive mode
    if [[ "$AUTO_UPDATE" == "true" ]]; then
        echo ""
        echo "In-place update mode (--update flag)."
        echo "  - Public IP and DNS name will be preserved"
        echo "  - Data disk will be preserved"
        echo "  - VM size, NSG rules, and alerts can be updated"
        echo "  - Cloud-init will NOT re-run (use transfer.sh for file updates)"
        echo ""
        UPDATE_MODE=true
    else
        echo ""
        echo "Options:"
        echo "  u) Update in-place - preserve public IP/DNS, update VM config (recommended)"
        echo "  d) Delete and recreate - destroys everything including data disk"
        echo "  c) Cancel"
        echo ""
        read -p "Choose action [u/d/c]: " -n 1 -r
        echo
        case $REPLY in
            [Uu])
                echo ""
                echo "In-place update mode selected."
                echo "  - Public IP and DNS name will be preserved"
                echo "  - Data disk will be preserved"
                echo "  - VM size, NSG rules, and alerts can be updated"
                echo "  - Cloud-init will NOT re-run (use transfer.sh for file updates)"
                echo ""
                UPDATE_MODE=true
                ;;
            [Dd])
                echo ""
                echo "WARNING: This will delete ALL data including the data disk!"
                read -p "Are you sure? (y/N) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    echo "Deleting existing resource group (this may take a few minutes)..."
                    az group delete --name "$RESOURCE_GROUP" --yes
                    echo "Resource group deleted."
                    UPDATE_MODE=false
                else
                    echo "Deployment cancelled"
                    exit 0
                fi
                ;;
            *)
                echo "Deployment cancelled"
                exit 0
                ;;
        esac
    fi
fi

# Prompt for admin password (only for new deployments)
if [[ "$UPDATE_MODE" == "false" ]]; then
    echo "Enter admin password for Serial Console access"
    echo "(min 12 chars, must include uppercase, lowercase, number, and special char)"
    while true; do
        read -s -p "Password: " ADMIN_PASSWORD
        echo
        read -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
        echo
        if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
            echo "Passwords do not match. Please try again."
            continue
        fi
        if [[ ${#ADMIN_PASSWORD} -lt 12 ]]; then
            echo "Password must be at least 12 characters. Please try again."
            continue
        fi
        break
    done
    echo ""
else
    # For updates, we need a placeholder - Bicep won't change existing password
    ADMIN_PASSWORD="PlaceholderNotUsed123!"
fi

# Confirmation prompt (skip with --yes flag)
if [[ "$AUTO_YES" == "true" ]]; then
    echo "Proceeding with deployment (--yes flag)..."
else
    read -p "Continue with deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled"
        exit 0
    fi
fi

# Process cloud-init template with substitutions (only for new deployments)
CLOUD_INIT_PROCESSED=$(mktemp)
CLOUD_INIT_BASE64=""

if [[ "$UPDATE_MODE" == "false" ]]; then
    # Build comma-separated list of service admin usernames
    # Entra ID login uses full email as Linux username (e.g., bino@princeton.edu)
    SERVICE_ADMIN_USERS=""
    if [[ ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
        for admin in "${SERVICE_ADMINS[@]}"; do
            if [[ -z "$SERVICE_ADMIN_USERS" ]]; then
                SERVICE_ADMIN_USERS="$admin"
            else
                SERVICE_ADMIN_USERS="$SERVICE_ADMIN_USERS,$admin"
            fi
        done
    fi

    # Substitute variables in cloud-init template
    sed -e "s/\${ALERT_EMAIL}/$ALERT_EMAIL/g" \
        -e "s/\${SERVICE_USER}/$SERVICE_USER/g" \
        -e "s/\${SERVICE_ADMIN_USERS}/$SERVICE_ADMIN_USERS/g" \
        "$CLOUD_INIT_FILE" > "$CLOUD_INIT_PROCESSED"

    # Base64 encode cloud-init for passing to Bicep
    CLOUD_INIT_BASE64=$(base64 -i "$CLOUD_INIT_PROCESSED" | tr -d '\n')
fi

echo ""
if [[ "$UPDATE_MODE" == "true" ]]; then
    echo "Step 1/3: Updating resource group..."
else
    echo "Step 1/4: Creating resource group..."
fi
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

# Convert NO_PUBLIC_IP to createPublicIp boolean for Bicep
if [[ "$NO_PUBLIC_IP" == "true" ]]; then
    CREATE_PUBLIC_IP="false"
else
    CREATE_PUBLIC_IP="true"
fi

if [[ "$UPDATE_MODE" == "true" ]]; then
    echo "Step 2/3: Updating infrastructure..."
    # For updates, don't pass customData - it can't be changed on existing VM
    DEPLOYMENT_OUTPUT=$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$BICEP_FILE" \
        --parameters \
            vmName="$VM_NAME" \
            vmSize="$VM_SIZE" \
            alertEmail="$ALERT_EMAIL" \
            dataDiskSizeGB="$DATA_DISK_SIZE" \
            adminUsername="$ADMIN_USERNAME" \
            adminPassword="$ADMIN_PASSWORD" \
            enableEntraSSH="$ENABLE_ENTRA_LOGIN" \
            projectName="$PROJECT_NAME" \
            inboundPorts="$INBOUND_PORTS_JSON" \
            createPublicIp="$CREATE_PUBLIC_IP" \
            enableCMK="$ENABLE_CMK" \
        --output json)
else
    echo "Step 2/4: Deploying infrastructure (this takes 3-5 minutes)..."
    if [[ "$ENABLE_CMK" == "true" ]]; then
        echo "  (CMK encryption adds ~2 minutes for Key Vault and encryption setup)"
    fi
    DEPLOYMENT_OUTPUT=$(az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$BICEP_FILE" \
        --parameters \
            vmName="$VM_NAME" \
            vmSize="$VM_SIZE" \
            alertEmail="$ALERT_EMAIL" \
            dataDiskSizeGB="$DATA_DISK_SIZE" \
            adminUsername="$ADMIN_USERNAME" \
            adminPassword="$ADMIN_PASSWORD" \
            enableEntraSSH="$ENABLE_ENTRA_LOGIN" \
            projectName="$PROJECT_NAME" \
            inboundPorts="$INBOUND_PORTS_JSON" \
            createPublicIp="$CREATE_PUBLIC_IP" \
            enableCMK="$ENABLE_CMK" \
            customData="$CLOUD_INIT_BASE64" \
        --output json)
fi

VM_IP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vmPublicIp.value // empty')
VM_FQDN=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vmFqdn.value // empty')
VM_PRIVATE_IP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vmPrivateIp.value // empty')
HAS_PUBLIC_IP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.hasPublicIp.value // true')
SERIAL_CONSOLE_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.serialConsoleUrl.value')
RUN_COMMAND_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.runCommandUrl.value')
CMK_ENABLED=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.cmkEnabled.value // false')
KEY_VAULT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.keyVaultName.value // empty')

# Cloud-init steps only for new deployments
if [[ "$UPDATE_MODE" == "false" ]]; then
    echo "Step 3/4: Applying cloud-init configuration..."
    az vm extension set \
        --resource-group "$RESOURCE_GROUP" \
        --vm-name "$VM_NAME" \
        --name customScript \
        --publisher Microsoft.Azure.Extensions \
        --settings "{\"commandToExecute\": \"cloud-init status --wait\"}" \
        --output none 2>/dev/null || true

    echo "Step 4/4: Running cloud-init setup..."
    az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "cloud-init status --wait && echo 'Cloud-init complete'" \
        --output none 2>/dev/null || true
fi

# Clean up temp file
rm -f "$CLOUD_INIT_PROCESSED"

# Get VM resource ID and subscription for role assignments
VM_RESOURCE_ID=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.vmResourceId.value')
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Helper function to assign role with retry
assign_role_with_retry() {
    local assignee="$1"
    local role="$2"
    local scope="$3"
    local max_attempts=3
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if az role assignment create \
            --assignee "$assignee" \
            --role "$role" \
            --scope "$scope" \
            --output none 2>/dev/null; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            sleep $((attempt * 5))
        fi
        ((attempt++))
    done
    return 1
}

# Assign Entra ID roles if specified
if [[ "$ENABLE_ENTRA_LOGIN" == "true" ]]; then
    echo ""
    if [[ "$UPDATE_MODE" == "true" ]]; then
        echo "Step 3/3: Configuring Entra ID access..."
    else
        echo "Step 5/5: Configuring Entra ID access..."
    fi

    # Get storage account ID for role scoping
    STORAGE_ACCOUNT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.storageAccountName.value // empty')
    if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
        # Fallback: derive from resource group
        STORAGE_ACCOUNT_NAME="${PROJECT_NAME}$(az group show --name "$RESOURCE_GROUP" --query id -o tsv | md5sum | cut -c1-13)"
    fi
    STORAGE_ACCOUNT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

    if [[ -n "$ENTRA_ADMIN" ]]; then
        echo "  Granting admin access to $ENTRA_ADMIN..."
        if ! assign_role_with_retry "$ENTRA_ADMIN" "Virtual Machine Administrator Login" "$VM_RESOURCE_ID"; then
            echo "    Warning: Could not assign role (user may not exist or already assigned)"
        fi
    fi

    # For regular users and service admins, create custom role with minimum Serial Console permissions
    if [[ ${#ENTRA_USERS[@]} -gt 0 || ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
        CUSTOM_ROLE_NAME="Serial Console User - $VM_NAME"

        # Get the actual storage account name from deployment output
        STORAGE_ACCOUNT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.storageAccountName.value // empty')
        if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
            # Query for it directly
            STORAGE_ACCOUNT_NAME=$(az storage account list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
        fi
        STORAGE_ACCOUNT_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

        # Check if custom role already exists
        if ! az role definition list --name "$CUSTOM_ROLE_NAME" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
            echo "  Creating custom role '$CUSTOM_ROLE_NAME'..."

            if [[ -n "$CUSTOM_ROLE_FILE" ]]; then
                # Use custom role definition file, updating name and scopes
                ROLE_DEF=$(cat "$CUSTOM_ROLE_FILE")
                ROLE_DEF=$(echo "$ROLE_DEF" | jq --arg name "$CUSTOM_ROLE_NAME" '.Name = $name')
                ROLE_DEF=$(echo "$ROLE_DEF" | jq --arg vm "$VM_RESOURCE_ID" --arg storage "$STORAGE_ACCOUNT_ID" '.AssignableScopes = [$vm, $storage]')
                echo "$ROLE_DEF" | az role definition create --role-definition @- --output none 2>/dev/null || echo "    Warning: Could not create custom role (may already exist)"
            else
                # Create default role definition scoped to specific VM and storage account
                az role definition create --role-definition "{
                    \"Name\": \"$CUSTOM_ROLE_NAME\",
                    \"Description\": \"Minimum permissions for Serial Console access with Entra ID login to $VM_NAME only\",
                    \"Actions\": [
                        \"Microsoft.Compute/virtualMachines/read\",
                        \"Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action\",
                        \"Microsoft.Storage/storageAccounts/read\",
                        \"Microsoft.Storage/storageAccounts/listKeys/action\",
                        \"Microsoft.SerialConsole/serialPorts/connect/action\",
                        \"Microsoft.Resources/subscriptions/resourceGroups/read\"
                    ],
                    \"DataActions\": [
                        \"Microsoft.Compute/virtualMachines/login/action\"
                    ],
                    \"AssignableScopes\": [
                        \"$VM_RESOURCE_ID\",
                        \"$STORAGE_ACCOUNT_ID\"
                    ]
                }" --output none 2>/dev/null || echo "    Warning: Could not create custom role (may already exist)"
            fi

            # Wait for role to propagate - poll until queryable
            echo "  Waiting for role to propagate..."
            for i in {1..12}; do
                if az role definition list --name "$CUSTOM_ROLE_NAME" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
                    echo "  Role is now available."
                    break
                fi
                if [[ $i -eq 12 ]]; then
                    echo "  Warning: Role propagation timeout, continuing anyway..."
                fi
                sleep 5
            done
        fi

        if [[ ${#ENTRA_USERS[@]} -gt 0 ]]; then
            for user in "${ENTRA_USERS[@]}"; do
                echo "  Granting Serial Console access to $user (scoped to $VM_NAME only)..."

                # Assign role scoped to VM
                if ! assign_role_with_retry "$user" "$CUSTOM_ROLE_NAME" "$VM_RESOURCE_ID"; then
                    echo "    Warning: Could not assign VM role (user may not exist or already assigned)"
                fi

                # Assign role scoped to storage account (required for boot diagnostics)
                if ! assign_role_with_retry "$user" "$CUSTOM_ROLE_NAME" "$STORAGE_ACCOUNT_ID"; then
                    echo "    Warning: Could not assign storage role (user may not exist or already assigned)"
                fi
            done
        fi

        # Service admins also need Serial Console access (plus sudoers configured via cloud-init)
        if [[ ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
            for user in "${SERVICE_ADMINS[@]}"; do
                echo "  Granting Serial Console access to $user (service admin, scoped to $VM_NAME only)..."

                # Virtual Machine User Login - required for Entra ID login at console prompt
                if ! assign_role_with_retry "$user" "Virtual Machine User Login" "$VM_RESOURCE_ID"; then
                    echo "    Warning: Could not assign VM User Login role (user may not exist or already assigned)"
                fi

                if ! assign_role_with_retry "$user" "$CUSTOM_ROLE_NAME" "$VM_RESOURCE_ID"; then
                    echo "    Warning: Could not assign VM role (user may not exist or already assigned)"
                fi

                if ! assign_role_with_retry "$user" "$CUSTOM_ROLE_NAME" "$STORAGE_ACCOUNT_ID"; then
                    echo "    Warning: Could not assign storage role (user may not exist or already assigned)"
                fi
            done
        fi
    fi
fi

echo ""
echo "========================================"
if [[ "$UPDATE_MODE" == "true" ]]; then
    echo "Update Complete!"
else
    echo "Deployment Complete!"
fi
echo "========================================"
echo ""
if [[ "$HAS_PUBLIC_IP" == "true" && -n "$VM_IP" ]]; then
echo "VM Public IP: $VM_IP"
echo "VM FQDN: $VM_FQDN"
else
echo "VM Private IP: $VM_PRIVATE_IP"
echo "(No public IP - access via VPN/private network only)"
fi
echo ""
if [[ "$UPDATE_MODE" == "false" ]]; then
echo "Local Admin (has sudo):"
echo "  Username: $ADMIN_USERNAME"
echo "  Password: (as entered during setup)"
fi
if [[ "$ENABLE_ENTRA_LOGIN" == "true" ]]; then
echo ""
echo "Entra ID Login:"
if [[ -n "$ENTRA_ADMIN" ]]; then
echo "  Admin: $ENTRA_ADMIN (has sudo, full VM access)"
fi
if [[ ${#ENTRA_USERS[@]} -gt 0 ]]; then
for user in "${ENTRA_USERS[@]}"; do
echo "  User: $user (Serial Console only, no sudo)"
done
fi
if [[ ${#SERVICE_ADMINS[@]} -gt 0 ]]; then
for user in "${SERVICE_ADMINS[@]}"; do
echo "  Service Admin: $user (can act as $SERVICE_USER)"
done
fi
echo ""
echo "  Login at Serial Console with Entra email and password."
fi
if [[ -n "$SERVICE_PORTS" ]]; then
echo ""
echo "Service Connection:"
if [[ "$HAS_PUBLIC_IP" == "true" && -n "$VM_FQDN" ]]; then
echo "  Host: $VM_FQDN"
else
echo "  Host: $VM_PRIVATE_IP (via VPN/private network)"
fi
echo "  Ports: $SERVICE_PORTS"
fi
echo ""
echo "Console Access (Azure Portal):"
echo "  Serial Console: $SERIAL_CONSOLE_URL"
echo "  Run Command: $RUN_COMMAND_URL"
echo ""
if [[ "$CMK_ENABLED" == "true" ]]; then
echo "Encryption (CMK):"
echo "  Key Vault: $KEY_VAULT_NAME"
echo "  Disks: Encrypted with customer-managed keys"
echo "  Encryption at Host: Enabled"
echo ""
fi
echo "========================================"
if [[ "$UPDATE_MODE" == "true" ]]; then
echo "Update Summary"
echo "========================================"
echo ""
echo "The following were updated (if changed):"
echo "  - VM size: $VM_SIZE"
echo "  - NSG inbound port rules"
echo "  - Alert configurations"
echo "  - Entra ID role assignments"
echo ""
echo "NOT changed:"
if [[ "$HAS_PUBLIC_IP" == "true" ]]; then
echo "  - Public IP and DNS (preserved)"
fi
echo "  - Data disk contents"
echo "  - Admin password"
echo "  - Cloud-init configuration"
echo ""
echo "To update application files, use transfer.sh:"
echo "  ./transfer.sh -g $RESOURCE_GROUP -n $VM_NAME -t ./app:/home/$SERVICE_USER"
else
echo "Next Steps"
echo "========================================"
echo ""
echo "1. Upload your application files via transfer.sh:"
echo "   ./transfer.sh -g $RESOURCE_GROUP -n $VM_NAME -t ./app:/home/$SERVICE_USER"
echo ""
echo "2. Configure and start your service via Run Command:"
echo "   az vm run-command invoke \\"
echo "     --resource-group $RESOURCE_GROUP \\"
echo "     --name $VM_NAME \\"
echo "     --command-id RunShellScript \\"
echo "     --scripts 'chown -R $SERVICE_USER:$SERVICE_USER /home/$SERVICE_USER'"
echo ""
echo "3. (Optional) Configure SMTP for email alerts:"
echo "   See azure/SMTP-SETUP.md for SendGrid configuration"
fi
echo ""
echo "========================================"
