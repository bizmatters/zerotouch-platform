#!/bin/bash
# Bootstrap Talos Cluster
# Usage: ./04-bootstrap-talos.sh <server-ip> [env]
#
# This script:
# 1. Applies Talos configuration with OIDC identity
# 2. Bootstraps etcd cluster
# 3. Fetches kubeconfig
# 4. Verifies cluster is ready

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Kubectl retry function
kubectl_retry() {
    local max_attempts=20
    local timeout=15
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if timeout $timeout kubectl "$@"; then
            return 0
        fi

        exitCode=$?

        if [ $attempt -lt $max_attempts ]; then
            local delay=$((attempt * 2))
            echo -e "${YELLOW}⚠️  kubectl command failed (attempt $attempt/$max_attempts). Retrying in ${delay}s...${NC}" >&2
            sleep $delay
        fi

        attempt=$((attempt + 1))
    done

    echo -e "${RED}✗ kubectl command failed after $max_attempts attempts${NC}" >&2
    return $exitCode
}

# Check arguments
SERVER_IP="$1"
ENV="${2:-dev}"

if [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Usage: $0 <server-ip> [env]${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"
TALOS_DIR="$REPO_ROOT/bootstrap/talos"
BASE_CONFIG="$TALOS_DIR/nodes/cp01-main/config.yaml"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Bootstrapping Talos Cluster ($ENV)                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# 1. Prepare Configuration
echo -e "${BLUE}Preparing Configuration...${NC}"

# Call helper to get OIDC patch
HELPER_SCRIPT="$REPO_ROOT/scripts/bootstrap/helpers/prepare-oidc-patch.sh"
if [ ! -x "$HELPER_SCRIPT" ]; then
    chmod +x "$HELPER_SCRIPT"
fi

OIDC_PATCH_FILE=$("$HELPER_SCRIPT" "$ENV")
if [ $? -ne 0 ] || [ -z "$OIDC_PATCH_FILE" ]; then
    echo -e "${RED}Failed to generate OIDC patch${NC}"
    exit 1
fi

# Merge Base Config + OIDC Patch
FINAL_CONFIG="/tmp/talos-config-final.yaml"
if command -v yq &> /dev/null; then
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$BASE_CONFIG" "$OIDC_PATCH_FILE" > "$FINAL_CONFIG"
    echo -e "${GREEN}✓ Configuration merged with OIDC Identity${NC}"
else
    echo -e "${RED}Error: yq is required for merging configurations${NC}"
    exit 1
fi

# Wait for Talos to boot
echo -e "${BLUE}⏳ Waiting 3 minutes for Talos to boot...${NC}"
sleep 180

# 2. Apply Configuration
cd "$TALOS_DIR"

# Source the Hetzner API helper for server ID lookups
source "$REPO_ROOT/scripts/bootstrap/helpers/hetzner-api.sh"

echo -e "${BLUE}Retrieving Hetzner server ID...${NC}"
SERVER_ID=$(get_server_id_by_ip "$SERVER_IP") || { echo -e "${YELLOW}Warning: Could not get Server ID, skipping provider-id injection${NC}"; SERVER_ID=""; }

echo -e "${BLUE}Applying configuration to $SERVER_IP...${NC}"

# Prepare ProviderID patch
PROVIDER_PATCH=""
if [ -n "$SERVER_ID" ]; then
    PROVIDER_PATCH="[{\"op\": \"add\", \"path\": \"/machine/kubelet/extraArgs\", \"value\": {\"provider-id\": \"hcloud://$SERVER_ID\"}}]"
    echo -e "${GREEN}✓ Injecting ProviderID: hcloud://$SERVER_ID${NC}"
fi

# Apply Config
if ! talosctl apply-config --insecure \
  --nodes "$SERVER_IP" \
  --endpoints "$SERVER_IP" \
  --file "$FINAL_CONFIG" \
  --config-patch "$PROVIDER_PATCH"; then
    echo -e "${RED}Failed to apply. Retrying in 10s...${NC}"
    sleep 10
    talosctl apply-config --insecure \
      --nodes "$SERVER_IP" \
      --endpoints "$SERVER_IP" \
      --file "$FINAL_CONFIG" \
      --config-patch "$PROVIDER_PATCH"
fi

echo -e "${BLUE}Waiting 30 seconds for config to apply...${NC}"
sleep 30

# 3. Bootstrap Etcd
echo -e "${BLUE}Bootstrapping etcd cluster...${NC}"
talosctl bootstrap \
  --nodes "$SERVER_IP" \
  --endpoints "$SERVER_IP" \
  --talosconfig talosconfig

echo -e "${BLUE}Waiting 60 seconds for API server...${NC}"
sleep 60

# 4. Fetch Kubeconfig
talosctl kubeconfig \
  --nodes "$SERVER_IP" \
  --endpoints "$SERVER_IP" \
  --talosconfig talosconfig \
  --force

# Cleanup
rm -f "$OIDC_PATCH_FILE" "$FINAL_CONFIG"

echo ""
echo -e "${GREEN}✓ Talos cluster bootstrapped successfully${NC}"
echo ""
