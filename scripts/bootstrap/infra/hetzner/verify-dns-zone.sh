#!/bin/bash
set -euo pipefail

# Verify Hetzner Cloud DNS Zone exists and show details
# This script verifies a DNS zone exists and displays nameservers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load environment variables
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Source Hetzner API helper
source "$REPO_ROOT/scripts/bootstrap/helpers/hetzner-api.sh"

ZONE_NAME="${1:-nutgraf.in}"

if [[ -z "$HETZNER_API_TOKEN" ]]; then
    echo "Error: HETZNER_API_TOKEN not set"
    echo "Ensure .env is configured with ${ENV_UPPER}_HETZNER_API_TOKEN"
    exit 1
fi

echo "Verifying DNS zone: $ZONE_NAME..."

# Get zone details using helper
zones=$(hetzner_api "GET" "/zones")

zone_found=$(echo "$zones" | jq -r ".zones[] | select(.name == \"$ZONE_NAME\") | .name" 2>/dev/null || echo "")

if [ "$zone_found" = "$ZONE_NAME" ]; then
    echo "✅ DNS zone verification successful"
    echo ""
    echo "Zone details:"
    echo "$zones" | jq ".zones[] | select(.name == \"$ZONE_NAME\")"
    
    # Extract and display nameservers
    echo ""
    echo "Assigned nameservers for $ZONE_NAME:"
    echo "$zones" | jq -r ".zones[] | select(.name == \"$ZONE_NAME\") | .authoritative_nameservers.assigned[]" 2>/dev/null || echo "None"
    
    echo ""
    echo "Delegated nameservers (current DNS setup):"
    echo "$zones" | jq -r ".zones[] | select(.name == \"$ZONE_NAME\") | .authoritative_nameservers.delegated[]" 2>/dev/null || echo "None"
    
    # Check delegation status
    delegation_status=$(echo "$zones" | jq -r ".zones[] | select(.name == \"$ZONE_NAME\") | .authoritative_nameservers.delegation_status" 2>/dev/null || echo "unknown")
    echo ""
    echo "Delegation status: $delegation_status"
    
    if [ "$delegation_status" = "invalid" ]; then
        echo ""
        echo "⚠️  DNS delegation is invalid. Update your domain registrar to use the assigned nameservers above."
    elif [ "$delegation_status" = "valid" ]; then
        echo "✅ DNS delegation is valid"
    fi
else
    echo "❌ DNS zone '$ZONE_NAME' not found"
    echo ""
    echo "Available zones:"
    echo "$zones" | jq -r '.zones[].name' 2>/dev/null || echo "None"
    exit 1
fi