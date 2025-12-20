#!/bin/bash
set -euo pipefail

# Configure Azure Defender / Security Center security contacts
# This addresses the following Secure Score recommendations:
# - Email notification to subscription owner for high severity alerts should be enabled
# - Subscriptions should have a contact email address for security issues
# - Email notification for high severity alerts should be enabled

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Configure security contact settings for Azure Security Center alerts.

Required:
  -e, --email ADDRESS          Security contact email address

Options:
  --phone PHONE                Security contact phone number (optional)
  --notify-admins              Also notify subscription admins/owners (default: true)
  --no-notify-admins           Don't notify subscription admins/owners
  --dry-run                    Show what would happen without making changes
  -h, --help                   Show this help message

Examples:
  # Configure security contacts
  $0 -e security@example.com

  # Configure with phone number
  $0 -e security@example.com --phone "+1-555-123-4567"

  # Dry run to preview
  $0 -e security@example.com --dry-run

EOF
    exit 1
}

EMAIL=""
PHONE=""
NOTIFY_ADMINS=true
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        --phone)
            PHONE="$2"
            shift 2
            ;;
        --notify-admins)
            NOTIFY_ADMINS=true
            shift
            ;;
        --no-notify-admins)
            NOTIFY_ADMINS=false
            shift
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
if [[ -z "$EMAIL" ]]; then
    echo "Error: Security contact email is required"
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

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

echo ""
echo "========================================"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "Security Contact Configuration (DRY RUN)"
else
    echo "Security Contact Configuration"
fi
echo "========================================"
echo ""
echo "Subscription: $SUBSCRIPTION_NAME"
echo "Subscription ID: $SUBSCRIPTION_ID"
echo ""
echo "Settings:"
echo "  Email: $EMAIL"
if [[ -n "$PHONE" ]]; then
echo "  Phone: $PHONE"
fi
echo "  Notify Admins: $NOTIFY_ADMINS"
echo ""
echo "This will configure:"
echo "  - Security contact email for alerts"
echo "  - High severity alert notifications enabled"
if [[ "$NOTIFY_ADMINS" == "true" ]]; then
echo "  - Subscription owner notifications enabled"
fi
echo ""
echo "========================================"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "Commands that would be executed:"
    echo ""
    echo "  az security contact create \\"
    echo "    --name 'default' \\"
    echo "    --emails '$EMAIL' \\"
    if [[ -n "$PHONE" ]]; then
    echo "    --phone '$PHONE' \\"
    fi
    echo "    --alert-notifications '{\"state\":\"On\",\"minimalSeverity\":\"High\"}' \\"
    if [[ "$NOTIFY_ADMINS" == "true" ]]; then
    echo "    --notifications-by-role '{\"state\":\"On\",\"roles\":[\"Owner\",\"ServiceAdmin\"]}'"
    else
    echo "    --notifications-by-role '{\"state\":\"Off\",\"roles\":[]}'"
    fi
    echo ""
    echo "No changes were made."
    exit 0
fi

echo ""
read -p "Continue with configuration? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Configuration cancelled"
    exit 0
fi

echo ""
echo "Configuring security contacts..."

# Build notification settings as JSON
ALERT_NOTIFICATIONS='{"state":"On","minimalSeverity":"High"}'

if [[ "$NOTIFY_ADMINS" == "true" ]]; then
    NOTIFICATIONS_BY_ROLE='{"state":"On","roles":["Owner","ServiceAdmin"]}'
else
    NOTIFICATIONS_BY_ROLE='{"state":"Off","roles":[]}'
fi

# Build the az command
CMD="az security contact create --name default --emails '$EMAIL'"

if [[ -n "$PHONE" ]]; then
    CMD="$CMD --phone '$PHONE'"
fi

CMD="$CMD --alert-notifications '$ALERT_NOTIFICATIONS' --notifications-by-role '$NOTIFICATIONS_BY_ROLE'"

# Execute
eval "$CMD" --output none

echo ""
echo "========================================"
echo "Configuration Complete!"
echo "========================================"
echo ""
echo "Security contact settings have been configured."
echo ""
echo "You can verify the settings in Azure Portal:"
echo "  https://portal.azure.com/#blade/Microsoft_Azure_Security/SecurityMenuBlade/SecurityContacts"
echo ""
echo "Or via CLI:"
echo "  az security contact list -o table"
echo ""
echo "========================================"
