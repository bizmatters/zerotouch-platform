#!/bin/bash
# Generate GHCR pull secret using GitHub App credentials
# Usage: ./generate-ghcr-pull-secret.sh <OUTPUT_FILE> <NAMESPACE> <SOPS_CONFIG> [ENV_FILE]

set -e

OUTPUT_FILE="${1:-}"
NAMESPACE="${2:-}"
SOPS_CONFIG="${3:-}"
ENV_FILE="${4:-.env}"

# Template paths
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TEMPLATE_DIR="$REPO_ROOT/scripts/bootstrap/infra/secrets/ksops/templates"
UNIVERSAL_SECRET_TEMPLATE="$TEMPLATE_DIR/universal-secret.yaml"

if [ -z "$OUTPUT_FILE" ] || [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <OUTPUT_FILE> <NAMESPACE> [SOPS_CONFIG] [ENV_FILE]"
    exit 1
fi

# Read GitHub App credentials from .env
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE file not found"
    exit 1
fi

source "$ENV_FILE"

if [ -z "$GIT_APP_ID" ] || [ -z "$GIT_APP_INSTALLATION_ID" ] || [ -z "$GIT_APP_PRIVATE_KEY" ]; then
    echo "Error: Missing GitHub App credentials in .env"
    echo "Required: GIT_APP_ID, GIT_APP_INSTALLATION_ID, GIT_APP_PRIVATE_KEY"
    exit 1
fi

# Generate JWT for GitHub App
NOW=$(date +%s)
IAT=$((NOW - 60))
EXP=$((NOW + 600))

HEADER='{"alg":"RS256","typ":"JWT"}'
PAYLOAD="{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GIT_APP_ID}\"}"

HEADER_B64=$(echo -n "$HEADER" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')

SIGNATURE=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -sign <(echo "$GIT_APP_PRIVATE_KEY") | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
JWT="${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"

# Get installation access token
TOKEN_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${GIT_APP_INSTALLATION_ID}/access_tokens")

GITHUB_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: Failed to generate GitHub App token"
    echo "API Response: $TOKEN_RESPONSE"
    exit 1
fi

# Create dockerconfigjson auth string (username:token in base64)
AUTH_STRING=$(echo -n "x-access-token:${GITHUB_TOKEN}" | base64)

# Create dockerconfigjson (single line, no formatting)
DOCKER_CONFIG_JSON="{\"auths\":{\"ghcr.io\":{\"auth\":\"${AUTH_STRING}\"}}}"

# Create secret YAML from template
cat > "$OUTPUT_FILE" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ghcr-pull-secret
  namespace: ${NAMESPACE}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    ${DOCKER_CONFIG_JSON}
EOF

# Encrypt with SOPS
if [ -n "$SOPS_CONFIG" ] && [ -f "$SOPS_CONFIG" ]; then
    sops --config "$SOPS_CONFIG" -e -i "$OUTPUT_FILE"
else
    sops -e -i "$OUTPUT_FILE"
fi

echo "✓ Created: $OUTPUT_FILE"
