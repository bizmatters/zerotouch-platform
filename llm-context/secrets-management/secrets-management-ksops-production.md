# Platform Secret Management: KSOPS Production Architecture
**Scope:** Development, Staging, Production Environments

## Executive Summary
Production secrets follow a **declarative GitOps pattern with KSOPS** (Kustomize Secret Operations). Secrets are SOPS-encrypted and stored directly in Git, with environment-specific overlays. The architecture ensures security through Age encryption while maintaining full GitOps auditability.

## Architecture Flow

```text
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           PRODUCTION SECRET LIFECYCLE (KSOPS)                       │
└─────────────────────────────────────────────────────────────────────────────────────┘

   1. SECRET STORAGE                    2. MANIFEST DEFINITION
   (Git - SOPS Encrypted)               (Git - Structure)
┌───────────────────────────┐        ┌───────────────────────────┐
│ zerotouch-platform/       │        │ bootstrap/argocd/         │
│ bootstrap/argocd/         │        │ overlays/main/            │
│                           │        │                           │
│ overlays/main/dev/        │        │ dev/kustomization.yaml    │
│   secrets/*.secret.yaml   │        │   resources:              │
│                           │        │     - ../core/secrets     │
│ overlays/main/staging/    │        │     - ./secrets           │
│   secrets/*.secret.yaml   │        │                           │
│                           │        │ (Decrypted by KSOPS)      │
│ overlays/main/prod/       │        │ (ArgoCD syncs)            │
│   secrets/*.secret.yaml   │        │                           │
│                           │        │                           │
│ (Age encrypted in Git)    │        │                           │
└─────────────┬─────────────┘        └─────────────┬─────────────┘
              │                                    │
              │ KSOPS Decrypts                     │ ArgoCD Syncs
              │ (Age key in cluster)               │
              ▼                                    ▼
┌────────────────────────────────────────────────────────────────┐
│ KUBERNETES CLUSTER                                              │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  KSOPS Plugin (ArgoCD/Kustomize)                               │
│    ↓ (decrypts with Age key)                                  │
│  K8s Secret (Opaque)                                           │
│    ↓ (mounted)                                                 │
│  Pod (envFrom: secretRef)                                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Secret Storage (Git with SOPS)
Secrets stored as encrypted YAML in Git:
- **Path Pattern:** `bootstrap/argocd/overlays/main/{env}/secrets/*.secret.yaml`
- **Encryption:** SOPS with Age encryption
- **Format:** Kubernetes Secret YAML (encrypted stringData)
- **Example:** `overlays/main/dev/secrets/hetzner-api-token.secret.yaml`

### 2. Secret Generation Script
Platform secrets generated from `.env` file:

```bash
# zerotouch-platform/scripts/bootstrap/infra/secrets/ksops/generate-platform-secrets.sh
# Processes:
# - DEV_* → overlays/main/dev/secrets/
# - STAGING_* → overlays/main/staging/secrets/
# - PROD_* → overlays/main/prod/secrets/
# - Others (except APP_*) → overlays/main/core/secrets/
```

**Generated Secret Structure:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hetzner-api-token
  namespace: kube-system
type: Opaque
stringData:
  value: <SOPS encrypted>
```

### 3. Environment Overlays (Kustomize)
Each environment includes secrets via kustomization:

```yaml
# overlays/main/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../core
- ../core/secrets  # Shared platform secrets
- ./secrets        # Dev-specific secrets
- 99-tenants.yaml
```

### 4. Deployment Flow
1. **Generate Secrets:** Run `generate-platform-secrets.sh` to create SOPS-encrypted secrets from `.env`
2. **Commit to Git:** Encrypted secrets committed to platform repository
3. **ArgoCD Sync:** ArgoCD detects changes and syncs (wave 0 - before platform components)
4. **KSOPS Decrypt:** KSOPS plugin decrypts secrets using Age key in cluster
5. **Platform Bootstrap:** Platform components (HCloud CCM, External-DNS) consume secrets

**Scripts:**
- `zerotouch-platform/scripts/bootstrap/infra/secrets/ksops/generate-platform-secrets.sh`
- `zerotouch-platform/scripts/bootstrap/install/08-setup-ksops.sh`

**Workflows:**
- `zerotouch-platform/.github/workflows/create-cluster.yaml`

### 5. Bootstrap Integration
KSOPS setup integrated into master bootstrap:

```bash
# Step 8: Setup KSOPS (before ArgoCD installation)
./scripts/bootstrap/install/08-setup-ksops.sh
```

**KSOPS Setup Steps:**
1. Install KSOPS tools (sops, age, ksops)
2. Inject GitHub App authentication
3. Bootstrap Hetzner Object Storage (for backups)
4. Generate Age keypair
5. Inject Age key into cluster
6. Create Age key backup

### 6. SOPS Configuration
`.sops.yaml` defines encryption rules:

```yaml
creation_rules:
  - path_regex: \.secret\.yaml$
    age: age1tvqpus0c9etv08qttaexvurh8sj0yc9nrc02v4u59ul5qp95puqq8ztefu
  - path_regex: \.yaml$
    age: age1tvqpus0c9etv08qttaexvurh8sj0yc9nrc02v4u59ul5qp95puqq8ztefu
```

## Key Patterns

### Environment Prefix Pattern
Secrets use environment prefixes for separation:
```bash
DEV_HETZNER_API_TOKEN=xxx
STAGING_HETZNER_API_TOKEN=yyy
PROD_HETZNER_API_TOKEN=zzz
```

Script generates:
- `overlays/main/dev/secrets/hetzner-api-token.secret.yaml`
- `overlays/main/staging/secrets/hetzner-api-token.secret.yaml`
- `overlays/main/prod/secrets/hetzner-api-token.secret.yaml`

### Namespace Targeting
All platform secrets target `kube-system` namespace:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hetzner-api-token
  namespace: kube-system  # Platform infrastructure namespace
type: Opaque
```

**Rationale:** Single namespace for all infrastructure secrets (easy tracking and audit)

### Core vs Environment Secrets
- **Core Secrets:** Shared across all environments (`overlays/main/core/secrets/`)
  - Example: `org-name`, `tenants-repo-name`
- **Environment Secrets:** Environment-specific (`overlays/main/{env}/secrets/`)
  - Example: `hetzner-api-token`, `database-url`

### Normalization Rules
- Keys: `UPPER_CASE` → `lowercase-hyphen`
- No underscores in secret names (Kubernetes naming)
- Consistent naming across all environments

## Sync Wave Timing

Platform secrets sync at **Wave 0** (default, no annotation):
- `platform-bootstrap` Application syncs `overlays/main/dev/` at wave 0
- Secrets included in kustomization deploy immediately
- **Wave 1** components (HCloud CCM) wait for wave 0 completion
- **Wave 4** components (External-DNS) have secrets ready

**No sync wave conflict:** Secrets available before any platform component needs them.

## Security Model

| Layer | Protection |
|-------|-----------|
| **Storage** | SOPS Age encryption in Git |
| **Access** | Age private key in cluster only |
| **Audit** | Git commit history tracks all changes |
| **Isolation** | Environment-specific overlays prevent cross-env leaks |
| **Namespace** | All platform secrets in `kube-system` |
| **Backup** | Age key backed up to Hetzner Object Storage |

## Platform Secret Mapping

| Secret Name | Namespace | Used By | Environment |
|-------------|-----------|---------|-------------|
| `hetzner-api-token` | kube-system | HCloud CCM | DEV/STAGING/PROD |
| `hetzner-dns-token` | kube-system | External-DNS | DEV/STAGING/PROD |
| `hetzner-s3-access-key` | kube-system | Cert-Manager | DEV/STAGING/PROD |
| `hetzner-s3-secret-key` | kube-system | Cert-Manager | DEV/STAGING/PROD |
| `database-url` | kube-system | Platform Services | DEV/STAGING/PROD |
| `org-name` | kube-system | Platform Config | CORE (all envs) |
| `tenants-repo-name` | kube-system | Platform Config | CORE (all envs) |

## Service Requirements

### Tenant Repository Structure

```
zerotouch-tenants/tenants/my-service/
├── base/
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── secrets/
    │   │   ├── kustomization.yaml
    │   │   └── *.secret.yaml (SOPS)
    │   ├── ksops-generator.yaml
    │   └── kustomization.yaml
    ├── staging/
    │   ├── secrets/
    │   │   └── *.secret.yaml (SOPS)
    │   └── kustomization.yaml
    └── prod/
        ├── secrets/
        │   └── *.secret.yaml (SOPS)
        └── kustomization.yaml
```

### Required KSOPS Generator
```yaml
# overlays/{env}/ksops-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: ksops-generator
files:
- ./secrets/*.secret.yaml
```

### Kustomization Integration
```yaml
# overlays/{env}/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base
- ./secrets/

generators:
- ksops-generator.yaml
```

## Troubleshooting

### Secret Not Available
```bash
# Check if secrets exist
kubectl get secrets -n kube-system

# Verify ArgoCD sync status
kubectl get application platform-bootstrap -n argocd

# Check KSOPS decryption
kubectl kustomize --enable-alpha-plugins bootstrap/argocd/overlays/main/dev
```

### SOPS Decryption Failed
```bash
# Verify Age key exists
kubectl get secret sops-age -n kube-system

# Test decryption locally
export SOPS_AGE_KEY=$(kubectl get secret sops-age -n kube-system -o jsonpath='{.data.keys\.txt}' | base64 -d)
sops -d bootstrap/argocd/overlays/main/dev/secrets/hetzner-api-token.secret.yaml
```

### ArgoCD Sync Issues
```bash
# Check ArgoCD application status
kubectl get application -n argocd

# View sync errors
kubectl describe application platform-bootstrap -n argocd

# Force refresh
kubectl patch application platform-bootstrap -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### KSOPS Plugin Not Found in ArgoCD
```bash
# Verify KSOPS installation in ArgoCD
kubectl exec -n argocd argocd-repo-server-xxx -- which ksops

# Check ArgoCD ConfigMap for KSOPS
kubectl get configmap argocd-cm -n argocd -o yaml | grep ksops
```

## Benefits

1. **GitOps Native:** Secrets stored in Git with encryption
2. **Full Auditability:** All changes tracked in Git history
3. **No External Dependencies:** No AWS SSM or external secret stores
4. **Environment Isolation:** Separate overlays prevent cross-environment leaks
5. **Early Sync:** Secrets available at wave 0 (before platform components)
6. **Consistent Pattern:** Same approach for platform and tenant secrets
7. **Backup Strategy:** Age key backed up to object storage

## Migration from ESO

For services migrating from External Secrets Operator to KSOPS:

1. **Generate KSOPS secrets** from existing `.env` variables
2. **Update kustomization** to include `./secrets/` and KSOPS generator
3. **Remove ExternalSecret** CRDs from manifests
4. **Commit encrypted secrets** to Git
5. **Verify ArgoCD sync** and secret availability
6. **Clean up SSM parameters** (optional, after validation)

**Key Difference:** Values now in Git (encrypted) instead of AWS SSM (external).
