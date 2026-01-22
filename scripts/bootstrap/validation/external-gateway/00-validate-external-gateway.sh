#!/bin/bash
# Run all gateway validation scripts in order
# This script executes validation scripts that are ready to run
#
# Usage: ./00-validate-all-gateway.sh
#
# Run this to validate complete gateway functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Gateway Validation Suite                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Track validation results
TOTAL_VALIDATIONS=0
PASSED_VALIDATIONS=0
FAILED_VALIDATIONS=0

# Infrastructure Components Validation
echo -e "${BLUE}Running: Infrastructure Components Validation${NC}"
TOTAL_VALIDATIONS=$((TOTAL_VALIDATIONS + 1))
if python3 "$SCRIPT_DIR/01-validate-infrastructure-components.py"; then
    echo -e "${GREEN}✓ Infrastructure Components PASSED${NC}"
    PASSED_VALIDATIONS=$((PASSED_VALIDATIONS + 1))
else
    echo -e "${RED}✗ Infrastructure Components FAILED${NC}"
    FAILED_VALIDATIONS=$((FAILED_VALIDATIONS + 1))
fi
echo ""

# Gateway Infrastructure Validation
echo -e "${BLUE}Running: Gateway Infrastructure Validation${NC}"
TOTAL_VALIDATIONS=$((TOTAL_VALIDATIONS + 1))
if python3 "$SCRIPT_DIR/04-validate-gateway-infrastructure.py"; then
    echo -e "${GREEN}✓ Gateway Infrastructure PASSED${NC}"
    PASSED_VALIDATIONS=$((PASSED_VALIDATIONS + 1))
else
    echo -e "${RED}✗ Gateway Infrastructure FAILED${NC}"
    FAILED_VALIDATIONS=$((FAILED_VALIDATIONS + 1))
fi
echo ""

# End-to-End Automation Validation
echo -e "${BLUE}Running: End-to-End Automation Validation${NC}"
TOTAL_VALIDATIONS=$((TOTAL_VALIDATIONS + 1))
if python3 "$SCRIPT_DIR/05-validate-e2e-automation.py"; then
    echo -e "${GREEN}✓ End-to-End Automation PASSED${NC}"
    PASSED_VALIDATIONS=$((PASSED_VALIDATIONS + 1))
else
    echo -e "${RED}✗ End-to-End Automation FAILED${NC}"
    FAILED_VALIDATIONS=$((FAILED_VALIDATIONS + 1))
fi
echo ""

# CHECKPOINT 3: Complete Authentication Flow Working (future implementation)
# echo -e "${BLUE}Running: CHECKPOINT 3 - Complete Authentication Flow${NC}"
# TOTAL_VALIDATIONS=$((TOTAL_VALIDATIONS + 1))
# if "$SCRIPT_DIR/04-run-platform-auth-validation.sh"; then
#     echo -e "${GREEN}✓ CHECKPOINT 3 PASSED${NC}"
#     PASSED_VALIDATIONS=$((PASSED_VALIDATIONS + 1))
# else
#     echo -e "${RED}✗ CHECKPOINT 3 FAILED${NC}"
#     FAILED_VALIDATIONS=$((FAILED_VALIDATIONS + 1))
# fi
# echo ""

# CHECKPOINT 4: Validation Suite Complete (future implementation)
# echo -e "${BLUE}Running: CHECKPOINT 4 - Validation Suite Complete${NC}"
# TOTAL_VALIDATIONS=$((TOTAL_VALIDATIONS + 1))
# if "$SCRIPT_DIR/05-run-validation-suite.sh"; then
#     echo -e "${GREEN}✓ CHECKPOINT 4 PASSED${NC}"
#     PASSED_VALIDATIONS=$((PASSED_VALIDATIONS + 1))
# else
#     echo -e "${RED}✗ CHECKPOINT 4 FAILED${NC}"
#     FAILED_VALIDATIONS=$((FAILED_VALIDATIONS + 1))
# fi
# echo ""

# Summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Validation Summary                                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "Total Validations: $TOTAL_VALIDATIONS"
echo -e "${GREEN}Passed: $PASSED_VALIDATIONS${NC}"
echo -e "${RED}Failed: $FAILED_VALIDATIONS${NC}"
echo ""

if [ $FAILED_VALIDATIONS -eq 0 ]; then
    echo -e "${GREEN}✓ All gateway validations passed successfully${NC}"
    exit 0
else
    echo -e "${RED}✗ $FAILED_VALIDATIONS validation(s) failed${NC}"
    exit 1
fi