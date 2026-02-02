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

# NOTE: Init container pattern does not use CMP ConfigMap
# The ConfigMap would trigger ArgoCD to create a sidecar, which we don't want
# echo -e "${BLUE}==> Skipping CMP ConfigMap (init container pattern)...${NC}"

# Apply KSOPS init container patch
echo -e "${BLUE}==> Applying KSOPS init container patch...${NC}"
kubectl patch deployment argocd-repo-server -n argocd --patch-file "$REPO_ROOT/platform/secrets/ksops/patches/repo-server-ksops-init.yaml"
echo -e "${GREEN}✓ KSOPS init container patch applied${NC}"

# Apply KSOPS package (includes Age Key Guardian CronJob)
echo -e "${BLUE}==> Applying KSOPS package resources...${NC}"
kubectl apply -k "$REPO_ROOT/platform/secrets/ksops/"
echo -e "${GREEN}✓ KSOPS package resources applied${NC}"

# Wait for rollout
echo -e "${BLUE}==> Waiting for repo-server rollout...${NC}"
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
echo -e "${GREEN}✓ ArgoCD repo-server restarted with KSOPS init container${NC}"

# Wait for init container to complete and repo-server to be ready
echo -e "${BLUE}==> Waiting for init container and repo-server...${NC}"
"$SCRIPT_DIR/../../../wait/09c-wait-ksops-sidecar.sh" --timeout 300
echo -e "${GREEN}✓ KSOPS init container completed and tools available${NC}"

echo -e "${GREEN}✅ KSOPS package deployment complete${NC}"