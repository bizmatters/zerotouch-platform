#!/bin/bash
set -euo pipefail

# ==============================================================================
# Database Migrations Script
# ==============================================================================
# Runs database migrations using Kubernetes Job
# Used by both local testing and CI workflows
# ==============================================================================

NAMESPACE="${1:-intelligence-deepagents}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

main() {
    log_info "Running database migrations..."
    
    # Read service name from config
    CONFIG_FILE="${SERVICE_ROOT:-$(pwd)}/ci/config.yaml"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        return 1
    fi
    
    SERVICE_NAME=$(yq eval '.service.name' "$CONFIG_FILE")
    if [[ -z "$SERVICE_NAME" || "$SERVICE_NAME" == "null" ]]; then
        log_error "Service name not found in config"
        return 1
    fi
    
    log_info "Using service: $SERVICE_NAME"
    
    # Create ConfigMap with migration files
    kubectl create configmap migration-files -n $NAMESPACE \
        --from-file=migrations/ \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Run migrations using a simple job
    MIGRATION_JOB="migration-job-$(date +%s)"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $MIGRATION_JOB
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: migrate
        image: postgres:15
        env:
        - name: POSTGRES_URI
          valueFrom:
            secretKeyRef:
              name: ${SERVICE_NAME}-db-conn
              key: POSTGRES_URI
        command: ["/bin/bash"]
        args:
        - -c
        - |
          echo "Waiting for PostgreSQL to be ready..."
          # Extract connection details from POSTGRES_URI
          POSTGRES_USER=\$(echo "\$POSTGRES_URI" | sed -n 's|.*://\([^:]*\):.*|\1|p')
          POSTGRES_HOST=\$(echo "\$POSTGRES_URI" | sed -n 's|.*@\([^:/]*\).*|\1|p')
          POSTGRES_PORT=\$(echo "\$POSTGRES_URI" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')
          
          until pg_isready -h "\$POSTGRES_HOST" -p "\$POSTGRES_PORT" -U "\$POSTGRES_USER"; do
            echo "PostgreSQL not ready, waiting..."
            sleep 2
          done
          echo "PostgreSQL is ready, running migrations..."
          
          # Run each migration file in order
          for migration in /migrations/*.up.sql; do
            if [ -f "\$migration" ]; then
              echo "Running migration: \$(basename \$migration)"
              psql "\$POSTGRES_URI" -f "\$migration"
            fi
          done
          
          echo "Migrations completed successfully!"
        volumeMounts:
        - name: migrations
          mountPath: /migrations
      volumes:
      - name: migrations
        configMap:
          name: migration-files
      restartPolicy: Never
  backoffLimit: 0
EOF

    # Wait for migration job to complete
    log_info "Waiting for migration job to complete..."
    kubectl wait --for=condition=complete --timeout=120s job/$MIGRATION_JOB -n $NAMESPACE || {
        log_error "Migration job failed or timed out"
        kubectl logs -l job-name=$MIGRATION_JOB -n $NAMESPACE || true
        return 1
    }
    
    # Show migration logs
    kubectl logs -l job-name=$MIGRATION_JOB -n $NAMESPACE
    
    # Clean up migration job
    kubectl delete job $MIGRATION_JOB -n $NAMESPACE --ignore-not-found=true
    
    log_success "Database migrations completed"
}

main "$@"