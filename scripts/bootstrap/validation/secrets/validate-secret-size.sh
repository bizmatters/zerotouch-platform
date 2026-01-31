#!/bin/bash
# Secret Size Validation Script
# Usage: ./validate-secret-size.sh <secret-file> [--template-vars <vars-file>]
#
# This script validates that secret files won't exceed Kubernetes size limits

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Size thresholds (in KB)
ERROR_THRESHOLD=900
WARNING_THRESHOLD=700

# Template expansion estimates (in bytes)
PASSWORD_SIZE=64
URL_SIZE=256
CERT_SIZE=4096

# Parse arguments
if [ "$#" -lt 1 ]; then
    echo -e "${RED}Usage:${NC} $0 <secret-file> [--template-vars <vars-file>]"
    echo ""
    echo "Arguments:"
    echo "  <secret-file>           Path to secret YAML file"
    echo "  --template-vars <file>  Optional template variables file"
    exit 1
fi

SECRET_FILE="$1"
TEMPLATE_VARS=""

shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --template-vars)
            TEMPLATE_VARS="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Secret Size Validation                                     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if secret file exists
if [ ! -f "$SECRET_FILE" ]; then
    echo -e "${RED}✗ Error: Secret file not found: $SECRET_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Secret file found: $SECRET_FILE${NC}"
echo ""

# Calculate base YAML size
BASE_SIZE=$(wc -c < "$SECRET_FILE")
BASE_SIZE_KB=$((BASE_SIZE / 1024))

echo -e "${BLUE}Base YAML size: ${BASE_SIZE_KB}KB (${BASE_SIZE} bytes)${NC}"

# Add SOPS metadata overhead
SOPS_OVERHEAD=2048
TOTAL_SIZE=$((BASE_SIZE + SOPS_OVERHEAD))
TOTAL_SIZE_KB=$((TOTAL_SIZE / 1024))

echo -e "${BLUE}SOPS metadata overhead: +2KB${NC}"
echo -e "${BLUE}Size with SOPS: ${TOTAL_SIZE_KB}KB${NC}"
echo ""

# Identify template placeholders
TEMPLATE_COUNT=$(grep -o '\${[A-Z_]*}' "$SECRET_FILE" | wc -l | tr -d ' ')

if [ "$TEMPLATE_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Found $TEMPLATE_COUNT template placeholders${NC}"
    
    # Estimate template expansion
    PASSWORD_COUNT=$(grep -o '\${[A-Z_]*PASSWORD[A-Z_]*}' "$SECRET_FILE" | wc -l | tr -d ' ')
    URL_COUNT=$(grep -o '\${[A-Z_]*URL[A-Z_]*}' "$SECRET_FILE" | wc -l | tr -d ' ')
    CERT_COUNT=$(grep -o '\${[A-Z_]*CERT[A-Z_]*}' "$SECRET_FILE" | wc -l | tr -d ' ')
    OTHER_COUNT=$((TEMPLATE_COUNT - PASSWORD_COUNT - URL_COUNT - CERT_COUNT))
    
    EXPANSION_SIZE=0
    EXPANSION_SIZE=$((EXPANSION_SIZE + PASSWORD_COUNT * PASSWORD_SIZE))
    EXPANSION_SIZE=$((EXPANSION_SIZE + URL_COUNT * URL_SIZE))
    EXPANSION_SIZE=$((EXPANSION_SIZE + CERT_COUNT * CERT_SIZE))
    EXPANSION_SIZE=$((EXPANSION_SIZE + OTHER_COUNT * PASSWORD_SIZE))
    
    EXPANSION_SIZE_KB=$((EXPANSION_SIZE / 1024))
    
    echo -e "${BLUE}  - Passwords: $PASSWORD_COUNT × ${PASSWORD_SIZE}B = $((PASSWORD_COUNT * PASSWORD_SIZE))B${NC}"
    echo -e "${BLUE}  - URLs: $URL_COUNT × ${URL_SIZE}B = $((URL_COUNT * URL_SIZE))B${NC}"
    echo -e "${BLUE}  - Certificates: $CERT_COUNT × ${CERT_SIZE}B = $((CERT_COUNT * CERT_SIZE))B${NC}"
    echo -e "${BLUE}  - Other: $OTHER_COUNT × ${PASSWORD_SIZE}B = $((OTHER_COUNT * PASSWORD_SIZE))B${NC}"
    echo -e "${BLUE}Estimated expansion: +${EXPANSION_SIZE_KB}KB${NC}"
    
    TOTAL_SIZE=$((TOTAL_SIZE + EXPANSION_SIZE))
    TOTAL_SIZE_KB=$((TOTAL_SIZE / 1024))
fi

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Size Breakdown                                             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Base YAML:           ${BASE_SIZE_KB}KB${NC}"
echo -e "${BLUE}SOPS overhead:       2KB${NC}"
if [ "$TEMPLATE_COUNT" -gt 0 ]; then
    echo -e "${BLUE}Template expansion:  ${EXPANSION_SIZE_KB}KB${NC}"
fi
echo -e "${BLUE}─────────────────────────────────${NC}"
echo -e "${BLUE}Total estimated:     ${TOTAL_SIZE_KB}KB${NC}"
echo ""

# Compare to thresholds
if [ $TOTAL_SIZE_KB -gt $ERROR_THRESHOLD ]; then
    echo -e "${RED}✗ FAIL: Secret size exceeds ${ERROR_THRESHOLD}KB threshold${NC}"
    echo -e "${RED}  Kubernetes secrets have a 1MB limit${NC}"
    echo -e "${RED}  Current size: ${TOTAL_SIZE_KB}KB${NC}"
    echo ""
    echo -e "${YELLOW}Recommendations:${NC}"
    echo -e "  - Split secret into multiple smaller secrets"
    echo -e "  - Store large files (certificates) in ConfigMaps"
    echo -e "  - Use external secret stores for large data"
    echo ""
    exit 1
elif [ $TOTAL_SIZE_KB -gt $WARNING_THRESHOLD ]; then
    echo -e "${YELLOW}⚠️  WARNING: Secret size exceeds ${WARNING_THRESHOLD}KB threshold${NC}"
    echo -e "${YELLOW}  Current size: ${TOTAL_SIZE_KB}KB${NC}"
    echo -e "${YELLOW}  Consider splitting if it grows larger${NC}"
    echo ""
else
    echo -e "${GREEN}✓ PASS: Secret size within acceptable limits${NC}"
    echo -e "${GREEN}  Current size: ${TOTAL_SIZE_KB}KB${NC}"
    echo ""
fi

echo -e "${BLUE}Pre-commit hook integration:${NC}"
echo -e "  Add to .git/hooks/pre-commit:"
echo -e "  ${GREEN}#!/bin/bash${NC}"
echo -e "  ${GREEN}for file in \$(git diff --cached --name-only | grep 'secrets/.*\\.yaml'); do${NC}"
echo -e "  ${GREEN}  ./scripts/bootstrap/validation/secrets/validate-secret-size.sh \"\$file\" || exit 1${NC}"
echo -e "  ${GREEN}done${NC}"
echo ""

exit 0
