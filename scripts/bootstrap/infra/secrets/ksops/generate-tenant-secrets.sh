#!/bin/bash
# Generate tenant secrets (GitHub App credentials for ArgoCD)

set -e

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env"
OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

set -a
source "$ENV_FILE"
set +a

REGISTRY_SECRETS_DIR="$OVERLAYS_DIR/registry"
CORE_SECRETS_DIR="$OVERLAYS_DIR/core/secrets"

echo -e "${BLUE}Processing TENANT secrets...${NC}"

mkdir -p "$REGISTRY_SECRETS_DIR"
mkdir -p "$CORE_SECRETS_DIR"

if [ -d "$REGISTRY_SECRETS_DIR" ]; then
    find "$REGISTRY_SECRETS_DIR" -name "*.secret.yaml" -type f -delete
fi

# ArgoCD repo secret
if [[ -n "$ORG_NAME" && -n "$TENANTS_REPO_NAME" && -n "$GITHUB_APP_ID" && -n "$GITHUB_APP_INSTALLATION_ID" && -n "$GITHUB_APP_PRIVATE_KEY" ]]; then
    REPO_URL="https://github.com/${ORG_NAME}/${TENANTS_REPO_NAME}.git"
    
    cat > "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-zerotouch-tenants
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
  annotations:
    argocd.argoproj.io/sync-wave: "2"
type: Opaque
stringData:
  type: git
EOF
    
    echo "  url: ${REPO_URL}" >> "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppID: \"${GITHUB_APP_ID}\"" >> "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppInstallationID: \"${GITHUB_APP_INSTALLATION_ID}\"" >> "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppPrivateKey: |" >> "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "$GITHUB_APP_PRIVATE_KEY" | sed 's/^/    /' >> "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    
    if sops -e -i "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ repo-zerotouch-tenants.secret.yaml${NC}"
    else
        echo -e "${RED}  ✗ Failed to encrypt: repo-zerotouch-tenants.secret.yaml${NC}"
        rm -f "$REGISTRY_SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    fi
else
    echo -e "${YELLOW}  ⚠️  Skipping ArgoCD repo secret (missing credentials)${NC}"
fi

# Individual GitHub App secrets for scripts
if [[ -n "$GITHUB_APP_ID" ]]; then
    cat > "$CORE_SECRETS_DIR/github-app-id.secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-app-id
  namespace: kube-system
type: Opaque
stringData:
  value: ${GITHUB_APP_ID}
EOF
    if sops -e -i "$CORE_SECRETS_DIR/github-app-id.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ github-app-id.secret.yaml${NC}"
    fi
fi

if [[ -n "$GITHUB_APP_INSTALLATION_ID" ]]; then
    cat > "$CORE_SECRETS_DIR/github-app-installation-id.secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: github-app-installation-id
  namespace: kube-system
type: Opaque
stringData:
  value: ${GITHUB_APP_INSTALLATION_ID}
EOF
    if sops -e -i "$CORE_SECRETS_DIR/github-app-installation-id.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ github-app-installation-id.secret.yaml${NC}"
    fi
fi

if [[ -n "$GITHUB_APP_PRIVATE_KEY" ]]; then
    cat > "$CORE_SECRETS_DIR/github-app-private-key.secret.yaml" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: github-app-private-key
  namespace: kube-system
type: Opaque
stringData:
  value: |
EOF
    echo "$GITHUB_APP_PRIVATE_KEY" | sed 's/^/    /' >> "$CORE_SECRETS_DIR/github-app-private-key.secret.yaml"
    
    if sops -e -i "$CORE_SECRETS_DIR/github-app-private-key.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ github-app-private-key.secret.yaml${NC}"
    else
        echo -e "${RED}  ✗ Failed to encrypt: github-app-private-key.secret.yaml${NC}"
        rm -f "$CORE_SECRETS_DIR/github-app-private-key.secret.yaml"
    fi
fi

echo ""
