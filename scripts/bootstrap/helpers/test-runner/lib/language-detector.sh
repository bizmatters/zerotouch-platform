#!/bin/bash

# ==============================================================================
# Language Detector Library
# ==============================================================================

detect_language() {
    local test_patterns="$1"
    
    # Detect from test_patterns extension
    if [[ "$test_patterns" == *".ts" ]] || [[ "$test_patterns" == *".js" ]]; then
        echo "node"
    elif [[ "$test_patterns" == *".go" ]]; then
        echo "go"
    elif [[ "$test_patterns" == *".py" ]]; then
        echo "python"
    else
        echo "unknown"
    fi
}
