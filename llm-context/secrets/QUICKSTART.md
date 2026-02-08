# Secrets Management Quick Start

## CI/CD (GitHub Actions)

**Required GitHub Secrets per Environment:**

| Environment | Secret Name | Purpose |
|-------------|-------------|---------|
| `pr` | `AGE_PRIVATE_KEY` | Decrypt SOPS secrets from Git |
| `dev` | `AGE_PRIVATE_KEY` | Decrypt SOPS secrets from Git |
| `staging` | `AGE_PRIVATE_KEY` | Decrypt SOPS secrets from Git |
| `production` | `AGE_PRIVATE_KEY` | Decrypt SOPS secrets from Git |

**That's it.** All other secrets (Hetzner API tokens, GitHub App credentials, etc.) are encrypted in Git and decrypted automatically using the Age key.

---

## Local Development

### Option 1: Use Age Key (Recommended for CI parity)

```bash
# Set Age key in environment
export AGE_PRIVATE_KEY="AGE-SECRET-KEY-1..."

# Bootstrap will auto-generate .env from encrypted secrets
ENV=dev ./scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh --mode preview
```

### Option 2: Use S3 Retrieval (No Age key needed)

```bash
# Set S3 credentials for your environment
export DEV_HETZNER_S3_ACCESS_KEY="..."
export DEV_HETZNER_S3_SECRET_KEY="..."
export DEV_HETZNER_S3_ENDPOINT="https://fsn1.your-objectstorage.com"
export DEV_HETZNER_S3_REGION="fsn1"
export DEV_HETZNER_S3_BUCKET_NAME="dev-secrets"

# Bootstrap will retrieve Age key from S3, then decrypt secrets
ENV=dev ./scripts/bootstrap/pipeline/02-master-bootstrap-v2.sh --mode preview
```

### Option 3: Manual .env.local (For secret generation)

```bash
# Create .env.local with all secrets
cat > .env.local << EOF
DEV_HETZNER_API_TOKEN=xxx
DEV_HETZNER_DNS_TOKEN=xxx
GIT_APP_ID=xxx
GIT_APP_INSTALLATION_ID=xxx
GIT_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----"
EOF

# Generate encrypted secrets (one-time setup)
set -a && source .env.local && set +a
./scripts/bootstrap/infra/secrets/ksops/generate-sops/generate-platform-sops.sh

# Commit encrypted secrets to Git
git add bootstrap/argocd/overlays/
git commit -m "chore: add encrypted secrets"
git push
```

---

## How It Works

**CI/CD Flow:**
```
AGE_PRIVATE_KEY (secret) → create-dot-env.sh → .env → bootstrap
```

**Local Flow (Option 1):**
```
AGE_PRIVATE_KEY (env var) → create-dot-env.sh → .env → bootstrap
```

**Local Flow (Option 2):**
```
S3 credentials → retrieve Age key → create-dot-env.sh → .env → bootstrap
```

**Manual Setup Flow:**
```
.env.local → generate-platform-sops.sh → encrypted *.secret.yaml → Git
```

---

## Key Points

- **CI only needs 1 secret per environment**: `AGE_PRIVATE_KEY`
- **Local dev has 3 options**: Age key, S3 retrieval, or manual .env.local
- **All secrets encrypted in Git**: Hetzner tokens, GitHub App creds, etc.
- **No secrets in CI workflows**: Everything decrypted from Git at runtime
- **S3 is optional**: Only needed for local dev without Age key
