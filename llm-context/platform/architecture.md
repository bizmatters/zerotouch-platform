# DeepAgents Runtime - Platform Architecture

## Current Architecture (Crossplane + ArgoCD Separation of Concerns)

**ArgoCD Role:**
- Deploys application manifests (Deployments, Services, ConfigMaps)
- Manages External Secrets for application configuration
- Handles GitOps workflow and sync waves
- Syncs tenant applications from `zerotouch-tenants/` repository

**Crossplane Role:**
- Provisions infrastructure ONLY (PostgreSQL, Redis/Dragonfly, S3 buckets)
- Creates infrastructure connection secrets automatically
- Does NOT generate application Deployments
- Manages infrastructure lifecycle (create, update, delete)

**Platform Abstraction:**
- Infrastructure: Crossplane Claims (PostgresInstance, DragonflyInstance)
- Applications: Standard Kubernetes manifests (Deployment, Service)
- Secrets: ExternalSecrets Operator syncs from AWS SSM
- Overlays: Kustomize handles environment-specific configuration

## Resource Flow

1. **ArgoCD** reads kustomization and deploys resources:
   ```yaml
   # Infrastructure Claims (Crossplane provisions)
   apiVersion: database.bizmatters.io/v1alpha1
   kind: PostgresInstance
   
   # Application Manifests (ArgoCD deploys)
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: identity-service
   spec:
     template:
       spec:
         containers:
         - name: identity-service
           envFrom:
           - secretRef:
               name: identity-service-db  # From ExternalSecret
   ```

2. **Crossplane** provisions infrastructure:
   - Creates PostgreSQL database instance
   - Generates connection secrets (identity-service-db-conn)
   - Does NOT create application Deployments

3. **External Secrets Operator** syncs application secrets from AWS SSM:
   - Database credentials (from Crossplane or external)
   - JWT keys (jwt_private_key, jwt_public_key)
   - API keys (openai_api_key, etc.)
   - Image pull secrets (ghcr-pull-secret)

4. **ArgoCD** deploys application Deployment:
   - References ExternalSecrets for configuration
   - Mounts secrets as environment variables
   - Manages application lifecycle independently of infrastructure

## Key Benefits

- **Clear Separation:** Infrastructure (Crossplane) vs Applications (ArgoCD)
- **Platform Team:** Provides infrastructure abstractions via Crossplane Claims
- **Developers:** Write standard Kubernetes manifests, reference infrastructure secrets
- **GitOps:** ArgoCD handles application deployment, Crossplane handles infrastructure provisioning
- **No Manual Configuration:** Infrastructure secrets auto-generated, application secrets synced from SSM

Both tools work together with clear boundaries - ArgoCD deploys applications, Crossplane provisions infrastructure.