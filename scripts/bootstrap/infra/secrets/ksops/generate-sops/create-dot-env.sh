#!/bin/bash
# Create .env file from encrypted secrets in Git
# Usage: ENV=pr ./create-dot-env.sh
#
# This script:
# 1. Retrieves Age key from S3
# 2. Decrypts all secrets from bootstrap/argocd/overlays/main/{env}/secrets/
# 3. Generates .env file with {ENV}_* prefixed variables
# 4. Fails if Age key not in S3 (no generation fallback)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Create .env from Encrypted Secrets                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Validate ENV is set
if [ -z "${ENV:-}" ]; then
    echo -e "${RED}✗ Error: ENV environment variable not set${NC}"
    echo -e "${YELLOW}Usage: ENV=pr $0${NC}"
    echo -e "${YELLOW}Valid values: pr, dev, staging, production${NC}"
    exit 1
fi

# Normalize environment name
case "$ENV" in
    pr|PR) ENV="pr"; ENV_UPPER="PR" ;;
    dev|DEV) ENV="dev"; ENV_UPPER="DEV" ;;
    staging|STAGING) ENV="staging"; ENV_UPPER="STAGING" ;;
    prod|production|PROD|PRODUCTION) ENV="prod"; ENV_UPPER="PROD" ;;
    *)
        echo -e "${RED}✗ Error: Invalid ENV value: $ENV${NC}"
        echo -e "${YELLOW}Valid values: pr, dev, staging, production${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}✓ Environment: $ENV_UPPER${NC}"
echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo ""

# Check required tools
for tool in age sops aws; do
    if ! command -v $tool &> /dev/null; then
        echo -e "${RED}✗ Error: $tool not found${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓ Required tools installed${NC}"
echo ""

# Source S3 helpers
HELPERS_DIR="$SCRIPT_DIR/../../helpers"
if [ ! -f "$HELPERS_DIR/s3-helpers.sh" ]; then
    echo -e "${RED}✗ Error: s3-helpers.sh not found${NC}"
    exit 1
fi

source "$HELPERS_DIR/s3-helpers.sh"

# Step 1: Configure S3 and retrieve Age key
echo -e "${BLUE}[1/4] Configuring S3 and retrieving Age key...${NC}"

if ! configure_s3_credentials "$ENV"; then
    echo -e "${RED}✗ Failed to configure S3 credentials${NC}"
    echo -e "${YELLOW}Required variables: ${ENV_UPPER}_HETZNER_S3_*${NC}"
    exit 1
fi

if ! AGE_PRIVATE_KEY=$(s3_retrieve_age_key); then
    echo -e "${RED}✗ Failed to retrieve Age key from S3${NC}"
    echo -e "${YELLOW}Run manual setup first:${NC}"
    echo -e "  1. ENV=$ENV source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh"
    echo -e "  2. ENV=$ENV ./scripts/bootstrap/infra/secrets/ksops/08b-backup-age-to-s3.sh"
    exit 1
fi

echo -e "${GREEN}✓ Age key retrieved from S3${NC}"
echo ""

# Step 2: Derive public key
echo -e "${BLUE}[2/4] Deriving public key...${NC}"

if ! AGE_PUBLIC_KEY=$(echo "$AGE_PRIVATE_KEY" | age-keygen -y 2>&1); then
    echo -e "${RED}✗ Failed to derive public key${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Age key decrypted${NC}"
echo ""

# Step 3: Validate against .sops.yaml
echo -e "${BLUE}[3/4] Validating Age key...${NC}"

SOPS_YAML="$REPO_ROOT/.sops.yaml"
if [ ! -f "$SOPS_YAML" ]; then
    echo -e "${RED}✗ .sops.yaml not found${NC}"
    exit 1
fi

EXPECTED_PUBLIC_KEY=$(grep "age:" "$SOPS_YAML" | sed -E 's/.*age:[[:space:]]*(age1[a-z0-9]+).*/\1/' | head -1)

if [ "$AGE_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]; then
    echo -e "${RED}✗ Age key mismatch${NC}"
    echo -e "${RED}Expected: $EXPECTED_PUBLIC_KEY${NC}"
    echo -e "${RED}Got: $AGE_PUBLIC_KEY${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Age key matches .sops.yaml${NC}"
echo ""

# Step 4: Decrypt secrets and generate .env
echo -e "${BLUE}[4/4] Decrypting secrets and generating .env...${NC}"

SECRETS_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main/$ENV/secrets"

if [ ! -d "$SECRETS_DIR" ]; then
    echo -e "${RED}✗ Secrets directory not found: $SECRETS_DIR${NC}"
    echo -e "${YELLOW}Run manual setup first:${NC}"
    echo -e "  ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh"
    exit 1
fi

export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"

ENV_FILE="$REPO_ROOT/.env"
> "$ENV_FILE"  # Clear file

SECRET_COUNT=0

# Process each encrypted secret file
while IFS= read -r secret_file; do
    # Decrypt secret
    if ! decrypted=$(sops -d "$secret_file" 2>&1); then
        echo -e "${YELLOW}⚠ Failed to decrypt: $(basename "$secret_file")${NC}"
        continue
    fi
    
    # Extract secret name and data
    secret_name=$(echo "$decrypted" | grep "name:" | head -1 | sed 's/.*name: *//')
    
    # Extract all stringData keys and values
    in_string_data=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^stringData: ]]; then
            in_string_data=true
            continue
        fi
        
        if [[ "$in_string_data" == true ]]; then
            # Stop if we hit another top-level key
            if [[ "$line" =~ ^[a-zA-Z] ]]; then
                break
            fi
            
            # Extract key: value pairs
            if [[ "$line" =~ ^[[:space:]]+([^:]+):[[:space:]]*(.+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                
                # Remove quotes if present
                value="${value#\"}"
                value="${value%\"}"
                
                # Convert secret name to env var format
                env_var_name=$(echo "$secret_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                
                # If key is not "value", append it to var name
                if [ "$key" != "value" ]; then
                    key_upper=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
                    env_var_name="${env_var_name}_${key_upper}"
                fi
                
                # Write to .env with environment prefix
                echo "${ENV_UPPER}_${env_var_name}=${value}" >> "$ENV_FILE"
                ((SECRET_COUNT++))
            fi
        fi
    done <<< "$decrypted"
    
done < <(find "$SECRETS_DIR" -name "*.secret.yaml" -type f)

if [ $SECRET_COUNT -eq 0 ]; then
    echo -e "${RED}✗ No secrets decrypted${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Decrypted $SECRET_COUNT secret values${NC}"
echo -e "${GREEN}✓ Generated: $ENV_FILE${NC}"
echo ""

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Summary                                                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}✓ Age key retrieved from S3${NC}"
echo -e "${GREEN}✓ Age key validated against .sops.yaml${NC}"
echo -e "${GREEN}✓ $SECRET_COUNT secrets decrypted${NC}"
echo -e "${GREEN}✓ .env file created with ${ENV_UPPER}_* prefixed variables${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Source .env: ${GREEN}set -a && source .env && set +a${NC}"
echo -e "  2. Run bootstrap: ${GREEN}./scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh${NC}"
echo ""

exit 0
