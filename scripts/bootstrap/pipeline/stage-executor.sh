#!/bin/bash
# Stage Executor - YAML-driven bootstrap stage execution
# Reads stage definitions from YAML and executes them in order
#
# Usage: ./stage-executor.sh <stage-file.yaml>
# Example: ./stage-executor.sh pipeline/preview.yaml
#
# Expected Environment Variables:
#   All variables documented in the stage YAML file
#   REPO_ROOT - Repository root directory
#   SKIP_CACHE - Set to "true" to ignore cache (default: false)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SKIP_CACHE=${SKIP_CACHE:-false}
STAGE_CACHE_FILE="${REPO_ROOT}/.zerotouch-cache/bootstrap-stage-cache.json"

# Validate arguments
if [[ $# -lt 1 ]]; then
    echo -e "${RED}Error: Stage file required${NC}"
    echo "Usage: $0 <stage-file.yaml>"
    exit 1
fi

STAGE_FILE="$1"

if [[ ! -f "$STAGE_FILE" ]]; then
    echo -e "${RED}Error: Stage file not found: $STAGE_FILE${NC}"
    exit 1
fi

# Validate yq is available
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: yq is required but not installed${NC}"
    echo -e "${RED}Install: brew install yq (macOS) or https://github.com/mikefarah/yq#install${NC}"
    exit 1
fi

# Validate jq is available (for cache management)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed${NC}"
    echo -e "${RED}Install: brew install jq (macOS) or https://stedolan.github.io/jq/download/${NC}"
    exit 1
fi

# Logging functions
log_info() { echo -e "${BLUE}[STAGE-EXECUTOR]${NC} $*"; }
log_success() { echo -e "${GREEN}[STAGE-EXECUTOR]${NC} $*"; }
log_error() { echo -e "${RED}[STAGE-EXECUTOR]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[STAGE-EXECUTOR]${NC} $*"; }
log_step() { echo -e "${YELLOW}[$1/$2]${NC} $3"; }

# Cache management functions
init_stage_cache() {
    # Note: Cache deletion is handled by workflow at startup when SKIP_CACHE=true
    # Stage-executor should never delete cache to preserve entries added by workflow (e.g., rescue_mode)
    # Only initialize if cache file doesn't exist
    
    if [[ ! -f "$STAGE_CACHE_FILE" ]]; then
        log_info "Initializing stage cache: $STAGE_CACHE_FILE"
        mkdir -p "$(dirname "$STAGE_CACHE_FILE")"
        echo '{"stages":{}}' > "$STAGE_CACHE_FILE"
    fi
}

mark_stage_complete() {
    local stage_name="$1"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    local temp_file=$(mktemp)
    jq --arg stage "$stage_name" --arg ts "$timestamp" \
       '.stages[$stage] = $ts' "$STAGE_CACHE_FILE" > "$temp_file"
    mv "$temp_file" "$STAGE_CACHE_FILE"
    log_success "Stage '$stage_name' marked complete"
}

is_stage_complete() {
    local stage_name="$1"
    
    log_info "DEBUG: Checking cache for stage '$stage_name'"
    log_info "DEBUG: STAGE_CACHE_FILE=$STAGE_CACHE_FILE"
    log_info "DEBUG: SKIP_CACHE=$SKIP_CACHE"
    log_info "DEBUG: File exists: $([ -f "$STAGE_CACHE_FILE" ] && echo "yes" || echo "no")"
    
    if [[ ! -f "$STAGE_CACHE_FILE" ]] || [[ "$SKIP_CACHE" == "true" ]]; then
        return 1
    fi
    
    local completed=$(jq -r --arg stage "$stage_name" '.stages[$stage] // empty' "$STAGE_CACHE_FILE")
    log_info "DEBUG: Cache value for '$stage_name': '$completed'"
    
    if [[ -n "$completed" ]]; then
        log_info "Stage '$stage_name' already complete (cached: $completed)"
        return 0
    fi
    
    return 1
}

# Read stage file metadata
MODE=$(yq eval '.mode' "$STAGE_FILE")
TOTAL_STEPS=$(yq eval '.total_steps' "$STAGE_FILE")
DESCRIPTION=$(yq eval '.description // ""' "$STAGE_FILE")

log_info "════════════════════════════════════════════════════════"
log_info "Stage Executor - ${MODE} Mode"
if [[ -n "$DESCRIPTION" ]]; then
    log_info "$DESCRIPTION"
fi
log_info "════════════════════════════════════════════════════════"
log_info "Stage file: $STAGE_FILE"
log_info "Total steps: $TOTAL_STEPS"
log_info "Cache: $([ "$SKIP_CACHE" == "true" ] && echo "Disabled" || echo "Enabled")"
echo ""

# Initialize cache
init_stage_cache

# Get number of stages
STAGE_COUNT=$(yq eval '.stages | length' "$STAGE_FILE")
CURRENT_STEP=0

# Execute each stage
for i in $(seq 0 $((STAGE_COUNT - 1))); do
    CURRENT_STEP=$((CURRENT_STEP + 1))
    
    # Read stage properties
    STAGE_NAME=$(yq eval ".stages[$i].name" "$STAGE_FILE")
    STAGE_DESC=$(yq eval ".stages[$i].description" "$STAGE_FILE")
    STAGE_SCRIPT=$(yq eval ".stages[$i].script" "$STAGE_FILE")
    STAGE_CACHE_KEY=$(yq eval ".stages[$i].cache_key" "$STAGE_FILE")
    STAGE_REQUIRED=$(yq eval ".stages[$i].required // true" "$STAGE_FILE")
    STAGE_SKIP_IF_EMPTY=$(yq eval ".stages[$i].skip_if_empty // \"\"" "$STAGE_FILE")
    
    log_step "$CURRENT_STEP" "$TOTAL_STEPS" "$STAGE_DESC"
    
    # Check skip condition if specified
    if [[ -n "$STAGE_SKIP_IF_EMPTY" && -z "${!STAGE_SKIP_IF_EMPTY}" ]]; then
        log_info "Skipping stage '$STAGE_NAME' (condition: $STAGE_SKIP_IF_EMPTY is empty)"
        echo ""
        continue
    fi
    
    # Handle null script (e.g., rescue_mode - assumed pre-executed)
    if [[ "$STAGE_SCRIPT" == "null" ]]; then
        log_info "Stage '$STAGE_NAME' has no script (pre-executed externally)"
        # Don't auto-mark complete - only skip if already cached
        echo ""
        continue
    fi
    
    # Check cache if cache_key is set
    if [[ "$STAGE_CACHE_KEY" != "null" ]] && is_stage_complete "$STAGE_CACHE_KEY"; then
        log_info "Skipping stage '$STAGE_NAME' (cached)"
        echo ""
        continue
    fi
    
    # Build script path
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    SCRIPT_PATH="$SCRIPT_DIR/$STAGE_SCRIPT"
    
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        if [[ "$STAGE_REQUIRED" == "true" ]]; then
            log_error "Required script not found: $SCRIPT_PATH"
            exit 1
        else
            log_warn "Optional script not found: $SCRIPT_PATH (skipping)"
            echo ""
            continue
        fi
    fi
    
    # Make script executable
    chmod +x "$SCRIPT_PATH"
    
    # Read args array if present
    ARGS_COUNT=$(yq eval ".stages[$i].args | length" "$STAGE_FILE" 2>/dev/null || echo "0")
    SCRIPT_ARGS=()
    
    if [[ "$ARGS_COUNT" -gt 0 ]]; then
        for j in $(seq 0 $((ARGS_COUNT - 1))); do
            ARG=$(yq eval ".stages[$i].args[$j]" "$STAGE_FILE")
            # Expand environment variables (safe for paths/IPs, NOT for passwords)
            # Passwords should be read from env vars by scripts, not passed as args
            ARG=$(eval echo "$ARG")
            SCRIPT_ARGS+=("$ARG")
        done
    fi
    
    # Execute stage script with args
    if [[ ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
        log_info "Executing: $STAGE_SCRIPT ${SCRIPT_ARGS[*]}"
        "$SCRIPT_PATH" "${SCRIPT_ARGS[@]}"
    else
        log_info "Executing: $STAGE_SCRIPT"
        "$SCRIPT_PATH"
    fi
    
    if [[ $? -eq 0 ]]; then
        log_success "Stage '$STAGE_NAME' completed successfully"
        
        # Mark stage complete if cache_key is set
        if [[ "$STAGE_CACHE_KEY" != "null" ]]; then
            mark_stage_complete "$STAGE_CACHE_KEY"
        fi
    else
        EXIT_CODE=$?
        log_error "Stage '$STAGE_NAME' failed with exit code $EXIT_CODE"
        exit $EXIT_CODE
    fi
    
    echo ""
done

# Execute post-validation steps
POST_VALIDATION_COUNT=$(yq eval '.post_validation | length' "$STAGE_FILE" 2>/dev/null || echo "0")

if [[ "$POST_VALIDATION_COUNT" -gt 0 ]]; then
    log_info "════════════════════════════════════════════════════════"
    log_info "Post-Validation Steps"
    log_info "════════════════════════════════════════════════════════"
    echo ""
    
    for i in $(seq 0 $((POST_VALIDATION_COUNT - 1))); do
        POST_NAME=$(yq eval ".post_validation[$i].name" "$STAGE_FILE")
        POST_DESC=$(yq eval ".post_validation[$i].description" "$STAGE_FILE")
        POST_SCRIPT=$(yq eval ".post_validation[$i].script" "$STAGE_FILE")
        POST_TIMEOUT=$(yq eval ".post_validation[$i].timeout // 0" "$STAGE_FILE")
        
        log_info "$POST_DESC"
        
        # Build script path
        SCRIPT_PATH="$SCRIPT_DIR/$POST_SCRIPT"
        
        if [[ ! -f "$SCRIPT_PATH" ]]; then
            log_warn "Post-validation script not found: $SCRIPT_PATH (skipping)"
            echo ""
            continue
        fi
        
        # Make script executable
        chmod +x "$SCRIPT_PATH"
        
        # Read args array if present
        POST_ARGS_COUNT=$(yq eval ".post_validation[$i].args | length" "$STAGE_FILE" 2>/dev/null || echo "0")
        POST_SCRIPT_ARGS=()
        
        if [[ "$POST_ARGS_COUNT" -gt 0 ]]; then
            for j in $(seq 0 $((POST_ARGS_COUNT - 1))); do
                POST_ARG=$(yq eval ".post_validation[$i].args[$j]" "$STAGE_FILE")
                # Expand environment variables in arg
                POST_ARG=$(eval echo "$POST_ARG")
                POST_SCRIPT_ARGS+=("$POST_ARG")
            done
        fi
        
        # Execute post-validation script
        if [[ ${#POST_SCRIPT_ARGS[@]} -gt 0 ]]; then
            log_info "Executing: $POST_SCRIPT ${POST_SCRIPT_ARGS[*]}"
            "$SCRIPT_PATH" "${POST_SCRIPT_ARGS[@]}"
        else
            log_info "Executing: $POST_SCRIPT"
            "$SCRIPT_PATH"
        fi
        
        if [[ $? -eq 0 ]]; then
            log_success "Post-validation '$POST_NAME' completed"
        else
            log_warn "Post-validation '$POST_NAME' had issues (non-fatal)"
        fi
        
        echo ""
    done
fi

log_success "════════════════════════════════════════════════════════"
log_success "All stages completed successfully!"
log_success "Mode: $MODE"
log_success "════════════════════════════════════════════════════════"

exit 0
