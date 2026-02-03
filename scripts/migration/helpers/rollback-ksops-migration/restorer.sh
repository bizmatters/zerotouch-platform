#!/usr/bin/env bash
# Restorer helper - restores ExternalSecret resources

export RESTORED_COUNT=0

restore_external_secrets() {
    echo "Restoring ExternalSecret resources..."
    
    # Check if external-secrets directories still exist
    local has_external_secrets=false
    
    for dir in "${TENANT_DIR}/base/external-secrets" "${TENANT_DIR}"/overlays/*/external-secrets; do
        if [[ -d "${dir}" ]]; then
            has_external_secrets=true
            break
        fi
    done
    
    if [[ "${has_external_secrets}" == "false" ]]; then
        echo "  WARNING: No external-secrets directories found"
        echo "  ExternalSecret resources may have been deleted during migration"
        echo "  You may need to restore from Git history"
        return 0
    fi
    
    # Update base kustomization to reference external-secrets
    local base_kustomization="${TENANT_DIR}/base/kustomization.yaml"
    
    # Ensure external-secrets are in resources
    if ! grep -q "^- external-secrets/" "${base_kustomization}"; then
        echo "  Adding external-secrets/ to base kustomization"
        
        # Add to resources section
        awk '/^resources:/ {print; print "- external-secrets/"; next} 1' \
            "${base_kustomization}" > "${base_kustomization}.tmp"
        mv "${base_kustomization}.tmp" "${base_kustomization}"
    fi
    
    # Update overlay kustomizations
    for overlay_dir in "${TENANT_DIR}"/overlays/*; do
        [[ ! -d "${overlay_dir}" ]] && continue
        
        local overlay_kustomization="${overlay_dir}/kustomization.yaml"
        [[ ! -f "${overlay_kustomization}" ]] && continue
        
        if [[ -d "${overlay_dir}/external-secrets" ]]; then
            echo "  Restoring external-secrets in $(basename "${overlay_dir}") overlay"
            
            if ! grep -q "^- external-secrets/" "${overlay_kustomization}"; then
                if grep -q "^resources:" "${overlay_kustomization}"; then
                    awk '/^resources:/ {print; print "- external-secrets/"; next} 1' \
                        "${overlay_kustomization}" > "${overlay_kustomization}.tmp"
                    mv "${overlay_kustomization}.tmp" "${overlay_kustomization}"
                fi
            fi
        fi
    done
    
    echo "✓ ExternalSecret resources restored"
    return 0
}
