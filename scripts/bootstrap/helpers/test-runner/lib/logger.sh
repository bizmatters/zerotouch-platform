#!/bin/bash

# ==============================================================================
# Logger Library
# ==============================================================================

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[TEST-RUNNER]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[TEST-RUNNER]${NC} $*" >&2; }
log_error() { echo -e "${RED}[TEST-RUNNER]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[TEST-RUNNER]${NC} $*" >&2; }
