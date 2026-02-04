## Complete KSOPS Key Management Changes Summary

**Core Problems:**
1. Key regeneration breaks existing encrypted secrets
2. No active key identification in S3
3. No key rotation strategy

**Required Changes:**

**1. Idempotency (08b-generate-age-keys.sh)**
- Check if `sops-age` secret exists → reuse existing key
- Only generate new key on first bootstrap

**2. .sops.yaml Sync (08b-generate-age-keys.sh)**
- Auto-update `.sops.yaml` with generated public key after generation

**3. Active Key Marking (08b-backup-age-to-s3.sh)**
- After timestamped upload, copy to `ACTIVE-age-key-encrypted.txt` and `ACTIVE-recovery-key.txt`
- Overwrite on rotation (don't delete old timestamped backups)

**4. Key Rotation Strategy**
- Keep all timestamped backups in S3
- Overwrite `ACTIVE-*` pointer files
- Re-encrypt secrets with new key
- Optional: lifecycle policy for old key cleanup

**Outcome:** Prevents accidental breakage, enables deterministic recovery, supports safe key rotation.