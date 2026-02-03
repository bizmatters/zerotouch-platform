#!/usr/bin/env bash
# Validator helper - validates migration prerequisites

export TENANT_DIR=""
export TENANT_ANNOTATION=""

validate_migration_request() {
    echo "Validating migration request..."
    
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
    
    # Check tenant has ESO annotation
    local kustomization="${TENANT_DIR}/base/kustomization.yaml"
    if [[ ! -f "${kustomization}" ]]; then
        echo "ERROR: Kustomization not found: ${kustomization}"
        return 1
    fi
    
    if ! grep -q 'secrets.zerotouch.dev/provider: "eso"' "${kustomization}"; then
        echo "ERROR: Tenant ${TENANT_NAME} is not marked as ESO tenant"
        echo "Run discover-eso-tenants.sh first to identify ESO tenants"
        return 1
    fi
    
    # Check SOPS is installed
    if ! command -v sops &> /dev/null; then
        echo "ERROR: SOPS not installed. Install from https://github.com/mozilla/sops"
        return 1
    fi
    
    # Check .sops.yaml exists
    if [[ ! -f "${TENANTS_REPO}/.sops.yaml" ]]; then
        echo "ERROR: .sops.yaml not found in ${TENANTS_REPO}"
        return 1
    fi
    
    echo "✓ Validation passed for tenant: ${TENANT_NAME}"
    return 0
}
