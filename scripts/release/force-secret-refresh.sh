#!/bin/bash
# Force External Secrets Refresh for Specific Environment
# Usage: ./force-secret-refresh.sh <service-name> <env> <namespace>

set -euo pipefail

SERVICE_NAME="$1"
ENV="$2"
NAMESPACE="$3"

if [[ -z "$SERVICE_NAME" || -z "$ENV" || -z "$NAMESPACE" ]]; then
    echo "❌ Usage: $0 <service-name> <env> <namespace>"
    exit 1
fi

echo "🔄 Triggering secret refresh for $SERVICE_NAME [$ENV] in namespace: $NAMESPACE"

# Target only secrets for this service and environment
LABEL_SELECTOR="zerotouch.io/managed=true,app.kubernetes.io/name=${SERVICE_NAME}"

# Force sync by updating annotation
kubectl annotate externalsecret \
    -n "$NAMESPACE" \
    -l "$LABEL_SELECTOR" \
    force-sync="$(date +%s)" \
    --overwrite

echo "⏳ Waiting for secrets to become Ready..."

# Wait for secrets to sync (fail fast if issues)
kubectl wait \
    --for=condition=Ready \
    externalsecret \
    -n "$NAMESPACE" \
    -l "$LABEL_SELECTOR" \
    --timeout=60s

echo "✅ Secrets successfully synced for $SERVICE_NAME [$ENV]."
