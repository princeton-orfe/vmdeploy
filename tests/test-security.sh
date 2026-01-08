#!/bin/bash
# Tests for security configuration in vmdeploy scripts
# Run from the vmdeploy directory: ./tests/test-security.sh

set -uo pipefail

# Determine project directory
if [[ -f "main.bicep" ]]; then
    PROJECT_DIR="."
elif [[ -f "../main.bicep" ]]; then
    PROJECT_DIR=".."
else
    echo "Error: Run this script from the vmdeploy directory or tests subdirectory"
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++)) || true
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++)) || true
}

echo "========================================"
echo "Security Configuration Tests"
echo "========================================"
echo ""

# Test 1: Guest Configuration extension is defined in Bicep
echo "Testing main.bicep..."

if grep -q "Microsoft.GuestConfiguration" "$PROJECT_DIR/main.bicep"; then
    pass "Guest Configuration extension is defined"
else
    fail "Guest Configuration extension is NOT defined"
fi

if grep -q "ConfigurationforLinux" "$PROJECT_DIR/main.bicep"; then
    pass "Guest Configuration uses Linux configuration type"
else
    fail "Guest Configuration does not use Linux configuration type"
fi

# Test 2: Storage account has shared key access enabled (required for Serial Console)
if grep -q "allowSharedKeyAccess: true" "$PROJECT_DIR/main.bicep"; then
    pass "Storage account has shared key access enabled (required for Serial Console)"
else
    fail "Storage account shared key access not configured"
fi

if grep -q "minimumTlsVersion: 'TLS1_2'" "$PROJECT_DIR/main.bicep"; then
    pass "Storage account enforces TLS 1.2"
else
    fail "Storage account does NOT enforce TLS 1.2"
fi

if grep -q "supportsHttpsTrafficOnly: true" "$PROJECT_DIR/main.bicep"; then
    pass "Storage account requires HTTPS only"
else
    fail "Storage account does NOT require HTTPS only"
fi

# Test 3: Key Vault diagnostic settings
if grep -q "Microsoft.Insights/diagnosticSettings" "$PROJECT_DIR/main.bicep"; then
    pass "Key Vault diagnostic settings are defined"
else
    fail "Key Vault diagnostic settings are NOT defined"
fi

if grep -q "Microsoft.OperationalInsights/workspaces" "$PROJECT_DIR/main.bicep"; then
    pass "Log Analytics workspace is defined for diagnostics"
else
    fail "Log Analytics workspace is NOT defined"
fi

if grep -q "categoryGroup: 'audit'" "$PROJECT_DIR/main.bicep"; then
    pass "Audit log category is enabled"
else
    fail "Audit log category is NOT enabled"
fi

# Test 4: Encryption at host
if grep -q "encryptionAtHost: true" "$PROJECT_DIR/main.bicep"; then
    pass "Encryption at host is enabled"
else
    fail "Encryption at host is NOT enabled"
fi

# Test 5: Key Vault security settings
if grep -q "enablePurgeProtection: true" "$PROJECT_DIR/main.bicep"; then
    pass "Key Vault purge protection is enabled"
else
    fail "Key Vault purge protection is NOT enabled"
fi

if grep -q "enableRbacAuthorization: true" "$PROJECT_DIR/main.bicep"; then
    pass "Key Vault RBAC authorization is enabled"
else
    fail "Key Vault RBAC authorization is NOT enabled"
fi

# Test 6: transfer.sh uses user delegation SAS
echo ""
echo "Testing transfer.sh..."

if grep -q "\-\-as-user" "$PROJECT_DIR/transfer.sh"; then
    pass "transfer.sh uses user delegation SAS tokens"
else
    fail "transfer.sh does NOT use user delegation SAS tokens"
fi

if grep -q "az storage account keys list" "$PROJECT_DIR/transfer.sh"; then
    fail "transfer.sh still uses storage account keys"
else
    pass "transfer.sh does not use storage account keys"
fi

# Test 7: deploy.sh grants Storage Blob Data Contributor
echo ""
echo "Testing deploy.sh..."

if grep -q "Storage Blob Data Contributor" "$PROJECT_DIR/deploy.sh"; then
    pass "deploy.sh grants Storage Blob Data Contributor role"
else
    fail "deploy.sh does NOT grant Storage Blob Data Contributor role"
fi

# Test 8: Custom role does not include listKeys
if grep -q "Microsoft.Storage/storageAccounts/listKeys/action" "$PROJECT_DIR/deploy.sh"; then
    fail "Custom role still includes listKeys action"
else
    pass "Custom role does not include listKeys action"
fi

# Test 9: Security contacts script exists and is executable
echo ""
echo "Testing configure-security-contacts.sh..."

if [[ -f "$PROJECT_DIR/configure-security-contacts.sh" ]]; then
    pass "configure-security-contacts.sh exists"
else
    fail "configure-security-contacts.sh does NOT exist"
fi

if [[ -x "$PROJECT_DIR/configure-security-contacts.sh" ]]; then
    pass "configure-security-contacts.sh is executable"
else
    fail "configure-security-contacts.sh is NOT executable"
fi

if grep -q "az security contact create" "$PROJECT_DIR/configure-security-contacts.sh"; then
    pass "configure-security-contacts.sh uses az security contact create"
else
    fail "configure-security-contacts.sh does NOT use correct command"
fi

if grep -q '"state":"On"' "$PROJECT_DIR/configure-security-contacts.sh"; then
    pass "configure-security-contacts.sh enables alert notifications"
else
    fail "configure-security-contacts.sh does NOT enable alert notifications"
fi

# Test 10: Entra ID authentication support in main.bicep
echo ""
echo "Testing Entra ID authentication configuration..."

if grep -q "enableEntraLogin" "$PROJECT_DIR/main.bicep"; then
    pass "main.bicep has enableEntraLogin parameter"
else
    fail "main.bicep does NOT have enableEntraLogin parameter"
fi

if grep -q "AADSSHLoginForLinux" "$PROJECT_DIR/main.bicep"; then
    pass "main.bicep defines AADSSHLoginForLinux extension"
else
    fail "main.bicep does NOT define AADSSHLoginForLinux extension"
fi

if grep -q "type: 'SystemAssigned'" "$PROJECT_DIR/main.bicep"; then
    pass "main.bicep supports System Assigned Managed Identity"
else
    fail "main.bicep does NOT support System Assigned Managed Identity"
fi

# Test 11: deploy.sh grants Virtual Machine Login roles
echo ""
echo "Testing deploy.sh Entra ID role assignments..."

if grep -q "Virtual Machine Administrator Login" "$PROJECT_DIR/deploy.sh"; then
    pass "deploy.sh grants Virtual Machine Administrator Login role"
else
    fail "deploy.sh does NOT grant Virtual Machine Administrator Login role"
fi

if grep -q "Virtual Machine User Login" "$PROJECT_DIR/deploy.sh"; then
    pass "deploy.sh grants Virtual Machine User Login role"
else
    fail "deploy.sh does NOT grant Virtual Machine User Login role"
fi

# Test 12: main.json is up to date
echo ""
echo "Testing main.json synchronization..."

if [[ -f "$PROJECT_DIR/main.json" ]]; then
    pass "main.json exists"

    if grep -q "allowSharedKeyAccess" "$PROJECT_DIR/main.json"; then
        pass "main.json contains storage security settings"
    else
        fail "main.json does NOT contain storage security settings (rebuild needed)"
    fi

    if grep -q "Microsoft.GuestConfiguration" "$PROJECT_DIR/main.json"; then
        pass "main.json contains Guest Configuration extension"
    else
        fail "main.json does NOT contain Guest Configuration extension (rebuild needed)"
    fi

    if grep -q "Microsoft.Insights/diagnosticSettings" "$PROJECT_DIR/main.json"; then
        pass "main.json contains diagnostic settings"
    else
        fail "main.json does NOT contain diagnostic settings (rebuild needed)"
    fi

    if grep -q "AADSSHLoginForLinux" "$PROJECT_DIR/main.json"; then
        pass "main.json contains AADSSHLoginForLinux extension"
    else
        fail "main.json does NOT contain AADSSHLoginForLinux extension (rebuild needed)"
    fi
else
    fail "main.json does NOT exist"
fi

# Summary
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
