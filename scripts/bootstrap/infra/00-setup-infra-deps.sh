#!/bin/bash
set -euo pipefail

# 00-setup-infra-deps.sh - Setup infrastructure dependencies for OIDC

echo "Setting up infrastructure dependencies..."

# Check if AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found. Installing..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
fi

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    echo "❌ OpenSSL not found. Installing..."
    sudo apt-get update && sudo apt-get install -y openssl
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    echo "❌ jq not found. Installing..."
    sudo apt-get update && sudo apt-get install -y jq
fi

echo "✅ All infrastructure dependencies are ready"
echo "AWS CLI version: $(aws --version)"
echo "OpenSSL version: $(openssl version)"
echo "jq version: $(jq --version)"