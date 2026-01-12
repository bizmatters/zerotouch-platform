# To Test argocd sync options without recreating cluster: 
- kubectl delete namespace argocd --wait=false
- sleep 5 && kubectl get namespace argocd 2>/dev/null || echo "ArgoCD namespace deleted"
- ./scripts/bootstrap/install/09-install-argocd.sh production dev

If you need it to terminate completely, you can try:
```bash
kubectl delete namespace argocd --force --grace-period=0
```

Or if there are stuck finalizers, you might need to patch the namespace:

```bash
kubectl patch namespace argocd -p '{"metadata":{"finalizers":null}}' --type=merge
```

```bash
kubectl get namespace argocd -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
```
# Argocd apps Sync issue:
cat zerotouch-platform/platform/apis/object-storage/composition.yaml | python3 -c "import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin)))" > /tmp/git-comp.json
kubectl get composition s3-bucket -o json | jq 'del(.metadata.annotations, .metadata.creationTimestamp, .metadata.generation, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields)' > /tmp/cluster-comp.json
diff <(jq -S '.spec' /tmp/git-comp.json) <(jq -S '.spec' /tmp/cluster-comp.json) | head -20