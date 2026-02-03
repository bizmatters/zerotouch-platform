#!/usr/bin/env bash
set -euo pipefail

# Test Migration Workflow Script
# Tests the complete migration workflow with a test tenant

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANTS_REPO="${TENANTS_REPO:-../zerotouch-tenants}"
TEST_TENANT="test-ksops-migration"

echo "=== Testing Migration Workflow ==="
echo ""

# Step 1: Create test tenant with ExternalSecret resources
echo "Step 1: Creating test tenant..."

mkdir -p "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/external-secrets"
mkdir -p "${TENANTS_REPO}/tenants/${TEST_TENANT}/overlays/dev"

# Create base kustomization
cat > "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- external-secrets/test-db-es.yaml
- external-secrets/test-api-key-es.yaml

commonLabels:
  app.kubernetes.io/name: test-ksops-migration
  tenant: test-ksops-migration

commonAnnotations:
  managed-by: "zerotouch-platform"
  tenant: "test-ksops-migration"
EOF

# Create test ExternalSecret (Static_Secret)
cat > "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/external-secrets/test-db-es.yaml" <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-db
  namespace: default
  labels:
    zerotouch.io/managed: "true"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-parameter-store
    kind: ClusterSecretStore
  target:
    name: test-db-secret
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: /zerotouch/dev/test/database_url
EOF

# Create test ExternalSecret (Dynamic_Secret - should be preserved)
cat > "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/external-secrets/test-api-key-es.yaml" <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: test-api-key
  namespace: default
  labels:
    zerotouch.io/managed: "true"
    crossplane.io/claim-name: "test-claim"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-parameter-store
    kind: ClusterSecretStore
  target:
    name: test-api-key-conn
  data:
  - secretKey: API_KEY
    remoteRef:
      key: /zerotouch/dev/test/api_key
EOF

echo "✓ Test tenant created"

# Step 2: Run discovery script
echo ""
echo "Step 2: Running discovery script..."
"${SCRIPT_DIR}/discover-eso-tenants.sh"

# Verify annotation was added
if grep -q 'secrets.zerotouch.dev/provider: "eso"' \
    "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/kustomization.yaml"; then
    echo "✓ Discovery script added ESO annotation"
else
    echo "✗ Discovery script failed to add annotation"
    exit 1
fi

# Step 3: Run migration script
echo ""
echo "Step 3: Running migration script..."
"${SCRIPT_DIR}/migrate-tenant-to-ksops.sh" --tenant "${TEST_TENANT}"

# Verify SOPS files created
if [[ -d "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/secrets" ]]; then
    echo "✓ SOPS-encrypted files created"
else
    echo "✗ SOPS-encrypted files not created"
    exit 1
fi

# Verify Static_Secret converted
if [[ -f "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/secrets/test-db.secret.yaml" ]]; then
    echo "✓ Static_Secret converted to SOPS"
else
    echo "✗ Static_Secret not converted"
    exit 1
fi

# Verify Dynamic_Secret preserved
if [[ -f "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/external-secrets/test-api-key-es.yaml" ]]; then
    echo "✓ Dynamic_Secret preserved (Crossplane-managed)"
else
    echo "✗ Dynamic_Secret was incorrectly removed"
    exit 1
fi

# Verify annotation updated
if grep -q 'secrets.zerotouch.dev/provider: "ksops"' \
    "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/kustomization.yaml"; then
    echo "✓ Provider annotation updated to ksops"
else
    echo "✗ Provider annotation not updated"
    exit 1
fi

# Step 4: Test rollback script
echo ""
echo "Step 4: Testing rollback script..."
"${SCRIPT_DIR}/rollback-ksops-migration.sh" --tenant "${TEST_TENANT}"

# Verify SOPS files removed
if [[ ! -d "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/secrets" ]]; then
    echo "✓ SOPS-encrypted files removed"
else
    echo "✗ SOPS-encrypted files still exist"
    exit 1
fi

# Verify annotation rolled back
if grep -q 'secrets.zerotouch.dev/provider: "eso"' \
    "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/kustomization.yaml"; then
    echo "✓ Provider annotation rolled back to eso"
else
    echo "✗ Provider annotation not rolled back"
    exit 1
fi

# Verify Dynamic_Secret still preserved
if [[ -f "${TENANTS_REPO}/tenants/${TEST_TENANT}/base/external-secrets/test-api-key-es.yaml" ]]; then
    echo "✓ Dynamic_Secret still preserved after rollback"
else
    echo "✗ Dynamic_Secret was incorrectly removed during rollback"
    exit 1
fi

# Step 5: Cleanup test tenant
echo ""
echo "Step 5: Cleaning up test tenant..."
rm -rf "${TENANTS_REPO}/tenants/${TEST_TENANT}"
echo "✓ Test tenant removed"

echo ""
echo "=== Migration Workflow Test Complete ==="
echo ""
echo "Summary:"
echo "  ✓ Discovery script identifies ESO tenants"
echo "  ✓ Migration script converts Static_Secret to SOPS"
echo "  ✓ Migration script preserves Dynamic_Secret (Crossplane)"
echo "  ✓ Migration script updates annotations"
echo "  ✓ Rollback script restores original state"
echo "  ✓ Rollback script preserves Dynamic_Secret"
echo ""
echo "All tests passed!"
