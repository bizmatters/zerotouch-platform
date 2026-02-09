# Platform Secret Management: Production Architecture
**Scope:** Development, Staging, Production Environments

## Executive Summary
Production secrets follow a **declarative GitOps pattern** with environment-specific overlays. Secrets are stored in AWS SSM Parameter Store and fetched by External Secrets Operator into Kubernetes. The architecture separates secret values (SSM) from secret definitions (Git), ensuring security and auditability.

## Architecture Flow

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           PRODUCTION SECRET LIFECYCLE                               │
└─────────────────────────────────────────────────────────────────────────────────────┘

   1. SECRET STORAGE                    2. MANIFEST DEFINITION
   (AWS SSM - Values)                   (Git - Structure)
┌───────────────────────────┐        ┌───────────────────────────┐
│ AWS SSM Parameter Store   │        │ zerotouch-tenants/        │
│                           │        │ tenants/service/          │
│ /zerotouch/dev/service/   │        │                           │
│   database_url            │        │ base/external-secrets/    │
│   openai_api_key          │        │   db-es.yaml              │
│                           │        │   key: /.../_ENV_/...     │
│ /zerotouch/staging/...    │        │                           │
│ /zerotouch/prod/...       │        │ overlays/prod/            │
│                           │        │   patches/secrets.yaml    │
│ (SecureString encrypted)  │        │   key: /.../prod/...      │
└─────────────┬─────────────┘        └─────────────┬─────────────┘
              │                                    │
              │ ESO Fetches                        │ ArgoCD Syncs
              │                                    │
              ▼                                    ▼
┌────────────────────────────────────────────────────────────────┐
│ KUBERNETES CLUSTER                                              │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ExternalSecret (CRD)                                          │
│    ↓ (ESO reconciles)                                          │
│  K8s Secret (Opaque)                                           │
│    ↓ (mounted)                                                 │
│  Pod (envFrom: secretRef)                                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Secret Storage (AWS SSM)
Secrets stored as encrypted parameters:
- **Path Pattern:** `/zerotouch/{env}/{service}/{key}`
- **Encryption:** SecureString type
- **Normalization:** Keys lowercase with underscores
- **Example:** `/zerotouch/prod/my-service/database_url`

### 2. Base Manifests (Placeholder Pattern)
ExternalSecrets defined with environment placeholder:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-service-db
  labels:
    zerotouch.io/managed: "true"
spec:
  secretStoreRef:
    name: aws-parameter-store
    kind: ClusterSecretStore
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: /zerotouch/_ENV_/my-service/database_url
```

**Purpose:** `_ENV_` placeholder prevents accidental production access if overlay fails.

### 3. Environment Overlays (Kustomize Patches)
Patches replace placeholder with actual environment:

```yaml
# overlays/prod/patches/secrets-patch.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-service-db
spec:
  data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: /zerotouch/prod/my-service/database_url
```

### 4. Deployment Flow
1. **Sync Secrets:** Release pipeline uses `sync-secrets-to-ssm.sh` to push secrets to SSM
2. **Deploy Manifests:** ArgoCD applies ExternalSecrets with overlays
3. **Force Refresh:** Release pipeline uses `force-secret-refresh.sh` to trigger immediate ESO sync
4. **Fetch Secrets:** ESO creates Kubernetes secrets from SSM
5. **Mount Secrets:** Pods consume via `envFrom`

**Scripts:**
- `zerotouch-platform/scripts/release/template/sync-secrets-to-ssm.sh`
- `zerotouch-platform/scripts/release/force-secret-refresh.sh`

**Workflows:**
- `zerotouch-platform/.github/workflows/release-pipeline.yml`

### 5. Authentication
**GitHub App Token Pattern:**
- Release workflows generate installation tokens using GitHub Apps
- Required inputs: `APP_ID` (variable), `APP_PRIVATE_KEY` (secret)
- Token scoped to required repositories only
- Scripts automatically use `GITHUB_REPOSITORY_OWNER` for organization detection

### 6. SecretStore Configuration
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
- Base uses `_ENV_` to prevent environment confusion
- Overlays inject actual environment (`dev`, `staging`, `prod`)
- Fail-safe: Invalid overlay = failed deployment (not wrong environment)

### Label-Based Sync
- `zerotouch.io/managed: "true"` label identifies platform-managed secrets
- Force-sync targets only labeled secrets
- Prevents interference with other secret sources

### Normalization Rules
- Keys: `UPPER_CASE` → `lowercase_underscore`
- No hyphens allowed (enforced by sync script)
- Consistent SSM paths across all services

## Security Model

| Layer | Protection |
|-------|-----------|
| **Storage** | SSM SecureString encryption at rest |
| **Access** | IAM roles with least-privilege policies |
| **Audit** | CloudTrail logs all SSM access |
| **Git** | Only paths stored, never values |
| **Blast Radius** | Label selectors limit sync scope |

## Service Requirements

### Adding New Secrets to Services

When platform infrastructure adds new ExternalSecrets (e.g., `platform-global-config`), services must update their deployment manifests to consume them:

**Steps:**
1. **Create ExternalSecret** in `base/external-secrets/` (e.g., `platform-config-es.yaml`)
2. **Add to base kustomization** in `base/kustomization.yaml`:
   ```yaml
   resources:
     - external-secrets/platform-config-es.yaml
   ```
3. **Update ALL deployment overlays** to reference the new secret:
   ```yaml
   # overlays/{dev,pr,staging,production}/deployment.yaml
   spec:
     secret1Name: service-db-conn
     secret2Name: service-app-secrets
     secret3Name: platform-global-config  # NEW SECRET
   ```

**Critical:** All environment overlays (dev, pr, staging, production) must be updated, or pods will fail to start due to missing secret references.

**Example: Adding Platform JWKS URL**
```yaml
# base/external-secrets/platform-config-es.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: platform-global-config
  namespace: service-namespace
spec:
  target:
    name: platform-global-config
  data:
  - secretKey: PLATFORM_JWKS_URL
    remoteRef:
      key: /zerotouch/_ENV_/zerotouch-platform/jwks_url
```

```yaml
# overlays/dev/deployment.yaml
spec:
  secret1Name: service-db-conn
  secret2Name: service-app-secrets
  secret3Name: platform-global-config  # Injects PLATFORM_JWKS_URL
```

### Tenant Repository Structure

```
zerotouch-tenants/tenants/my-service/
├── base/
│   ├── external-secrets/
│   │   ├── db-es.yaml              # _ENV_ placeholder
│   │   └── llm-keys-es.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── patches/
    │   │   └── secrets-patch.yaml  # dev paths
    │   └── kustomization.yaml
    ├── staging/
    │   ├── patches/
    │   │   └── secrets-patch.yaml  # staging paths
    │   └── kustomization.yaml
    └── prod/
        ├── patches/
        │   └── secrets-patch.yaml  # prod paths
        └── kustomization.yaml
```

### Required Labels
```yaml
metadata:
  labels:
    zerotouch.io/managed: "true"  # Enables force-sync
```

### Multi-line Secrets
```yaml
data:
- secretKey: JWT_PRIVATE_KEY
  remoteRef:
    key: /zerotouch/prod/service/jwt_private_key
```

## Troubleshooting

### Secret Not Available
```bash
# Check ExternalSecret status
kubectl get externalsecret -n namespace

# Verify SSM parameter
aws ssm get-parameter --name /zerotouch/prod/service/key

# Check ESO logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

### Overlay Not Applied
```bash
# Test kustomize build
kubectl kustomize tenants/service/overlays/prod

# Verify ArgoCD sync
kubectl get application -n argocd
```
