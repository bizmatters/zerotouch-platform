#!/bin/bash
set -e

# ArgoCD Root Application Deployment Script
# Deploys the platform root application after KSOPS is configured
# Prerequisites: ArgoCD installed, KSOPS package deployed
# Usage: ./10-deploy-root-app.sh [MODE] [ENVIRONMENT]

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ARGOCD_NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"

# Parse mode parameter (first arg) and environment (second arg)
MODE="${1:-auto}"
ENVIRONMENT="${2:-dev}"

# Root application path - now using environment-specific overlays
if [ "$MODE" = "preview" ]; then
    ROOT_APP_OVERLAY="bootstrap/argocd/overlays/preview"
else
    # Use environment-specific overlay inside main (dev, staging, production)
    ROOT_APP_OVERLAY="bootstrap/argocd/overlays/main/$ENVIRONMENT"
fi

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

# Check prerequisites
log_info "════════════════════════════════════════════════════════"
log_info "ArgoCD Root Application Deployment"
log_info "════════════════════════════════════════════════════════"

# Step 1: Get initial admin password
log_info ""
log_step "Step 1/3: Retrieving ArgoCD credentials..."

ARGOCD_PASSWORD=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [[ -z "$ARGOCD_PASSWORD" ]]; then
    log_warn "Could not retrieve ArgoCD password (might be using external auth)"
else
    log_info "✓ ArgoCD credentials retrieved"
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "ArgoCD Login Credentials:"
    echo -e "  ${YELLOW}Username:${NC} admin"
    if [[ -z "$CI" ]]; then
        echo -e "  ${YELLOW}Password:${NC} $ARGOCD_PASSWORD"
    else
        echo -e "  ${YELLOW}Password:${NC} ***MASKED*** (CI mode)"
    fi
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

# Step 2: Deploy root application using overlays
log_info ""
log_step "Step 2/3: Deploying platform via Kustomize overlay..."

if [[ ! -d "$REPO_ROOT/$ROOT_APP_OVERLAY" ]]; then
    log_error "Root application overlay not found at: $REPO_ROOT/$ROOT_APP_OVERLAY"
    exit 1
fi

if [ "$MODE" = "preview" ]; then
    log_info "Applying PREVIEW configuration (No Cilium, Local URLs)..."
else
    log_info "Applying PRODUCTION configuration (With Cilium, GitHub URLs)..."
fi

# Debug: Log overlay contents before applying
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "DEBUG: Verifying overlay configuration"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log_info "Using overlay: $ROOT_APP_OVERLAY"

# Export SOPS_AGE_KEY for kustomize KSOPS plugin
if kubectl get secret sops-age -n argocd &>/dev/null; then
    export SOPS_AGE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d)
    log_info "✓ SOPS_AGE_KEY exported for kustomize"
fi

# Test the kustomization
log_info "Testing kustomization build..."
XDG_CONFIG_HOME="$HOME/.config" kubectl kustomize "$REPO_ROOT/$ROOT_APP_OVERLAY" --enable-alpha-plugins > /tmp/kustomize-output.yaml
KUSTOMIZE_APPS=$(grep -c "kind: Application" /tmp/kustomize-output.yaml || echo "0")
log_info "  Generated $KUSTOMIZE_APPS Application resources"

if [ "$MODE" = "preview" ]; then
    LOCAL_COUNT=$(grep -c "file:///repo" /tmp/kustomize-output.yaml || echo "0")
    CILIUM_EXCLUDED=$(grep -c "exclude.*cilium" /tmp/kustomize-output.yaml || echo "0")
    log_info "  Local file URLs: $LOCAL_COUNT"
    log_info "  Cilium exclusions: $CILIUM_EXCLUDED"
else
    GITHUB_COUNT=$(grep -c "github.com" /tmp/kustomize-output.yaml || echo "0")
    CILIUM_APPS=$(grep -c "name: cilium" /tmp/kustomize-output.yaml || echo "0")
    log_info "  GitHub URLs: $GITHUB_COUNT"
    log_info "  Cilium applications: $CILIUM_APPS"
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log_info "Applying root application..."
kubectl apply --server-side -f "$REPO_ROOT/$ROOT_APP_OVERLAY/root.yaml"

log_info "✓ Platform definitions applied"

# Step 3: Wait for initial sync
log_info ""
log_step "Step 3/3: Waiting for initial sync..."

# Give ArgoCD time to detect and process the application
sleep 5

log_info "Checking ArgoCD applications..."
kubectl get applications -n "$ARGOCD_NAMESPACE"

log_info ""
log_info "✓ GitOps deployment initiated!"

# Final instructions
cat << EOF

${GREEN}════════════════════════════════════════════════════════${NC}
${GREEN}✓ ArgoCD Root Application Deployment Completed!${NC}
${GREEN}════════════════════════════════════════════════════════${NC}

${YELLOW}What's Happening Now:${NC}
- ArgoCD applications have been created but are still syncing
- Applications may show "Unknown" status initially - this is normal
- Foundation layer (Cilium, Crossplane, KEDA, Kagent) will deploy first

${YELLOW}⚠️  Note: Applications are NOT yet synced - use the monitoring commands below${NC}

${YELLOW}Monitor Deployment:${NC}

1. ${BLUE}Watch ArgoCD applications:${NC}
   kubectl get applications -n argocd -w

2. ${BLUE}Access ArgoCD UI:${NC}
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   
   Then open: https://localhost:8080
   Username: admin
   Password: $ARGOCD_PASSWORD

3. ${BLUE}Check specific layers:${NC}
   # Foundation layer
   kubectl get pods -n kube-system
   kubectl get pods -n crossplane-system
   kubectl get pods -n kagent
   
   # Intelligence layer
   kubectl get pods -n intelligence

4. ${BLUE}View ArgoCD sync status:${NC}
   kubectl get applications -n argocd
   
   # Expected applications:
   # - platform-root (root app-of-apps)
   # - foundation
   # - intelligence

${YELLOW}Troubleshooting:${NC}
- If applications show "OutOfSync", they may be syncing
- If applications show "Degraded", check pod status
- View application details: kubectl describe application <name> -n argocd
- View ArgoCD logs: kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

${YELLOW}Next Steps:${NC}
1. Wait 5-10 minutes for all components to sync and become healthy
2. Verify foundation layer is running
3. Verify intelligence layer components are deployed
4. Create required secrets (GitHub token, OpenAI key) for intelligence layer

${GREEN}Documentation:${NC}
- ArgoCD: https://argo-cd.readthedocs.io/
- Platform walkthrough: See walkthrough.md artifact

EOF
