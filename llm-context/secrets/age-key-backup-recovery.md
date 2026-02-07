# Age Key Backup and Recovery

## Overview
Age keys encrypt all SOPS secrets in the platform. Losing the age key means losing access to all encrypted secrets. This document explains the backup and recovery process.

## Backup Process

### Scripts
- **08b-generate-age-keys.sh**: Generates new age keypair, exports `AGE_PUBLIC_KEY` and `AGE_PRIVATE_KEY`
- **08b-backup-age-to-s3.sh**: Encrypts age key with recovery master key, uploads to Hetzner S3

### Backup Flow
1. Generate age keypair (or use existing from environment)
2. Generate recovery master keypair
3. Encrypt age private key using recovery public key
4. Upload encrypted age key to S3: `s3://pr-secrets/age-keys/{timestamp}-age-key-encrypted.txt`
5. Upload recovery private key to S3: `s3://pr-secrets/age-keys/{timestamp}-recovery-key.txt`

### Environment Variables Required
```bash
DEV_HETZNER_S3_ENDPOINT=https://fsn1.your-objectstorage.com
DEV_HETZNER_S3_REGION=fsn1
DEV_HETZNER_S3_BUCKET_NAME=pr-secrets
DEV_HETZNER_S3_ACCESS_KEY=<access-key>
DEV_HETZNER_S3_SECRET_KEY=<secret-key>
```

### Run Backup
```bash
cd zerotouch-platform
source .env
source scripts/bootstrap/infra/secrets/ksops/08b-generate-age-keys.sh
scripts/bootstrap/infra/secrets/ksops/08b-backup-age-to-s3.sh
```

## Files Backed Up

### age-key-encrypted.txt (442 B)
- Age private key encrypted with recovery master key
- Required to decrypt all SOPS secrets
- Safe to store in S3 (encrypted)

### recovery-key.txt (75 B)
- Recovery master private key
- Decrypts the age-key-encrypted.txt
- **CRITICAL**: Store offline securely (password manager, vault)

## Recovery Process

### When to Recover
- Lost cluster age key
- Migrating to new cluster
- Disaster recovery

### Recovery Steps
```bash
# 1. Download backup files
aws s3 cp s3://pr-secrets/age-keys/{timestamp}-recovery-key.txt recovery.key \
  --endpoint-url https://fsn1.your-objectstorage.com

aws s3 cp s3://pr-secrets/age-keys/{timestamp}-age-key-encrypted.txt encrypted.txt \
  --endpoint-url https://fsn1.your-objectstorage.com

# 2. Decrypt age private key
age -d -i recovery.key encrypted.txt

# 3. Output is your original age private key
# Use it to re-inject into cluster or decrypt secrets
```

### Re-inject into Cluster
```bash
export AGE_PRIVATE_KEY="<decrypted-key>"
kubectl create secret generic sops-age \
  --namespace=argocd \
  --from-literal=keys.txt="$AGE_PRIVATE_KEY"
```

## Security Notes
- Recovery key must be stored offline securely
- Never commit recovery key to git
- Encrypted age key is safe in S3 (requires recovery key to decrypt)
- Rotate age keys periodically and re-encrypt all secrets
