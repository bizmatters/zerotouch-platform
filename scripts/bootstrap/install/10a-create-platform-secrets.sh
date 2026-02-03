#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/logging.sh"

echo -e "${BLUE}Creating platform secrets from .env...${NC}"

# Load .env file
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    exit 1
fi

# Source .env
set -a
source "$ENV_FILE"
set +a

# Create external-dns-hetzner secret
if [[ -n "${HETZNER_DNS_TOKEN:-}" ]]; then
    echo -e "${BLUE}Creating external-dns-hetzner secret...${NC}"
    kubectl create secret generic external-dns-hetzner \
        -n kube-system \
        --from-literal=HETZNER_DNS_TOKEN="$HETZNER_DNS_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✓ external-dns-hetzner secret created${NC}"
else
    echo -e "${YELLOW}⚠ HETZNER_DNS_TOKEN not found in .env, skipping external-dns-hetzner secret${NC}"
fi

# Create hcloud secret
if [[ -n "${HETZNER_API_TOKEN:-}" ]]; then
    echo -e "${BLUE}Creating hcloud secret...${NC}"
    kubectl create secret generic hcloud \
        -n kube-system \
        --from-literal=token="$HETZNER_API_TOKEN" \
        --from-literal=network="bizmatters-dev-network" \
        --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✓ hcloud secret created${NC}"
else
    echo -e "${YELLOW}⚠ HETZNER_API_TOKEN not found in .env, skipping hcloud secret${NC}"
fi

echo -e "${GREEN}✓ Platform secrets created successfully${NC}"
