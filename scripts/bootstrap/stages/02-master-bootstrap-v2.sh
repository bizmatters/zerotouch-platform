#!/bin/bash
# Master Bootstrap Script V2 - YAML-driven stage execution
# Usage: 
#   Production: ./02-master-bootstrap-v2.sh <server-ip> <root-password> [--worker-nodes <list>]
#   Preview:    ./02-master-bootstrap-v2.sh --mode preview
#
# This version uses YAML stage definitions for cleaner, more maintainable bootstrap logic

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SKIP_CACHE=${SKIP_CACHE:-false}
ARGOCD_NAMESPACE="argocd"

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source bootstrap config helper
source "$SCRIPT_DIR/helpers/bootstrap-config.sh"

# Ensure cache directory exists early
ensure_cache_dir

# Logging functions
log_info() { echo -e "${BLUE}[BOOTSTRAP]${NC} $*"; }
log_success() { echo -e "${GREEN}[BOOTSTRAP]${NC} $*"; }
log_error() { echo -e "${RED}[BOOTSTRAP]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[BOOTSTRAP]${NC} $*"; }

# Default mode
MODE="production"
ENV="dev"
SERVER_IP=""
ROOT_PASSWORD=""
WORKER_NODES=""
WORKER_PASSWORD=""

# Parse arguments
if [ "$#" -eq 0 ]; then
    echo -e "${RED}Usage:${NC}"
    echo -e "  ${GREEN}Production (from tenant repo):${NC} $0 [ENV]"
    echo -e "  ${GREEN}Production (manual):${NC}           $0 <server-ip> <root-password> [--worker-nodes <list>]"
    echo -e "  ${GREEN}Preview:${NC}                       $0 --mode preview"
    echo ""
    echo "Arguments:"
    echo "  ENV                 Environment name (dev/staging/production) - reads from tenant repo"
    echo "  <server-ip>         Control plane server IP (manual mode)"
    echo "  <root-password>     Root password for rescue mode (manual mode)"
    echo "  --mode preview      Run in preview mode (GitHub Actions/Kind cluster)"
    echo "  --worker-nodes      Optional: Comma-separated list of worker nodes (name:ip format)"
    echo "  --worker-password   Optional: Worker node rescue password (if different from control plane)"
    echo ""
    echo "Examples:"
    echo "  From tenant repo:        $0 dev"
    echo "  Manual single node:      $0 46.62.218.181 MyS3cur3P@ssw0rd"
    echo "  Manual multi-node:       $0 46.62.218.181 MyS3cur3P@ssw0rd --worker-nodes worker01:95.216.151.243"
    echo "  Preview (CI/CD):         $0 --mode preview"
    exit 1
fi

# Check if first argument is --mode
if [ "$1" = "--mode" ]; then
    MODE="$2"
    shift 2
# Check if first argument looks like an environment name (not an IP)
elif [[ "$1" =~ ^(dev|staging|production)$ ]]; then
    ENV="$1"
    
    # Write bootstrap config IMMEDIATELY after ENV is determined
    write_bootstrap_config "$ENV"
    
    shift
    log_info "Using environment: $ENV"
    log_info "Fetching configuration from tenant repository..."
    
    # Parse tenant config using helper
    source "$SCRIPT_DIR/helpers/parse-tenant-config.sh" "$ENV"
    
    log_success "Configuration loaded from tenant repo"
else
    # Manual mode - require server-ip and password
    if [ "$#" -lt 2 ]; then
        log_error "Manual mode requires <server-ip> and <root-password>"
        echo -e "Usage: $0 <server-ip> <root-password> [--worker-nodes <list>]"
        echo -e "   or: $0 [ENV]  (to use tenant repo)"
        echo -e "   or: $0 --mode preview"
        exit 1
    fi
    SERVER_IP="$1"
    ROOT_PASSWORD="$2"
    shift 2
fi

# Parse remaining optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --worker-nodes)
            WORKER_NODES="$2"
            shift 2
            ;;
        --worker-password)
            WORKER_PASSWORD="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# If worker password not specified, use control plane password
if [ -z "$WORKER_PASSWORD" ] && [ -n "$ROOT_PASSWORD" ]; then
    WORKER_PASSWORD="$ROOT_PASSWORD"
fi

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   BizMatters Infrastructure - Master Bootstrap V2          ║${NC}"
echo -e "${BLUE}║   YAML-Driven Stage Execution                               ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Mode:${NC} $MODE"
if [[ "$SKIP_CACHE" == "true" ]]; then
    echo -e "${YELLOW}Cache:${NC} Disabled (full rebuild)"
else
    echo -e "${GREEN}Cache:${NC} Enabled (resume from failures)"
fi
echo ""

# ============================================================================
# EXPORT ENVIRONMENT CONTEXT
# All variables needed by stage scripts
# ============================================================================

export MODE
export ENV
export SERVER_IP
export ROOT_PASSWORD
export WORKER_NODES
export WORKER_PASSWORD
export REPO_ROOT
export SCRIPT_DIR
export ARGOCD_NAMESPACE
export SKIP_CACHE

# Additional context variables
export CLUSTER_NAME="${CLUSTER_NAME:-zerotouch-${ENV}-01}"
export CREDENTIALS_FILE=""

log_info "Environment context exported:"
log_info "  MODE=$MODE"
log_info "  ENV=$ENV"
log_info "  REPO_ROOT=$REPO_ROOT"
if [[ "$MODE" == "production" ]]; then
    log_info "  SERVER_IP=$SERVER_IP"
    log_info "  CLUSTER_NAME=$CLUSTER_NAME"
fi
echo ""

# ============================================================================
# PREVIEW MODE ENVIRONMENT SETUP
# Copy service .env and export KIND_NODE_IMAGE for CI
# ============================================================================

if [ "$MODE" = "preview" ]; then
    # Copy service .env file to REPO_ROOT for downstream scripts
    SERVICE_ENV_FILE="$(cd "$SCRIPT_DIR/../../.." && pwd)/.env"
    PLATFORM_ENV_FILE="$REPO_ROOT/.env"
    
    if [[ -f "$SERVICE_ENV_FILE" ]]; then
        log_info "Copying service .env file to platform root..."
        cp "$SERVICE_ENV_FILE" "$PLATFORM_ENV_FILE"
        
        # Source the copied .env file
        set -a  # automatically export all variables
        source "$PLATFORM_ENV_FILE"
        set +a  # stop automatically exporting
        log_success "Environment variables loaded from .env"
    else
        log_error "Service .env file not found at $SERVICE_ENV_FILE"
        exit 1
    fi
    
    # Handle CI specific image caching
    if [[ -n "${KIND_NODE_IMAGE:-}" ]]; then
        log_info "Exporting KIND_NODE_IMAGE=$KIND_NODE_IMAGE"
        export KIND_NODE_IMAGE
    fi
fi

# ============================================================================
# PRODUCTION CREDENTIALS SETUP (Pre-flight - must run before stages)
# This runs outside stage loop because master script needs CREDENTIALS_FILE
# variable for final summary
# ============================================================================

if [ "$MODE" = "production" ]; then
    if [ -z "$SERVER_IP" ] || [ -z "$ROOT_PASSWORD" ]; then
        log_error "Production mode requires SERVER_IP and ROOT_PASSWORD"
        exit 1
    fi
    
    log_info "Setting up production credentials..."
    CREDENTIALS_FILE=$("$SCRIPT_DIR/helpers/setup-production.sh" "$SERVER_IP" "$ROOT_PASSWORD" "$WORKER_NODES" "$WORKER_PASSWORD" --yes)
    
    if [ -z "$CREDENTIALS_FILE" ] || [ ! -f "$CREDENTIALS_FILE" ]; then
        log_error "Failed to create credentials file"
        exit 1
    fi
    
    log_success "Credentials file: $CREDENTIALS_FILE"
    export CREDENTIALS_FILE
fi

# ============================================================================
# EXECUTE STAGES FROM YAML
# All mode-specific logic is now in stage definitions
# ============================================================================

STAGE_FILE="$SCRIPT_DIR/stages/${MODE}.yaml"

if [[ ! -f "$STAGE_FILE" ]]; then
    log_error "Stage file not found: $STAGE_FILE"
    exit 1
fi

log_info "════════════════════════════════════════════════════════"
log_info "Executing stages from: $STAGE_FILE"
log_info "════════════════════════════════════════════════════════"
echo ""

# Execute stage executor
"$SCRIPT_DIR/helpers/stage-executor.sh" "$STAGE_FILE"

# ============================================================================
# POST-BOOTSTRAP TASKS
# ============================================================================

# Extract ArgoCD password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "NOT_GENERATED")

if [ "$MODE" = "production" ]; then
    "$SCRIPT_DIR/helpers/add-credentials.sh" "$CREDENTIALS_FILE" "ARGOCD CREDENTIALS" "Username: admin
Password: $ARGOCD_PASSWORD

Access ArgoCD UI:
  kubectl port-forward -n argocd svc/argocd-server 8080:443
  Open: https://localhost:8080

Access via CLI:
  argocd login localhost:8080 --username admin --password '$ARGOCD_PASSWORD'"
else
    echo ""
    echo -e "${GREEN}ArgoCD Credentials:${NC}"
    echo -e "  Username: ${YELLOW}admin${NC}"
    if [[ -z "$CI" ]]; then
        echo -e "  Password: ${YELLOW}$ARGOCD_PASSWORD${NC}"
    else
        echo -e "  Password: ${YELLOW}***MASKED*** (saved to credentials file)${NC}"
    fi
    echo ""
fi

# ============================================================================
# BOOTSTRAP COMPLETE
# ============================================================================

"$SCRIPT_DIR/99-bootstrap-complete.sh" "$MODE" "${CREDENTIALS_FILE:-}" "${SERVER_IP:-}" "${WORKER_NODES:-}"
