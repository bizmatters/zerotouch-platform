## Test Validation Workflow

## Explanation:

ArgoCD Application exists and discovered the tenant
ArgoCD synced secrets and Dragonfly (wave 0)
Migration job (wave 2) failed with old secret reference
WebService (wave 6) never deployed because migration hook blocking
WebService CRD would create the actual Deployment, but it's stuck OutOfSync

**1. Deploy Service to Cluster:**
- Apply kustomization: `kubectl apply -k zerotouch-tenants/tenants/identity-service/overlays/dev`
- Verify deployment phases: namespace → secrets → Dragonfly → migrations (wave 2) → service (wave 6)

**2. Validate Deployment:**
- Check migration job completion: `kubectl get job identity-service-migrations -n platform-identity`
- Check service pods running: `kubectl get pods -n platform-identity`
- Check service health: `kubectl logs -n platform-identity -l app=identity-service`
- Service deployment
    - kubectl get application -n argocd | grep identity
    - kubectl get application identity-service -n argocd -o yaml | grep -A 10 "status:"
    - kubectl get deployment -n platform-identity
    - kubectl get webservice -n platform-identity

**3. Run In-Cluster Integration Tests:**
- Build test image: `docker build -t identity-service:ci-test identity-service/`
- Load to cluster: `kind load docker-image identity-service:ci-test --name zerotouch-preview`
- Execute tests: `./identity-service/scripts/ci/in-cluster-test.sh`

**4. Validate Test Execution:**
- Tests use single `DATABASE_URL` from KSOPS secret
- Tests connect to external Neon DB
- Tests validate service endpoints and business logic

**Next Step:** Deploy service first, then run integration tests against deployed service.