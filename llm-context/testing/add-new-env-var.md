# Adding New Environment Variables to SSM Parameter Store

## Overview
When adding new services or environment variables, you need to update the SSM parameter injection workflow to include the new parameters.

## Steps

### 1. Update the Parameter List
Edit `<service-repo>/.github/workflows/inject-secrets.yml`:

eg. PR_POSTGRES_URI, DEV_POSTGRES_URI and so on...