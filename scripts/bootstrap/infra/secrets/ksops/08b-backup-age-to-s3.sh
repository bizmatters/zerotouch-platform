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

if [ -z "${DEV_HETZNER_S3_ACCESS_KEY:-}" ] || [ -z "${DEV_HETZNER_S3_SECRET_KEY:-}" ]; then
    echo -e "${RED}✗ DEV_HETZNER_S3_ACCESS_KEY or DEV_HETZNER_S3_SECRET_KEY not set${NC}"
    exit 1
fi

if [ -z "${DEV_HETZNER_S3_ENDPOINT:-}" ] || [ -z "${DEV_HETZNER_S3_BUCKET_NAME:-}" ]; then
    echo -e "${RED}✗ DEV_HETZNER_S3_ENDPOINT or DEV_HETZNER_S3_BUCKET_NAME not set${NC}"
    exit 1
fi

if [ -z "${DEV_HETZNER_S3_REGION:-}" ]; then
    echo -e "${RED}✗ DEV_HETZNER_S3_REGION not set${NC}"
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
export AWS_ACCESS_KEY_ID="$DEV_HETZNER_S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$DEV_HETZNER_S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$DEV_HETZNER_S3_REGION"

S3_ENDPOINT="$DEV_HETZNER_S3_ENDPOINT"
BUCKET_NAME="$DEV_HETZNER_S3_BUCKET_NAME"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Check if bucket exists, create if not
echo -e "${BLUE}Checking S3 bucket...${NC}"
if ! aws s3 ls "s3://$BUCKET_NAME" --endpoint-url "$S3_ENDPOINT" --cli-connect-timeout 10 &>/dev/null; then
    echo -e "${YELLOW}Bucket doesn't exist, creating...${NC}"
    if ! aws s3 mb "s3://$BUCKET_NAME" --endpoint-url "$S3_ENDPOINT" --region "$DEV_HETZNER_S3_REGION" --cli-connect-timeout 10 2>&1 | grep -v "BucketAlreadyExists"; then
        # Check if bucket now exists (might have been created by another process)
        if ! aws s3 ls "s3://$BUCKET_NAME" --endpoint-url "$S3_ENDPOINT" --cli-connect-timeout 10 &>/dev/null; then
            echo -e "${RED}✗ Failed to create bucket${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✓ Bucket ready${NC}"
else
    echo -e "${GREEN}✓ Bucket exists${NC}"
fi
echo ""

# Upload encrypted Age key
echo -e "${BLUE}Uploading encrypted Age key to S3...${NC}"
if ! aws s3 cp "$TEMP_DIR/age-key-encrypted.txt" \
    "s3://$BUCKET_NAME/age-keys/$TIMESTAMP-age-key-encrypted.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 \
    --cli-read-timeout 30; then
    echo -e "${RED}✗ Failed to upload encrypted Age key${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Encrypted Age key uploaded${NC}"
echo ""

# Upload recovery key
echo -e "${BLUE}Uploading recovery key to S3...${NC}"
if ! aws s3 cp "$TEMP_DIR/recovery-key.txt" \
    "s3://$BUCKET_NAME/age-keys/$TIMESTAMP-recovery-key.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 \
    --cli-read-timeout 30; then
    echo -e "${RED}✗ Failed to upload recovery key${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Recovery key uploaded${NC}"
echo ""

# Mark as active key by creating stable reference files
echo -e "${BLUE}Marking as active key...${NC}"
if ! aws s3 cp "$TEMP_DIR/age-key-encrypted.txt" \
    "s3://$BUCKET_NAME/age-keys/ACTIVE-age-key-encrypted.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 \
    --cli-read-timeout 30; then
    echo -e "${RED}✗ Failed to mark active encrypted key${NC}"
    exit 1
fi

if ! aws s3 cp "$TEMP_DIR/recovery-key.txt" \
    "s3://$BUCKET_NAME/age-keys/ACTIVE-recovery-key.txt" \
    --endpoint-url "$S3_ENDPOINT" \
    --cli-connect-timeout 10 \
    --cli-read-timeout 30; then
    echo -e "${RED}✗ Failed to mark active recovery key${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Active key markers created${NC}"
echo ""

# Export recovery key for in-cluster backup
export RECOVERY_PRIVATE_KEY="$RECOVERY_PRIVATE"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Backup Summary                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Age key backed up to Hetzner Object Storage${NC}"
echo -e "${GREEN}✓ Location: s3://$BUCKET_NAME/age-keys/$TIMESTAMP-*${NC}"
echo -e "${GREEN}✓ Active key: s3://$BUCKET_NAME/age-keys/ACTIVE-*${NC}"
echo -e "${GREEN}✓ Files:${NC}"
echo -e "${GREEN}  - $TIMESTAMP-age-key-encrypted.txt (timestamped backup)${NC}"
echo -e "${GREEN}  - $TIMESTAMP-recovery-key.txt (timestamped backup)${NC}"
echo -e "${GREEN}  - ACTIVE-age-key-encrypted.txt (current active key)${NC}"
echo -e "${GREEN}  - ACTIVE-recovery-key.txt (current active recovery)${NC}"
echo ""
echo -e "${YELLOW}CRITICAL: Store recovery key securely offline${NC}"
echo -e "${YELLOW}Recovery public key: $RECOVERY_PUBLIC${NC}"
echo ""
echo -e "${BLUE}To recover Age key (using active markers):${NC}"
echo -e "  1. Download: ${GREEN}aws s3 cp s3://$BUCKET_NAME/age-keys/ACTIVE-recovery-key.txt recovery.key --endpoint-url $S3_ENDPOINT${NC}"
echo -e "  2. Download: ${GREEN}aws s3 cp s3://$BUCKET_NAME/age-keys/ACTIVE-age-key-encrypted.txt encrypted.txt --endpoint-url $S3_ENDPOINT${NC}"
echo -e "  3. Decrypt: ${GREEN}age -d -i recovery.key encrypted.txt${NC}"
echo ""

