#!/usr/bin/env bash
# Validator helper - validates rollback prerequisites

export TENANT_DIR=""

validate_rollback_request() {
    echo "Validating rollback request..."
    
    # Check tenant name provided
    if [[ -z "${TENANT_NAME}" ]]; then
        echo "ERROR: Tenant name required (--tenant <name>)"
        return 1
    fi
    
    # Check tenants repository exists
    if [[ ! -d "${TENANTS_REPO}/tenants" ]]; then
        echo "ERROR: Tenants directory not found at ${TENANTS_REPO}/tenants"
        return 1
    fi
    
    # Check tenant directory exists
    TENANT_DIR="${TENANTS_REPO}/tenants/${TENANT_NAME}"
    if [[ ! -d "${TENANT_DIR}" ]]; then
        echo "ERROR: Tenant directory not found: ${TENANT_DIR}"
        return 1
    fi
    
    # Check tenant has KSOPS annotation
    local kustomization="${TENANT_DIR}/base/kustomization.yaml"
    if [[ ! -f "${kustomization}" ]]; then
        echo "ERROR: Kustomization not found: ${kustomization}"
        return 1
    fi
    
    if ! grep -q 'secrets.zerotouch.dev/provider: "ksops"' "${kustomization}"; then
        echo "ERROR: Tenant ${TENANT_NAME} is not marked as KSOPS tenant"
        echo "Nothing to rollback"
        return 1
    fi
    
    # Check if Git working directory is clean
    cd "${TENANTS_REPO}" || return 1
    if ! git diff --quiet "tenants/${TENANT_NAME}/"; then
        echo "WARNING: Uncommitted changes detected in tenant directory"
        echo "Commit or stash changes before rollback"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    echo "✓ Validation passed for rollback: ${TENANT_NAME}"
    return 0
}
