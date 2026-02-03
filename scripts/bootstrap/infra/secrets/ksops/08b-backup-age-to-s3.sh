#!/bin/bash
set -euo pipefail

# Backup Age Private Key to Hetzner Object Storage
# Usage: ./08b-backup-age-to-s3.sh
#
# Requires:
# - AGE_PRIVATE_KEY environment variable (from 08b-generate-age-keys.sh)
# - HETZNER_S3_ACCESS_KEY environment variable
# - HETZNER_S3_SECRET_KEY environment variable

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Backup Age Key to Hetzner Object Storage                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Validate prerequisites
if [ -z "${AGE_PRIVATE_KEY:-}" ]; then
    echo -e "${RED}✗ AGE_PRIVATE_KEY not set${NC}"
    echo -e "${YELLOW}Run 08b-generate-age-keys.sh first${NC}"
    exit 1
fi

if [ -z "${HETZNER_S3_ACCESS_KEY:-}" ] || [ -z "${HETZNER_S3_SECRET_KEY:-}" ]; then
    echo -e "${RED}✗ Hetzner S3 credentials not set${NC}"
    echo -e "${YELLOW}Set HETZNER_S3_ACCESS_KEY and HETZNER_S3_SECRET_KEY${NC}"
    exit 1
fi

# Check if age is installed
if ! command -v age &> /dev/null; then
    echo -e "${RED}✗ age not found${NC}"
    echo -e "${YELLOW}Run 08a-install-ksops.sh first${NC}"
    exit 1
fi

# Check if aws CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${YELLOW}Installing AWS CLI...${NC}"
    if command -v brew &> /dev/null; then
        brew install awscli
    else
        echo -e "${RED}✗ AWS CLI not found and brew not available${NC}"
        echo -e "${YELLOW}Install AWS CLI: https://aws.amazon.com/cli/${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Prerequisites validated${NC}"
echo ""

# Generate recovery master key
echo -e "${BLUE}Generating recovery master key...${NC}"
RECOVERY_KEY=$(age-keygen 2>/dev/null)
RECOVERY_PUBLIC=$(echo "$RECOVERY_KEY" | grep "public key:" | cut -d: -f2 | xargs)
RECOVERY_PRIVATE=$(echo "$RECOVERY_KEY" | grep "AGE-SECRET-KEY-" | xargs)

echo -e "${GREEN}✓ Recovery master key generated${NC}"
echo -e "${BLUE}Recovery public key: $RECOVERY_PUBLIC${NC}"
echo ""

# Encrypt Age private key with recovery master key
echo -e "${BLUE}Encrypting Age private key...${NC}"
ENCRYPTED_BACKUP=$(echo "$AGE_PRIVATE_KEY" | age -r "$RECOVERY_PUBLIC" -a)
echo -e "${GREEN}✓ Age private key encrypted${NC}"
echo ""

# Create temporary files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "$ENCRYPTED_BACKUP" > "$TEMP_DIR/age-key-encrypted.txt"
echo "$RECOVERY_PRIVATE" > "$TEMP_DIR/recovery-key.txt"

# Configure AWS CLI for Hetzner
export AWS_ACCESS_KEY_ID="$HETZNER_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$HETZNER_S3_SECRET_KEY"
export AWS_DEFAULT_REGION="eu-central"

S3_ENDPOINT="https://fsn1.your-objectstorage.com"
BUCKET_NAME="zerotouch-platform-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Upload encrypted Age key
echo -e "${BLUE}Uploading encrypted Age key to S3...${NC}"
aws s3 cp "$TEMP_DIR/age-key-encrypted.txt" \
    "s3://$BUCKET_NAME/age-keys/$TIMESTAMP-age-key-encrypted.txt" \
    --endpoint-url "$S3_ENDPOINT"
echo -e "${GREEN}✓ Encrypted Age key uploaded${NC}"
echo ""

# Upload recovery key
echo -e "${BLUE}Uploading recovery key to S3...${NC}"
aws s3 cp "$TEMP_DIR/recovery-key.txt" \
    "s3://$BUCKET_NAME/age-keys/$TIMESTAMP-recovery-key.txt" \
    --endpoint-url "$S3_ENDPOINT"
echo -e "${GREEN}✓ Recovery key uploaded${NC}"
echo ""

# Export recovery key for in-cluster backup
export RECOVERY_PRIVATE_KEY="$RECOVERY_PRIVATE"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Backup Summary                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Age key backed up to Hetzner Object Storage${NC}"
echo -e "${GREEN}✓ Location: s3://$BUCKET_NAME/age-keys/$TIMESTAMP-*${NC}"
echo -e "${GREEN}✓ Files:${NC}"
echo -e "${GREEN}  - age-key-encrypted.txt (encrypted Age private key)${NC}"
echo -e "${GREEN}  - recovery-key.txt (recovery master key)${NC}"
echo ""
echo -e "${YELLOW}CRITICAL: Store recovery key securely offline${NC}"
echo -e "${YELLOW}Recovery public key: $RECOVERY_PUBLIC${NC}"
echo ""
echo -e "${BLUE}To recover Age key:${NC}"
echo -e "  1. Download: ${GREEN}aws s3 cp s3://$BUCKET_NAME/age-keys/$TIMESTAMP-recovery-key.txt recovery.key --endpoint-url $S3_ENDPOINT${NC}"
echo -e "  2. Download: ${GREEN}aws s3 cp s3://$BUCKET_NAME/age-keys/$TIMESTAMP-age-key-encrypted.txt encrypted.txt --endpoint-url $S3_ENDPOINT${NC}"
echo -e "  3. Decrypt: ${GREEN}age -d -i recovery.key encrypted.txt${NC}"
echo ""

