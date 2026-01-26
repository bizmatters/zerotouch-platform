# Adding New Environment Variables to SSM Parameter Store

## Overview
When adding new services or environment variables, you need to update the SSM parameter generation script to include the new parameters.

## Steps

### 1. Update the Parameter List
Edit `zerotouch-platform/scripts/bootstrap/helpers/generate-env-ssm.sh`:

Add your service parameters to the `PARAM_LIST`:
```bash
/zerotouch/prod/<service-name>/<param-name>=
```

Example for deepagents-runtime:
```bash
/zerotouch/prod/deepagents-runtime/postgres_uri=
/zerotouch/prod/deepagents-runtime/openai_api_key=
/zerotouch/prod/deepagents-runtime/anthropic_api_key=
```

### 2. Add Environment Variable Mappings
In the same file, add the mapping from SSM path to environment variable name:

```bash
# <Service Name> secrets
/zerotouch/prod/<service-name>/<param-name>) env_var="ENV_VAR_NAME" ;;
```

Example for deepagents-runtime:
```bash
# DeepAgents Runtime secrets
/zerotouch/prod/deepagents-runtime/postgres_uri) env_var="POSTGRES_URI" ;;
/zerotouch/prod/deepagents-runtime/openai_api_key) env_var="OPENAI_API_KEY" ;;
/zerotouch/prod/deepagents-runtime/anthropic_api_key) env_var="ANTHROPIC_API_KEY" ;;
```

### 3. Inject Parameters to SSM
From your service directory, run:

```bash
rm -f .env.ssm && export $(grep -v '^#' .env | xargs) && ./zerotouch-platform/scripts/bootstrap/install/08-inject-ssm-parameters.sh
```

This will:
1. Generate `.env.ssm` from your `.env` file
2. Create SSM parameters in AWS Parameter Store
3. External Secrets Operator will automatically sync them to Kubernetes secrets

### 4. Verify
Check that parameters were created:
```bash
aws ssm get-parameters-by-path --path /zerotouch/prod/<service-name> --recursive --region ap-south-1
```

Check that External Secrets synced:
```bash
kubectl get externalsecret -n <namespace>
kubectl get secret <secret-name> -n <namespace>
```
