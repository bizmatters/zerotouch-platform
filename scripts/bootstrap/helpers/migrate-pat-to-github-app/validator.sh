#!/usr/bin/env bash
# Validator helper - validates GitHub App credentials

export GITHUB_TOKEN=""

validate_github_app() {
    echo "Validating GitHub App credentials..."
    
    # Check required parameters
    if [[ -z "${APP_ID}" ]]; then
        echo "ERROR: GitHub App ID required (--app-id)"
        return 1
    fi
    
    if [[ -z "${INSTALLATION_ID}" ]]; then
        echo "ERROR: Installation ID required (--installation-id)"
        return 1
    fi
    
    if [[ -z "${PRIVATE_KEY_FILE}" ]]; then
        echo "ERROR: Private key file required (--private-key-file)"
        return 1
    fi
    
    # Check private key file exists
    if [[ ! -f "${PRIVATE_KEY_FILE}" ]]; then
        echo "ERROR: Private key file not found: ${PRIVATE_KEY_FILE}"
        return 1
    fi
    
    # Validate private key format
    if ! grep -q "BEGIN RSA PRIVATE KEY" "${PRIVATE_KEY_FILE}"; then
        echo "ERROR: Invalid private key format (expected RSA PRIVATE KEY)"
        return 1
    fi
    
    # Check kubectl is available
    if ! command -v kubectl &> /dev/null; then
        echo "ERROR: kubectl not found"
        return 1
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        echo "ERROR: Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    # Check argocd namespace exists
    if ! kubectl get namespace argocd &> /dev/null; then
        echo "ERROR: ArgoCD namespace not found"
        return 1
    fi
    
    # Test GitHub App token generation
    echo "  Testing GitHub App token generation..."
    
    # Generate JWT for GitHub App
    local header='{"alg":"RS256","typ":"JWT"}'
    local now=$(date +%s)
    local iat=$((now - 60))
    local exp=$((now + 600))
    local payload="{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${APP_ID}\"}"
    
    # Base64 encode (URL-safe)
    local header_b64=$(echo -n "${header}" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    local payload_b64=$(echo -n "${payload}" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    # Sign with private key
    local signature=$(echo -n "${header_b64}.${payload_b64}" | \
        openssl dgst -sha256 -sign "${PRIVATE_KEY_FILE}" | \
        openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    local jwt="${header_b64}.${payload_b64}.${signature}"
    
    # Get installation access token
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens")
    
    GITHUB_TOKEN=$(echo "${response}" | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    
    if [[ -z "${GITHUB_TOKEN}" ]]; then
        echo "ERROR: Failed to generate GitHub App token"
        echo "Response: ${response}"
        return 1
    fi
    
    # Test token with GitHub API
    local user_response=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/user")
    
    if echo "${user_response}" | grep -q "Bad credentials"; then
        echo "ERROR: GitHub App token invalid"
        return 1
    fi
    
    echo "✓ GitHub App credentials valid"
    return 0
}
