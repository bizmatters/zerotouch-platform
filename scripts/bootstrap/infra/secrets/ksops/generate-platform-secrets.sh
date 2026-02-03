#!/bin/bash
# Generate SOPS-encrypted platform secrets for each environment overlay
# Usage: ./generate-platform-secrets.sh
#
# Creates secrets in:
# - bootstrap/argocd/overlays/main/{dev,staging,prod}/secrets/ (environment-specific)
# - bootstrap/argocd/overlays/main/core/secrets/ (shared platform secrets)
# 
# Processes:
# - DEV_*, STAGING_*, PROD_* → environment-specific
# - Other variables (except APP_*) → core/secrets
# - APP_* → skipped (application secrets)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env"
OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Generate Platform Secrets (KSOPS)                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if .env file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    exit 1
fi

# Check if sops is installed
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    echo -e "${YELLOW}Install sops: https://github.com/getsops/sops${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}✓ Reading from: $ENV_FILE${NC}"
echo ""

# Process environment-specific secrets (DEV_*, STAGING_*, PROD_*)
for ENV in dev staging prod; do
    ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
    SECRETS_DIR="$OVERLAYS_DIR/$ENV/secrets"
    
    echo -e "${BLUE}Processing ${ENV_UPPER} environment...${NC}"
    
    # Create secrets directory
    mkdir -p "$SECRETS_DIR"
    
    # Track created secrets for kustomization
    SECRET_FILES=()
    SECRET_COUNT=0
    
    # Read and process environment-prefixed variables
    while IFS='=' read -r name value || [ -n "$name" ]; do
        # Skip empty lines and comments
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        
        # Check if matches current environment prefix
        if [[ "$name" =~ ^${ENV_UPPER}_(.+)$ ]]; then
            secret_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            secret_file="${secret_name}.secret.yaml"
            
            # Create secret YAML file
            cat > "$SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
type: Opaque
stringData:
  value: ${value}
EOF
            
            # Encrypt with SOPS
            if sops -e -i "$SECRETS_DIR/$secret_file" 2>/dev/null; then
                echo -e "${GREEN}  ✓ ${secret_file}${NC}"
                SECRET_FILES+=("$secret_file")
                ((SECRET_COUNT++))
            else
                echo -e "${RED}  ✗ Failed to encrypt: ${secret_file}${NC}"
                rm -f "$SECRETS_DIR/$secret_file"
            fi
        fi
    done < "$ENV_FILE"
    
    # Create kustomization.yaml
    if [ ${#SECRET_FILES[@]} -gt 0 ]; then
        cat > "$SECRETS_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
EOF
        for file in "${SECRET_FILES[@]}"; do
            echo "- $file" >> "$SECRETS_DIR/kustomization.yaml"
        done
        echo -e "${GREEN}  ✓ kustomization.yaml (${SECRET_COUNT} secrets)${NC}"
    else
        echo -e "${YELLOW}  ⚠️  No ${ENV_UPPER}_* variables found${NC}"
    fi
    echo ""
done

# Process core platform secrets (no prefix, excluding APP_*)
CORE_SECRETS_DIR="$OVERLAYS_DIR/core/secrets"
echo -e "${BLUE}Processing CORE platform secrets...${NC}"

mkdir -p "$CORE_SECRETS_DIR"

CORE_SECRET_FILES=()
CORE_SECRET_COUNT=0

while IFS='=' read -r name value || [ -n "$name" ]; do
    # Skip empty lines and comments
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    
    # Skip APP_* variables
    [[ "$name" =~ ^APP_ ]] && continue
    
    # Skip environment-prefixed variables (already processed)
    [[ "$name" =~ ^(DEV|STAGING|PROD|PR)_ ]] && continue
    
    # Skip multiline values (contains newlines or is too long)
    [[ "$value" =~ $'\n' ]] && continue
    [[ ${#value} -gt 500 ]] && continue
    
    # Skip if value is empty
    [[ -z "$value" ]] && continue
    
    # Process as core secret
    secret_name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    
    # Validate secret name (must be valid Kubernetes resource name)
    if [[ ! "$secret_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        echo -e "${YELLOW}  ⚠️  Skipping invalid secret name: ${secret_name}${NC}"
        continue
    fi
    
    secret_file="${secret_name}.secret.yaml"
    
    # Create secret YAML file
    cat > "$CORE_SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
type: Opaque
stringData:
  value: ${value}
EOF
    
    # Encrypt with SOPS
    if sops -e -i "$CORE_SECRETS_DIR/$secret_file" 2>/dev/null; then
        echo -e "${GREEN}  ✓ ${secret_file}${NC}"
        CORE_SECRET_FILES+=("$secret_file")
        ((CORE_SECRET_COUNT++))
    else
        echo -e "${RED}  ✗ Failed to encrypt: ${secret_file}${NC}"
        rm -f "$CORE_SECRETS_DIR/$secret_file"
    fi
done < "$ENV_FILE"

# Create core kustomization.yaml
if [ ${#CORE_SECRET_FILES[@]} -gt 0 ]; then
    cat > "$CORE_SECRETS_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
EOF
    for file in "${CORE_SECRET_FILES[@]}"; do
        echo "- $file" >> "$CORE_SECRETS_DIR/kustomization.yaml"
    done
    echo -e "${GREEN}  ✓ kustomization.yaml (${CORE_SECRET_COUNT} secrets)${NC}"
else
    echo -e "${YELLOW}  ⚠️  No core platform secrets found${NC}"
fi
echo ""

echo -e "${GREEN}✅ Platform secrets generated${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review: ${GREEN}ls -la $OVERLAYS_DIR/*/secrets/${NC}"
echo -e "  2. Commit: ${GREEN}git add bootstrap/ && git commit -m 'chore: add platform secrets'${NC}"
echo -e "  3. Push: ${GREEN}git push${NC}"

exit 0
