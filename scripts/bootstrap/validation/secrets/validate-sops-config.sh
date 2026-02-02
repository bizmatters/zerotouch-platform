#!/bin/bash
# SOPS Configuration Validation Script
# Usage: ./validate-sops-config.sh
#
# This script validates SOPS configuration for the platform repository

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   SOPS Configuration Validation                              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

cd "$REPO_ROOT"

# Check if .sops.yaml exists
if [[ ! -f "$REPO_ROOT/.sops.yaml" ]]; then
    echo -e "${RED}✗ Error: .sops.yaml not found in repository${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found .sops.yaml in repository${NC}"

# Validate YAML format
if ! python3 -c "import yaml; yaml.safe_load(open('.sops.yaml'))" 2>/dev/null; then
    echo -e "${RED}✗ Error: Invalid YAML format in .sops.yaml${NC}"
    exit 1
fi

echo -e "${GREEN}✓ .sops.yaml format valid${NC}"

# Test encryption
cat > test-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
type: Opaque
stringData:
  test: value
EOF

if sops -e -i test-secret.yaml 2>/dev/null; then
    echo -e "${GREEN}✓ SOPS encryption successful with repository config${NC}"
    rm -f test-secret.yaml
else
    echo -e "${RED}✗ Error: SOPS encryption failed${NC}"
    rm -f test-secret.yaml
    exit 1
fi

echo -e "${GREEN}✓ SOPS configuration validation complete${NC}"
exit 0
