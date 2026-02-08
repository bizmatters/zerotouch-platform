# Platform Secrets Management Workflow (End-to-End)

## Overview

Platform secrets follow a **Git-first** approach where encrypted secrets are committed to the repository and decrypted on-demand. This document covers the complete lifecycle: generation, storage, retrieval, and usage in both local and CI environments.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Manual Setup (One-time)                                     │
├─────────────────────────────────────────────────────────────┤
│ 1. Create .env.local with {ENV}_* prefixed secrets          │
│    → Manual: Create/edit .env.local file                    │
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

Create `.env.local` with environment-prefixed secrets:

```bash
# .env.local example
PR_HETZNER_API_TOKEN=xxx
PR_HETZNER_DNS_TOKEN=xxx
PR_HETZNER_S3_ACCESS_KEY=xxx
PR_HETZNER_S3_SECRET_KEY=xxx
PR_HETZNER_S3_ENDPOINT=https://fsn1.your-objectstorage.com
PR_HETZNER_S3_REGION=us-east-1
PR_HETZNER_S3_BUCKET_NAME=pr-secrets

DEV_HETZNER_API_TOKEN=xxx
# ... repeat for DEV, STAGING, PROD

# Core secrets (no prefix)
GIT_APP_ID=xxx
GIT_APP_INSTALLATION_ID=xxx
GIT_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----"
ORG_NAME=bizmatters
TENANTS_REPO_NAME=zerotouch-tenants
```

**Supported prefixes**: `PR_`, `DEV_`, `STAGING_`, `PROD_`

### Step 2: Run E2E Setup Script

```bash
cd zerotouch-platform

# Setup secrets for each environment (one command per env)
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh pr
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh dev
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh staging
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh prod
```

**This script does:**
1. Generates Age keypair (or retrieves from S3 if exists)
2. Creates environment-specific `.sops.yaml` in overlay directory
3. Backs up Age key to S3 (encrypted with recovery key)
4. Generates all encrypted secrets for the environment

**Output locations**:
- `bootstrap/argocd/overlays/preview/.sops.yaml` + `secrets/` (PR)
- `bootstrap/argocd/overlays/main/dev/.sops.yaml` + `secrets/`
- `bootstrap/argocd/overlays/main/staging/.sops.yaml` + `secrets/`
- `bootstrap/argocd/overlays/main/prod/.sops.yaml` + `secrets/`

**Important**: Each environment has its own `.sops.yaml` with environment-specific Age public key.

### Step 3: Add Age Keys to GitHub Organization

For each environment, add the Age private key to GitHub org secrets:

1. Go to GitHub Organization → Settings → Secrets → Actions
2. Create new secrets (one per environment):
   - Name: `SOPS_AGE_KEY_PR`, Value: Age private key from PR setup
   - Name: `SOPS_AGE_KEY_DEV`, Value: Age private key from DEV setup
   - Name: `SOPS_AGE_KEY_STAGING`, Value: Age private key from STAGING setup
   - Name: `SOPS_AGE_KEY_PROD`, Value: Age private key from PROD setup
3. Set visibility: All repositories (or specific repos)

**Important**: Each environment has its own Age keypair. Do not reuse keys across environments.

### Step 4: Commit Encrypted Secrets

```bash
# Verify encrypted secrets
ls -la bootstrap/argocd/overlays/preview/secrets/
ls -la bootstrap/argocd/overlays/main/dev/secrets/

# Commit to Git
git add bootstrap/argocd/overlays/
git add .gitignore  # If updated
git commit -m "chore: setup environment-specific encrypted secrets"
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
    runs-on: ubuntu-latest
    steps:
      - name: Determine Environment
        id: env
        run: |
          if [[ "${{ github.ref }}" == "refs/heads/main" ]]; then
            echo "name=dev" >> $GITHUB_OUTPUT
            echo "age_secret=SOPS_AGE_KEY_DEV" >> $GITHUB_OUTPUT
          else
            echo "name=pr" >> $GITHUB_OUTPUT
            echo "age_secret=SOPS_AGE_KEY_PR" >> $GITHUB_OUTPUT
          fi
      
      - name: Decrypt Secrets
        env:
          SOPS_AGE_KEY: ${{ secrets[steps.env.outputs.age_secret] }}
        run: |
          # Decrypt GitHub App credentials and other secrets
          ENV="${{ steps.env.outputs.name }}"
          if [[ "$ENV" == "pr" ]]; then
            SECRETS_DIR="bootstrap/argocd/overlays/preview/secrets"
          else
            SECRETS_DIR="bootstrap/argocd/overlays/main/${ENV}/secrets"
          fi
          
          # Decrypt and use secrets...
```

**Key points**:
- Only 1 org secret per environment: `SOPS_AGE_KEY_{ENV}`
- Dynamic Age key selection based on branch
- Environment-specific `.sops.yaml` in overlay directories
- No individual secret passing required
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

- Commit unencrypted `.env` or `.env.local` files
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
| Age public key | `bootstrap/argocd/overlays/{preview\|main/$ENV}/.sops.yaml` | ✓ Yes |
| Age private key | S3 `{bucket}/age-keys/ACTIVE-age-key-encrypted.txt` | ✗ No |
| Recovery key | S3 `{bucket}/age-keys/ACTIVE-recovery-key.txt` | ✗ No |
| Encrypted secrets | `bootstrap/argocd/overlays/{preview\|main/$ENV}/secrets/*.secret.yaml` | ✓ Yes |
| Environment file (manual) | `.env.local` (manual setup) | ✗ No |
| Environment file (automated) | `.env` (generated on-demand) | ✗ No |
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
| `setup-env-secrets.sh ENV` | E2E: Generate Age key + Backup + Encrypt secrets | Initial setup per environment |
| `08b-generate-age-keys.sh` | Generate/retrieve Age keypair | Called by setup script |
| `08b-backup-age-to-s3.sh` | Backup Age key to S3 | Called by setup script |
| `generate-platform-sops.sh` | Generate encrypted secrets | After .env.local updated |
| `create-dot-env.sh` | Decrypt secrets → .env | CI/local when .env missing |
| `08c-inject-age-key.sh` | Create sops-age secret | During bootstrap |

---

## Workflow Comparison

### Old Workflow (Deprecated)
```
CI → Pass all secrets individually → Bootstrap generates secrets → Inject to cluster
```
**Issues**: 10+ secrets in CI, cluttered workflows, no validation before bootstrap

### New Workflow (Current)
```
Manual → setup-env-secrets.sh → Encrypted secrets in Git → Backup Age key to S3
CI → Uses SOPS_AGE_KEY_{ENV} → Decrypt secrets → Bootstrap uses .env → Inject to cluster
```
**Benefits**: 
- 1 org secret per environment in CI
- Environment-specific Age keys (isolated encryption)
- Environment-specific `.sops.yaml` in overlay directories
- Fail-fast validation
- Git as source of truth
- E2E automation via single script
