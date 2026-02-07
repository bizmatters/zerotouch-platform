#!/bin/bash
# Generate environment-specific secrets (DEV_*, STAGING_*, PROD_*)
# cd zerotouch-platform && set -a && source .env && set +a && ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-env-secrets.sh

set -e

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENV_FILE="$REPO_ROOT/.env.local"

# Determine overlay directory based on ENV
ENV="${ENV:-dev}"
if [[ "$ENV" == "pr" ]]; then
    OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/preview"
else
    OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main"
fi

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
            echo "hcloud:token:kube-system"
            ;;
        HETZNER_DNS_TOKEN|DEV_HETZNER_DNS_TOKEN|STAGING_HETZNER_DNS_TOKEN|PROD_HETZNER_DNS_TOKEN)
            echo "hetzner-dns:api-key:cert-manager"
            echo "external-dns-hetzner:HETZNER_DNS_TOKEN:kube-system"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Only process the specified environment, not all environments
if [[ -z "$ENV" ]]; then
    echo -e "${RED}Error: ENV variable not set${NC}"
    exit 1
fi

ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')

# Determine overlay directory for this specific ENV
if [[ "$ENV" == "pr" ]]; then
    ENV_OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/preview"
    SECRETS_DIR="$ENV_OVERLAYS_DIR/secrets"
else
    ENV_OVERLAYS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main"
    SECRETS_DIR="$ENV_OVERLAYS_DIR/$ENV/secrets"
fi

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
                # Process each mapping (some vars create multiple secrets)
                while IFS= read -r map; do
                    [ -z "$map" ] && continue
                    IFS=':' read -r secret_name secret_key secret_namespace <<< "$map"
                    secret_namespace="${secret_namespace:-kube-system}"
                    
                    secret_file="${secret_name}.secret.yaml"
                    
                    # Determine sync wave based on namespace
                    sync_wave=""
                    if [ "$secret_namespace" = "cert-manager" ]; then
                        sync_wave="4"
                    fi
                    
                    cat > "$SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${secret_namespace}
EOF
                    
                    if [ -n "$sync_wave" ]; then
                        cat >> "$SECRETS_DIR/$secret_file" << EOF
  annotations:
    argocd.argoproj.io/sync-wave: "${sync_wave}"
EOF
                    fi
                    
                    cat >> "$SECRETS_DIR/$secret_file" << EOF
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
                done <<< "$mapping"
            else
                secret_name=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
                secret_key="value"
                secret_namespace="kube-system"
                secret_file="${secret_name}.secret.yaml"
                
                cat > "$SECRETS_DIR/$secret_file" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: ${secret_namespace}
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
        fi
    done < "$ENV_FILE"
    
    if [ ${#SECRET_FILES[@]} -gt 0 ]; then
        # Create or append to KSOPS Generator
        if [ ! -f "$SECRETS_DIR/ksops-generator.yaml" ]; then
            # Create new generator
            cat > "$SECRETS_DIR/ksops-generator.yaml" << EOF
# Generated by: scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-env-secrets.sh
# DO NOT EDIT MANUALLY - Changes will be overwritten
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ${ENV}-secrets-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
EOF
        fi
        
        # Append files to generator
        for file in "${SECRET_FILES[@]}"; do
            if ! grep -q "\./$file" "$SECRETS_DIR/ksops-generator.yaml" 2>/dev/null; then
                echo "  - ./$file" >> "$SECRETS_DIR/ksops-generator.yaml"
            fi
        done
        
        # Create Kustomization if it doesn't exist
        if [ ! -f "$SECRETS_DIR/kustomization.yaml" ]; then
            cat > "$SECRETS_DIR/kustomization.yaml" << EOF
# Generated by: scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-env-secrets.sh
# DO NOT EDIT MANUALLY - Changes will be overwritten
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

generators:
- ksops-generator.yaml
EOF
        fi
        echo -e "${GREEN}  ✓ kustomization.yaml (KSOPS generator with ${SECRET_COUNT} secrets)${NC}"
    else
        echo -e "${YELLOW}  ⚠️  No ${ENV_UPPER}_* variables found${NC}"
    fi
    echo ""
