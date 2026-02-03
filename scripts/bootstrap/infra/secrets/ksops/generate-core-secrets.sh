#!/bin/bash
# Generate core platform secrets (non-prefixed variables)

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

get_secret_mapping() {
    local var_name="$1"
    case "$var_name" in
        HETZNER_API_TOKEN|DEV_HETZNER_API_TOKEN|STAGING_HETZNER_API_TOKEN|PROD_HETZNER_API_TOKEN)
            echo "hcloud:token"
            ;;
        HETZNER_DNS_TOKEN|DEV_HETZNER_DNS_TOKEN|STAGING_HETZNER_DNS_TOKEN|PROD_HETZNER_DNS_TOKEN)
            echo "external-dns-hetzner:HETZNER_DNS_TOKEN"
            ;;
        *)
            echo ""
            ;;
    esac
}

CORE_SECRETS_DIR="$OVERLAYS_DIR/core/secrets"
echo -e "${BLUE}Processing CORE platform secrets...${NC}"

mkdir -p "$CORE_SECRETS_DIR"

set -a
source "$ENV_FILE"
set +a

CORE_SECRET_FILES=()
CORE_SECRET_COUNT=0

# Create ORG_NAME and TENANTS_REPO_NAME secrets
if [[ -n "$ORG_NAME" ]]; then
    cat > "$CORE_SECRETS_DIR/org-name.secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: org-name
  namespace: kube-system
type: Opaque
stringData:
  value: ${ORG_NAME}
EOF
    if sops -e -i "$CORE_SECRETS_DIR/org-name.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ org-name.secret.yaml${NC}"
        CORE_SECRET_FILES+=("org-name.secret.yaml")
        ((CORE_SECRET_COUNT++))
    fi
fi

if [[ -n "$TENANTS_REPO_NAME" ]]; then
    cat > "$CORE_SECRETS_DIR/tenants-repo-name.secret.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: tenants-repo-name
  namespace: kube-system
type: Opaque
stringData:
  value: ${TENANTS_REPO_NAME}
EOF
    if sops -e -i "$CORE_SECRETS_DIR/tenants-repo-name.secret.yaml" 2>/dev/null; then
        echo -e "${GREEN}  ✓ tenants-repo-name.secret.yaml${NC}"
        CORE_SECRET_FILES+=("tenants-repo-name.secret.yaml")
        ((CORE_SECRET_COUNT++))
    fi
fi

while IFS='=' read -r name value || [ -n "$name" ]; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    [[ "$name" =~ ^APP_ ]] && continue
    [[ "$name" =~ ^GITHUB_APP_ ]] && continue
    [[ "$name" =~ ^(ORG_NAME|TENANTS_REPO_NAME)$ ]] && continue
    [[ "$name" =~ ^(DEV|STAGING|PROD|PR)_ ]] && continue
    [[ "$value" =~ $'\n' ]] && continue
    [[ ${#value} -gt 500 ]] && continue
    [[ -z "$value" ]] && continue
    
    mapping=$(get_secret_mapping "$name")
    if [ -n "$mapping" ]; then
        secret_name="${mapping%%:*}"
        secret_key="${mapping##*:}"
    else
        secret_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        secret_key="value"
    fi
    
    [[ ! "$secret_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && continue
    
    secret_file="${secret_name}.secret.yaml"
    
    cat > "$CORE_SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
type: Opaque
stringData:
  ${secret_key}: ${value}
EOF
    
    if sops -e -i "$CORE_SECRETS_DIR/$secret_file" 2>/dev/null; then
        echo -e "${GREEN}  ✓ ${secret_file}${NC}"
        CORE_SECRET_FILES+=("$secret_file")
        ((CORE_SECRET_COUNT++))
    else
        echo -e "${RED}  ✗ Failed to encrypt: ${secret_file}${NC}"
        rm -f "$CORE_SECRETS_DIR/$secret_file"
    fi
done < "$ENV_FILE"

# Add GitHub App secrets to kustomization (created by tenant script)
for github_secret in github-app-id.secret.yaml github-app-installation-id.secret.yaml github-app-private-key.secret.yaml; do
    if [ -f "$CORE_SECRETS_DIR/$github_secret" ]; then
        CORE_SECRET_FILES+=("$github_secret")
        ((CORE_SECRET_COUNT++))
    fi
done

if [ ${#CORE_SECRET_FILES[@]} -gt 0 ]; then
    # Create KSOPS Generator
    cat > "$CORE_SECRETS_DIR/ksops-generator.yaml" << EOF
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: core-secrets-generator
files:
EOF
    for file in "${CORE_SECRET_FILES[@]}"; do
        echo "  - ./$file" >> "$CORE_SECRETS_DIR/ksops-generator.yaml"
    done
    
    # Create Kustomization with generator
    cat > "$CORE_SECRETS_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

generators:
- ksops-generator.yaml
EOF
    echo -e "${GREEN}  ✓ kustomization.yaml (KSOPS generator with ${CORE_SECRET_COUNT} secrets)${NC}"
else
    echo -e "${YELLOW}  ⚠️  No core platform secrets found${NC}"
fi
echo ""
