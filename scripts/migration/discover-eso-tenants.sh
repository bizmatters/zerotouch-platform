#!/usr/bin/env bash
set -euo pipefail

# ESO Tenant Discovery Script
# Discovers tenants using External Secrets Operator and annotates them

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENANTS_REPO="${TENANTS_REPO:-../zerotouch-tenants}"

# Source helpers
source "${SCRIPT_DIR}/helpers/discover-eso-tenants/scanner.sh"
source "${SCRIPT_DIR}/helpers/discover-eso-tenants/annotator.sh"
source "${SCRIPT_DIR}/helpers/discover-eso-tenants/reporter.sh"

main() {
    echo "=== ESO Tenant Discovery ==="
    
    # Step 1: Validate tenants repository exists
    if [[ ! -d "${TENANTS_REPO}/tenants" ]]; then
        echo "ERROR: Tenants directory not found at ${TENANTS_REPO}/tenants"
        exit 1
    fi
    
    # Step 2: Scan for ExternalSecret resources
    if ! scan_external_secrets; then
        echo "ERROR: Failed to scan for ExternalSecret resources"
        exit 1
    fi
    
    # Step 3: Add annotations where missing
    if ! annotate_tenants; then
        echo "ERROR: Failed to annotate tenants"
        exit 1
    fi
    
    # Step 4: Generate report
    if ! generate_report; then
        echo "ERROR: Failed to generate report"
        exit 1
    fi
    
    echo "=== Discovery Complete ==="
}

main "$@"
