#!/bin/bash
set -euo pipefail

# ==============================================================================
# Run Test Job Script (Test Runner Pattern)
# ==============================================================================
# Creates Kubernetes test jobs using test-runner architecture
# Usage: ./run-test-job.sh <test-path> <test-name> <timeout> <image-tag>
# ==============================================================================

TEST_PATH="${1:-}"
TEST_NAME="${2:-}"
TIMEOUT="${3:-600}"
IMAGE_TAG="${4:-}"

# Validate arguments
if [[ -z "$TEST_PATH" ]] || [[ -z "$TEST_NAME" ]] || [[ -z "$IMAGE_TAG" ]]; then
    echo "Usage: $0 <test-path> <test-name> <timeout> <image-tag>"
    exit 1
fi

# Required environment variables
SERVICE_NAME="${SERVICE_NAME:-}"
NAMESPACE="${NAMESPACE:-}"
SERVICE_ROOT="${SERVICE_ROOT:-$(pwd)}"

if [[ -z "$SERVICE_NAME" ]] || [[ -z "$NAMESPACE" ]]; then
    echo "Error: SERVICE_NAME and NAMESPACE environment variables required"
    exit 1
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[TEST-JOB]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[TEST-JOB]${NC} $*" >&2; }
log_error() { echo -e "${RED}[TEST-JOB]${NC} $*" >&2; }

# Generate job name
JOB_NAME="${TEST_NAME}-$(date +%s)"

log_info "Creating test job: $JOB_NAME"
log_info "Test: $TEST_PATH"
log_info "Image: $IMAGE_TAG"

# Get test-runner path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_RUNNER_DIR="$SCRIPT_DIR"

# Create test job manifest
cat > /tmp/test-job-${JOB_NAME}.yaml <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${SERVICE_NAME}-tests
    test-type: integration
    test-suite: ${TEST_NAME}
spec:
  template:
    metadata:
      labels:
        app: ${SERVICE_NAME}-tests
        test-type: integration
        test-suite: ${TEST_NAME}
    spec:
      containers:
      - name: test-runner
        image: ${IMAGE_TAG}
        workingDir: /app
        command: ["/test-runner/test-runner.sh"]
        args: ["exec", "--config", "ci/config.yaml", "--test", "${TEST_PATH}", "--artifacts", "/app/artifacts"]
        envFrom:
        - secretRef:
            name: database-url
            optional: true
        - secretRef:
            name: ${SERVICE_NAME}-cache-conn
            optional: true
        env:
        - name: TEST_ENV
          value: "integration"
        - name: SERVICE_NAME
          value: "${SERVICE_NAME}"
        - name: NAMESPACE
          value: "${NAMESPACE}"
        - name: NODE_ENV
          value: "test"
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1.5Gi"
            cpu: "1000m"
        volumeMounts:
        - name: artifacts
          mountPath: /app/artifacts
        - name: test-runner
          mountPath: /test-runner
          readOnly: true
      volumes:
      - name: artifacts
        emptyDir: {}
      - name: test-runner
        configMap:
          name: test-runner-scripts
          defaultMode: 0755
      restartPolicy: Never
      serviceAccountName: default
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
EOF

# Create ConfigMap with test-runner scripts
log_info "Creating test-runner ConfigMap..."
kubectl create configmap test-runner-scripts \
  --from-file=test-runner.sh=${TEST_RUNNER_DIR}/test-runner.sh \
  --from-file=logger.sh=${TEST_RUNNER_DIR}/lib/logger.sh \
  --from-file=config-parser.sh=${TEST_RUNNER_DIR}/lib/config-parser.sh \
  --from-file=language-detector.sh=${TEST_RUNNER_DIR}/lib/language-detector.sh \
  --from-file=node-adapter.sh=${TEST_RUNNER_DIR}/adapters/node-adapter.sh \
  --from-file=python-adapter.sh=${TEST_RUNNER_DIR}/adapters/python-adapter.sh \
  --from-file=go-adapter.sh=${TEST_RUNNER_DIR}/adapters/go-adapter.sh \
  -n ${NAMESPACE} \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply job
log_info "Applying test job..."
kubectl apply -f /tmp/test-job-${JOB_NAME}.yaml

echo "🚀 Starting test job: $JOB_NAME"
echo "⏳ Waiting for job to complete (timeout: ${TIMEOUT}s)..."
echo "📊 Namespace: $NAMESPACE"
echo ""

# Wait for job completion
ELAPSED=0
POLL_INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
    JOB_STATUS=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
    JOB_FAILED=$(kubectl get job $JOB_NAME -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
    
    if [ "$JOB_STATUS" = "True" ]; then
        echo "✅ Job completed successfully after $((ELAPSED))s"
        break
    elif [ "$JOB_FAILED" = "True" ]; then
        echo "❌ Job failed after $((ELAPSED))s"
        break
    fi
    
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Get pod logs
POD_NAME=$(kubectl get pods -n $NAMESPACE -l job-name=$JOB_NAME -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD_NAME" ]; then
    echo ""
    echo "=== TEST EXECUTION LOGS ==="
    kubectl logs $POD_NAME -n $NAMESPACE || echo "Could not retrieve logs"
    echo "=== END LOGS ==="
fi

# Check final status
if [ "$JOB_FAILED" = "True" ]; then
    log_error "Test job failed"
    exit 1
elif [ "$JOB_STATUS" != "True" ]; then
    log_error "Test job did not complete within timeout"
    exit 1
fi

log_success "✅ Test completed successfully"
exit 0
