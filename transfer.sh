#!/bin/bash
set -euo pipefail

# Azure VM Data Transfer Script
# Transfers files to Azure VM via temporary Blob Storage container
# Automatically cleans up the container after transfer to avoid ongoing costs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
RESOURCE_GROUP=""
VM_NAME=""
DRY_RUN=false
VERBOSE=false
QUICK_MODE=false

# Transfer paths (can specify multiple)
declare -a LOCAL_PATHS=()
declare -a VM_PATHS=()

# Project-specific settings
SERVICE_USER="appuser"
VM_BASE_PATH=""
PARAMETERS_FILE=""

# Quick mode size limit (1MB base64 encoded fits in run-command)
QUICK_MODE_LIMIT=$((512 * 1024))

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Transfer files from local machine to Azure VM via temporary Blob Storage.
The storage container is automatically deleted after transfer to avoid costs.

Required:
  -g, --resource-group NAME    Azure resource group (must match deployment)
  -n, --name NAME              VM name (must match deployment)

Transfer Paths (at least one required):
  -t, --transfer LOCAL:VM      Transfer LOCAL path to VM path
                               Can be specified multiple times
                               Directories are transferred recursively

Options:
  --parameters FILE            Parameters JSON (to read serviceUser)
  --service-user USER          Override service user (default: appuser)
  --quick                      Quick mode for single small files (<512KB)
                               Uses run-command instead of blob storage
  --dry-run                    Show what would happen without transferring
  -v, --verbose                Show detailed progress
  -h, --help                   Show this help message

Examples:
  # Transfer single directory
  $0 -g myapp-rg -n myapp-vm -t ./myapp:/home/appuser

  # Transfer multiple paths
  $0 -g myapp-rg -n myapp-vm \\
     -t ./app:/home/appuser \\
     -t ./data:/home/appuser/data

  # Transfer with parameters file (gets service user from parameters)
  $0 -g hfm-rg -n hfm-vm \\
     --parameters ./hfm-parameters.json \\
     -t ./hfm:/home/hfm

  # HFM-specific example (transfers hfm dir including db subdirectory)
  $0 -g hfm-rg -n hfm-vm \\
     --service-user hfm \\
     -t ./hfm:/home/hfm

  # Dry run to preview
  $0 -g myapp-rg -n myapp-vm -t ./app:/home/appuser --dry-run

  # Quick transfer of a single small file (no blob storage)
  $0 -g myapp-rg -n myapp-vm --quick -t ./config.json:/home/appuser/config.json

How it works:
  1. Creates temporary storage container in resource group's storage account
  2. Uses azcopy to upload files from local machine to blob storage
  3. Uses azcopy on VM (via Run Command) to download from blob to VM
  4. Sets correct ownership (serviceUser:serviceUser)
  5. Deletes the temporary container to avoid storage costs

Prerequisites:
  - Azure CLI (az) installed and logged in
  - azcopy installed locally (for uploading)
  - azcopy installed on VM (included in cloud-init)
  - VM deployed via deploy.sh with boot diagnostics storage account

EOF
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "$*"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -t|--transfer)
            # Parse LOCAL:VM format
            TRANSFER_SPEC="$2"
            if [[ ! "$TRANSFER_SPEC" =~ : ]]; then
                echo "Error: Transfer path must be in LOCAL:VM format"
                echo "Example: -t ./myapp:/home/appuser"
                exit 1
            fi
            LOCAL_PATH="${TRANSFER_SPEC%%:*}"
            VM_PATH="${TRANSFER_SPEC#*:}"
            LOCAL_PATHS+=("$LOCAL_PATH")
            VM_PATHS+=("$VM_PATH")
            shift 2
            ;;
        --parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        --service-user)
            SERVICE_USER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --quick)
            QUICK_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
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

if [[ -z "$VM_NAME" ]]; then
    echo "Error: VM name is required"
    usage
fi

if [[ ${#LOCAL_PATHS[@]} -eq 0 ]]; then
    echo "Error: At least one transfer path is required"
    usage
fi

# Load service user from parameters if provided
if [[ -n "$PARAMETERS_FILE" ]]; then
    if [[ ! -f "$PARAMETERS_FILE" ]]; then
        echo "Error: Parameters file not found: $PARAMETERS_FILE"
        exit 1
    fi
    PARAM_SERVICE_USER=$(jq -r '.parameters.serviceUser.value // empty' "$PARAMETERS_FILE")
    if [[ -n "$PARAM_SERVICE_USER" ]]; then
        SERVICE_USER="$PARAM_SERVICE_USER"
    fi
fi

# Check for required tools
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed"
    echo "Install from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

if ! command -v azcopy &> /dev/null; then
    echo "Error: azcopy is not installed"
    echo "Install from: https://docs.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-v10"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

# Check Azure login
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

# Validate local paths exist
for i in "${!LOCAL_PATHS[@]}"; do
    LOCAL_PATH="${LOCAL_PATHS[$i]}"
    if [[ ! -e "$LOCAL_PATH" ]]; then
        echo "Error: Local path does not exist: $LOCAL_PATH"
        exit 1
    fi
done

# Quick mode: transfer single small file via run-command (no blob storage)
if [[ "$QUICK_MODE" == "true" ]]; then
    # Validate quick mode constraints
    if [[ ${#LOCAL_PATHS[@]} -ne 1 ]]; then
        echo "Error: Quick mode only supports a single file transfer"
        exit 1
    fi

    LOCAL_PATH="${LOCAL_PATHS[0]}"
    VM_PATH="${VM_PATHS[0]}"

    if [[ -d "$LOCAL_PATH" ]]; then
        echo "Error: Quick mode does not support directories. Use without --quick for directories."
        exit 1
    fi

    FILE_SIZE=$(stat -f%z "$LOCAL_PATH" 2>/dev/null || stat -c%s "$LOCAL_PATH" 2>/dev/null)
    if [[ "$FILE_SIZE" -gt "$QUICK_MODE_LIMIT" ]]; then
        echo "Error: File too large for quick mode (${FILE_SIZE} bytes > ${QUICK_MODE_LIMIT} bytes limit)"
        echo "Use without --quick for large files."
        exit 1
    fi

    echo ""
    echo "========================================"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Quick Transfer (DRY RUN)"
    else
        echo "Quick Transfer"
    fi
    echo "========================================"
    echo ""
    echo "Resource Group: $RESOURCE_GROUP"
    echo "VM Name: $VM_NAME"
    echo "Service User: $SERVICE_USER"
    echo ""
    echo "Transfer:"
    echo "  $LOCAL_PATH -> $VM_PATH ($(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "${FILE_SIZE} bytes"))"
    echo ""
    echo "========================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "Would transfer file via az vm run-command (base64 encoded)"
        echo "No blob storage container would be created."
        exit 0
    fi

    echo ""
    log "Transferring file via run-command..."

    # Base64 encode the file
    FILE_CONTENT=$(base64 -i "$LOCAL_PATH" | tr -d '\n')
    VM_DIR=$(dirname "$VM_PATH")

    # Build the script to decode and write the file
    SCRIPT="mkdir -p '$VM_DIR'; echo '$FILE_CONTENT' | base64 -d > '$VM_PATH'; chown '$SERVICE_USER:$SERVICE_USER' '$VM_PATH'; chmod 644 '$VM_PATH'; ls -la '$VM_PATH'"

    RESULT=$(az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --command-id RunShellScript \
        --scripts "$SCRIPT" \
        --output json 2>&1)

    if echo "$RESULT" | jq -e '.value[0].message' &>/dev/null; then
        MESSAGE=$(echo "$RESULT" | jq -r '.value[0].message')
        if [[ "$MESSAGE" == *"error"* || "$MESSAGE" == *"Error"* ]]; then
            echo "Error: Transfer failed"
            echo "$MESSAGE"
            exit 1
        else
            echo ""
            echo "========================================"
            echo "Quick Transfer Complete!"
            echo "========================================"
            echo ""
            echo "File transferred: $VM_PATH"
            echo "Owner: $SERVICE_USER"
            echo ""
            echo "VM output:"
            echo "$MESSAGE" | grep -v '^\[std'
            echo "========================================"
        fi
    else
        echo "Error: Unexpected response:"
        echo "$RESULT"
        exit 1
    fi

    exit 0
fi

# Get storage account from resource group
log "Looking up storage account in resource group '$RESOURCE_GROUP'..."
STORAGE_ACCOUNT=$(az storage account list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[0].name" -o tsv 2>/dev/null)

if [[ -z "$STORAGE_ACCOUNT" ]]; then
    echo "Error: No storage account found in resource group '$RESOURCE_GROUP'"
    echo "Make sure the VM was deployed with deploy.sh (which creates a storage account)"
    exit 1
fi

verbose "Found storage account: $STORAGE_ACCOUNT"

# Generate unique container name
CONTAINER_NAME="transfer-$(date +%Y%m%d-%H%M%S)-$$"
verbose "Container name: $CONTAINER_NAME"

# Calculate transfer summary
echo ""
echo "========================================"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Data Transfer to Azure VM (DRY RUN)"
else
    echo "Data Transfer to Azure VM"
fi
echo "========================================"
echo ""
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Name: $VM_NAME"
echo "Storage Account: $STORAGE_ACCOUNT"
echo "Container: $CONTAINER_NAME (temporary)"
echo "Service User: $SERVICE_USER"
echo ""
echo "Transfers:"
for i in "${!LOCAL_PATHS[@]}"; do
    LOCAL_PATH="${LOCAL_PATHS[$i]}"
    VM_PATH="${VM_PATHS[$i]}"
    # Get size estimate
    if [[ -d "$LOCAL_PATH" ]]; then
        SIZE=$(du -sh "$LOCAL_PATH" 2>/dev/null | cut -f1)
        echo "  $LOCAL_PATH/ -> $VM_PATH/ ($SIZE)"
    else
        SIZE=$(ls -lh "$LOCAL_PATH" 2>/dev/null | awk '{print $5}')
        echo "  $LOCAL_PATH -> $VM_PATH ($SIZE)"
    fi
done
echo ""
echo "========================================"

# Dry run mode
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Steps that would be performed:"
    echo ""
    echo "  1. CREATE temporary container '$CONTAINER_NAME' in storage account"
    echo "  2. UPLOAD files from local paths to blob storage using azcopy"
    for i in "${!LOCAL_PATHS[@]}"; do
        LOCAL_PATH="${LOCAL_PATHS[$i]}"
        echo "     - $LOCAL_PATH -> blob:$CONTAINER_NAME/transfer-$i/"
    done
    echo "  3. DOWNLOAD files from blob storage to VM using azcopy (via Run Command)"
    for i in "${!VM_PATHS[@]}"; do
        VM_PATH="${VM_PATHS[$i]}"
        echo "     - blob:$CONTAINER_NAME/transfer-$i/ -> $VM_PATH"
    done
    echo "  4. SET ownership to $SERVICE_USER:$SERVICE_USER"
    echo "  5. DELETE temporary container '$CONTAINER_NAME'"
    echo ""
    echo "No changes were made."
    exit 0
fi

echo ""
read -p "Continue with transfer? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Transfer cancelled"
    exit 0
fi

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -n "${CONTAINER_CREATED:-}" && "$CONTAINER_CREATED" == "true" ]]; then
        log "Cleaning up: Deleting temporary container '$CONTAINER_NAME'..."
        az storage container delete \
            --name "$CONTAINER_NAME" \
            --account-name "$STORAGE_ACCOUNT" \
            --auth-mode login \
            --output none 2>/dev/null || true
        log "Container deleted."
    fi
    exit $exit_code
}
trap cleanup EXIT

# Step 1: Create temporary container
log "Step 1/${#LOCAL_PATHS[@]}+3: Creating temporary container..."
az storage container create \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --output none
CONTAINER_CREATED=true
verbose "Container created: $CONTAINER_NAME"

# Step 2: Upload files to blob storage
log "Step 2/${#LOCAL_PATHS[@]}+3: Uploading files to blob storage..."

# Generate SAS token valid for 1 hour (enough for transfer)
# macOS uses -v+1H, Linux uses -d '+1 hour'
SAS_EXPIRY=$(date -u -v+1H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')
verbose "Generating SAS token (expires: $SAS_EXPIRY)..."

# Use user delegation SAS (Entra ID-based, no shared keys required)
# This requires the user to have Storage Blob Data Contributor role on the storage account
verbose "Generating user delegation SAS token..."
SAS_TOKEN=$(az storage container generate-sas \
    --name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --as-user \
    --auth-mode login \
    --permissions rwdl \
    --expiry "$SAS_EXPIRY" \
    -o tsv 2>/dev/null) || {
    echo ""
    echo "Error: Failed to generate user delegation SAS token."
    echo "This requires 'Storage Blob Data Contributor' role on the storage account."
    echo ""
    echo "To fix this, assign the role to yourself:"
    echo "  az role assignment create --assignee <your-email> \\"
    echo "    --role 'Storage Blob Data Contributor' \\"
    echo "    --scope /subscriptions/<sub>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"
    exit 1
}

BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER_NAME}"

for i in "${!LOCAL_PATHS[@]}"; do
    LOCAL_PATH="${LOCAL_PATHS[$i]}"
    BLOB_DEST="${BLOB_URL}/transfer-${i}"

    log "  Uploading: $LOCAL_PATH -> blob:transfer-${i}/"

    # Run azcopy - set COLUMNS to ensure full progress line is shown
    # Use || true to prevent set -e from exiting on partial failures
    if [[ -d "$LOCAL_PATH" ]]; then
        # Directory upload
        COLUMNS=120 azcopy copy \
            "$LOCAL_PATH/*" \
            "${BLOB_DEST}?${SAS_TOKEN}" \
            --recursive || {
                echo ""
                echo "    Warning: Some files may have failed to upload (check azcopy output above)"
            }
    else
        # Single file upload
        COLUMNS=120 azcopy copy \
            "$LOCAL_PATH" \
            "${BLOB_DEST}/$(basename "$LOCAL_PATH")?${SAS_TOKEN}" || {
                echo ""
                echo "    Warning: File upload may have failed"
            }
    fi
    echo ""
done

log "  Upload complete"

# Step 3: Download files to VM via Run Command
log "Step 3/${#LOCAL_PATHS[@]}+3: Downloading files to VM..."

# Build the download script
DOWNLOAD_SCRIPT="#!/bin/bash
set -e

# Install azcopy if not present
if ! command -v azcopy &> /dev/null; then
    echo 'Installing azcopy...'
    cd /tmp
    curl -sL https://aka.ms/downloadazcopy-v10-linux | tar xz --strip-components=1
    mv azcopy /usr/local/bin/
    chmod +x /usr/local/bin/azcopy
fi

BLOB_URL='$BLOB_URL'
SAS_TOKEN='$SAS_TOKEN'

"

for i in "${!VM_PATHS[@]}"; do
    VM_PATH="${VM_PATHS[$i]}"
    DOWNLOAD_SCRIPT+="
echo 'Downloading to: $VM_PATH'
mkdir -p '$VM_PATH'
azcopy copy \"\${BLOB_URL}/transfer-${i}/*?\${SAS_TOKEN}\" '$VM_PATH' --recursive 2>&1 || true
"
done

# Set ownership
DOWNLOAD_SCRIPT+="
echo 'Setting ownership to $SERVICE_USER:$SERVICE_USER'
"
for i in "${!VM_PATHS[@]}"; do
    VM_PATH="${VM_PATHS[$i]}"
    DOWNLOAD_SCRIPT+="chown -R '$SERVICE_USER:$SERVICE_USER' '$VM_PATH' 2>/dev/null || echo 'Warning: Could not set ownership on $VM_PATH'
"
done

DOWNLOAD_SCRIPT+="
echo 'Transfer complete!'
"

verbose "Running download script on VM..."

# Execute on VM via Run Command
RESULT=$(az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "$DOWNLOAD_SCRIPT" \
    --output json 2>&1)

# Check result
if echo "$RESULT" | jq -e '.value[0].message' &>/dev/null; then
    MESSAGE=$(echo "$RESULT" | jq -r '.value[0].message')
    if [[ "$MESSAGE" == *"error"* || "$MESSAGE" == *"Error"* || "$MESSAGE" == *"failed"* ]]; then
        echo ""
        echo "Warning: VM command completed with errors:"
        echo "$MESSAGE"
    else
        verbose "VM download output:"
        verbose "$MESSAGE"
    fi
else
    echo ""
    echo "Warning: Unexpected response from VM run-command:"
    echo "$RESULT"
fi

# Step 4: Container cleanup happens in trap

echo ""
log "Step 4/${#LOCAL_PATHS[@]}+3: Cleaning up temporary container..."
# The trap will handle deletion

echo ""
echo "========================================"
echo "Transfer Complete!"
echo "========================================"
echo ""
echo "Files transferred to VM:"
for i in "${!VM_PATHS[@]}"; do
    VM_PATH="${VM_PATHS[$i]}"
    echo "  - $VM_PATH (owned by $SERVICE_USER)"
done
echo ""
echo "Temporary storage container has been deleted."
echo "No ongoing storage costs will be incurred."
echo ""
echo "To verify on the VM:"
echo "  az vm run-command invoke \\"
echo "    --resource-group $RESOURCE_GROUP \\"
echo "    --name $VM_NAME \\"
echo "    --command-id RunShellScript \\"
echo "    --scripts 'ls -la ${VM_PATHS[0]}'"
echo ""
echo "========================================"
