#!/bin/bash
# Bootstrap script to inject platform secrets using SOPS
# Usage: ./08d-inject-sops-secrets.sh
#
# This script dynamically discovers all environment-prefixed secrets and creates SOPS-encrypted K8s secrets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Platform Secrets Injection - SOPS                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Detect environment (PR, DEV, STAGING, PRD)
ENVIRONMENT="${ENVIRONMENT:-PR}"
ENV_PREFIX="${ENVIRONMENT}_"

echo -e "${BLUE}Environment: ${ENVIRONMENT}${NC}"
echo -e "${BLUE}Looking for secrets with prefix: ${ENV_PREFIX}${NC}"
echo ""

# Find all environment variables with the environment prefix
PREFIXED_SECRETS=$(printenv | grep "^${ENV_PREFIX}" | cut -d= -f1 | sort)

if [ -z "$PREFIXED_SECRETS" ]; then
    echo -e "${YELLOW}⚠️  No secrets found with prefix ${ENV_PREFIX}${NC}"
    echo -e "${YELLOW}⚠️  Skipping secrets injection${NC}"
    exit 0
fi

echo -e "${GREEN}✓ Found secrets with ${ENV_PREFIX} prefix:${NC}"
echo "$PREFIXED_SECRETS" | while read secret_name; do
    echo -e "  - $secret_name"
done
echo ""

SECRET_COUNT=$(echo "$PREFIXED_SECRETS" | wc -l)
echo -e "${GREEN}✓ Total secrets to process: $SECRET_COUNT${NC}"
echo ""

# Check prerequisites
if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ Error: kubectl not found${NC}"
    exit 1
fi

# Verify Age key exists
if ! kubectl get secret sops-age -n argocd &>/dev/null; then
    echo -e "${RED}✗ Error: sops-age secret not found in argocd namespace${NC}"
    echo -e "${YELLOW}Run 08c-inject-age-key.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites satisfied${NC}"
echo ""

# Create temporary directory for SOPS files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Process each secret
CREATED_COUNT=0
FAILED_COUNT=0

echo -e "${BLUE}==> Processing secrets...${NC}"
echo ""

for prefixed_var in $PREFIXED_SECRETS; do
    # Strip environment prefix
    secret_name="${prefixed_var#${ENV_PREFIX}}"
    secret_value="${!prefixed_var}"
    
    # Convert to lowercase and replace underscores with hyphens for K8s naming
    k8s_secret_name=$(echo "$secret_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    
    # Determine namespace (default to 'default', can be customized based on secret name)
    namespace="default"
    
    echo -e "${BLUE}Processing: ${prefixed_var} → ${k8s_secret_name} (namespace: ${namespace})${NC}"
    
    # Create SOPS-encrypted secret file
    cat > "$TEMP_DIR/${k8s_secret_name}.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${k8s_secret_name}
  namespace: ${namespace}
type: Opaque
stringData:
  value: ${secret_value}
EOF
    
    # Encrypt with SOPS
    if sops -e -i "$TEMP_DIR/${k8s_secret_name}.yaml" 2>/dev/null; then
        # Apply to cluster
        if kubectl apply -f "$TEMP_DIR/${k8s_secret_name}.yaml" &>/dev/null; then
            # Verify secret exists
            if kubectl get secret "${k8s_secret_name}" -n "${namespace}" &>/dev/null; then
                echo -e "${GREEN}✓ Created: ${k8s_secret_name}${NC}"
                ((CREATED_COUNT++))
            else
                echo -e "${RED}✗ Failed to verify: ${k8s_secret_name}${NC}"
                ((FAILED_COUNT++))
            fi
        else
            echo -e "${RED}✗ Failed to apply: ${k8s_secret_name}${NC}"
            ((FAILED_COUNT++))
        fi
    else
        echo -e "${RED}✗ Failed to encrypt: ${k8s_secret_name}${NC}"
        ((FAILED_COUNT++))
    fi
    echo ""
done

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Summary                                                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Environment: ${ENVIRONMENT}${NC}"
echo -e "${GREEN}✓ Secrets processed: ${SECRET_COUNT}${NC}"
echo -e "${GREEN}✓ Successfully created: ${CREATED_COUNT}${NC}"
if [ $FAILED_COUNT -gt 0 ]; then
    echo -e "${RED}✗ Failed: ${FAILED_COUNT}${NC}"
    exit 1
fi
echo ""
echo -e "${GREEN}✅ All secrets injected successfully${NC}"
echo ""

exit 0
