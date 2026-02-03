#!/usr/bin/env bash
# Annotator helper - adds provider annotation to tenant configs

annotate_tenants() {
    local tenants_dir="${TENANTS_REPO}/tenants"
    local annotation_key="secrets.zerotouch.dev/provider"
    local annotation_value="eso"
    
    echo "Checking tenant annotations..."
    
    for tenant_name in "${DISCOVERED_TENANTS[@]}"; do
        local tenant_dir="${tenants_dir}/${tenant_name}"
        local kustomization_file="${tenant_dir}/base/kustomization.yaml"
        
        # Skip if kustomization doesn't exist
        if [[ ! -f "${kustomization_file}" ]]; then
            echo "  WARNING: No kustomization.yaml found for ${tenant_name}"
            continue
        fi
        
        # Check if annotation already exists
        if grep -q "${annotation_key}: \"${annotation_value}\"" "${kustomization_file}"; then
            echo "  ${tenant_name}: annotation already present"
            continue
        fi
        
        # Add annotation to commonAnnotations section
        if grep -q "^commonAnnotations:" "${kustomization_file}"; then
            # commonAnnotations section exists, add to it after the line
            awk -v key="${annotation_key}" -v val="${annotation_value}" '
                /^commonAnnotations:/ {
                    print
                    print "  " key ": \"" val "\""
                    next
                }
                {print}
            ' "${kustomization_file}" > "${kustomization_file}.tmp"
            mv "${kustomization_file}.tmp" "${kustomization_file}"
        else
            # No commonAnnotations section, create it
            echo "" >> "${kustomization_file}"
            echo "commonAnnotations:" >> "${kustomization_file}"
            echo "  ${annotation_key}: \"${annotation_value}\"" >> "${kustomization_file}"
        fi
        
        echo "  ${tenant_name}: annotation added"
    done
    
    return 0
}
