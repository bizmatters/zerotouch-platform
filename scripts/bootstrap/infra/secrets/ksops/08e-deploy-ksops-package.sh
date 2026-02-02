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

# Apply KSOPS ConfigMap
echo -e "${BLUE}==> Applying KSOPS ConfigMap...${NC}"
kubectl apply -f "$REPO_ROOT/platform/secrets/ksops/cmp-plugin.yaml"
echo -e "${GREEN}✓ KSOPS ConfigMap applied${NC}"

# Apply KSOPS sidecar patch
echo -e "${BLUE}==> Applying KSOPS sidecar patch...${NC}"
kubectl patch deployment argocd-repo-server -n argocd --patch-file "$REPO_ROOT/platform/secrets/ksops/patches/repo-server-ksops-sidecar.yaml"
echo -e "${GREEN}✓ KSOPS sidecar patch applied${NC}"

# Wait for rollout
echo -e "${BLUE}==> Waiting for repo-server rollout...${NC}"
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
echo -e "${GREEN}✓ ArgoCD repo-server restarted with KSOPS sidecar${NC}"

echo -e "${GREEN}✅ KSOPS package deployment complete${NC}"