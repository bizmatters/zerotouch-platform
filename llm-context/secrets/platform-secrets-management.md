# Platform Secrets Management Workflow (End-to-End)

## Overview

Platform secrets follow a **Git-first** approach where encrypted secrets are committed to the repository and decrypted on-demand. This document covers the complete lifecycle: generation, storage, retrieval, and usage in both local and CI environments.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Manual Setup (One-time)                                     │
├─────────────────────────────────────────────────────────────┤
│ 1. Create .env with {ENV}_* prefixed secrets                │
│    → Manual: Create/edit .env file                          │
│                                                              │
│ 2. Generate Age keypair (or retrieve from S3)               │
│    → 08b-generate-age-keys.sh                               │
│                                                              │
│ 3. Generate encrypted secrets → Git                         │
│    → generate-platform-sops.sh                              │
│      ├─ generate-env-secrets.sh                             │
│      ├─ generate-tenant-registry-secrets.sh                 │
│      └─ generate-core-secrets.sh                            │
│                                                              │
│ 4. Backup Age key → S3                                      │
│    → 08b-backup-age-to-s3.sh                                │
│                                                              │
│ 5. Commit encrypted secrets to Git                          │
│    → Manual: git add/commit/push                            │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Automated Workflow (Local/CI)                               │
├─────────────────────────────────────────────────────────────┤
│ 1. Check if .env exists                                     │
│    → Workflow conditional check                             │
│                                                              │
│ 2. If missing: Decrypt secrets → .env                       │
│    → create-dot-env.sh (NEW)                                │
│      ├─ Retrieve Age key from S3                            │
│      ├─ Validate against .sops.yaml                         │
│      └─ Decrypt all *.secret.yaml → .env                    │
│                                                              │
│ 3. Bootstrap uses .env for cluster setup                    │
│    → 02-master-bootstrap-v2.sh                              │
│                                                              │
│ 4. Setup KSOPS (simplified)                                 │
│    → 08-setup-ksops.sh                                      │
│      ├─ 08a-install-ksops.sh (install tools)                │
│      ├─ 08c-inject-age-key.sh (inject to cluster)          │
│      └─ 08e-deploy-ksops-package.sh (ArgoCD plugin)        │
│                                                              │
│ 5. ArgoCD syncs and decrypts secrets                        │
│    → ArgoCD + KSOPS plugin                                  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **Tools installed**: `age`, `age-keygen`, `sops`, `aws` CLI
2. **S3 credentials**: `{ENV}_HETZNER_S3_*` environment variables
3. **Git access**: Repository with write permissions

---

## Phase 1: Manual Secret Generation (One-Time Setup)

### Step 1: Create Environment File

Create `.env` with environment-prefixed secrets:

```bash
# .env example
PR_HETZNER_API_TOKEN=xxx
PR_HETZNER_DNS_TOKEN=xxx
PR_HETZNER_S3_ACCESS_KEY=xxx
PR_HETZNER_S3_SECRET_KEY=xxx
PR_HETZNER_S3_ENDPOINT=https://fsn1.your-objectstorage.com
PR_HETZNER_S3_REGION=us-east-1
PR_HETZNER_S3_BUCKET_NAME=pr-secrets

DEV_HETZNER_API_TOKEN=xxx
# ... repeat for DEV, STAGING, PROD
```

**Supported prefixes**: `PR_`, `DEV_`, `STAGING_`, `PROD_`

### Step 2: Generate Age Keypair

```bash
cd zerotouch-platform

# Generate new Age keypair
source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh

# This exports:
# - AGE_PUBLIC_KEY
# - AGE_PRIVATE_KEY
```

**Note**: Script checks cluster for existing key first, generates only if not found.

### Step 3: Generate Encrypted Secrets

```bash
# Ensure .env is sourced
set -a && source .env && set +a

# Generate all platform secrets
./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh
```

**Output locations**:
- `bootstrap/argocd/overlays/main/pr/secrets/` (NEW)
- `bootstrap/argocd/overlays/main/dev/secrets/`
- `bootstrap/argocd/overlays/main/staging/secrets/`
- `bootstrap/argocd/overlays/main/prod/secrets/`
- `bootstrap/argocd/overlays/main/core/secrets/`
- `bootstrap/argocd/overlays/main/tenants/secrets/`

### Step 4: Backup Age Key to S3

```bash
# Backup Age key with environment-specific credentials
./scripts/bootstrap/infra/secrets/ksops/08b-backup-age-to-s3.sh
```

**S3 structure**:
```
s3://{bucket}/age-keys/
├── ACTIVE-age-key-encrypted.txt      # Current active key
├── ACTIVE-recovery-key.txt           # Recovery key for decryption
├── 20260207-143022-age-key-encrypted.txt  # Timestamped backup
└── 20260207-143022-recovery-key.txt       # Timestamped recovery
```

### Step 5: Verify and Commit

```bash
# Verify decryption works
export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
sops -d bootstrap/argocd/overlays/main/pr/secrets/hcloud.secret.yaml

# Commit encrypted secrets
git add bootstrap/argocd/overlays/main/*/secrets/*.secret.yaml
git add .sops.yaml
git commit -m "chore: add encrypted platform secrets for all environments"
git push
```

---

## Phase 2: Automated Workflow (Local/CI)

### Workflow Entry Point

Both local and CI workflows start with the same check:

```bash
# Check if .env exists
if [ ! -f .env ]; then
    # Generate .env from encrypted secrets
    ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
fi

# Proceed with bootstrap
./scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh --mode preview
```

### create-dot-env.sh Logic

**Purpose**: Reverse operation - decrypt secrets from Git → generate `.env`

**Steps**:
1. Retrieve Age key from S3 (using `{ENV}_HETZNER_S3_*` credentials)
2. Decrypt Age key using recovery key
3. Verify public key matches `.sops.yaml`
4. Decrypt all `*.secret.yaml` in `bootstrap/argocd/overlays/main/{env}/secrets/`
5. Extract secret values
6. Write to `.env` with `{ENV}_` prefix
7. **Fail if Age key not in S3** (no generation fallback)

**Required environment variables**:
- `ENV` (pr/dev/staging/production)
- `{ENV}_HETZNER_S3_ACCESS_KEY`
- `{ENV}_HETZNER_S3_SECRET_KEY`
- `{ENV}_HETZNER_S3_ENDPOINT`
- `{ENV}_HETZNER_S3_REGION`
- `{ENV}_HETZNER_S3_BUCKET_NAME`

### Bootstrap Workflow

After `.env` exists:

1. **08-setup-ksops.sh** (simplified):
   - ~~Retrieve/generate Age key~~ (removed)
   - ~~Backup to S3~~ (removed)
   - Inject Age key to cluster (from `.env` or S3)
   - Validate secrets in Git

2. **ArgoCD installation**:
   - KSOPS plugin mounts `sops-age` secret
   - Syncs encrypted secrets from Git
   - Decrypts using mounted Age key

---

## CI/CD Integration

### GitHub Actions Workflow

```yaml
jobs:
  integration-test:
    environment: preview  # Access to PR_* secrets
    steps:
      - name: Generate .env from encrypted secrets
        env:
          PR_HETZNER_S3_ACCESS_KEY: ${{ secrets.PR_HETZNER_S3_ACCESS_KEY }}
          PR_HETZNER_S3_SECRET_KEY: ${{ secrets.PR_HETZNER_S3_SECRET_KEY }}
          PR_HETZNER_S3_ENDPOINT: ${{ secrets.PR_HETZNER_S3_ENDPOINT }}
          PR_HETZNER_S3_REGION: ${{ secrets.PR_HETZNER_S3_REGION }}
          PR_HETZNER_S3_BUCKET_NAME: ${{ secrets.PR_HETZNER_S3_BUCKET_NAME }}
        run: |
          if [ ! -f .env ]; then
            ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
          fi
      
      - name: Bootstrap Platform
        run: |
          ./scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh --mode preview
```

**Key points**:
- Only S3 credentials needed in CI (5 secrets)
- No individual secret passing required
- `.env` generated on-demand from Git secrets
- Fail-fast if Age key missing/invalid

---

## Key Principles

### ✓ DO

- Generate secrets **before** cluster creation
- Commit encrypted secrets to Git
- Use S3 as source of truth for Age key
- Validate decryption before pushing to Git
- Keep `.sops.yaml` in sync with Age public key
- Use environment prefixes (`PR_`, `DEV_`, etc.)
- Run `create-dot-env.sh` when `.env` missing

### ✗ DON'T

- Commit unencrypted `.env` file
- Generate secrets during cluster bootstrap
- Generate new Age key if one exists in S3
- Proceed with bootstrap if secrets can't be decrypted
- Mix Age keys between environments
- Pass individual secrets in CI workflows

---

## Environment-Specific Workflows

### PR Environment (CI Only)

```bash
ENV=pr ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
# Generates .env with PR_* prefixed variables
```

### Dev Environment (Local/CI)

```bash
ENV=dev ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
# Generates .env with DEV_* prefixed variables
```

### Production Environment (Local Only)

```bash
ENV=production ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
# Generates .env with PROD_* prefixed variables
```

---

## Troubleshooting

### Error: "Age key not found in S3"

**Cause**: First-time setup or S3 backup missing

**Fix**:
```bash
# Generate Age keypair
source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh

# Backup to S3
./scripts/bootstrap/infra/secrets/ksops/08b-backup-age-to-s3.sh

# Retry
./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
```

### Error: "Age key mismatch with .sops.yaml"

**Cause**: Age key in S3 doesn't match `.sops.yaml`

**Fix**:
```bash
# Re-encrypt all secrets with correct key from S3
export SOPS_AGE_KEY="<key from S3>"
find bootstrap/argocd/overlays/main -name "*.secret.yaml" -exec sops updatekeys -y {} \;
git add bootstrap/
git commit -m "fix: re-encrypt secrets with correct Age key"
git push
```

### Error: "Cannot decrypt secrets in Git"

**Cause**: Secrets encrypted with different Age key

**Fix**:
```bash
# Retrieve correct Age key
ENV=dev ./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh

# Re-generate all secrets
./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

# Commit
git add bootstrap/
git commit -m "fix: regenerate secrets with correct Age key"
git push
```

### Error: ".env exists but secrets outdated"

**Cause**: Secrets changed in Git but `.env` not regenerated

**Fix**:
```bash
# Force regeneration
rm .env
./scripts/bootstrap/infra/secrets/ksops/generate-sops/create-dot-env.sh
```

---

## Recovery Scenarios

### Lost Age Key (S3 backup exists)

```bash
# Download from S3
aws s3 cp s3://{bucket}/age-keys/ACTIVE-recovery-key.txt recovery.key \
  --endpoint-url {endpoint}

aws s3 cp s3://{bucket}/age-keys/ACTIVE-age-key-encrypted.txt encrypted.txt \
  --endpoint-url {endpoint}

# Decrypt
age -d -i recovery.key encrypted.txt
```

### Lost Age Key (in-cluster backup exists)

```bash
# Extract from cluster
kubectl get secret recovery-master-key -n argocd -o jsonpath='{.data.recovery-key\.txt}' | base64 -d > recovery.key
kubectl get secret age-backup-encrypted -n argocd -o jsonpath='{.data.encrypted-key\.txt}' | base64 -d > encrypted.txt

# Decrypt
age -d -i recovery.key encrypted.txt
```

### Lost Everything

```bash
# Generate new Age key
source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh

# Re-encrypt ALL secrets in Git
find bootstrap/argocd/overlays/main -name "*.secret.yaml" -exec sops updatekeys -y {} \;

# Backup to S3
./scripts/bootstrap/infra/secrets/ksops/08b-backup-age-to-s3.sh

# Commit
git add .sops.yaml bootstrap/
git commit -m "emergency: regenerate Age key and re-encrypt all secrets"
git push
```

---

## File Locations

| Item | Location | Committed to Git |
|------|----------|------------------|
| Age public key | `.sops.yaml` | ✓ Yes |
| Age private key | S3 `{bucket}/age-keys/ACTIVE-age-key-encrypted.txt` | ✗ No |
| Recovery key | S3 `{bucket}/age-keys/ACTIVE-recovery-key.txt` | ✗ No |
| Encrypted secrets | `bootstrap/argocd/overlays/main/*/secrets/*.secret.yaml` | ✓ Yes |
| Environment file | `.env` (generated on-demand) | ✗ No |
| Cluster secret | `kubectl get secret sops-age -n argocd` | ✗ No |

---

## Security Notes

1. **Never commit** `.env` file or unencrypted secrets
2. **Always verify** decryption before committing encrypted secrets
3. **Store recovery key** offline in secure location (not just S3)
4. **Rotate Age keys** periodically (requires re-encryption of all secrets)
5. **Audit S3 access** to Age key backups
6. **Use environment-specific** S3 buckets (pr-secrets, dev-secrets, etc.)
7. **Limit CI secrets** to S3 credentials only (not individual secrets)

---

## Script Reference

| Script | Purpose | When to Run |
|--------|---------|-------------|
| `08b-generate-age-keys.sh` | Generate/retrieve Age keypair | Manual setup |
| `08b-backup-age-to-s3.sh` | Backup Age key to S3 | After key generation |
| `generate-platform-sops.sh` | Generate encrypted secrets | After .env created |
| `create-dot-env.sh` | Decrypt secrets → .env | CI/local when .env missing |
| `08-setup-ksops.sh` | Inject Age key to cluster | During bootstrap |
| `08c-inject-age-key.sh` | Create sops-age secret | Called by 08-setup-ksops.sh |

---

## Workflow Comparison

### Old Workflow (Deprecated)
```
CI → Pass all secrets individually → Bootstrap generates secrets → Inject to cluster
```
**Issues**: 10+ secrets in CI, cluttered workflows, no validation before bootstrap

### New Workflow (Current)
```
Manual → Generate secrets → Commit to Git → Backup Age key to S3
CI → Pass S3 creds only → create-dot-env.sh → Bootstrap uses .env → Inject to cluster
```
**Benefits**: 5 secrets in CI, fail-fast validation, Git as source of truth
