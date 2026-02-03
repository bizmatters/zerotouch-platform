#!/usr/bin/env bash
# Updater helper - updates ArgoCD repository credentials

update_argocd_credentials() {
    echo "Updating ArgoCD repository credentials..."
    
    # Read private key
    local private_key=$(cat "${PRIVATE_KEY_FILE}")
    
    # Create GitHub App credentials secret
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: argocd-github-app-creds
  namespace: argocd
type: Opaque
stringData:
  appID: "${APP_ID}"
  installationID: "${INSTALLATION_ID}"
  privateKey: |
$(echo "${private_key}" | sed 's/^/    /')
EOF
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: Failed to create GitHub App credentials secret"
        return 1
    fi
    
    echo "  ✓ GitHub App credentials secret created"
    
    # Update repository credentials to use GitHub App
    # Note: This assumes repository secrets exist with label argocd.argoproj.io/secret-type=repository
    
    local repo_secrets=$(kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=repository -o name)
    
    if [[ -z "${repo_secrets}" ]]; then
        echo "  WARNING: No repository secrets found to update"
        echo "  You may need to manually configure ArgoCD repository credentials"
        return 0
    fi
    
    for secret in ${repo_secrets}; do
        local secret_name=$(echo "${secret}" | cut -d'/' -f2)
        echo "  Updating ${secret_name}..."
        
        # Get current repository URL
        local repo_url=$(kubectl get secret "${secret_name}" -n argocd -o jsonpath='{.data.url}' | base64 -d)
        
        # Create updated secret with GitHub App credentials
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${repo_url}
  githubAppID: "${APP_ID}"
  githubAppInstallationID: "${INSTALLATION_ID}"
  githubAppPrivateKey: |
$(echo "${private_key}" | sed 's/^/    /')
EOF
        
        if [[ $? -eq 0 ]]; then
            echo "    ✓ Updated ${secret_name}"
        else
            echo "    ERROR: Failed to update ${secret_name}"
            return 1
        fi
    done
    
    echo "✓ ArgoCD credentials updated to use GitHub App"
    return 0
}
