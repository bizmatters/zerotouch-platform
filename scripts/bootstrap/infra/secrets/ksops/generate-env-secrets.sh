#!/bin/bash
# Generate environment-specific secrets (DEV_*, STAGING_*, PROD_*)

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

for ENV in dev staging prod; do
    ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
    SECRETS_DIR="$OVERLAYS_DIR/$ENV/secrets"
    
    echo -e "${BLUE}Processing ${ENV_UPPER} environment...${NC}"
    
    mkdir -p "$SECRETS_DIR"
    
    if [ -d "$SECRETS_DIR" ]; then
        find "$SECRETS_DIR" -name "*.secret.yaml" -type f -delete
    fi
    
    SECRET_FILES=()
    SECRET_COUNT=0
    
    while IFS='=' read -r name value || [ -n "$name" ]; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        
        if [[ "$name" =~ ^${ENV_UPPER}_(.+)$ ]]; then
            mapping=$(get_secret_mapping "$name")
            if [ -n "$mapping" ]; then
                secret_name="${mapping%%:*}"
                secret_key="${mapping##*:}"
            else
                secret_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                secret_key="value"
            fi
            
            secret_file="${secret_name}.secret.yaml"
            
            cat > "$SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
type: Opaque
stringData:
  ${secret_key}: ${value}
EOF
            
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
    
    if [ ${#SECRET_FILES[@]} -gt 0 ]; then
        # Create KSOPS Generator
        cat > "$SECRETS_DIR/ksops-generator.yaml" << EOF
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ${ENV}-secrets-generator
files:
EOF
        for file in "${SECRET_FILES[@]}"; do
            echo "  - ./$file" >> "$SECRETS_DIR/ksops-generator.yaml"
        done
        
        # Create Kustomization with generator
        cat > "$SECRETS_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

generators:
- ksops-generator.yaml
EOF
        echo -e "${GREEN}  ✓ kustomization.yaml (KSOPS generator with ${SECRET_COUNT} secrets)${NC}"
    else
        echo -e "${YELLOW}  ⚠️  No ${ENV_UPPER}_* variables found${NC}"
    fi
    echo ""
done
