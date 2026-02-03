#!/usr/bin/env bash
set -euo pipefail

# Tenant Migration Script - ESO to KSOPS
# Migrates a single tenant from External Secrets Operator to KSOPS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANTS_REPO="${TENANTS_REPO:-../zerotouch-tenants}"

# Parse arguments
TENANT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --tenant)
            TENANT_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --tenant <tenant-name>"
            exit 1
            ;;
    esac
done

# Source helpers
source "${SCRIPT_DIR}/helpers/migrate-tenant-to-ksops/validator.sh"
source "${SCRIPT_DIR}/helpers/migrate-tenant-to-ksops/converter.sh"
source "${SCRIPT_DIR}/helpers/migrate-tenant-to-ksops/updater.sh"
source "${SCRIPT_DIR}/helpers/migrate-tenant-to-ksops/committer.sh"

main() {
    echo "=== Tenant Migration: ${TENANT_NAME} ==="
    
    # Step 1: Validate tenant and inputs
    if ! validate_migration_request; then
        echo "ERROR: Migration validation failed"
        exit 1
    fi
    
    # Step 2: Convert ExternalSecrets to SOPS-encrypted files
    if ! convert_secrets_to_ksops; then
        echo "ERROR: Secret conversion failed"
        exit 1
    fi
    
    # Step 3: Update tenant configuration
    if ! update_tenant_config; then
        echo "ERROR: Configuration update failed"
        exit 1
    fi
    
    # Step 4: Commit changes
    if ! commit_migration_changes; then
        echo "ERROR: Failed to commit changes"
        exit 1
    fi
    
    echo "=== Migration Complete ==="
}

main "$@"
