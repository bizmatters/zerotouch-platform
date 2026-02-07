#!/bin/bash
# Update tenant configuration and push to private repository
#
# Usage:
#   ./helpers/update-tenant-config.sh <FILE_PATH> <COMMIT_MESSAGE> [CACHE_DIR]

set -e

FILE_PATH="$1"
COMMIT_MESSAGE="${2:-Update tenant configuration}"
CACHE_DIR_PARAM="$3"

if [[ -z "$FILE_PATH" ]]; then
    echo "Error: File path required" >&2
    echo "Usage: $0 <file-path> [commit-message] [cache-dir]" >&2
    exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
    echo "Error: File not found: $FILE_PATH" >&2
    exit 1
fi

# Use provided cache directory or calculate it
if [[ -n "$CACHE_DIR_PARAM" ]]; then
    CACHE_DIR="$CACHE_DIR_PARAM"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Find repository root by looking for .git directory
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$SCRIPT_DIR" && while [[ ! -d .git && $(pwd) != "/" ]]; do cd ..; done; pwd))"
    CACHE_DIR="$REPO_ROOT/.tenants-cache"
fi

# Verify file is in cache directory
CACHE_DIR_REAL=$(realpath "$CACHE_DIR")
FILE_PATH_REAL=$(realpath "$FILE_PATH")

if [[ ! "$FILE_PATH_REAL" =~ ^"$CACHE_DIR_REAL" ]]; then
    echo "Error: File must be in tenant cache directory" >&2
    echo "Cache dir: $CACHE_DIR_REAL" >&2
    echo "File path: $FILE_PATH_REAL" >&2
    exit 1
fi

if [[ ! -d "$CACHE_DIR/.git" ]]; then
    echo "Error: Tenant cache not initialized" >&2
    exit 1
fi

cd "$CACHE_DIR"

# Check if there are changes
if git diff --quiet "$FILE_PATH"; then
    echo "No changes to commit" >&2
    return 0
fi

echo "Committing changes to tenant repository..." >&2

# Configure git if needed
git config user.email "bootstrap@zerotouch.dev" 2>/dev/null || true
git config user.name "ZeroTouch Bootstrap" 2>/dev/null || true

# Commit and push
BRANCH_NAME="rescue-mode-$(date +%Y%m%d-%H%M%S)"
git checkout -b "$BRANCH_NAME" --quiet
git add "$FILE_PATH"
git commit -m "$COMMIT_MESSAGE" --quiet

# Regenerate GitHub App token if using GitHub App auth
if [[ -n "$GIT_APP_ID" && -n "$GIT_APP_INSTALLATION_ID" && -n "$GIT_APP_PRIVATE_KEY" ]]; then
    echo "Regenerating GitHub App token for push..." >&2
    
    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))
    
    HEADER='{"alg":"RS256","typ":"JWT"}'
    PAYLOAD="{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${GIT_APP_ID}\"}"
    
    HEADER_B64=$(echo -n "$HEADER" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    PAYLOAD_B64=$(echo -n "$PAYLOAD" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    
    SIGNATURE=$(echo -n "${HEADER_B64}.${PAYLOAD_B64}" | openssl dgst -sha256 -sign <(echo "$GIT_APP_PRIVATE_KEY") | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    JWT="${HEADER_B64}.${PAYLOAD_B64}.${SIGNATURE}"
    
    GITHUB_TOKEN=$(curl -s -X POST \
        -H "Authorization: Bearer $JWT" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${GIT_APP_INSTALLATION_ID}/access_tokens" | \
        jq -r '.token // empty')
    
    if [[ -n "$GITHUB_TOKEN" ]]; then
        # Update remote URL with fresh token
        REMOTE_URL=$(git remote get-url origin)
        REPO_PATH=$(echo "$REMOTE_URL" | sed 's|https://.*@github.com/||' | sed 's|https://github.com/||')
        git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO_PATH}"
    fi
fi

# Push branch
git push origin "$BRANCH_NAME" --quiet 2>&1 || {
    echo "Error: Failed to push branch to tenant repository" >&2
    echo "Branch: $BRANCH_NAME" >&2
    git remote -v >&2
    exit 1
}

# Create PR
if [[ -n "$GITHUB_TOKEN" ]]; then
    REPO_OWNER=$(echo "$REPO_PATH" | cut -d'/' -f1)
    REPO_NAME=$(echo "$REPO_PATH" | cut -d'/' -f2 | sed 's/.git$//')
    
    PR_RESPONSE=$(curl -s -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls" \
        -d "{\"title\":\"${COMMIT_MESSAGE}\",\"head\":\"${BRANCH_NAME}\",\"base\":\"main\",\"body\":\"Automated update from bootstrap script\"}")
    
    PR_URL=$(echo "$PR_RESPONSE" | jq -r '.html_url // empty')
    
    if [[ -n "$PR_URL" ]]; then
        echo "✓ Pull request created: $PR_URL" >&2
    else
        echo "Error: Failed to create pull request" >&2
        echo "$PR_RESPONSE" >&2
        exit 1
    fi
else
    echo "⚠ GitHub token not available, cannot create PR" >&2
    exit 1
fi

echo "✓ Changes pushed to tenant repository" >&2
