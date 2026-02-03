#!/usr/bin/env bash
# Scanner helper - finds ExternalSecret resources in tenant directories

# Export results for downstream helpers
export TENANT_SECRETS_MAP=""
export DISCOVERED_TENANTS=()

scan_external_secrets() {
    local tenants_dir="${TENANTS_REPO}/tenants"
    local tenant_data=()
    
    echo "Scanning for ExternalSecret resources..."
    
    # Find all tenant directories
    for tenant_dir in "${tenants_dir}"/*; do
        if [[ ! -d "${tenant_dir}" ]]; then
            continue
        fi
        
        local tenant_name=$(basename "${tenant_dir}")
        local secret_count=0
        
        # Search in base/ and overlays/*/
        local search_paths=(
            "${tenant_dir}/base"
            "${tenant_dir}/overlays"/*
        )
        
        for search_path in "${search_paths[@]}"; do
            if [[ ! -d "${search_path}" ]]; then
                continue
            fi
            
            # Find ExternalSecret resources
            while IFS= read -r file; do
                # Skip if file doesn't exist
                [[ ! -f "${file}" ]] && continue
                
                # Check if it's an ExternalSecret
                if ! grep -q "kind: ExternalSecret" "${file}"; then
                    continue
                fi
                
                # Extract secret name
                local secret_name=$(grep "name:" "${file}" | head -1 | awk '{print $2}')
                
                # Exclude Crossplane-generated secrets
                if [[ "${secret_name}" =~ -conn$ ]] || [[ "${secret_name}" =~ -cache- ]]; then
                    continue
                fi
                
                # Check for crossplane.io/claim-name label
                if grep -q "crossplane.io/claim-name" "${file}"; then
                    continue
                fi
                
                ((secret_count++))
            done < <(find "${search_path}" -name "*.yaml" -type f 2>/dev/null)
        done
        
        # Record tenant if it has ExternalSecrets
        if [[ ${secret_count} -gt 0 ]]; then
            DISCOVERED_TENANTS+=("${tenant_name}")
            tenant_data+=("${tenant_name}:${secret_count}")
            echo "  Found tenant: ${tenant_name} (${secret_count} secrets)"
        fi
    done
    
    # Export results
    TENANT_SECRETS_MAP=$(IFS=,; echo "${tenant_data[*]}")
    
    if [[ ${#DISCOVERED_TENANTS[@]} -eq 0 ]]; then
        echo "No tenants with ExternalSecret resources found"
        return 0
    fi
    
    echo "Discovered ${#DISCOVERED_TENANTS[@]} tenants with ExternalSecret resources"
    return 0
}
