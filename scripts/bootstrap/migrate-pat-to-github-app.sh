#!/usr/bin/env bash
set -euo pipefail

# GitHub App Migration Script
# Migrates existing clusters from PAT to GitHub App authentication

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
APP_ID=""
INSTALLATION_ID=""
PRIVATE_KEY_FILE=""
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --app-id)
            APP_ID="$2"
            shift 2
            ;;
        --installation-id)
            INSTALLATION_ID="$2"
            shift 2
            ;;
        --private-key-file)
            PRIVATE_KEY_FILE="$2"
            shift 2
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --app-id <id> --installation-id <id> --private-key-file <path> [--verify-only]"
            exit 1
            ;;
    esac
done

# Source helpers
source "${SCRIPT_DIR}/helpers/migrate-pat-to-github-app/validator.sh"
source "${SCRIPT_DIR}/helpers/migrate-pat-to-github-app/backup.sh"
source "${SCRIPT_DIR}/helpers/migrate-pat-to-github-app/updater.sh"
source "${SCRIPT_DIR}/helpers/migrate-pat-to-github-app/tester.sh"
source "${SCRIPT_DIR}/helpers/migrate-pat-to-github-app/reporter.sh"

main() {
    echo "=== GitHub App Migration ==="
    
    # Step 1: Validate GitHub App credentials
    if ! validate_github_app; then
        echo "ERROR: GitHub App validation failed"
        exit 1
    fi
    
    if [[ "${VERIFY_ONLY}" == "true" ]]; then
        echo "✓ Verification complete (dry-run mode)"
        exit 0
    fi
    
    # Step 2: Backup existing PAT configuration
    if ! backup_pat_config; then
        echo "ERROR: Failed to backup PAT configuration"
        exit 1
    fi
    
    # Step 3: Update ArgoCD repository credentials
    if ! update_argocd_credentials; then
        echo "ERROR: Failed to update ArgoCD credentials"
        exit 1
    fi
    
    # Step 4: Test ArgoCD connectivity
    if ! test_argocd_connectivity; then
        echo "ERROR: ArgoCD connectivity test failed"
        echo "Rolling back to PAT..."
        kubectl apply -f /tmp/argocd-pat-backup.yaml
        exit 1
    fi
    
    # Step 5: Generate migration report
    generate_migration_report
    
    echo "=== Migration Complete ==="
}

main "$@"
