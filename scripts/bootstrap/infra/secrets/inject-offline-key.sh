#!/bin/bash
# Emergency Break-Glass: Inject Age Private Key Offline
# Usage: ./inject-offline-key.sh [OPTIONS]
#
# This script provides emergency recovery capability to inject Age private keys
# into the cluster when automated recovery fails or during disaster recovery scenarios.
#
# SECURITY WARNING: This script handles sensitive cryptographic material.
# Use only in emergency situations and ensure secure key handling.

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-argocd}"
SECRET_NAME="${SECRET_NAME:-sops-age}"
AGE_KEY_FILE=""
AGE_KEY_STDIN=false
VERIFY_DECRYPTION=true

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Emergency script to inject Age private key into cluster for SOPS decryption.

OPTIONS:
    -f, --file FILE         Path to Age private key file
    -s, --stdin             Read Age private key from stdin (secure)
    -n, --namespace NS      Kubernetes namespace (default: argocd)
    --secret-name NAME      Secret name (default: sops-age)
    --no-verify             Skip decryption verification test
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    NAMESPACE               Kubernetes namespace (default: argocd)
    SECRET_NAME             Secret name (default: sops-age)

EXAMPLES:
    # Read key from file
    $0 --file /path/to/age-key.txt

    # Read key from stdin (more secure - no file on disk)
    cat age-key.txt | $0 --stdin

    # Read key from password manager
    op read "op://vault/age-key/private-key" | $0 --stdin

    # Specify custom namespace
    $0 --file age-key.txt --namespace custom-ns

OFFLINE BACKUP RETRIEVAL:
    1. Retrieve Age private key from secure password manager
    2. Verify key format (starts with AGE-SECRET-KEY-1)
    3. Run this script to inject into cluster
    4. Verify ArgoCD can decrypt secrets

SECURITY NOTES:
    - Age private keys are sensitive cryptographic material
    - Use stdin input to avoid leaving keys on disk
    - Delete key files immediately after use
    - Rotate keys after emergency recovery
    - Audit cluster access after break-glass events

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            AGE_KEY_FILE="$2"
            shift 2
            ;;
        -s|--stdin)
            AGE_KEY_STDIN=true
            shift
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --no-verify)
            VERIFY_DECRYPTION=false
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}❌ Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl not found. Please install kubectl.${NC}"
    exit 1
fi

# Validate cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}❌ Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi

echo -e "${BLUE}🚨 Emergency Break-Glass: Age Key Injection${NC}"
echo ""
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  Secret Name: $SECRET_NAME"
echo "  Verify Decryption: $VERIFY_DECRYPTION"
echo ""

# Read Age private key
AGE_PRIVATE_KEY=""

if [[ "$AGE_KEY_STDIN" == true ]]; then
    echo -e "${BLUE}📥 Reading Age private key from stdin...${NC}"
    AGE_PRIVATE_KEY=$(cat)
elif [[ -n "$AGE_KEY_FILE" ]]; then
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        echo -e "${RED}❌ Age key file not found: $AGE_KEY_FILE${NC}"
        exit 1
    fi
    echo -e "${BLUE}📥 Reading Age private key from file: $AGE_KEY_FILE${NC}"
    AGE_PRIVATE_KEY=$(cat "$AGE_KEY_FILE")
else
    echo -e "${RED}❌ No Age private key provided${NC}"
    echo "   Use --file or --stdin to provide the key"
    exit 1
fi

# Validate Age key format
if [[ ! "$AGE_PRIVATE_KEY" =~ ^AGE-SECRET-KEY-1 ]]; then
    echo -e "${RED}❌ Invalid Age private key format${NC}"
    echo "   Age private keys must start with 'AGE-SECRET-KEY-1'"
    exit 1
fi

# Validate key length (Age keys are base64-encoded 32-byte keys)
KEY_LENGTH=${#AGE_PRIVATE_KEY}
if [[ $KEY_LENGTH -lt 50 || $KEY_LENGTH -gt 100 ]]; then
    echo -e "${YELLOW}⚠️  Warning: Age key length unusual ($KEY_LENGTH chars)${NC}"
    echo "   Expected length: ~74 characters"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Aborted by user${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Age private key validated${NC}"
echo ""

# Ensure namespace exists
echo -e "${BLUE}🔍 Checking namespace...${NC}"
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}⚠️  Namespace $NAMESPACE does not exist${NC}"
    echo -e "${BLUE}   Creating namespace...${NC}"
    kubectl create namespace "$NAMESPACE"
    echo -e "${GREEN}✓ Namespace created${NC}"
else
    echo -e "${GREEN}✓ Namespace exists${NC}"
fi
echo ""

# Check if secret already exists
echo -e "${BLUE}🔍 Checking existing secret...${NC}"
if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${YELLOW}⚠️  Secret $SECRET_NAME already exists in namespace $NAMESPACE${NC}"
    echo ""
    echo "This will OVERWRITE the existing secret."
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}❌ Aborted by user${NC}"
        exit 1
    fi
    
    # Backup existing secret
    echo -e "${BLUE}💾 Backing up existing secret...${NC}"
    BACKUP_FILE="/tmp/${SECRET_NAME}-backup-$(date +%Y%m%d-%H%M%S).yaml"
    kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o yaml > "$BACKUP_FILE"
    echo -e "${GREEN}✓ Backup saved to: $BACKUP_FILE${NC}"
    echo ""
fi

# Create or update secret
echo -e "${BLUE}🔐 Injecting Age private key into cluster...${NC}"

# Use kubectl create secret with --dry-run=client and apply for idempotency
kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --from-literal=keys.txt="$AGE_PRIVATE_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓ Age private key injected successfully${NC}"
else
    echo -e "${RED}❌ Failed to inject Age private key${NC}"
    exit 1
fi
echo ""

# Verify secret was created correctly
echo -e "${BLUE}🔍 Verifying secret...${NC}"
if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}❌ Secret not found after creation${NC}"
    exit 1
fi

# Verify secret contains keys.txt
if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.keys\.txt}' | base64 -d | grep -q "AGE-SECRET-KEY-1"; then
    echo -e "${RED}❌ Secret does not contain valid Age key${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Secret verified${NC}"
echo ""

# Verify decryption capability (optional)
if [[ "$VERIFY_DECRYPTION" == true ]]; then
    echo -e "${BLUE}🧪 Testing decryption capability...${NC}"
    
    # Check if sops is available
    if ! command -v sops &> /dev/null; then
        echo -e "${YELLOW}⚠️  SOPS not found - skipping decryption test${NC}"
        echo "   Install SOPS to enable decryption verification"
    else
        # Create a test secret
        TEST_SECRET=$(mktemp)
        cat > "$TEST_SECRET" << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-decryption
type: Opaque
stringData:
  test: "emergency-recovery-test"
EOF
        
        # Get Age public key from private key
        if command -v age-keygen &> /dev/null; then
            AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y)
            
            # Encrypt test secret
            TEST_ENCRYPTED=$(mktemp)
            sops --encrypt --age "$AGE_PUBLIC_KEY" "$TEST_SECRET" > "$TEST_ENCRYPTED" 2>/dev/null
            
            # Try to decrypt using the injected key
            export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
            if sops --decrypt "$TEST_ENCRYPTED" > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Decryption test passed${NC}"
            else
                echo -e "${RED}❌ Decryption test failed${NC}"
                echo "   The injected key may not be correct"
                rm -f "$TEST_SECRET" "$TEST_ENCRYPTED"
                exit 1
            fi
            
            # Cleanup
            rm -f "$TEST_SECRET" "$TEST_ENCRYPTED"
            unset SOPS_AGE_KEY
        else
            echo -e "${YELLOW}⚠️  age-keygen not found - skipping decryption test${NC}"
            echo "   Install age to enable decryption verification"
        fi
    fi
    echo ""
fi

# Final instructions
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Emergency Age Key Injection Complete${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Next Steps:"
echo "  1. Verify ArgoCD can sync SOPS-encrypted applications"
echo "  2. Check ArgoCD logs for decryption errors"
echo "  3. Monitor application deployments"
echo "  4. Plan Age key rotation after emergency recovery"
echo "  5. Audit cluster access and document break-glass event"
echo ""
echo "Verify ArgoCD Decryption:"
echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=argocd-repo-server -c ksops"
echo ""
echo "Trigger ArgoCD Sync:"
echo "  argocd app sync <app-name>"
echo ""
echo -e "${YELLOW}⚠️  SECURITY REMINDER:${NC}"
echo "  • Delete Age key files from disk immediately"
echo "  • Rotate Age keys after emergency recovery"
echo "  • Document this break-glass event in incident log"
echo "  • Review cluster access logs"
echo ""

exit 0
