# Tenant Management Scripts

Platform-controlled scripts for managing tenant repository structure and services.

## Scripts

### 1. `tenant-repo-boilerplate.sh`

Creates a complete tenant repository from scratch for new tenant onboarding.

**Usage:**
```bash
./tenant-repo-boilerplate.sh <repo-name> <org-name> <output-path>
```

**Example:**
```bash
./tenant-repo-boilerplate.sh zerotouch-tenants arun4infra /path/to/output
```

**Creates:**
- Complete directory structure (`tenants/`, `scripts/`, `environments/`)
- `.env` with `ORG_NAME` configured
- `.env.example` template
- `.gitignore` and `.sops.yaml`
- `README.md` with usage instructions
- Wrapper scripts that call platform scripts

**Use Case:** First-time tenant repository creation

---

### 2. `create-tenant.sh`

Creates a new service structure within an existing tenant repository.

**Usage:**
```bash
./create-tenant.sh <service-name> <tenant-repo-path> <namespace> <port> [size]
```

**Example:**
```bash
./create-tenant.sh my-api /path/to/zerotouch-tenants apis-myapi 8080 micro
```

**Creates:**
- `tenants/<service-name>/base/` - Base Kustomize resources
- `tenants/<service-name>/overlays/{dev,staging,production}/` - Environment overlays
- Deployment manifests with correct `ghcr.io/${ORG_NAME}` registry
- Migration job templates
- KSOPS secret placeholders

**Reads:**
- `ORG_NAME` from `<tenant-repo-path>/.env`

**Use Case:** Adding new microservice to existing tenant repository

---

## Design Principles

### Single Source of Truth
- Platform repository controls tenant structure
- Tenant repositories have wrapper scripts that call platform scripts
- Structure changes are made in platform, automatically propagated

### Dynamic Registry Owner
- Reads `ORG_NAME` from tenant `.env`
- Generates manifests with `ghcr.io/${ORG_NAME}/service:tag`
- No hardcoded registry owners

### Execution Model
1. Tenant repo wrapper script (`zerotouch-tenants/scripts/create-tenant.sh`)
2. Clones platform repo temporarily
3. Calls platform script (`zerotouch-platform/scripts/tenants/create-tenant.sh`)
4. Platform script generates manifests in tenant repo
5. Cleanup platform checkout

## Workflow

### Creating New Tenant Repository

```bash
# From platform repo
cd zerotouch-platform
./scripts/tenants/tenant-repo-boilerplate.sh my-tenants my-org /output/path

# Initialize git
cd /output/path/my-tenants
git init
git add .
git commit -m "Initial tenant repository"
```

### Adding Service to Tenant Repository

```bash
# From tenant repo
cd zerotouch-tenants
./scripts/create-tenant.sh my-service apis-myservice 8080 micro

# Add service secrets
echo "DEV_MYSERVICE_DATABASE_URL=..." >> tenants/my-service/.env

# Generate encrypted secrets
./scripts/sync-ksops-secrets.sh my-service

# Commit
git add tenants/my-service
git commit -m "feat: add my-service"
```

## Integration with Existing Scripts

- **Secret Generation:** `sync-ksops-secrets.sh` reads service `.env` and generates SOPS-encrypted secrets
- **Platform Secrets:** `zerotouch-platform/scripts/bootstrap/infra/secrets/ksops/generate-sops/` handles platform-level secrets
- **Tenant Secrets:** Tenant-specific secrets are managed per-service with environment prefixes

## Future Enhancements

- [ ] Support for custom resource templates (databases, caches, etc.)
- [ ] Validation of generated manifests
- [ ] Migration script to update existing tenants with correct registry owner
- [ ] CI/CD integration for automated tenant creation
