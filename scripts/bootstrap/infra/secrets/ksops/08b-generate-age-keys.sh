#!/bin/bash
# Bootstrap script to generate Age keypair for SOPS encryption
# Usage: ENV=dev ./generate-age-keys.sh
#
# This script checks S3 first for existing Age key, generates new if not found

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPERS_DIR="$SCRIPT_DIR/../../../helpers"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Age Keypair Generation for SOPS Encryption                ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Validate ENV is set
if [ -z "${ENV:-}" ]; then
    echo -e "${RED}✗ Error: ENV environment variable not set${NC}"
    echo -e "${YELLOW}Usage: ENV=dev $0${NC}"
    exit 1
fi

ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
echo -e "${GREEN}✓ Environment: $ENV_UPPER${NC}"
echo ""

# Check if age-keygen is installed
if ! command -v age-keygen &> /dev/null; then
    echo -e "${RED}✗ Error: age-keygen not found${NC}"
    echo -e "${YELLOW}Install age: https://github.com/FiloSottile/age${NC}"
    echo ""
    echo -e "${YELLOW}Installation options:${NC}"
    echo -e "  macOS:   ${GREEN}brew install age${NC}"
    echo -e "  Linux:   ${GREEN}apt-get install age${NC} or ${GREEN}yum install age${NC}"
    exit 1
fi

echo -e "${GREEN}✓ age-keygen found${NC}"
echo ""

# Source S3 helpers
if [ ! -f "$HELPERS_DIR/s3-helpers.sh" ]; then
    echo -e "${RED}✗ Error: s3-helpers.sh not found${NC}"
    exit 1
fi

source "$HELPERS_DIR/s3-helpers.sh"

# Configure S3 credentials
echo -e "${BLUE}Configuring S3 credentials...${NC}"
if ! configure_s3_credentials "$ENV"; then
    echo -e "${RED}✗ Error: Failed to configure S3 credentials${NC}"
    echo -e "${YELLOW}Required variables: ${ENV_UPPER}_HETZNER_S3_*${NC}"
    exit 1
fi
echo -e "${GREEN}✓ S3 credentials configured${NC}"
echo ""

# Check if Age key exists in S3
echo -e "${BLUE}Checking S3 for existing Age key...${NC}"
if s3_age_key_exists; then
    echo -e "${YELLOW}⚠ Existing Age key found in S3${NC}"
    echo -e "${BLUE}Retrieving existing Age key to maintain secret decryption...${NC}"
    
    # Retrieve Age key from S3
    if ! AGE_PRIVATE_KEY=$(s3_retrieve_age_key); then
        echo -e "${RED}✗ Error: Failed to retrieve Age key from S3${NC}"
        exit 1
    fi
    
    # Trim whitespace
    AGE_PRIVATE_KEY=$(echo "$AGE_PRIVATE_KEY" | tr -d '[:space:]' | grep -o 'AGE-SECRET-KEY-1[A-Z0-9]*')
    
    if [[ ! "$AGE_PRIVATE_KEY" =~ ^AGE-SECRET-KEY-1 ]]; then
        echo -e "${RED}✗ Error: Invalid Age private key format from S3${NC}"
        exit 1
    fi
    
    # Derive public key from private key
    AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y 2>/dev/null)
    
    if [ -z "$AGE_PUBLIC_KEY" ]; then
        echo -e "${RED}✗ Error: Failed to derive public key from existing private key${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Existing Age key retrieved from S3${NC}"
    echo ""
    KEY_SOURCE="s3"
else
    echo -e "${BLUE}No existing Age key in S3, generating new keypair...${NC}"
    KEY_SOURCE="generated"

    # Generate keypair and capture output
    KEYGEN_OUTPUT=$(age-keygen 2>&1)

    # Extract public key (format: # public key: age1...)
    AGE_PUBLIC_KEY=$(echo "$KEYGEN_OUTPUT" | grep "# public key:" | sed 's/# public key: //')

    # Extract private key (format: AGE-SECRET-KEY-1...)
    AGE_PRIVATE_KEY=$(echo "$KEYGEN_OUTPUT" | grep "^AGE-SECRET-KEY-1" | head -n 1)

    # Validate keys were generated
    if [ -z "$AGE_PUBLIC_KEY" ]; then
        echo -e "${RED}✗ Error: Failed to generate public key${NC}"
        exit 1
    fi

    if [ -z "$AGE_PRIVATE_KEY" ]; then
        echo -e "${RED}✗ Error: Failed to generate private key${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Age keypair generated successfully${NC}"
    echo ""
    
    # Auto-backup to S3
    echo -e "${BLUE}Backing up new Age key to S3...${NC}"
    
    # Generate recovery master key
    RECOVERY_KEY=$(age-keygen 2>/dev/null)
    RECOVERY_PUBLIC=$(echo "$RECOVERY_KEY" | grep "public key:" | cut -d: -f2 | xargs)
    RECOVERY_PRIVATE=$(echo "$RECOVERY_KEY" | grep "AGE-SECRET-KEY-" | xargs)
    
    # Use centralized S3 backup function
    if ! s3_backup_age_key "$AGE_PRIVATE_KEY" "$RECOVERY_PRIVATE" "$RECOVERY_PUBLIC"; then
        echo -e "${RED}✗ Failed to backup Age key to S3${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Age key backed up to S3${NC}"
    echo -e "${YELLOW}CRITICAL: Store recovery key securely offline${NC}"
    echo -e "${YELLOW}Recovery public key: $RECOVERY_PUBLIC${NC}"
    echo ""
fi

# Export keys to environment variables
export AGE_PUBLIC_KEY
export AGE_PRIVATE_KEY

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Generated Keys                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Public Key:${NC}"
echo -e "  $AGE_PUBLIC_KEY"
echo ""
echo -e "${GREEN}Private Key:${NC}"
echo -e "  $AGE_PRIVATE_KEY"
echo ""

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Environment Variables                                      ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ AGE_PUBLIC_KEY exported${NC}"
echo -e "${GREEN}✓ AGE_PRIVATE_KEY exported${NC}"
echo ""

# Determine overlay path based on environment
if [[ "$ENV" == "pr" ]]; then
    OVERLAY_DIR="$SCRIPT_DIR/../../../../../bootstrap/argocd/overlays/preview"
else
    OVERLAY_DIR="$SCRIPT_DIR/../../../../../bootstrap/argocd/overlays/main/$ENV"
fi

SOPS_YAML_PATH="$OVERLAY_DIR/.sops.yaml"

echo -e "${BLUE}Updating environment-specific .sops.yaml...${NC}"
echo -e "${BLUE}Path: $SOPS_YAML_PATH${NC}"

# Create overlay directory if it doesn't exist
mkdir -p "$OVERLAY_DIR"

# Create or update .sops.yaml
if [ -f "$SOPS_YAML_PATH" ]; then
    # Check if public key already matches
    if grep -q "$AGE_PUBLIC_KEY" "$SOPS_YAML_PATH"; then
        echo -e "${GREEN}✓ .sops.yaml already contains current public key${NC}"
    else
        # Update the age key in .sops.yaml
        sed -i.bak "s/age: age1[a-z0-9]*/age: $AGE_PUBLIC_KEY/" "$SOPS_YAML_PATH"
        rm -f "$SOPS_YAML_PATH.bak"
        echo -e "${GREEN}✓ .sops.yaml updated with public key${NC}"
    fi
else
    # Create new .sops.yaml
    cat > "$SOPS_YAML_PATH" <<EOF
creation_rules:
  - path_regex: .*\.yaml$
    age: $AGE_PUBLIC_KEY
    encrypted_regex: '^(data|stringData)'
EOF
    echo -e "${GREEN}✓ .sops.yaml created with public key${NC}"
fi
echo ""

# Update environment-specific .sops.yaml with current public key (only for newly generated keys)
if [ "${KEY_SOURCE:-}" = "generated" ]; then
    echo -e "${YELLOW}⚠ IMPORTANT: Re-encrypt all secrets for $ENV_UPPER environment:${NC}"
    echo -e "  ${GREEN}ENV=$ENV ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh${NC}"
    echo ""
fi

echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Run inject-age-key.sh to create Kubernetes secret"
echo -e "  2. Configure .sops.yaml with the public key"
echo -e "  3. Store private key securely (backup)"
echo ""
echo -e "${YELLOW}Usage in subsequent scripts:${NC}"
echo -e "  ${GREEN}source ./generate-age-keys.sh${NC}"
echo -e "  ${GREEN}echo \$AGE_PUBLIC_KEY${NC}"
echo -e "  ${GREEN}echo \$AGE_PRIVATE_KEY${NC}"
echo ""

# Note: No exit statement - this script is meant to be sourced to preserve environment variables
