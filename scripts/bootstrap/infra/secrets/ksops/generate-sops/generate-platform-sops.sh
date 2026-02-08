#!/bin/bash
# Master script to generate all platform secrets
# Usage: ENV=dev ./generate-platform-sops.sh
# cd zerotouch-platform && set -a && source .env.local && set +a && ENV=dev ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.local"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Generate Platform Secrets (KSOPS)                         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Validate ENV is set
if [ -z "${ENV:-}" ]; then
    echo -e "${RED}✗ Error: ENV environment variable not set${NC}"
    echo -e "${YELLOW}Usage: ENV=dev $0${NC}"
    echo -e "${YELLOW}Valid values: pr, dev, staging, prod${NC}"
    exit 1
fi

ENV_UPPER=$(echo "$ENV" | tr '[:lower:]' '[:upper:]')
echo -e "${GREEN}✓ Environment: $ENV_UPPER${NC}"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

# Determine overlay directory
if [[ "$ENV" == "pr" ]]; then
    OVERLAY_DIR="$REPO_ROOT/bootstrap/argocd/overlays/preview"
else
    OVERLAY_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main/$ENV"
fi

# Verify .sops.yaml exists in overlay
SOPS_YAML="$OVERLAY_DIR/.sops.yaml"
if [ ! -f "$SOPS_YAML" ]; then
    echo -e "${RED}✗ Error: .sops.yaml not found at $SOPS_YAML${NC}"
    echo -e "${YELLOW}Run: ENV=$ENV source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}✓ Reading from: $ENV_FILE${NC}"
echo -e "${GREEN}✓ SOPS config: $SOPS_YAML${NC}"
echo -e "${GREEN}✓ Output: $OVERLAY_DIR/secrets/${NC}"
echo ""

# Clean up old secrets
SECRETS_DIR="$OVERLAY_DIR/secrets"
if [ -d "$SECRETS_DIR" ]; then
    echo -e "${YELLOW}Cleaning up old secrets...${NC}"
    rm -f "$SECRETS_DIR"/*.secret.yaml
    echo -e "${GREEN}✓ Old secrets removed${NC}"
    echo ""
fi

# Export ENV and SOPS config for sub-scripts
export ENV
export SOPS_CONFIG="$SOPS_YAML"

"$SCRIPT_DIR/generate-env-secrets.sh"
"$SCRIPT_DIR/generate-tenant-registry-secrets.sh"
"$SCRIPT_DIR/generate-core-secrets.sh"

echo -e "${GREEN}✅ Platform secrets generated for $ENV_UPPER${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review: ${GREEN}ls -la $OVERLAY_DIR/secrets/${NC}"
echo -e "  2. Commit: ${GREEN}git add bootstrap/ && git commit -m 'chore: update $ENV secrets'${NC}"
echo -e "  3. Push: ${GREEN}git push${NC}"

exit 0
