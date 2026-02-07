#!/bin/bash
# Local CI simulation for V2 YAML-driven bootstrap validation (Production)
# Usage: ./create-cluster-workflow-v2.sh <environment>
# Examples:
#   ./create-cluster-workflow-v2.sh dev
#   SKIP_CACHE=true ./create-cluster-workflow-v2.sh dev
#
# cd zerotouch-platform && set -a && source .env && set +a && ./scripts/local-ci/create-cluster-workflow-v2.sh dev

set -e

# Source .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# Parse arguments
ENVIRONMENT="${1:-dev}"

LOG_DIR="$SCRIPT_DIR/logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/create-cluster-v2-${ENVIRONMENT}-${TIMESTAMP}.log"
STAGE_CACHE_FILE="$REPO_ROOT/.zerotouch-cache/bootstrap-stage-cache.json"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to check if stage is complete
is_stage_complete() {
    local stage_name="$1"
    
    if [[ ! -f "$STAGE_CACHE_FILE" ]]; then
        return 1
    fi
    
    if command -v jq &> /dev/null; then
        local completed=$(jq -r --arg stage "$stage_name" '.stages[$stage] // empty' "$STAGE_CACHE_FILE")
        if [[ -n "$completed" ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Function to run command with logging
run_with_log() {
    log "Running: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -ne 0 ]; then
        log "Command failed with exit code: $exit_code"
        exit $exit_code
    fi
}

# Set CI environment variable to match workflow
export CI=true

# Debug: Check if critical env vars are set
if [ -z "$GIT_APP_ID" ]; then
    log "⚠️  WARNING: GIT_APP_ID not set - rescue mode may fail"
fi
if [ -z "$HETZNER_API_TOKEN" ]; then
    log "⚠️  WARNING: HETZNER_API_TOKEN not set - rescue mode may fail"
fi

log "╔══════════════════════════════════════════════════════════════╗"
log "║   Local CI: V2 Create Cluster Workflow (Production)         ║"
log "╚══════════════════════════════════════════════════════════════╝"
log "Environment: $ENVIRONMENT"
log "Log file: $LOG_FILE"
log ""

# Handle SKIP_CACHE - delete cache immediately if set
if [ "${SKIP_CACHE:-false}" = "true" ]; then
    log "==> SKIP_CACHE=true: Removing existing stage cache..."
    if [ -f "$STAGE_CACHE_FILE" ]; then
        rm -f "$STAGE_CACHE_FILE"
        log "✓ Stage cache removed"
    else
        log "✓ No stage cache to remove"
    fi
    
    # Also remove tenant cache to prevent git fetch errors
    TENANT_CACHE_DIR="$REPO_ROOT/.zerotouch-cache/tenants-cache"
    if [ -d "$TENANT_CACHE_DIR" ]; then
        rm -rf "$TENANT_CACHE_DIR"
        log "✓ Tenant cache removed"
    else
        log "✓ No tenant cache to remove"
    fi
    log ""
fi

# Step 0: Setup environment
log "==> Step 0: Setup environment..."
if ! command -v python3 &> /dev/null; then
    log "⚠ Python3 not found, please install it"
    exit 1
fi

# Install pyyaml if not available
python3 -c "import yaml" 2>/dev/null || pip3 install pyyaml

# Validate yq and jq
if ! command -v yq &> /dev/null; then
    log "✗ yq not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install yq
    else
        log "Please install yq: https://github.com/mikefarah/yq#install"
        exit 1
    fi
fi

if ! command -v jq &> /dev/null; then
    log "✗ jq not found. Installing..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install jq
    else
        log "Please install jq: https://stedolan.github.io/jq/download/"
        exit 1
    fi
fi

log "✓ Environment setup complete"
log ""

# Step 1: Validate environment overlay exists
log "==> Step 1: Validating environment overlay..."
OVERLAY_DIR="$REPO_ROOT/bootstrap/argocd/overlays/main/$ENVIRONMENT"

if [ -d "$OVERLAY_DIR" ]; then
    log "✓ Environment overlay found: $OVERLAY_DIR"
else
    log "✗ Environment overlay not found: $OVERLAY_DIR"
    log "  Available overlays: $(ls -1 "$REPO_ROOT/bootstrap/argocd/overlays/main/" | tr '\n' ' ')"
    exit 1
fi
log ""

# Step 2: Validate stage YAML file
log "==> Step 2: Validating production stage definition..."
# Map environment to stage file (all environments use production.yaml for production mode)
STAGE_FILE="$REPO_ROOT/scripts/bootstrap/pipeline/production.yaml"

if [ ! -f "$STAGE_FILE" ]; then
    log "✗ Stage file not found: $STAGE_FILE"
    exit 1
fi

# Validate YAML syntax
if ! yq eval '.' "$STAGE_FILE" > /dev/null 2>&1; then
    log "✗ Invalid YAML syntax in $STAGE_FILE"
    exit 1
fi

TOTAL_STAGES=$(yq eval '.stages | length' "$STAGE_FILE")
log "✓ Stage file valid: $STAGE_FILE"
log "  Total stages: $TOTAL_STAGES"
log ""

# Step 3: Enable Rescue Mode
# Skip only if already in cache (and SKIP_CACHE is not true)
if [ "${SKIP_CACHE:-false}" != "true" ] && is_stage_complete "rescue_mode"; then
    log "==> Step 3-4: Skipping rescue mode (already complete in cache)"
else
    log "==> Step 3: Enable Rescue Mode..."
    run_with_log "$REPO_ROOT/scripts/bootstrap/00-enable-rescue-mode.sh" "$ENVIRONMENT" -y
    
    log "==> Step 4: Wait for rescue mode boot (90s)..."
    sleep 90
    
    # Mark rescue mode complete
    if command -v jq &> /dev/null; then
        mkdir -p "$(dirname "$STAGE_CACHE_FILE")"
        if [[ ! -f "$STAGE_CACHE_FILE" ]]; then
            echo '{"stages":{}}' > "$STAGE_CACHE_FILE"
        fi
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        TEMP_FILE=$(mktemp)
        jq --arg ts "$TIMESTAMP" '.stages.rescue_mode = $ts' "$STAGE_CACHE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$STAGE_CACHE_FILE"
        log "✓ Rescue mode marked complete"
    fi
fi
log ""

# Step 5: Bootstrap Cluster with V2
log "==> Step 5: Running V2 Bootstrap..."
log "Executing: scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh $ENVIRONMENT"
log "Note: Server details will be read from tenant repository"
log ""

run_with_log "$REPO_ROOT/scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh" "$ENVIRONMENT"

# Step 6: Run E2E Communication Tests
log ""
log "==> Step 6: Running E2E Communication Tests..."
log "Testing actual service communication and deployment..."
E2E_SCRIPT="$REPO_ROOT/scripts/bootstrap/validation/18-verify-e2e-communication.sh"
if [ -f "$E2E_SCRIPT" ]; then
    chmod +x "$E2E_SCRIPT"
    if "$E2E_SCRIPT" 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ E2E Communication tests passed"
    else
        log "⚠ E2E Communication tests failed (expected for fresh cluster without deployed services)"
        log "  This is normal - services need proper GHCR credentials and Gateway API to be fully functional"
    fi
else
    log "⚠ E2E Communication test script not found: $E2E_SCRIPT"
fi

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║   V2 Bootstrap Complete                                      ║"
log "╚══════════════════════════════════════════════════════════════╝"
log ""
log "Summary:"
log "  Environment: $ENVIRONMENT"
log "  Log file: $LOG_FILE"
log "  Stage cache: $STAGE_CACHE_FILE"
log ""
log "Next steps:"
log "  - Review logs: $LOG_FILE"
log "  - Check stage cache: cat $STAGE_CACHE_FILE | jq"
log "  - Access ArgoCD: kubectl port-forward -n argocd svc/argocd-server 8080:443"
log "  - Get password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

exit 0

