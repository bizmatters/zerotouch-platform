#!/bin/bash
set -euo pipefail

# 00-setup-infra-deps.sh - Setup infrastructure dependencies for OIDC

echo "Setting up infrastructure dependencies..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Installing..."
    curl -LO "https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ helm not found. Installing..."
    export DESIRED_VERSION=v3.13.0
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

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

# Check if age is available
if ! command -v age &> /dev/null; then
    echo "❌ age not found. Installing..."
    AGE_VERSION=1.1.1
    curl -Lo age.tar.gz "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz"
    tar xf age.tar.gz
    sudo mv age/age age/age-keygen /usr/local/bin/
    rm -rf age age.tar.gz
fi

# Check if sops is available
if ! command -v sops &> /dev/null; then
    echo "❌ sops not found. Installing..."
    SOPS_VERSION=3.8.1
    curl -Lo sops "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
    chmod +x sops
    sudo mv sops /usr/local/bin/
fi

echo "✅ All infrastructure dependencies are ready"
echo "kubectl version: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
echo "helm version: $(helm version --short 2>/dev/null || echo 'installed')"
echo "AWS CLI version: $(aws --version)"
echo "OpenSSL version: $(openssl version)"
echo "jq version: $(jq --version)"
echo "age version: $(age --version)"
echo "sops version: $(sops --version)"