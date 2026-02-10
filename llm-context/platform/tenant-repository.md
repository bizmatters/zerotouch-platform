# Tenant Repository Setup

## What is a Tenant Repository?

A private Git repository that stores two types of information:

1. **Environment Configurations** - Server details needed to deploy Talos clusters
2. **Tenant Definitions** - Applications that should be deployed on the platform

## Why Separate from Platform Repository?

**Security:** Server IPs, passwords, and credentials never stored in the public platform repository.

**Separation:** Platform code (public) stays generic while infrastructure details (private) remain secure.

**Multi-tenancy:** Multiple tenant applications can be added without modifying platform code.

## Repository Structure

The tenant repository needs three main directories:

```text
zerotouch-tenants/
├── environments/         # Server & Infrastructure configs
│   ├── dev/
│   ├── staging/
│   └── production/
├── repositories/         # Private repo access (ExternalSecrets)
└── tenants/              # Tenant application definitions
    ├── deepagents-runtime/
    ├── ide-orchestrator/
    └── example/
```

### environments/

Contains server configurations for each environment (dev, staging, production).

Each environment has a file describing:
- Control plane server IP and credentials
- Worker node IPs and credentials
- Cluster networking configuration
- Talos and Kubernetes versions

Bootstrap scripts automatically fetch these configurations and use them to install Talos on your servers.

### tenants/

Contains definitions for each tenant application.

Each tenant directory must include:
- **Mandatory:** `overlays/{environment}/config.yaml` - ArgoCD discovery file
- Kustomize base and overlay structure
- Namespace definition

**Critical:** ArgoCD uses an ApplicationSet with a Git file generator that scans for `tenants/*/overlays/{environment}/config.yaml`. Tenants without this file will NOT be discovered or deployed.

#### Required config.yaml Structure

```yaml
# Tenant Configuration for ArgoCD ApplicationSet Discovery
tenant: <service-name>              # Tenant identifier (kebab-case)
environment: dev                    # Environment: dev, staging, production
repoURL: https://github.com/org/zerotouch-tenants.git
targetRevision: main                # Git branch to deploy from
appPath: tenants/<service-name>/overlays  # Path to overlay directory
namespace: <namespace>              # Target Kubernetes namespace
```

**Example:** `tenants/identity-service/overlays/dev/config.yaml`
```yaml
tenant: identity-service
environment: dev
repoURL: https://github.com/bizmatters/zerotouch-tenants.git
targetRevision: main
appPath: tenants/identity-service/overlays
namespace: platform-identity
```

## How It Works

### Environment Configurations

When you run bootstrap scripts, they:
1. Connect to your tenant repository using GitHub credentials
2. Fetch the environment configuration file
3. Read server IPs and other details
4. Use this information to install Talos and Kubernetes
5. Generate rescue passwords and commit them back to the repository

### Tenant Applications

After the platform is deployed, ArgoCD:
1. Watches your tenant repository for changes
2. **Discovers tenants by scanning for `tenants/*/overlays/{environment}/config.yaml` files**
3. Creates an ArgoCD Application for each discovered tenant using ApplicationSet
4. Syncs the tenant's Kubernetes manifests from the path specified in config.yaml
5. Automatically deploys and manages the tenant applications

**Discovery Mechanism:** The ApplicationSet controller uses a Git file generator with path pattern `tenants/*/overlays/dev/config.yaml` (for dev environment). Only tenants with this file are deployed. Missing config.yaml = tenant excluded from deployment.

## Security Model

**Tenant Repository:** Private repository containing references and configurations, but not actual secrets.

**AWS SSM Parameter Store:** Stores actual credentials (API keys, GitHub tokens, passwords) encrypted at rest.

**ExternalSecrets Operator:** Syncs credentials from AWS SSM into Kubernetes secrets automatically.

**Git Commits:** Only configuration files and ExternalSecret manifests are committed to Git, never plaintext secrets.

## Getting Started

To use this pattern:

1. Create a new private Git repository
2. Set up the three directories (environments, repositories, tenants)
3. Add environment configurations with your server details
4. Configure platform repository to access your tenant repository
5. Run bootstrap scripts to deploy your cluster

The platform will automatically fetch configurations, deploy infrastructure, and manage tenant applications through GitOps.
