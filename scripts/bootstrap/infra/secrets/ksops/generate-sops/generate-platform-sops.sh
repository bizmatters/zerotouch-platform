#!/bin/bash
# Master script to generate all platform secrets
# cd zerotouch-platform && set -a && source .env && set +a && ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

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

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}✗ Error: $ENV_FILE not found${NC}"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ Error: sops not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Repository: $REPO_ROOT${NC}"
echo -e "${GREEN}✓ Reading from: $ENV_FILE${NC}"
echo ""

"$SCRIPT_DIR/generate-env-secrets.sh"
"$SCRIPT_DIR/generate-tenant-registry-secrets.sh"
"$SCRIPT_DIR/generate-core-secrets.sh"

echo -e "${GREEN}✅ Platform secrets generated${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Review: ${GREEN}ls -la $REPO_ROOT/bootstrap/argocd/overlays/main/*/secrets/${NC}"
echo -e "  2. Commit: ${GREEN}git add bootstrap/ && git commit -m 'chore: add platform secrets'${NC}"
echo -e "  3. Push: ${GREEN}git push${NC}"

exit 0
