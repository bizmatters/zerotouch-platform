#!/bin/bash
# ==============================================================================
# Tenant Repository Boilerplate Generator
# ==============================================================================
# Purpose: Create complete tenant repository structure from scratch
# Location: zerotouch-platform/scripts/tenants/tenant-repo-boilerplate.sh
#
# Usage: 
#   ./tenant-repo-boilerplate.sh <repo-name> <org-name> <output-path>
#
# Example:
#   ./tenant-repo-boilerplate.sh zerotouch-tenants arun4infra /path/to/output
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Arguments
REPO_NAME="${1:-}"
ORG_NAME="${2:-}"
OUTPUT_PATH="${3:-}"

# Validation
if [ -z "$REPO_NAME" ] || [ -z "$ORG_NAME" ] || [ -z "$OUTPUT_PATH" ]; then
    echo -e "${RED}Usage: $0 <repo-name> <org-name> <output-path>${NC}"
    echo -e "${YELLOW}Example: $0 zerotouch-tenants arun4infra /path/to/output${NC}"
    exit 1
fi

REPO_DIR="$OUTPUT_PATH/$REPO_NAME"

if [ -d "$REPO_DIR" ]; then
    echo -e "${RED}✗ Error: Directory already exists: $REPO_DIR${NC}"
    exit 1
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Creating Tenant Repository: $REPO_NAME${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}✓ Organization: $ORG_NAME${NC}"
echo -e "${GREEN}✓ Output: $REPO_DIR${NC}"
echo ""

# Create directory structure
echo -e "${BLUE}Creating directory structure...${NC}"
mkdir -p "$REPO_DIR/tenants"
mkdir -p "$REPO_DIR/scripts"
mkdir -p "$REPO_DIR/environments/dev"
mkdir -p "$REPO_DIR/environments/staging"
mkdir -p "$REPO_DIR/environments/production"
mkdir -p "$REPO_DIR/archived/repositories"
echo -e "${GREEN}✓ Directories created${NC}"

# Create .env.example
echo -e "${BLUE}Creating .env.example...${NC}"
cat > "$REPO_DIR/.env.example" << 'EOF'
# Organization Configuration
ORG_NAME=your-github-org

# GitHub App Credentials (for GHCR access)
GIT_APP_ID=
GIT_APP_INSTALLATION_ID=
GIT_APP_PRIVATE_KEY=""

# Service-specific secrets (prefix with environment)
# DEV_<SERVICE>_<SECRET_NAME>=value
# STAGING_<SERVICE>_<SECRET_NAME>=value
# PROD_<SERVICE>_<SECRET_NAME>=value

# Example:
# DEV_MYSERVICE_DATABASE_URL=postgresql://...
# DEV_MYSERVICE_API_KEY=secret123
EOF
echo -e "${GREEN}✓ .env.example${NC}"

# Create actual .env with provided org
echo -e "${BLUE}Creating .env...${NC}"
cat > "$REPO_DIR/.env" << EOF
# Organization Configuration
ORG_NAME=$ORG_NAME

# GitHub App Credentials (for GHCR access)
# Get these from: https://github.com/organizations/$ORG_NAME/settings/apps
GIT_APP_ID=
GIT_APP_INSTALLATION_ID=
GIT_APP_PRIVATE_KEY=""
EOF
echo -e "${GREEN}✓ .env${NC}"

# Create .gitignore
echo -e "${BLUE}Creating .gitignore...${NC}"
cat > "$REPO_DIR/.gitignore" << 'EOF'
# Environment files
.env
.env.local
.env.*.local

# Temporary files
*.tmp
*.bak
.DS_Store

# Platform checkout (temporary)
zerotouch-platform/

# IDE
.vscode/
.idea/
*.swp
*.swo
EOF
echo -e "${GREEN}✓ .gitignore${NC}"

# Create .sops.yaml
echo -e "${BLUE}Creating .sops.yaml...${NC}"
cat > "$REPO_DIR/.sops.yaml" << 'EOF'
# SOPS configuration for tenant secrets
# Age key should be deployed to cluster as secret/sops-age in kube-system namespace
creation_rules:
  - path_regex: \.secret\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: >-
      age1placeholder
EOF
echo -e "${GREEN}✓ .sops.yaml${NC}"

# Create README.md
echo -e "${BLUE}Creating README.md...${NC}"
cat > "$REPO_DIR/README.md" << EOF
# $REPO_NAME

Tenant repository for deploying services to the zerotouch platform.

## Structure

\`\`\`
$REPO_NAME/
├── .env                    # Organization and service secrets (not in git)
├── .env.example            # Template for .env
├── .sops.yaml              # SOPS encryption configuration
├── tenants/                # Service definitions
│   └── <service-name>/
│       ├── base/           # Base Kustomize resources
│       └── overlays/       # Environment-specific overlays
│           ├── dev/
│           ├── staging/
│           └── production/
├── scripts/                # Utility scripts
│   ├── create-tenant.sh    # Create new service
│   └── sync-ksops-secrets.sh  # Generate encrypted secrets
└── environments/           # Environment-specific configurations
    ├── dev/
    ├── staging/
    └── production/
\`\`\`

## Getting Started

### 1. Configure Organization

Edit \`.env\` and set your organization name:

\`\`\`bash
ORG_NAME=$ORG_NAME
\`\`\`

### 2. Create a New Service

\`\`\`bash
./scripts/create-tenant.sh <service-name> <namespace> [port] [size]
\`\`\`

Example:
\`\`\`bash
./scripts/create-tenant.sh my-api apis-myapi 8080 micro
\`\`\`

### 3. Add Service Secrets

Create \`tenants/<service-name>/.env\` with environment-prefixed secrets:

\`\`\`bash
# Development secrets
DEV_MYAPI_DATABASE_URL=postgresql://...
DEV_MYAPI_API_KEY=dev-key-123

# Staging secrets
STAGING_MYAPI_DATABASE_URL=postgresql://...
STAGING_MYAPI_API_KEY=staging-key-456

# Production secrets
PROD_MYAPI_DATABASE_URL=postgresql://...
PROD_MYAPI_API_KEY=prod-key-789
\`\`\`

### 4. Generate Encrypted Secrets

\`\`\`bash
./scripts/sync-ksops-secrets.sh <service-name>
\`\`\`

Or sync all services:
\`\`\`bash
./scripts/sync-ksops-secrets.sh
\`\`\`

### 5. Commit and Deploy

\`\`\`bash
git add tenants/
git commit -m "feat: add <service-name>"
git push
\`\`\`

## Scripts

- **create-tenant.sh**: Scaffold new service structure with correct registry owner
- **sync-ksops-secrets.sh**: Generate SOPS-encrypted secrets for all environments

## Platform Integration

This repository is managed by the zerotouch-platform. Service structure and scripts are controlled by:
- \`zerotouch-platform/scripts/tenants/create-tenant.sh\`
- \`zerotouch-platform/scripts/tenants/tenant-repo-boilerplate.sh\`

Do not modify script logic locally - changes should be made in the platform repository.
EOF
echo -e "${GREEN}✓ README.md${NC}"

# Create wrapper script for create-tenant
echo -e "${BLUE}Creating scripts/create-tenant.sh...${NC}"
cat > "$REPO_DIR/scripts/create-tenant.sh" << 'EOF'
#!/bin/bash
# Wrapper script - calls platform script
# See: zerotouch-platform/scripts/tenants/create-tenant.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME="${1:-}"
NAMESPACE="${2:-}"
PORT="${3:-8080}"
SIZE="${4:-micro}"

if [ -z "$SERVICE_NAME" ] || [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Usage: $0 <service-name> <namespace> [port] [size]${NC}"
    echo -e "${YELLOW}Example: $0 my-service apis-myservice 8080 micro${NC}"
    exit 1
fi

PLATFORM_BRANCH="${PLATFORM_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/.env" ]; then
    echo -e "${RED}✗ Error: .env not found. Please create it with ORG_NAME${NC}"
    exit 1
fi

if [ -d "$REPO_ROOT/tenants/$SERVICE_NAME" ]; then
    echo -e "${RED}✗ Error: Service '$SERVICE_NAME' already exists${NC}"
    exit 1
fi

echo -e "${BLUE}Fetching platform scripts...${NC}"
if [[ -d "$REPO_ROOT/zerotouch-platform" ]]; then
    rm -rf "$REPO_ROOT/zerotouch-platform"
fi

git clone -b "$PLATFORM_BRANCH" https://github.com/arun4infra/zerotouch-platform.git "$REPO_ROOT/zerotouch-platform"
echo -e "${GREEN}✓ Platform cloned${NC}"

PLATFORM_SCRIPT="$REPO_ROOT/zerotouch-platform/scripts/tenants/create-tenant.sh"
chmod +x "$PLATFORM_SCRIPT"
"$PLATFORM_SCRIPT" "$SERVICE_NAME" "$REPO_ROOT" "$NAMESPACE" "$PORT" "$SIZE"

rm -rf "$REPO_ROOT/zerotouch-platform"
echo -e "${GREEN}✓ Done${NC}"
EOF
chmod +x "$REPO_DIR/scripts/create-tenant.sh"
echo -e "${GREEN}✓ scripts/create-tenant.sh${NC}"

# Create wrapper script for sync-ksops-secrets
echo -e "${BLUE}Creating scripts/sync-ksops-secrets.sh...${NC}"
cat > "$REPO_DIR/scripts/sync-ksops-secrets.sh" << 'EOF'
#!/bin/bash
# Wrapper script - calls platform script
# See: zerotouch-platform/scripts/bootstrap/infra/secrets/ksops/generate-sops/

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TENANT_NAME="${1:-}"
PLATFORM_BRANCH="${PLATFORM_BRANCH:-main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}Fetching platform scripts...${NC}"
if [[ -d "$REPO_ROOT/zerotouch-platform" ]]; then
    rm -rf "$REPO_ROOT/zerotouch-platform"
fi

git clone -b "$PLATFORM_BRANCH" https://github.com/arun4infra/zerotouch-platform.git "$REPO_ROOT/zerotouch-platform"
echo -e "${GREEN}✓ Platform cloned${NC}"

# TODO: Implement secret sync logic
echo -e "${YELLOW}⚠️  Secret sync not yet implemented${NC}"
echo -e "${YELLOW}This will call platform secret generation scripts${NC}"

rm -rf "$REPO_ROOT/zerotouch-platform"
EOF
chmod +x "$REPO_DIR/scripts/sync-ksops-secrets.sh"
echo -e "${GREEN}✓ scripts/sync-ksops-secrets.sh${NC}"

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Tenant Repository Created Successfully                     ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}✓ Location: $REPO_DIR${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Initialize git: ${GREEN}cd $REPO_DIR && git init${NC}"
echo -e "  2. Update .env with GitHub App credentials"
echo -e "  3. Update .sops.yaml with age key"
echo -e "  4. Create first service: ${GREEN}./scripts/create-tenant.sh my-service apis-myservice${NC}"
echo ""
