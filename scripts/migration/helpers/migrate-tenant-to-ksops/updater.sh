#!/usr/bin/env bash
# Updater helper - updates tenant configuration for KSOPS

update_tenant_config() {
    echo "Updating tenant configuration..."
    
    # Update base kustomization
    local base_kustomization="${TENANT_DIR}/base/kustomization.yaml"
    
    # Add secrets directory to resources if secrets were created
    if [[ ${#CONVERTED_SECRETS[@]} -gt 0 ]]; then
        if [[ -d "${TENANT_DIR}/base/secrets" ]]; then
            echo "  Adding secrets/ to base kustomization resources"
            
            # Check if secrets already in resources
            if ! grep -q "^- secrets/" "${base_kustomization}"; then
                # Add after external-secrets section
                awk '/^- external-secrets\// {print; print "# KSOPS-encrypted secrets"; print "- secrets/"; next} 1' \
                    "${base_kustomization}" > "${base_kustomization}.tmp"
                mv "${base_kustomization}.tmp" "${base_kustomization}"
            fi
        fi
    fi
    
    # Update overlay kustomizations
    for overlay_dir in "${TENANT_DIR}"/overlays/*; do
        [[ ! -d "${overlay_dir}" ]] && continue
        
        local overlay_kustomization="${overlay_dir}/kustomization.yaml"
        [[ ! -f "${overlay_kustomization}" ]] && continue
        
        if [[ -d "${overlay_dir}/secrets" ]]; then
            echo "  Adding secrets/ to $(basename "${overlay_dir}") overlay"
            
            if ! grep -q "^- secrets/" "${overlay_kustomization}"; then
                # Add to resources if not present
                if grep -q "^resources:" "${overlay_kustomization}"; then
                    awk '/^resources:/ {print; print "- secrets/"; next} 1' \
                        "${overlay_kustomization}" > "${overlay_kustomization}.tmp"
                    mv "${overlay_kustomization}.tmp" "${overlay_kustomization}"
                else
                    echo "" >> "${overlay_kustomization}"
                    echo "resources:" >> "${overlay_kustomization}"
                    echo "- secrets/" >> "${overlay_kustomization}"
                fi
            fi
        fi
    done
    
    # Update provider annotation from eso to ksops
    echo "  Updating provider annotation to ksops"
    sed -i.bak 's/secrets\.zerotouch\.dev\/provider: "eso"/secrets.zerotouch.dev\/provider: "ksops"/' \
        "${base_kustomization}"
    rm -f "${base_kustomization}.bak"
    
    # Add comment about ExternalSecrets preservation
    if [[ ${#DYNAMIC_SECRETS[@]} -gt 0 ]]; then
        echo "  Adding comment about preserved Dynamic_Secret resources"
        
        # Add comment before external-secrets section
        awk '/^- external-secrets\// {
            print "# External Secrets (Dynamic_Secret - Crossplane-managed, preserved)"
            print
            next
        } 1' "${base_kustomization}" > "${base_kustomization}.tmp"
        mv "${base_kustomization}.tmp" "${base_kustomization}"
    fi
    
    echo "✓ Configuration updated"
    return 0
}
