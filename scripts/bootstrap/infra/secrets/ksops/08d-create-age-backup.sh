#!/bin/bash
set -euo pipefail

# Create Age Key Backup for Automated Recovery
# Usage: ./08d-create-age-backup.sh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Age Key Backup Creation for Disaster Recovery             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if sops-age secret exists
if ! kubectl get secret sops-age -n argocd &>/dev/null; then
    echo -e "${RED}✗ sops-age secret not found${NC}"
    echo -e "${YELLOW}Run 08c-inject-age-key.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}✓ sops-age secret found${NC}"
echo ""

# Generate recovery master key
echo -e "${BLUE}Generating recovery master key...${NC}"
RECOVERY_KEY=$(age-keygen 2>/dev/null)
RECOVERY_PUBLIC=$(echo "$RECOVERY_KEY" | grep "public key:" | cut -d: -f2 | xargs)
RECOVERY_PRIVATE=$(echo "$RECOVERY_KEY" | grep "AGE-SECRET-KEY-" | xargs)

echo -e "${GREEN}✓ Recovery master key generated${NC}"
echo -e "${BLUE}Recovery public key: $RECOVERY_PUBLIC${NC}"
echo ""

# Extract Age private key from sops-age secret
echo -e "${BLUE}Extracting Age private key...${NC}"
AGE_PRIVATE_KEY=$(kubectl get secret sops-age -n argocd -o jsonpath='{.data.keys\.txt}' | base64 -d)
echo -e "${GREEN}✓ Age private key extracted${NC}"
echo ""

# Encrypt Age private key with recovery master key
echo -e "${BLUE}Encrypting Age private key with recovery master key...${NC}"
ENCRYPTED_BACKUP=$(echo "$AGE_PRIVATE_KEY" | age -r "$RECOVERY_PUBLIC" -a)
echo -e "${GREEN}✓ Age private key encrypted${NC}"
echo ""

# Create age-backup-encrypted secret
echo -e "${BLUE}Creating age-backup-encrypted secret...${NC}"
kubectl create secret generic age-backup-encrypted \
    --from-literal=encrypted-key.txt="$ENCRYPTED_BACKUP" \
    --namespace=argocd \
    --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ age-backup-encrypted secret created${NC}"
echo ""

# Create recovery-master-key secret
echo -e "${BLUE}Creating recovery-master-key secret...${NC}"
kubectl create secret generic recovery-master-key \
    --from-literal=recovery-key.txt="$RECOVERY_PRIVATE" \
    --namespace=argocd \
    --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ recovery-master-key secret created${NC}"
echo ""

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Backup Summary                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Age key backup created successfully${NC}"
echo -e "${GREEN}✓ Secret: age-backup-encrypted (encrypted Age key)${NC}"
echo -e "${GREEN}✓ Secret: recovery-master-key (recovery key)${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Store recovery master key securely offline${NC}"
echo -e "${YELLOW}Recovery public key: $RECOVERY_PUBLIC${NC}"
echo ""
