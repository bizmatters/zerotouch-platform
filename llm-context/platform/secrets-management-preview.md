
# Platform Secret Management: Preview Architecture
**Scope:** Pull Requests (PRs), CI Testing (Kind Clusters)

## Executive Summary
Preview environments use the **same declarative pattern** as production, with secrets synced to `/zerotouch/pr/*` in AWS SSM. This ensures PR tests validate the actual production secret flow, catching integration issues early.

## Architecture Flow

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                             PREVIEW SECRET LIFECYCLE                                │
└─────────────────────────────────────────────────────────────────────────────────────┘

   1. SECRET STORAGE                    2. MANIFEST DEFINITION
   (AWS SSM - Values)                   (Service Repo - Structure)
┌───────────────────────────┐        ┌───────────────────────────┐
│ AWS SSM Parameter Store   │        │ service-repo/platform/    │
│                           │        │ service/                  │
│ /zerotouch/pr/service/    │        │                           │
│   database_url            │        │ base/external-secrets/    │
│   openai_api_key          │        │   db-es.yaml              │
│                           │        │   key: /.../_ENV_/...     │
│ (Ephemeral - cleaned up)  │        │                           │
│ (SecureString encrypted)  │        │ overlays/pr/              │
└─────────────┬─────────────┘        │   patches/secrets.yaml    │
              │                      │   key: /.../pr/...        │
              │ ESO Fetches          └─────────────┬─────────────┘
              │                                    │
              │                                    │ kubectl apply
              ▼                                    ▼
┌────────────────────────────────────────────────────────────────┐
│ KIND CLUSTER (Ephemeral)                                       │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ExternalSecret (CRD)                                          │
│    ↓ (ESO reconciles)                                          │
│  K8s Secret (Opaque)                                           │
│    ↓ (mounted)                                                 │
│  Pod (Test Runner - envFrom: secretRef)                        │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Secret Storage (AWS SSM)
- **Path Pattern:** `/zerotouch/pr/{service}/{key}`
- **Encryption:** SecureString type
- **Lifecycle:** Ephemeral - created during CI, cleaned up after PR
- **Example:** `/zerotouch/pr/identity-service/database_url`

### 2. Base Manifests (Service Repo)
ExternalSecrets live in **service repository** (not tenant repo):

```yaml
# service-repo/platform/service/base/external-secrets/db-es.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: service-db
  labels:
    zerotouch.io/managed: "true"
spec:
  secretStoreRef:
    name: aws-parameter-store
    kind: ClusterSecretStore
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: /zerotouch/_ENV_/service/database_url
```

### 3. PR Overlay (Kustomize Patches)
Patches inject `pr` environment:

```yaml
# service-repo/platform/service/overlays/pr/patches/secrets-patch.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: service-db
spec:
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: /zerotouch/pr/service/database_url  # Actual path
```

### 4. Deployment Flow
1. **Sync to SSM:** Deploy script uses `sync-secrets-to-ssm.sh` to push PR secrets to `/zerotouch/pr/*`
2. **Apply Manifests:** Deploy script uses `kubectl kustomize` to merge base + PR overlay
3. **Force Refresh:** Deploy script uses `force-secret-refresh.sh` to annotate ExternalSecrets
4. **ESO Fetch:** External Secrets Operator creates Kubernetes secrets
5. **Pod Mount:** Test pods consume via `envFrom: secretRef`

**Scripts:**
- `zerotouch-platform/scripts/release/template/sync-secrets-to-ssm.sh`
- `zerotouch-platform/scripts/release/force-secret-refresh.sh`
- `zerotouch-platform/scripts/bootstrap/preview/tenants/scripts/deploy.sh`

**Workflows:**
- `zerotouch-platform/.github/workflows/ci-test.yml`

### 5. SecretStore Configuration
ESO requires ClusterSecretStore to authenticate with AWS:

```yaml
# Deployed by platform bootstrap
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-parameter-store
spec:
  provider:
    aws:
      service: ParameterStore
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**Auth Method:** IRSA (IAM Roles for Service Accounts) - no credentials in cluster

## Key Patterns

### Placeholder Pattern
Base manifests use `_ENV_` placeholder to prevent accidental cross-environment access:
```yaml
key: /zerotouch/_ENV_/service/database_url
```
If overlay fails to patch, ESO attempts to fetch `/zerotouch/_ENV_/...` and fails immediately.

### Label-Based Sync
All managed ExternalSecrets require label:
```yaml
metadata:
  labels:
    zerotouch.io/managed: "true"
```
Enables scoped force-sync without affecting platform secrets (ArgoCD, ESO).

### Key Normalization
- **GitHub Secrets:** `PR_DATABASE_URL` (uppercase with underscores)
- **SSM Path:** `/zerotouch/pr/service/database_url` (lowercase)
- **Sync Script:** Automatically converts and validates (rejects hyphens)

## Service Requirements

### Repository Structure
```
service-repo/
├── .github/workflows/
│   └── main-pipeline.yml           # Calls ci-test.yml
├── platform/
│   └── service-name/
│       ├── base/
│       │   ├── external-secrets/
│       │   │   └── *.yaml          # _ENV_ placeholder
│       │   └── kustomization.yaml
│       └── overlays/
│           └── pr/
│               ├── patches/
│               │   └── secrets-patch.yaml  # pr paths
│               └── kustomization.yaml
└── scripts/ci/
    └── in-cluster-test.sh          # Local dev testing
```

### GitHub Secrets Naming Convention
```
PR_DATABASE_URL
PR_OPENAI_API_KEY
PR_ANTHROPIC_API_KEY
```
**Pattern:** `PR_` prefix + `UPPER_CASE_UNDERSCORE` (no hyphens)

### Local Development
Set same env variables in `.env` and run `scripts/ci/in-cluster-test.sh` - identical to PR flow.

## Security Model

| Layer | Protection |
|-------|-----------|
| **Storage** | SSM SecureString encryption at rest |
| **Access** | IAM roles with least-privilege policies |
| **Audit** | CloudTrail logs all SSM parameter access |
| **Isolation** | Separate `/pr/` namespace prevents cross-env leaks |
| **Lifecycle** | Ephemeral - deleted after PR closes |

## Key Differences from Production

| Aspect | Production | Preview (PR) |
|--------|-----------|--------------|
| **Manifest Location** | `zerotouch-tenants/` repo | `service-repo/platform/` |
| **Deployment** | ArgoCD GitOps | Direct `kubectl apply` |
| **SSM Path** | `/zerotouch/{dev\|staging\|prod}/*` | `/zerotouch/pr/*` |
| **Cluster** | Persistent (Talos) | Ephemeral (Kind) |
| **Lifecycle** | Permanent | Deleted with PR |

## Troubleshooting

### Secrets Not Available in Pods
```bash
# 1. Check ExternalSecret status
kubectl get externalsecret -n namespace
kubectl describe externalsecret service-db -n namespace

# 2. Verify SSM parameter exists
aws ssm get-parameter --name /zerotouch/pr/service/database_url

# 3. Check ESO operator logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### Kustomize Patch Not Applied
```bash
# Test kustomize build locally
kubectl kustomize platform/service/overlays/pr

# Verify _ENV_ was replaced
kubectl kustomize platform/service/overlays/pr | grep "key:"
```

### Force-Sync Not Triggering
```bash
# Check label exists
kubectl get externalsecret -n namespace -l zerotouch.io/managed=true

# Manually trigger sync
kubectl annotate externalsecret service-db -n namespace \
  force-sync=$(date +%s) --overwrite
```

## Benefits

1. **Production Parity:** PR tests validate actual ExternalSecrets flow
2. **Early Detection:** Catches secret integration issues before merge
3. **Audit Trail:** All access logged in CloudTrail
4. **Security:** Secrets encrypted in SSM, never in CI logs
5. **Consistency:** Single pattern across all environments