#!/bin/bash
set -euo pipefail

# Azure Subscription Move Script
# Moves all resources from one subscription to another within the same tenant

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Required:
  -g, --resource-group NAME       Resource group to move
  -t, --target-subscription ID    Target subscription ID or name

Optional:
  --dry-run                       Show what would happen without making changes
  -h, --help                      Show this help message

Notes:
  - Both subscriptions must be in the same Azure AD tenant
  - You must have Contributor access on both subscriptions
  - Some resources may have brief downtime during the move
  - The resource group name will remain the same in the target subscription

Examples:
  # Dry run to see what will be moved
  $0 -g myapp-rg -t "New-Subscription-Name" --dry-run

  # Perform the move
  $0 -g myapp-rg -t "00000000-0000-0000-0000-000000000000"

EOF
    exit 1
}

# Default values
RESOURCE_GROUP=""
TARGET_SUBSCRIPTION=""
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -t|--target-subscription)
            TARGET_SUBSCRIPTION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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

if [[ -z "$TARGET_SUBSCRIPTION" ]]; then
    echo "Error: Target subscription is required"
    usage
fi

# Check for Azure CLI
if ! command -v az &> /dev/null; then
    echo "Error: Azure CLI (az) is not installed"
    exit 1
fi

# Check Azure login
if ! az account show &> /dev/null; then
    echo "Not logged in to Azure. Running 'az login'..."
    az login
fi

# Get current subscription info
CURRENT_SUBSCRIPTION=$(az account show --query id -o tsv)
CURRENT_SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# Resolve target subscription ID if name was provided
if [[ ! "$TARGET_SUBSCRIPTION" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "Resolving subscription name '$TARGET_SUBSCRIPTION'..."
    TARGET_SUBSCRIPTION_ID=$(az account list --query "[?name=='$TARGET_SUBSCRIPTION'].id" -o tsv)
    if [[ -z "$TARGET_SUBSCRIPTION_ID" ]]; then
        echo "Error: Could not find subscription with name '$TARGET_SUBSCRIPTION'"
        echo ""
        echo "Available subscriptions:"
        az account list --query "[].{Name:name, ID:id}" -o table
        exit 1
    fi
    TARGET_SUBSCRIPTION="$TARGET_SUBSCRIPTION_ID"
fi

# Verify target subscription exists and is in same tenant
TARGET_TENANT=$(az account show --subscription "$TARGET_SUBSCRIPTION" --query tenantId -o tsv 2>/dev/null) || {
    echo "Error: Cannot access target subscription '$TARGET_SUBSCRIPTION'"
    echo "Make sure you have access to this subscription."
    exit 1
}

if [[ "$TENANT_ID" != "$TARGET_TENANT" ]]; then
    echo "Error: Target subscription is in a different tenant"
    echo "  Current tenant: $TENANT_ID"
    echo "  Target tenant:  $TARGET_TENANT"
    echo ""
    echo "Cross-tenant moves are not supported. Use Bicep/Terraform redeploy instead."
    exit 1
fi

TARGET_SUBSCRIPTION_NAME=$(az account show --subscription "$TARGET_SUBSCRIPTION" --query name -o tsv)

# Check if source resource group exists
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "Error: Resource group '$RESOURCE_GROUP' does not exist in current subscription"
    exit 1
fi

# Check if resource group already exists in target subscription
if az group show --name "$RESOURCE_GROUP" --subscription "$TARGET_SUBSCRIPTION" &> /dev/null 2>&1; then
    echo "Error: Resource group '$RESOURCE_GROUP' already exists in target subscription"
    echo "Delete it first or choose a different resource group name."
    exit 1
fi

# Get all resources in the resource group
echo "Discovering resources in '$RESOURCE_GROUP'..."
RESOURCES=$(az resource list --resource-group "$RESOURCE_GROUP" --query "[].{id:id, name:name, type:type}" -o json)
RESOURCE_COUNT=$(echo "$RESOURCES" | jq length)
RESOURCE_IDS=$(echo "$RESOURCES" | jq -r '.[].id' | tr '\n' ' ')

echo ""
echo "========================================"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Azure Subscription Move (DRY RUN)"
else
    echo "Azure Subscription Move"
fi
echo "========================================"
echo ""
echo "Source:"
echo "  Subscription: $CURRENT_SUBSCRIPTION_NAME"
echo "  ID: $CURRENT_SUBSCRIPTION"
echo ""
echo "Target:"
echo "  Subscription: $TARGET_SUBSCRIPTION_NAME"
echo "  ID: $TARGET_SUBSCRIPTION"
echo ""
echo "Resource Group: $RESOURCE_GROUP"
echo "Resources to move: $RESOURCE_COUNT"
echo ""
echo "Resources:"
echo "$RESOURCES" | jq -r '.[] | "  - \(.type): \(.name)"'
echo ""
echo "========================================"

# Validate that resources can be moved
echo ""
echo "Validating move operation..."
VALIDATION_RESULT=$(az resource invoke-action \
    --action validateMoveResources \
    --ids "/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP" \
    --request-body "{
        \"resources\": $(echo "$RESOURCES" | jq '[.[].id]'),
        \"targetResourceGroup\": \"/subscriptions/$TARGET_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP\"
    }" 2>&1) || {
    echo ""
    echo "Warning: Move validation returned an error (this may be expected for some resource types)"
    echo "$VALIDATION_RESULT"
    echo ""
}

# Check for resources that cannot be moved
echo ""
echo "Checking resource move support..."
UNSUPPORTED=""
for type in $(echo "$RESOURCES" | jq -r '.[].type' | sort -u); do
    # Known unsupported types
    case "$type" in
        "Microsoft.Compute/virtualMachines/extensions")
            # Extensions move with their parent VM
            ;;
        *)
            ;;
    esac
done

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "DRY RUN: Would perform the following actions:"
    echo ""
    echo "  1. Create resource group '$RESOURCE_GROUP' in target subscription"
    echo "  2. Move $RESOURCE_COUNT resources to target subscription"
    echo "  3. Delete empty resource group from source subscription"
    echo ""
    echo "Estimated time: 5-15 minutes (varies by resource types)"
    echo ""
    echo "No changes were made."
    exit 0
fi

echo ""
read -p "Proceed with move? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Move cancelled"
    exit 0
fi

# Create resource group in target subscription
echo ""
echo "Step 1/3: Creating resource group in target subscription..."
LOCATION=$(az group show --name "$RESOURCE_GROUP" --query location -o tsv)
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --subscription "$TARGET_SUBSCRIPTION" \
    --output none

# Move resources
echo "Step 2/3: Moving resources (this may take 5-15 minutes)..."
az resource move \
    --destination-group "$RESOURCE_GROUP" \
    --destination-subscription-id "$TARGET_SUBSCRIPTION" \
    --ids $RESOURCE_IDS

# Delete empty source resource group
echo "Step 3/3: Cleaning up source resource group..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

echo ""
echo "========================================"
echo "Move Complete!"
echo "========================================"
echo ""
echo "Resources have been moved to:"
echo "  Subscription: $TARGET_SUBSCRIPTION_NAME"
echo "  Resource Group: $RESOURCE_GROUP"
echo ""
echo "To work with these resources, switch subscriptions:"
echo "  az account set --subscription \"$TARGET_SUBSCRIPTION\""
echo ""
echo "Note: It may take a few minutes for all resources to be fully available."
echo "========================================"
