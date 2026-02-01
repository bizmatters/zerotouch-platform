#!/bin/bash
# Tier 3 Script: Setup Preview Cluster
# Creates Kind cluster and installs required tools for CI/CD testing
#
# Environment Variables (required):
#   AWS_ACCESS_KEY_ID - AWS access key for ESO
#   AWS_SECRET_ACCESS_KEY - AWS secret key for ESO
#   AWS_SESSION_TOKEN - AWS session token (optional, for OIDC)
#
# Exit Codes:
#   0 - Success
#   1 - Missing AWS credentials
#   2 - Tool installation failed
#   3 - Kind cluster creation failed

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Find repository root by looking for .git directory
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"
CLUSTER_NAME="zerotouch-preview"
KIND_CONFIG="$SCRIPT_DIR/helpers/kind-config.yaml"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Setup Preview Cluster                                     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Preview mode - tenant resources will be cleaned up after ArgoCD deployment
echo -e "${BLUE}Preview mode configured${NC}"
echo ""

# 1. Apply preview patches (URLs, storage class, tolerations, disable local-path-provisioner)
echo -e "${BLUE}Applying preview patches...${NC}"
# Pass --force since we're definitely in preview mode (cluster doesn't exist yet)
"$SCRIPT_DIR/patches/00-apply-all-patches.sh" --force

# Patches applied - using default storage class (no verification needed)
echo ""

# 2. Update Kind config to mount local repo
echo -e "${BLUE}Updating Kind config to mount local repo...${NC}"

cat > "$KIND_CONFIG" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: zerotouch-preview
nodes:
- role: control-plane
  extraPortMappings:
  # NATS client port
  - containerPort: 30080
    hostPort: 4222
    protocol: TCP
  # PostgreSQL port
  - containerPort: 30432
    hostPort: 5432
    protocol: TCP
  # Dragonfly (Redis-compatible) port
  - containerPort: 30379
    hostPort: 6379
    protocol: TCP
  extraMounts:
  # Mount local repo for ArgoCD to sync from
  - hostPath: $REPO_ROOT
    containerPath: /repo
    readOnly: true
EOF

echo -e "${GREEN}✓ Kind config updated with local repo mount at /repo${NC}"
echo ""

# 4. Validate AWS credentials
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo -e "${RED}Error: AWS credentials required${NC}"
    echo -e "Set: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN (optional)"
    exit 1
fi

echo -e "${GREEN}✓ AWS credentials configured${NC}"
echo ""

# 5. Calculate version hash for preview image
echo -e "${YELLOW}Calculating preview image version...${NC}"
VERSION_HASH=$(sha256sum "$REPO_ROOT/platform/versions.yaml" | cut -d' ' -f1 | cut -c1-8)
# Extract repository owner from git remote
REPO_OWNER=$(git remote get-url origin | sed -n 's/.*github\.com[:/]\([^/]*\)\/.*/\1/p')
KIND_NODE_IMAGE="ghcr.io/$REPO_OWNER/zerotouch-preview-node:$VERSION_HASH"
echo -e "${GREEN}✓ Using preview image: $KIND_NODE_IMAGE${NC}"
echo -e "${GREEN}✓ All CLI tools pre-installed in preview image${NC}"
echo ""

# 6. Create Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${YELLOW}Kind cluster '$CLUSTER_NAME' already exists${NC}"
else
    # Use versioned preview image (no fallback)
    echo -e "${BLUE}Creating Kind cluster '$CLUSTER_NAME'...${NC}"
    echo -e "${BLUE}Using Node Image: $KIND_NODE_IMAGE${NC}"
    
    if [ ! -f "$KIND_CONFIG" ]; then
        echo -e "${RED}Error: Kind config not found at $KIND_CONFIG${NC}"
        exit 3
    fi
    kind create cluster --config "$KIND_CONFIG" --image "$KIND_NODE_IMAGE" || exit 3
    echo -e "${GREEN}✓ Kind cluster created${NC}"
fi

# 7. Set kubectl context
kubectl config use-context "kind-${CLUSTER_NAME}"

# 8. Label nodes for database workloads
echo -e "${BLUE}Labeling nodes for database workloads...${NC}"
kubectl label nodes --all workload.bizmatters.dev/databases=true --overwrite
echo -e "${GREEN}✓ Nodes labeled${NC}"

echo ""

# Preview-specific exclusions and setup complete
echo ""
echo -e "${GREEN}✓ Preview cluster setup complete${NC}"
echo -e "  Cluster: ${BLUE}kind-${CLUSTER_NAME}${NC}"
echo -e "  Context: ${BLUE}kind-${CLUSTER_NAME}${NC}"
echo ""

exit 0