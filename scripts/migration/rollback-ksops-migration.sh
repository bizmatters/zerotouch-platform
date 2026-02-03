#!/usr/bin/env bash
set -euo pipefail

# Migration Rollback Script
# Reverts a tenant from KSOPS back to ESO

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
source "${SCRIPT_DIR}/helpers/rollback-ksops-migration/validator.sh"
source "${SCRIPT_DIR}/helpers/rollback-ksops-migration/restorer.sh"
source "${SCRIPT_DIR}/helpers/rollback-ksops-migration/cleaner.sh"
source "${SCRIPT_DIR}/helpers/rollback-ksops-migration/committer.sh"

main() {
    echo "=== Rollback Migration: ${TENANT_NAME} ==="
    
    # Step 1: Validate rollback request
    if ! validate_rollback_request; then
        echo "ERROR: Rollback validation failed"
        exit 1
    fi
    
    # Step 2: Restore ExternalSecret resources
    if ! restore_external_secrets; then
        echo "ERROR: Failed to restore ExternalSecret resources"
        exit 1
    fi
    
    # Step 3: Clean up SOPS-encrypted files
    if ! cleanup_ksops_files; then
        echo "ERROR: Failed to clean up KSOPS files"
        exit 1
    fi
    
    # Step 4: Commit rollback changes
    if ! commit_rollback_changes; then
        echo "ERROR: Failed to commit rollback"
        exit 1
    fi
    
    echo "=== Rollback Complete ==="
}

main "$@"
