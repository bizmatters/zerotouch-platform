# Secrets Management Quick Start

## CI/CD (GitHub Actions)

**Required GitHub Organization Secrets:**

| Secret Name | Purpose | Visibility |
|-------------|---------|------------|
| `SOPS_AGE_KEY_PR` | Decrypt PR environment secrets | All repos |
| `SOPS_AGE_KEY_DEV` | Decrypt DEV environment secrets | All repos |
| `SOPS_AGE_KEY_STAGING` | Decrypt STAGING environment secrets | All repos |
| `SOPS_AGE_KEY_PROD` | Decrypt PROD environment secrets | All repos |

**That's it.** All other secrets (Hetzner API tokens, GitHub App credentials, etc.) are encrypted in Git and decrypted automatically using environment-specific Age keys.

---

## Local Development

### E2E Setup (Generate + Backup + Encrypt)

```bash
cd zerotouch-platform

# One command per environment
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh pr
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh dev
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh staging
./scripts/bootstrap/infra/secrets/ksops/setup-env-secrets.sh prod

# Script will:
# 1. Generate Age keypair (or retrieve from S3)
# 2. Create environment-specific .sops.yaml
# 3. Backup Age key to S3
# 4. Generate all encrypted secrets
# 5. Output: Add SOPS_AGE_KEY_{ENV} to GitHub org secrets
```

### Refresh Secrets (After updating .env.local)

```bash
# Re-encrypt secrets with existing Age key
ENV=dev ./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

# Commit changes
git add bootstrap/argocd/overlays/
git commit -m "chore: update dev secrets"
git push
```

---

## How It Works

**CI/CD Flow:**
```
SOPS_AGE_KEY_{ENV} (org secret) → decrypt secrets → .env → bootstrap
```

**Local Flow (Option 1):**
```
SOPS_AGE_KEY (env var) → decrypt secrets → .env → bootstrap
```

**Local Flow (Option 2):**
```
S3 credentials → retrieve Age key → decrypt secrets → .env → bootstrap
```

**Manual Setup Flow:**
```
.env.local → setup-env-secrets.sh → encrypted *.secret.yaml → Git
```

---

## Key Points

- **CI uses environment-specific Age keys**: `SOPS_AGE_KEY_PR`, `SOPS_AGE_KEY_DEV`, etc.
- **Each environment has its own Age keypair**: Isolated encryption per environment
- **Local dev has 3 options**: Age key, S3 retrieval, or manual .env.local
- **All secrets encrypted in Git**: Hetzner tokens, GitHub App creds, etc.
- **No secrets in CI workflows**: Everything decrypted from Git at runtime
- **S3 is optional**: Only needed for local dev without Age key
