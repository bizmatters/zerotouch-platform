#!/bin/bash
# Find Orphaned GitHub Secrets
# Usage: ./find-orphaned-secrets.sh
#
# This script identifies GitHub Secrets that don't have corresponding YAML keys in tenant files.
# It lists all GitHub Secrets matching pattern {ENVIRONMENT}_{SECRET_NAME} and searches for
# corresponding YAML keys in tenant files. Secrets without matches are marked as orphaned.
#
# Safety measures:
# - Never auto-deletes secrets
# - Preserves secrets used within 30 days
# - Requires manual review and deletion

set -euo pipefail

# Configuration
TENANT_REPO_PATH="${TENANT_REPO_PATH:-../zerotouch-tenants}"
GITHUB_ORG="${GITHUB_ORG:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
PRESERVE_DAYS=30

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

Find GitHub Secrets that don't have corresponding YAML keys in tenant files.

OPTIONS:
    -o, --org ORG           GitHub organization name (required)
    -r, --repo REPO         GitHub repository name (required)
    -t, --token TOKEN       GitHub token with repo:read permissions (required)
    -p, --path PATH         Path to zerotouch-tenants repository (default: ../zerotouch-tenants)
    -d, --preserve-days N   Preserve secrets used within N days (default: 30)
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_ORG              GitHub organization name
    GITHUB_REPO             GitHub repository name
    GITHUB_TOKEN            GitHub token with repo:read permissions
    TENANT_REPO_PATH        Path to zerotouch-tenants repository

EXAMPLES:
    # Using command-line arguments
    $0 --org myorg --repo myrepo --token ghp_xxx

    # Using environment variables
    export GITHUB_ORG=myorg
    export GITHUB_REPO=myrepo
    export GITHUB_TOKEN=ghp_xxx
    $0

SAFETY MEASURES:
    - Never auto-deletes secrets
    - Preserves secrets used within ${PRESERVE_DAYS} days
    - Requires manual review and deletion

OUTPUT:
    Lists orphaned secrets with:
    - Secret name
    - Last updated timestamp
    - Recommendation (SAFE_TO_DELETE or PRESERVE)

MANUAL DELETION:
    To delete an orphaned secret:
    gh secret delete SECRET_NAME --repo OWNER/REPO

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--org)
            GITHUB_ORG="$2"
            shift 2
            ;;
        -r|--repo)
            GITHUB_REPO="$2"
            shift 2
            ;;
        -t|--token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        -p|--path)
            TENANT_REPO_PATH="$2"
            shift 2
            ;;
        -d|--preserve-days)
            PRESERVE_DAYS="$2"
            shift 2
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

# Validate required parameters
if [[ -z "$GITHUB_ORG" ]]; then
    echo -e "${RED}❌ GitHub organization is required${NC}"
    echo "   Set GITHUB_ORG environment variable or use --org flag"
    exit 1
fi

if [[ -z "$GITHUB_REPO" ]]; then
    echo -e "${RED}❌ GitHub repository is required${NC}"
    echo "   Set GITHUB_REPO environment variable or use --repo flag"
    exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo -e "${RED}❌ GitHub token is required${NC}"
    echo "   Set GITHUB_TOKEN environment variable or use --token flag"
    exit 1
fi

# Validate tenant repository path
if [[ ! -d "$TENANT_REPO_PATH" ]]; then
    echo -e "${RED}❌ Tenant repository not found: $TENANT_REPO_PATH${NC}"
    exit 1
fi

# Validate gh CLI is available
if ! command -v gh &> /dev/null; then
    echo -e "${RED}❌ GitHub CLI (gh) not found. Please install: https://cli.github.com/${NC}"
    exit 1
fi

# Validate jq is available
if ! command -v jq &> /dev/null; then
    echo -e "${RED}❌ jq not found. Please install jq for JSON processing${NC}"
    exit 1
fi

echo -e "${BLUE}🔍 Finding orphaned GitHub Secrets...${NC}"
echo ""
echo "Configuration:"
echo "  Organization: $GITHUB_ORG"
echo "  Repository: $GITHUB_REPO"
echo "  Tenant Path: $TENANT_REPO_PATH"
echo "  Preserve Days: $PRESERVE_DAYS"
echo ""

# Authenticate gh CLI
export GH_TOKEN="$GITHUB_TOKEN"

# List all GitHub Secrets
echo -e "${BLUE}📋 Fetching GitHub Secrets...${NC}"
SECRETS_JSON=$(gh api "/repos/$GITHUB_ORG/$GITHUB_REPO/actions/secrets" --jq '.secrets')

if [[ -z "$SECRETS_JSON" || "$SECRETS_JSON" == "null" ]]; then
    echo -e "${YELLOW}⚠️  No secrets found in repository${NC}"
    exit 0
fi

# Extract secret names and updated_at timestamps
SECRET_COUNT=$(echo "$SECRETS_JSON" | jq 'length')
echo -e "${GREEN}   Found $SECRET_COUNT secrets${NC}"
echo ""

# Arrays to store results
declare -a ORPHANED_SECRETS=()
declare -a ORPHANED_TIMESTAMPS=()
declare -a MATCHED_SECRETS=()

# Calculate cutoff date for preservation
CUTOFF_DATE=$(date -u -d "$PRESERVE_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-${PRESERVE_DAYS}d +%Y-%m-%dT%H:%M:%SZ)

echo -e "${BLUE}🔎 Analyzing secrets...${NC}"

# Process each secret
for i in $(seq 0 $((SECRET_COUNT - 1))); do
    SECRET_NAME=$(echo "$SECRETS_JSON" | jq -r ".[$i].name")
    UPDATED_AT=$(echo "$SECRETS_JSON" | jq -r ".[$i].updated_at")
    
    # Check if secret matches pattern {ENVIRONMENT}_{SECRET_NAME}
    if [[ ! "$SECRET_NAME" =~ ^(DEV|STAGING|PRODUCTION)_ ]]; then
        echo -e "${YELLOW}   ⏭️  Skipping $SECRET_NAME (doesn't match environment pattern)${NC}"
        continue
    fi
    
    # Extract environment and key name
    if [[ "$SECRET_NAME" =~ ^([A-Z]+)_(.+)$ ]]; then
        ENV="${BASH_REMATCH[1]}"
        KEY_NAME="${BASH_REMATCH[2]}"
    else
        echo -e "${YELLOW}   ⚠️  Cannot parse $SECRET_NAME${NC}"
        continue
    fi
    
    # Convert key name to lowercase for YAML search (following normalization pattern)
    YAML_KEY=$(echo "$KEY_NAME" | tr '[:upper:]' '[:lower:]')
    
    echo -e "   Checking: ${SECRET_NAME} (${ENV}/${YAML_KEY})"
    
    # Search for YAML key in tenant files
    # Look in both base/secrets/ and overlays/{env}/secrets/ directories
    ENV_LOWER=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')
    
    FOUND=false
    
    # Search in base secrets
    if grep -r "^[[:space:]]*${YAML_KEY}:" "$TENANT_REPO_PATH/tenants/"*/base/secrets/*.yaml 2>/dev/null | grep -q .; then
        FOUND=true
    fi
    
    # Search in environment-specific secrets
    if grep -r "^[[:space:]]*${YAML_KEY}:" "$TENANT_REPO_PATH/tenants/"*/overlays/"${ENV_LOWER}"/secrets/*.yaml 2>/dev/null | grep -q .; then
        FOUND=true
    fi
    
    # Also search in stringData section
    if grep -r "^[[:space:]]*${YAML_KEY}:" "$TENANT_REPO_PATH/tenants/"*/base/secrets/*.yaml 2>/dev/null | grep -q .; then
        FOUND=true
    fi
    
    if grep -r "^[[:space:]]*${YAML_KEY}:" "$TENANT_REPO_PATH/tenants/"*/overlays/"${ENV_LOWER}"/secrets/*.yaml 2>/dev/null | grep -q .; then
        FOUND=true
    fi
    
    if [[ "$FOUND" == true ]]; then
        MATCHED_SECRETS+=("$SECRET_NAME")
        echo -e "      ${GREEN}✓ Found in tenant files${NC}"
    else
        ORPHANED_SECRETS+=("$SECRET_NAME")
        ORPHANED_TIMESTAMPS+=("$UPDATED_AT")
        echo -e "      ${RED}✗ Not found in tenant files (orphaned)${NC}"
    fi
done

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📊 Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Total Secrets: $SECRET_COUNT"
echo "Matched: ${#MATCHED_SECRETS[@]}"
echo "Orphaned: ${#ORPHANED_SECRETS[@]}"
echo ""

if [[ ${#ORPHANED_SECRETS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No orphaned secrets found${NC}"
    exit 0
fi

echo -e "${YELLOW}⚠️  Orphaned Secrets Found:${NC}"
echo ""
printf "%-40s %-30s %-20s\n" "SECRET NAME" "LAST UPDATED" "RECOMMENDATION"
printf "%-40s %-30s %-20s\n" "$(printf '%.0s-' {1..40})" "$(printf '%.0s-' {1..30})" "$(printf '%.0s-' {1..20})"

for i in "${!ORPHANED_SECRETS[@]}"; do
    SECRET_NAME="${ORPHANED_SECRETS[$i]}"
    UPDATED_AT="${ORPHANED_TIMESTAMPS[$i]}"
    
    # Determine if secret should be preserved based on last updated date
    if [[ "$UPDATED_AT" > "$CUTOFF_DATE" ]]; then
        RECOMMENDATION="${YELLOW}PRESERVE (< ${PRESERVE_DAYS} days)${NC}"
    else
        RECOMMENDATION="${RED}SAFE_TO_DELETE${NC}"
    fi
    
    printf "%-40s %-30s %-20b\n" "$SECRET_NAME" "$UPDATED_AT" "$RECOMMENDATION"
done

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  Manual Review Required${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "SAFETY MEASURES:"
echo "  • This script NEVER auto-deletes secrets"
echo "  • Secrets updated within ${PRESERVE_DAYS} days are marked PRESERVE"
echo "  • Manual review is required before deletion"
echo ""
echo "MANUAL DELETION PROCESS:"
echo "  1. Review each orphaned secret above"
echo "  2. Verify the secret is truly unused"
echo "  3. Delete using GitHub CLI:"
echo ""
echo "     gh secret delete SECRET_NAME --repo $GITHUB_ORG/$GITHUB_REPO"
echo ""
echo "  4. Or delete via GitHub UI:"
echo "     https://github.com/$GITHUB_ORG/$GITHUB_REPO/settings/secrets/actions"
echo ""
echo -e "${RED}⚠️  WARNING: Deleting active secrets will break deployments!${NC}"
echo ""

exit 0
