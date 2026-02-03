#!/usr/bin/env bash
# Cleaner helper - removes KSOPS-encrypted files

export REMOVED_COUNT=0

cleanup_ksops_files() {
    echo "Cleaning up KSOPS-encrypted files..."
    
    # Remove secrets directories
    for secrets_dir in "${TENANT_DIR}/base/secrets" "${TENANT_DIR}"/overlays/*/secrets; do
        if [[ -d "${secrets_dir}" ]]; then
            echo "  Removing: ${secrets_dir}"
            rm -rf "${secrets_dir}"
            ((REMOVED_COUNT++))
        fi
    done
    
    # Remove secrets/ references from kustomizations
    local base_kustomization="${TENANT_DIR}/base/kustomization.yaml"
    
    if grep -q "^- secrets/" "${base_kustomization}"; then
        echo "  Removing secrets/ from base kustomization"
        grep -v "^- secrets/" "${base_kustomization}" > "${base_kustomization}.tmp"
        mv "${base_kustomization}.tmp" "${base_kustomization}"
    fi
    
    # Remove from overlays
    for overlay_dir in "${TENANT_DIR}"/overlays/*; do
        [[ ! -d "${overlay_dir}" ]] && continue
        
        local overlay_kustomization="${overlay_dir}/kustomization.yaml"
        [[ ! -f "${overlay_kustomization}" ]] && continue
        
        if grep -q "^- secrets/" "${overlay_kustomization}"; then
            echo "  Removing secrets/ from $(basename "${overlay_dir}") overlay"
            grep -v "^- secrets/" "${overlay_kustomization}" > "${overlay_kustomization}.tmp"
            mv "${overlay_kustomization}.tmp" "${overlay_kustomization}"
        fi
    done
    
    # Update provider annotation back to eso
    echo "  Updating provider annotation to eso"
    sed -i.bak 's/secrets\.zerotouch\.dev\/provider: "ksops"/secrets.zerotouch.dev\/provider: "eso"/' \
        "${base_kustomization}"
    rm -f "${base_kustomization}.bak"
    
    # Remove KSOPS-related comments
    sed -i.bak '/# KSOPS-encrypted secrets/d' "${base_kustomization}"
    rm -f "${base_kustomization}.bak"
    
    echo "✓ KSOPS files cleaned up"
    return 0
}
