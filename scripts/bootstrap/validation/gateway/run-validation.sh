#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building validation image..."
docker build -t validation-test-endpoint:latest .

echo "Loading image into cluster..."
kind load docker-image validation-test-endpoint:latest --name zerotouch-preview

echo "Applying validation job..."
kubectl apply -f validation-job.yaml

echo "Waiting for job to complete..."
kubectl wait --for=condition=complete job/validate-test-endpoint -n platform-identity --timeout=120s

echo "Getting job results..."
kubectl logs job/validate-test-endpoint -n platform-identity

echo "Cleaning up..."
kubectl delete job validate-test-endpoint -n platform-identity