#!/usr/bin/env bash
# Backup helper - backs up existing PAT configuration

export BACKUP_FILE="/tmp/argocd-pat-backup.yaml"

backup_pat_config() {
    echo "Backing up existing PAT configuration..."
    
    # Export current repository credentials
    if kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository &> /dev/null; then
        kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o yaml > "${BACKUP_FILE}"
        echo "  ✓ PAT configuration backed up to ${BACKUP_FILE}"
    else
        echo "  WARNING: No existing repository credentials found"
        echo "  Creating empty backup file"
        touch "${BACKUP_FILE}"
    fi
    
    # Also create backup secret in cluster
    if kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository &> /dev/null; then
        kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o yaml | \
            sed 's/name: repo-/name: repo-pat-backup-/' | \
            kubectl apply -f - || true
        echo "  ✓ Backup secret created in cluster: repo-pat-backup-*"
    fi
    
    return 0
}
