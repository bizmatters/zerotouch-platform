#!/usr/bin/env bash
# Reporter helper - generates discovery report

generate_report() {
    echo ""
    echo "=== ESO Tenant Discovery Report ==="
    echo ""
    
    if [[ ${#DISCOVERED_TENANTS[@]} -eq 0 ]]; then
        echo "No tenants using External Secrets Operator found."
        return 0
    fi
    
    echo "Tenants using External Secrets Operator:"
    echo ""
    
    # Parse tenant data and display
    IFS=',' read -ra tenant_entries <<< "${TENANT_SECRETS_MAP}"
    for entry in "${tenant_entries[@]}"; do
        IFS=':' read -r tenant_name secret_count <<< "${entry}"
        printf "  %-30s %3d secrets\n" "${tenant_name}" "${secret_count}"
    done
    
    echo ""
    echo "Total tenants: ${#DISCOVERED_TENANTS[@]}"
    
    # Calculate total secrets
    local total_secrets=0
    for entry in "${tenant_entries[@]}"; do
        IFS=':' read -r _ secret_count <<< "${entry}"
        ((total_secrets += secret_count))
    done
    echo "Total secrets: ${total_secrets}"
    
    return 0
}
