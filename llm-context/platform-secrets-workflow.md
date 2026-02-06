# Platform Secrets Creation Workflow

## Overview

Platform secrets must be created and committed to Git **BEFORE** cluster creation. The bootstrap workflow validates that secrets exist and can be decrypted, but does NOT generate them.

## Prerequisites

1. Age keypair exists in S3 backup OR will be generated fresh
2. `.env` file populated with all required secrets
3. Git repository access configured

---

## Workflow: New Cluster Creation

### Phase 1: Secret Generation (Manual - Outside Cluster)

**When**: Before running cluster bootstrap workflow

**Steps**:

1. **Generate or retrieve Age keypair**
   ```bash
   # Option A: Retrieve from S3 (if exists)
   ./scripts/bootstrap/infra/secrets/ksops/retrieve-age-from-s3.sh
   
   # Option B: Generate new (first time only)
   source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh
   ```

2. **Verify `.sops.yaml` has correct Age public key**
   ```bash
   grep "age:" .sops.yaml
   # Should match: age-keygen -y <<< "$AGE_PRIVATE_KEY"
   ```

3. **Generate platform secrets**
   ```bash
   ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh
   ```
   
   This creates encrypted `*.secret.yaml` files in:
   - `bootstrap/argocd/overlays/main/dev/secrets/`
   - `bootstrap/argocd/overlays/main/core/secrets/`
   - `bootstrap/argocd/overlays/main/tenants/secrets/`

4. **Verify secrets can be decrypted**
   ```bash
   export SOPS_AGE_KEY="$AGE_PRIVATE_KEY"
   sops -d bootstrap/argocd/overlays/main/core/secrets/org-name.secret.yaml
   ```

5. **Commit and push to Git**
   ```bash
   git add bootstrap/argocd/overlays/main/*/secrets/*.secret.yaml
   git add .sops.yaml
   git commit -m "chore: add encrypted platform secrets for dev environment"
   git push
   ```

---

### Phase 2: Cluster Bootstrap (Automated)

**When**: After secrets committed to Git

**Steps** (automated by bootstrap workflow):

1. **Retrieve Age key from S3**
   - Downloads `ACTIVE-age-key-encrypted.txt`
   - Decrypts using `ACTIVE-recovery-key.txt`
   - Verifies public key matches `.sops.yaml`
   - **FAILS if mismatch**

2. **Validate secrets in Git**
   - Checks encrypted `*.secret.yaml` files exist
   - Attempts decryption with retrieved Age key
   - **FAILS if decryption fails**

3. **Inject Age key into cluster**
   - Creates `sops-age` secret in `argocd` namespace
   - ArgoCD repo-server mounts this secret

4. **Install ArgoCD**
   - ArgoCD syncs from Git
   - KSOPS plugin decrypts secrets using mounted Age key
   - Secrets applied to cluster

---

## Key Principles

### ✓ DO

- Generate secrets **before** cluster creation
- Commit encrypted secrets to Git
- Use S3 backup as source of truth for Age key
- Validate decryption before pushing to Git
- Keep `.sops.yaml` in sync with Age public key

### ✗ DON'T

- Generate secrets during cluster bootstrap
- Commit unencrypted secrets
- Generate new Age key if one exists in S3
- Proceed with bootstrap if secrets can't be decrypted
- Mix Age keys between environments

---

## Troubleshooting

### Error: "Age key mismatch"

**Cause**: Age key in S3 doesn't match `.sops.yaml`

**Fix**:
```bash
# Re-encrypt all secrets with correct key
export SOPS_AGE_KEY="<key from S3>"
find bootstrap/argocd/overlays/main -name "*.secret.yaml" -exec sops updatekeys -y {} \;
git add bootstrap/
git commit -m "fix: re-encrypt secrets with correct Age key"
git push
```

### Error: "Secrets cannot be decrypted"

**Cause**: Secrets in Git encrypted with different Age key

**Fix**:
```bash
# Retrieve correct Age key from S3
./scripts/bootstrap/infra/secrets/ksops/retrieve-age-from-s3.sh

# Re-generate all secrets
./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

# Commit and push
git add bootstrap/
git commit -m "fix: regenerate secrets with correct Age key"
git push
```

### Error: "S3 backup not found"

**Cause**: First time setup, no Age key in S3

**Fix**:
```bash
# Generate new Age keypair
source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh

# Generate secrets
./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

# Commit to Git
git add .sops.yaml bootstrap/
git commit -m "feat: initial platform secrets"
git push

# Proceed with cluster bootstrap (will backup to S3)
```

---

## Recovery Scenarios

### Lost Age Key (S3 backup exists)

```bash
# Download from S3
aws s3 cp s3://pr-secrets/age-keys/ACTIVE-recovery-key.txt recovery.key \
  --endpoint-url https://fsn1.your-objectstorage.com

aws s3 cp s3://pr-secrets/age-keys/ACTIVE-age-key-encrypted.txt encrypted.txt \
  --endpoint-url https://fsn1.your-objectstorage.com

# Decrypt
age -d -i recovery.key encrypted.txt
```

### Lost Age Key (in-cluster backup exists)

```bash
# Extract from cluster
kubectl get secret recovery-master-key -n argocd -o jsonpath='{.data.recovery\.key}' | base64 -d > recovery.key
kubectl get secret age-backup-encrypted -n argocd -o jsonpath='{.data.age-key-encrypted\.txt}' | base64 -d > encrypted.txt

# Decrypt
age -d -i recovery.key encrypted.txt
```

### Lost Everything

```bash
# Generate new Age key
source ./scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh

# Re-encrypt ALL secrets in Git
find bootstrap/argocd/overlays/main -name "*.secret.yaml" -exec sops updatekeys -y {} \;

# Commit
git add .sops.yaml bootstrap/
git commit -m "emergency: regenerate Age key and re-encrypt all secrets"
git push
```

---

## File Locations

- **Age public key**: `.sops.yaml` (committed to Git)
- **Age private key**: S3 `s3://pr-secrets/age-keys/ACTIVE-age-key-encrypted.txt`
- **Recovery key**: S3 `s3://pr-secrets/age-keys/ACTIVE-recovery-key.txt`
- **Encrypted secrets**: `bootstrap/argocd/overlays/main/*/secrets/*.secret.yaml` (committed to Git)
- **Cluster secret**: `kubectl get secret sops-age -n argocd`

---

## Security Notes

1. **Never commit** `.env` file or unencrypted secrets
2. **Always verify** decryption before committing encrypted secrets
3. **Store recovery key** offline in secure location
4. **Rotate Age keys** periodically (requires re-encryption of all secrets)
5. **Audit S3 access** to Age key backups
