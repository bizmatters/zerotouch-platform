#!/bin/bash
set -euo pipefail

# Create Hetzner Cloud DNS Zone
# This script creates a DNS zone in Hetzner Cloud for external-dns integration

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
    echo "Ensure .env is configured with ${ENV_UPPER}_HCLOUD_TOKEN"
    exit 1
fi

echo "Creating DNS zone: $ZONE_NAME in Hetzner Cloud..."

# Try different mode values based on Hetzner Cloud API
for mode in "primary" "secondary" "managed"; do
    echo "Trying mode: $mode"
    
    response=$(hetzner_api "POST" "/zones" "{\"name\": \"$ZONE_NAME\", \"ttl\": 3600, \"mode\": \"$mode\"}")
    
    # Check response for success
    if echo "$response" | jq -e '.zone' > /dev/null 2>&1; then
        echo "✅ DNS zone '$ZONE_NAME' created successfully with mode: $mode"
        echo "Response: $response"
        break
    else
        error_msg=$(echo "$response" | jq -r '.error.message' 2>/dev/null || echo "Unknown error")
        if [[ "$error_msg" == *"already exists"* ]]; then
            echo "✅ DNS zone '$ZONE_NAME' already exists"
            break
        else
            echo "Mode $mode failed: $error_msg"
            continue
        fi
    fi
done

echo ""
echo "✅ DNS zone creation complete!"
echo ""
echo "To verify the zone and get nameservers, run:"
echo "  ./verify-dns-zone.sh $ZONE_NAME"
echo ""
echo "To restart external-dns:"
echo "  kubectl rollout restart deployment/external-dns -n kube-system"