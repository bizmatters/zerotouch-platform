
### 2. Preview Architecture (PRs / CI Testing)
This document outlines the declarative flow used for ephemeral testing environments.

**File:** `docs/architecture/secrets-management-preview.md`

```markdown
# Platform Secret Management: Preview Architecture
**Scope:** Pull Requests (PRs), Local Testing (Kind), CI Pipelines

## Executive Summary
Preview environments now use the **same declarative pattern** as production environments.
Secrets are synced to AWS SSM under `/zerotouch/pr/*` paths, then fetched by External Secrets Operator.
This ensures consistency across all environments and provides audit trails.

## Architecture Wireframe

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                             PREVIEW SECRET LIFECYCLE                                │
└─────────────────────────────────────────────────────────────────────────────────────┘

   1. PREPARATION                       2. SYNC TO SSM
   (GitHub Secrets)                     (deploy.sh)
┌───────────────────────────┐        ┌───────────────────────────┐
│ Service Repo              │        │ CI Runner (GitHub)        │
│ ├── .github/workflows/    │        │                           │
│ │   main-pipeline.yml     │ Blob   │ 1. prepare-secrets job    │
│ │   prepare-secrets:      │ ─────> │ 2. sync-secrets-to-ssm.sh │
│ │     PR_DATABASE_URL     │        │ 3. Push to SSM            │
│ │     PR_OPENAI_API_KEY   │        └─────────────┬─────────────┘
└───────────────────────────┘                      │
                                                   │ Synced to SSM
                                                   ▼
                                        ┌──────────────────────────┐
                                        │ AWS SSM Parameter Store  │
                                        │ /zerotouch/pr/service/*  │
                                        └─────────────┬────────────┘
                                                      │
   3. DECLARATIVE FETCH                               │ ESO Fetches
   (ExternalSecrets + Kustomize)                      │
┌────────────────────────────────────────────────────┼────────────┐
│ KIND CLUSTER (Ephemeral Namespace)                 │            │
├─────────────────────────────────────────────────────┼────────────┤
│                                                     ▼            │
│    ┌───────────────────┐       ┌──────────────────────────┐    │
│    │ ExternalSecret    │ ────> │ K8s Secret (Opaque)      │    │
│    │ (PR Overlay)      │ ESO   │ envFrom: secretRef       │    │
│    │ /zerotouch/pr/*   │       └──────────────────────────┘    │
│    └───────────────────┘                                        │
│                                                                 │
│    * External Secrets Operator fetches from SSM                │
│    * Kustomize patches apply PR-specific paths                 │
└─────────────────────────────────────────────────────────────────┘
```

## The Workflow Steps

### 1. Secret Preparation (`main-pipeline.yml`)
The service workflow prepares secrets as KEY=VALUE blob:

```yaml
prepare-secrets:
  outputs:
    pr_blob: ${{ steps.pr.outputs.blob }}
  steps:
    - id: pr
      run: |
        echo "DATABASE_URL=${{ secrets.PR_DATABASE_URL }}" >> $GITHUB_OUTPUT
        echo "OPENAI_API_KEY=${{ secrets.PR_OPENAI_API_KEY }}" >> $GITHUB_OUTPUT
```

### 2. Sync to SSM (`deploy.sh`)
The deploy script syncs secrets to SSM before applying manifests:

```bash
sync-secrets-to-ssm.sh "${SERVICE_NAME}" "pr" "${PR_SECRETS_BLOB}"
```

This creates parameters at `/zerotouch/pr/{service}/{key}` with:
- Hyphen validation (enforces underscores)
- Lowercase normalization
- SecureString encryption

### 3. Declarative Application
ExternalSecrets are applied via kustomize with PR overlay patches:

```bash
kubectl kustomize overlays/pr | kubectl apply -f -
```

**Base manifest** uses `_ENV_` placeholder:
```yaml
remoteRef:
  key: /zerotouch/_ENV_/service/database_url
```

**PR patch** overrides with actual path:
```yaml
remoteRef:
  key: /zerotouch/pr/service/database_url
```

### 4. Force Sync
After applying ExternalSecrets, immediate sync is triggered:

```bash
kubectl annotate externalsecret -l zerotouch.io/managed=true force-sync=$(date +%s)
kubectl wait --for=condition=Ready externalsecret --timeout=60s
```

## Key Differences from Production

| Feature | Production (Main) | Preview (PR) |
| :--- | :--- | :--- |
| **Mechanism** | GitOps + External Secrets Operator | Same (ESO) |
| **Source** | AWS SSM `/zerotouch/prod/*` | AWS SSM `/zerotouch/pr/*` |
| **Persistence** | Permanent | Ephemeral (cleaned up) |
| **Latency** | 10s - 60s (ESO Sync) | Same (with force-sync) |
| **Auditing** | CloudTrail Logs | CloudTrail Logs |
| **Overlay** | prod patches | pr patches |

## Benefits of Declarative Approach
1. **Consistency:** Same pattern across all environments
2. **Audit Trail:** All secret access logged in CloudTrail
3. **Security:** Secrets encrypted in SSM, not in CI logs
4. **Testability:** PR tests use real ExternalSecrets flow
5. **Maintainability:** Single code path for all environments
```