#!/bin/bash
set -euo pipefail

# Requirement: yq (https://github.com/mikefarah/yq)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/platform/versions.yaml"

echo "Syncing ArgoCD manifests with platform/versions.yaml..."

# Verify yq is installed
if ! command -v yq &> /dev/null; then
    echo "Error: yq is required but not installed"
    echo "Install: https://github.com/mikefarah/yq"
    exit 1
fi

# Verify versions file exists
if [ ! -f "$VERSIONS_FILE" ]; then
    echo "Error: versions.yaml not found at $VERSIONS_FILE"
    exit 1
fi

# Helper function to update only if changed
update_if_changed() {
    local file=$1
    local current_val=$(yq "$2" "$file")
    local new_val=$3
    
    if [ "$current_val" != "$new_val" ]; then
        yq -i "$2 = \"$new_val\"" "$file"
        return 0
    fi
    return 1
}

# 1. Update Crossplane
VER=$(yq '.components.crossplane.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/01-crossplane.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ Crossplane -> $VER (updated)"
else
    echo "✓ Crossplane -> $VER (unchanged)"
fi

# 2. Update External Secrets
VER=$(yq '.components.external_secrets.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/00-eso.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ ESO -> $VER (updated)"
else
    echo "✓ ESO -> $VER (unchanged)"
fi

# 3. Update Cert Manager
VER=$(yq '.components.cert_manager.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/01-cert-manager.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ Cert Manager -> $VER (updated)"
else
    echo "✓ Cert Manager -> $VER (unchanged)"
fi

# 4. Update CNPG
VER=$(yq '.components.cnpg.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/02-cnpg.yaml" ".spec.source.targetRevision" "$VER"; then
    PG_IMG=$(yq '.components.cnpg.postgres_image' $VERSIONS_FILE)
    echo "✓ CNPG -> $VER (updated, Postgres: $PG_IMG)"
else
    echo "✓ CNPG -> $VER (unchanged)"
fi

# 5. Update NATS
VER=$(yq '.components.nats.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/05-nats.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ NATS -> $VER (updated)"
else
    echo "✓ NATS -> $VER (unchanged)"
fi

# 6. Update KEDA
VER=$(yq '.components.keda.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/04-keda.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ KEDA -> $VER (updated)"
else
    echo "✓ KEDA -> $VER (unchanged)"
fi

# 7. Update kagent
VER=$(yq '.components.kagent.chart_version' $VERSIONS_FILE)
if update_if_changed "${REPO_ROOT}/bootstrap/argocd/base/04-kagent.yaml" ".spec.source.targetRevision" "$VER"; then
    echo "✓ kagent -> $VER (updated)"
else
    echo "✓ kagent -> $VER (unchanged)"
fi

# 8. Update ArgoCD version in install script
ARGOCD_VER=$(yq '.components.argocd.version' $VERSIONS_FILE)
CURRENT_ARGOCD=$(grep '^ARGOCD_VERSION=' ${REPO_ROOT}/scripts/bootstrap/install/09-install-argocd.sh | cut -d'"' -f2)
if [ "$CURRENT_ARGOCD" != "$ARGOCD_VER" ]; then
    sed -i.bak "s/ARGOCD_VERSION=\".*\"/ARGOCD_VERSION=\"$ARGOCD_VER\"/" ${REPO_ROOT}/scripts/bootstrap/install/09-install-argocd.sh
    rm ${REPO_ROOT}/scripts/bootstrap/install/09-install-argocd.sh.bak
    echo "✓ ArgoCD -> $ARGOCD_VER (updated)"
else
    echo "✓ ArgoCD -> $ARGOCD_VER (unchanged)"
fi

# 9. Update Talos version in install script
TALOS_VER=$(yq '.components.talos.version' $VERSIONS_FILE)
CURRENT_TALOS=$(grep '^TALOS_VERSION=' ${REPO_ROOT}/scripts/bootstrap/install/03-install-talos.sh | cut -d'"' -f2)
if [ "$CURRENT_TALOS" != "$TALOS_VER" ]; then
    sed -i.bak "s/^TALOS_VERSION=\".*\"/TALOS_VERSION=\"$TALOS_VER\"/" ${REPO_ROOT}/scripts/bootstrap/install/03-install-talos.sh
    rm ${REPO_ROOT}/scripts/bootstrap/install/03-install-talos.sh.bak
    echo "✓ Talos -> $TALOS_VER (updated)"
else
    echo "✓ Talos -> $TALOS_VER (unchanged)"
fi

# 10. Update Cilium operator image in template
CILIUM_IMG=$(yq '.components.cilium.operator_image' $VERSIONS_FILE)
CURRENT_CILIUM=$(grep 'image: "quay.io/cilium/operator-generic:' ${REPO_ROOT}/bootstrap/talos/templates/cilium/08-operator-deployment.yaml | sed 's/.*image: "\(.*\)"/\1/')
if [ "$CURRENT_CILIUM" != "$CILIUM_IMG" ]; then
    sed -i.bak "s|image: \"quay.io/cilium/operator-generic:.*\"|image: \"$CILIUM_IMG\"|" ${REPO_ROOT}/bootstrap/talos/templates/cilium/08-operator-deployment.yaml
    rm ${REPO_ROOT}/bootstrap/talos/templates/cilium/08-operator-deployment.yaml.bak
    echo "✓ Cilium -> $(yq '.components.cilium.version' $VERSIONS_FILE) (updated)"
else
    echo "✓ Cilium -> $(yq '.components.cilium.version' $VERSIONS_FILE) (unchanged)"
fi

echo ""
echo "Sync complete. Commit changes to bootstrap/argocd/base/ and scripts/."
