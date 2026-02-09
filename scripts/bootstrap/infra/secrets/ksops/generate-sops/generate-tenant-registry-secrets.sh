#!/bin/bash
# Generate tenant secrets (GitHub App credentials for ArgoCD)

set -e

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env.local"

# Template paths
TEMPLATE_DIR="$REPO_ROOT/scripts/bootstrap/infra/secrets/ksops/templates"
UNIVERSAL_SECRET_TEMPLATE="$TEMPLATE_DIR/universal-secret.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Determine overlay directory based on ENV (single secrets folder)
ENV="${ENV:-dev}"
if [[ "$ENV" == "pr" ]]; then
    SECRETS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/preview/secrets"
else
    SECRETS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main/${ENV}/secrets"
fi

echo -e "${BLUE}Processing TENANT secrets for ENV=${ENV}...${NC}"
echo -e "${BLUE}Target directory: ${SECRETS_DIR}${NC}"

set -a
source "$ENV_FILE"
set +a

mkdir -p "$SECRETS_DIR"

# ArgoCD repo credentials template (repo-creds)
# Uses repo-creds type with project scoping to avoid conflicts with repository type secrets
# Scoped to tenants repo only for principle of least privilege
if [[ -n "$ORG_NAME" && -n "$TENANTS_REPO_NAME" && -n "$GIT_APP_ID" && -n "$GIT_APP_INSTALLATION_ID" && -n "$GIT_APP_PRIVATE_KEY" ]]; then
    REPO_URL="https://github.com/${ORG_NAME}/${TENANTS_REPO_NAME}.git"
    
    cat > "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-zerotouch-tenants
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
  annotations:
    argocd.argoproj.io/sync-wave: "2"
type: Opaque
stringData:
  type: git
EOF
    
    echo "  url: ${REPO_URL}" >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  project: default" >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppID: \"${GIT_APP_ID}\"" >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppInstallationID: \"${GIT_APP_INSTALLATION_ID}\"" >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "  githubAppPrivateKey: |" >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    echo "$GIT_APP_PRIVATE_KEY" | sed 's/^/    /' >> "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    
    if sops --config "$SOPS_CONFIG" -e -i "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ repo-zerotouch-tenants.secret.yaml${NC}"
    else
        echo -e "${RED}  ✗ Failed to encrypt: repo-zerotouch-tenants.secret.yaml${NC}"
        rm -f "$SECRETS_DIR/repo-zerotouch-tenants.secret.yaml"
    fi
    
    # Update kustomization to include tenant secret
    if [ -f "$SECRETS_DIR/kustomization.yaml" ]; then
        # Append to existing ksops-generator.yaml
        if ! grep -q "repo-zerotouch-tenants.secret.yaml" "$SECRETS_DIR/ksops-generator.yaml" 2>/dev/null; then
            echo "  - ./repo-zerotouch-tenants.secret.yaml" >> "$SECRETS_DIR/ksops-generator.yaml"
            echo -e "${GREEN}  ✓ Updated ksops-generator.yaml${NC}"
        fi
    fi
else
    echo -e "${YELLOW}  ⚠️  Skipping ArgoCD repo secret (missing credentials)${NC}"
fi

# GHCR pull secret (initial bootstrap only)
# This creates the initial ghcr-pull-secret for first deployment
# After deployment, platform/foundation/ghcr-token-refresher/cronjob.yaml automatically
# refreshes this secret every 30 minutes in all tenant namespaces using github-app-credentials
if [[ -n "$GIT_APP_ID" && -n "$GIT_APP_INSTALLATION_ID" && -n "$GIT_APP_PRIVATE_KEY" ]]; then
    # Generate JWT for GitHub App
    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    
    HEADER='{"alg":"RS256","typ":"JWT"}'
    PAYLOAD="{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GIT_APP_ID}\"}"
    
    HEADER_B64=$(echo -n "$HEADER" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    SIGNATURE=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -sign <(echo "$GIT_APP_PRIVATE_KEY") | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    JWT="${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"
    
    # Get installation access token
    TOKEN_RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $JWT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${GIT_APP_INSTALLATION_ID}/access_tokens")
    
    GITHUB_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
    
    if [ -n "$GITHUB_TOKEN" ]; then
        # Create dockerconfigjson auth string
        AUTH_STRING=$(echo -n "x-access-token:${GITHUB_TOKEN}" | base64)
        
        DOCKER_CONFIG_JSON="{\"auths\":{\"ghcr.io\":{\"auth\":\"${AUTH_STRING}\"}}}"
        
        cat > "$SECRETS_DIR/ghcr-pull-secret.secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull-secret
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    ${DOCKER_CONFIG_JSON}
EOF
        
        if sops --config "$SOPS_CONFIG" -e -i "$SECRETS_DIR/ghcr-pull-secret.secret.yaml" 2>/dev/null; then
            echo -e "${GREEN}  ✓ ghcr-pull-secret.secret.yaml${NC}"
            
            # Update kustomization to include GHCR secret
            if [ -f "$SECRETS_DIR/kustomization.yaml" ]; then
                if ! grep -q "ghcr-pull-secret.secret.yaml" "$SECRETS_DIR/ksops-generator.yaml" 2>/dev/null; then
                    echo "  - ./ghcr-pull-secret.secret.yaml" >> "$SECRETS_DIR/ksops-generator.yaml"
                    echo -e "${GREEN}  ✓ Updated ksops-generator.yaml${NC}"
                fi
            fi
        else
            echo -e "${RED}  ✗ Failed to encrypt: ghcr-pull-secret.secret.yaml${NC}"
            rm -f "$SECRETS_DIR/ghcr-pull-secret.secret.yaml"
        fi
    else
        echo -e "${RED}  ✗ Failed to generate GitHub App token${NC}"
    fi
else
    echo -e "${YELLOW}  ⚠️  Skipping GHCR pull secret (missing credentials)${NC}"
fi

echo ""
