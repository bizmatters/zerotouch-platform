#!/usr/bin/env bash
# Committer helper - commits migration changes to Git

commit_migration_changes() {
    echo "Committing migration changes..."
    
    cd "${TENANTS_REPO}" || return 1
    
    # Check if there are changes to commit
    if ! git diff --quiet; then
        echo "  Staging changes..."
        git add "tenants/${TENANT_NAME}/"
        
        # Create commit message
        local commit_msg="chore: migrate ${TENANT_NAME} from ESO to KSOPS

- Converted ${#CONVERTED_SECRETS[@]} Static_Secret resources to SOPS-encrypted files
- Preserved ${#DYNAMIC_SECRETS[@]} Dynamic_Secret resources (Crossplane-managed)
- Updated provider annotation to ksops
- Updated kustomization to reference secrets/

Migration performed by: migrate-tenant-to-ksops.sh"
        
        echo "  Creating commit..."
        git commit -m "${commit_msg}"
        
        echo "✓ Changes committed"
        echo ""
        echo "Next steps:"
        echo "  1. Review the commit: git show"
        echo "  2. Populate secret values in secrets/*.secret.yaml files"
        echo "  3. Re-encrypt with SOPS: sops -e -i <file>"
        echo "  4. Push changes: git push"
    else
        echo "  No changes to commit"
    fi
    
    return 0
}
