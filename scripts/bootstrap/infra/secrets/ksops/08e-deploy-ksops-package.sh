#!/bin/bash
set -e

# Deploy KSOPS Package to ArgoCD
# Usage: ./08e-deploy-ksops-package.sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   KSOPS Package Deployment to ArgoCD                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

# Check ArgoCD is running
echo -e "${BLUE}==> Checking ArgoCD status...${NC}"
if ! kubectl get deployment argocd-repo-server -n argocd &>/dev/null; then
    echo -e "${RED}❌ ArgoCD repo-server deployment not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ ArgoCD repo-server found${NC}"

# NOTE: KSOPS init container patch is already applied during ArgoCD installation
# via bootstrap/argocd/install/kustomization.yaml (JSON patches)
# No need to patch again here
echo -e "${BLUE}==> Skipping KSOPS patch (already applied at install time)...${NC}"

# Apply KSOPS package (includes Age Key Guardian CronJob)
echo -e "${BLUE}==> Applying KSOPS package resources...${NC}"
kubectl apply -k "$REPO_ROOT/platform/secrets/ksops/"
echo -e "${GREEN}✓ KSOPS package resources applied${NC}"

# No rollout needed - deployment not changed
echo -e "${GREEN}✓ ArgoCD repo-server already configured with KSOPS${NC}"

# Wait for init container to complete and repo-server to be ready
echo -e "${BLUE}==> Waiting for init container and repo-server...${NC}"
"$SCRIPT_DIR/../../../wait/09c-wait-ksops-sidecar.sh" --timeout 300
echo -e "${GREEN}✓ KSOPS init container completed and tools available${NC}"

echo -e "${GREEN}✅ KSOPS package deployment complete${NC}"