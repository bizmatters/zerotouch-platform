# PR Environment Secret Management

## Overview
PR environment uses KSOPS (SOPS + Age encryption) for secret management, applied via ArgoCD.

## Secret Flow

### 1. Platform Secrets (Bootstrap)
- Stored in `bootstrap/argocd/overlays/preview/secrets/`
- Encrypted with SOPS using Age key
- Decrypted by `create-dot-env.sh` using `SOPS_AGE_KEY_PR`
- Written to `.env` with `PR_` prefix (e.g., `PR_DATABASE_URL`)
- Core secrets unprefixed: `GIT_APP_ID`, `TENANTS_REPO_NAME`, `ORG_NAME`

### 2. Tenant Service Secrets (Runtime)
- Stored in `tenants/{service}/overlays/pr/secrets/*.secret.yaml`
- Encrypted with SOPS using Age key
- Decrypted by ArgoCD with KSOPS plugin
- Applied as Kubernetes secrets to namespace
- Mounted to pods via `secret1Name`, `secret2Name`, etc.

## Kustomization Structure

**Include** `secrets/` directory in kustomization for ArgoCD:
```yaml
# ✅ CORRECT - KSOPS secrets decrypted by ArgoCD
resources:
  - secrets/
  - deployment.yaml
  - migration-job.yaml
```

**Note**: Direct `kubectl apply -k` will fail (no KSOPS plugin). Secrets applied via ArgoCD only.

## Deploy Script Behavior
1. Applies kustomization: `kubectl apply -k overlays/pr` (deployment + migration only)
2. ArgoCD syncs and decrypts KSOPS secrets separately
3. Secrets available to pods as Kubernetes secrets

## Key Differences from Production
- Production: KSOPS secrets in tenant repo, decrypted by ArgoCD
- Preview: Same approach - KSOPS secrets decrypted by ArgoCD
- CI kubectl doesn't apply secrets directly (ArgoCD handles it)

