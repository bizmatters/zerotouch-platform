FROM kindest/node:v1.31.0

# Copy the source of truth
COPY platform/versions.yaml /tmp/versions.yaml

# Start containerd and pre-pull images (excluding preview-only components)
RUN set -x && \
    # Start containerd in background with privileged mode
    containerd > /tmp/containerd.log 2>&1 & \
    CONTAINERD_PID=$! && \
    # Wait for containerd to be ready
    for i in $(seq 1 30); do \
        if ctr version >/dev/null 2>&1; then break; fi; \
        sleep 1; \
    done && \
    # Extract and pull images (exclude components not used or problematic in preview)
    grep "image:" /tmp/versions.yaml | \
    grep -v "talos" | \
    grep -v "cilium" | \
    grep -v "cloudnative-pg" | \
    grep -v "kagent" | \
    grep -v "qdrant" | \
    sed 's/.*image: //' | tr -d '"' | while read img; do \
        echo "Pre-pulling $img..." && \
        ctr -n k8s.io images pull "$img" || echo "Failed to pull $img"; \
    done && \
    # Stop containerd
    kill $CONTAINERD_PID || true && \
    wait $CONTAINERD_PID || true && \
    # Clean up
    rm /tmp/versions.yaml

LABEL description="ZeroTouch Preview Node - Core Platform Images Cached"
