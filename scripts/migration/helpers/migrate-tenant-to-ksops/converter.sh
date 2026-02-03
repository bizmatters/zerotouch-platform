#!/usr/bin/env bash
# Converter helper - converts ExternalSecrets to SOPS-encrypted files

export CONVERTED_SECRETS=()
export DYNAMIC_SECRETS=()

convert_secrets_to_ksops() {
    echo "Converting ExternalSecrets to SOPS-encrypted files..."
    
    local secrets_created=0
    
    # Process base and overlay directories
    for env_dir in "${TENANT_DIR}/base" "${TENANT_DIR}"/overlays/*; do
        [[ ! -d "${env_dir}" ]] && continue
        
        local env_name=$(basename "${env_dir}")
        local external_secrets_dir="${env_dir}/external-secrets"
        
        [[ ! -d "${external_secrets_dir}" ]] && continue
        
        echo "  Processing ${env_name}..."
        
        # Find all ExternalSecret files
        while IFS= read -r es_file; do
            [[ ! -f "${es_file}" ]] && continue
            
            # Extract secret name
            local secret_name=$(grep "name:" "${es_file}" | head -1 | awk '{print $2}')
            local target_name=$(grep "name:" "${es_file}" | grep -A 5 "target:" | tail -1 | awk '{print $2}')
            
            # Skip Crossplane-generated secrets (Dynamic_Secret)
            if [[ "${target_name}" =~ -conn$ ]] || [[ "${target_name}" =~ -cache- ]]; then
                echo "    Skipping Dynamic_Secret: ${secret_name} (Crossplane-managed)"
                DYNAMIC_SECRETS+=("${secret_name}")
                continue
            fi
            
            # Check for crossplane label
            if grep -q "crossplane.io/claim-name" "${es_file}"; then
                echo "    Skipping Dynamic_Secret: ${secret_name} (Crossplane label)"
                DYNAMIC_SECRETS+=("${secret_name}")
                continue
            fi
            
            # This is a Static_Secret - convert to SOPS
            echo "    Converting Static_Secret: ${secret_name}"
            
            # Create secrets directory if it doesn't exist
            local secrets_dir="${env_dir}/secrets"
            mkdir -p "${secrets_dir}"
            
            # Create SOPS-encrypted secret file
            local sops_file="${secrets_dir}/${secret_name}.secret.yaml"
            
            # Extract namespace
            local namespace=$(grep "namespace:" "${es_file}" | head -1 | awk '{print $2}')
            
            # Create plaintext secret YAML
            cat > "${sops_file}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${target_name:-${secret_name}}
  namespace: ${namespace}
type: Opaque
stringData:
  # TODO: Populate secret values from GitHub Secrets or AWS SSM
  # This file will be encrypted with SOPS
  placeholder: "REPLACE_WITH_ACTUAL_SECRET_VALUE"
EOF
            
            # Encrypt with SOPS
            if ! sops -e -i "${sops_file}" 2>/dev/null; then
                echo "    WARNING: SOPS encryption failed for ${sops_file}"
                echo "    File created but not encrypted - encrypt manually"
            else
                echo "    ✓ Created and encrypted: ${sops_file}"
            fi
            
            CONVERTED_SECRETS+=("${secret_name}")
            ((secrets_created++))
            
        done < <(find "${external_secrets_dir}" -name "*-es.yaml" -o -name "*-external-secret.yaml" 2>/dev/null)
    done
    
    if [[ ${secrets_created} -eq 0 ]]; then
        echo "  No Static_Secret resources found to convert"
    else
        echo "  Converted ${secrets_created} Static_Secret resources"
    fi
    
    if [[ ${#DYNAMIC_SECRETS[@]} -gt 0 ]]; then
        echo "  Preserved ${#DYNAMIC_SECRETS[@]} Dynamic_Secret resources (Crossplane-managed)"
    fi
    
    return 0
}
