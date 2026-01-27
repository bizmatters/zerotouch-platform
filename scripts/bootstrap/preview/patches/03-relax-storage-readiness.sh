#!/bin/bash
# Relax storage readiness checks for CI/preview environments
# Removes strict "Bound" check that causes timeouts in fresh Kind clusters

set -euo pipefail

echo "🔧 Relaxing storage readiness checks for preview mode..."

# Check if composition exists
if ! kubectl get composition agentsandbox-storage >/dev/null 2>&1; then
    echo "⚠️  Composition agentsandbox-storage not found, skipping..."
    exit 0
fi

# Patch the composition to remove strict Bound check
kubectl patch composition agentsandbox-storage --type=json -p='[
  {
    "op": "remove",
    "path": "/spec/resources/0/readinessChecks/1"
  }
]' 2>/dev/null || echo "⚠️  Readiness check already removed or path changed"

echo "✅ Storage readiness checks relaxed for preview mode"
