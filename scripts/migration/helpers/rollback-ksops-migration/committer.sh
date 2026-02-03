#!/usr/bin/env bash
# Committer helper - commits rollback changes

commit_rollback_changes() {
    echo "Committing rollback changes..."
    
    cd "${TENANTS_REPO}" || return 1
    
    # Check if there are changes to commit
    if ! git diff --quiet; then
        echo "  Staging changes..."
        git add "tenants/${TENANT_NAME}/"
        
        # Create commit message
        local commit_msg="chore: rollback ${TENANT_NAME} from KSOPS to ESO

- Restored ExternalSecret resources
- Removed KSOPS-encrypted secret files
- Updated provider annotation to eso
- Updated kustomization to reference external-secrets/

Rollback performed by: rollback-ksops-migration.sh"
        
        echo "  Creating commit..."
        git commit -m "${commit_msg}"
        
        echo "✓ Rollback committed"
        echo ""
        echo "Next steps:"
        echo "  1. Review the commit: git show"
        echo "  2. Verify ExternalSecret resources are correct"
        echo "  3. Push changes: git push"
        echo "  4. Verify tenant pods restart successfully"
    else
        echo "  No changes to commit"
    fi
    
    return 0
}
