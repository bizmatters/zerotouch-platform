## Pre-Deployment Conditions for identity-service



**1. Cluster Prerequisites:**
- Cluster Reachability
    - kubectl cluster-info
- Namespace `platform-identity` must exist
    - kubectl get namespace platform-identity
    - kubectl get crd dragonflyinstances.database.bizmatters.io
- KSOPS/SOPS decryption configured (AGE key available)
    - which sops
- Platform XRDs installed: `DragonflyInstance` CRD
    - kubectl get dragonflyinstance -n platform-identity
- GHCR pull secret (`ghcr-pull-secret`) in namespace
    - kubectl get secret ghcr-pull-secret -n platform-identity

**2. Secret Dependencies:**
- All 6 KSOPS secrets decrypted and available in `overlays/dev/secrets/`
    - sops -d zerotouch-tenants/tenants/identity-service/overlays/dev/secrets/database-url.secret.yaml 2>&1 | head -5

**3. Infrastructure Claims:**
- Dragonfly cache instance will be provisioned (sync-wave: 0)
    - kubectl get crd dragonflyinstances.database.bizmatters.io
- No PostgreSQL claim (using external Neon DB)

**4. Migration Job Issues:**
- References `identity-service-db` secret (should be `database-url`)
- Runs at sync-wave: 2 (before app deployment at wave: 6)

## Pre-Deployment Validation Report
✅ **Cluster Reachable:** Control plane at 95.216.151.243:6443
✅ **Namespace:** `platform-identity` exists (Active, 136m)
✅ **CRD Available:** `dragonflyinstances.database.bizmatters.io` installed
✅ **Image Pull Secret:** `ghcr-pull-secret` present in namespace
✅ **Dragonfly Cache:** `identity-service-cache` already provisioned (SYNCED, READY)

**Ready for Deployment** - All prerequisites met. KSOPS secrets need decryption during kustomize build.