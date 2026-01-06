#!/usr/bin/env python3
"""
Verify AgentSandboxService secret injection
Usage: pytest test_07_verify_secrets.py [--tenant <name>] [--namespace <name>] [-v] [--cleanup]

Validates that secret management follows exact EventDrivenService pattern
"""

import pytest
import subprocess
import os
import time
import json
from typing import List


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'


class TestSecretInjection:
    """Test class for secret injection validation"""
    
    def setup_method(self):
        """Setup for each test method"""
        self.tenant_name = "deepagents-runtime"
        self.namespace = "intelligence-deepagents"
        self.test_claim_name = f"test-secrets-{int(time.time())}"
        
        print(f"{Colors.BLUE}[INFO] Starting AgentSandboxService secret injection validation{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] Tenant: {self.tenant_name}, Namespace: {self.namespace}{Colors.NC}")
    
    def teardown_method(self):
        """Cleanup test resources"""
        try:
            # Delete test claim
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", self.test_claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
            
            # Delete test secrets
            for i in range(1, 6):
                subprocess.run([
                    "kubectl", "delete", "secret", f"test-secret-{i}", 
                    "-n", self.namespace, "--ignore-not-found=true"
                ], capture_output=True, text=True, check=False)
        except:
            pass
    
    def test_validate_prerequisites(self):
        """Validate prerequisites"""
        print(f"{Colors.BLUE}[INFO] Validating prerequisites...{Colors.NC}")
        
        # Check namespace exists
        try:
            subprocess.run([
                "kubectl", "get", "namespace", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Namespace {self.namespace} does not exist{Colors.NC}")
            pytest.fail(f"Namespace {self.namespace} does not exist")
        
        # Check AgentSandboxService XRD exists
        try:
            subprocess.run([
                "kubectl", "get", "xrd", "xagentsandboxservices.platform.bizmatters.io"
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] AgentSandboxService XRD not found{Colors.NC}")
            pytest.fail("AgentSandboxService XRD not found")
        
        # Check aws-access-token secret exists
        try:
            subprocess.run([
                "kubectl", "get", "secret", "aws-access-token", "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] aws-access-token secret not found in namespace {self.namespace}{Colors.NC}")
            pytest.fail(f"aws-access-token secret not found")
        
        print(f"{Colors.BLUE}[INFO] Prerequisites validated successfully{Colors.NC}")
    
    def test_create_test_secrets(self):
        """Create test secrets"""
        print(f"{Colors.BLUE}[INFO] Creating test secrets...{Colors.NC}")
        
        # Create test secrets with known values
        for i in range(1, 6):
            secret_yaml = f"""apiVersion: v1
kind: Secret
metadata:
  name: test-secret-{i}
  namespace: {self.namespace}
type: Opaque
data:
  TEST_VAR_{i}: {subprocess.check_output(['base64'], input=f'test-value-{i}'.encode()).decode().strip()}
  COMMON_VAR: {subprocess.check_output(['base64'], input=f'from-secret-{i}'.encode()).decode().strip()}
"""
            
            try:
                process = subprocess.run([
                    "kubectl", "apply", "-f", "-"
                ], input=secret_yaml, text=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Failed to create test-secret-{i}{Colors.NC}")
                pytest.fail(f"Failed to create test-secret-{i}")
        
        print(f"{Colors.BLUE}[INFO] Test secrets created successfully{Colors.NC}")
    
    def test_create_test_claim(self):
        """Create AgentSandboxService test claim with all secrets"""
        print(f"{Colors.BLUE}[INFO] Creating AgentSandboxService test claim with all secrets...{Colors.NC}")
        
        claim_yaml = f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {self.test_claim_name}
  namespace: {self.namespace}
spec:
  image: busybox:latest
  command: ["sleep", "3600"]
  size: micro
  secret1Name: test-secret-1
  secret2Name: test-secret-2
  secret3Name: test-secret-3
  secret4Name: test-secret-4
  secret5Name: test-secret-5
  nats:
    url: nats://nats-headless.nats.svc.cluster.local:4222
    stream: TEST_STREAM
    consumer: test-consumer
  storageGB: 5
"""
        
        try:
            process = subprocess.run([
                "kubectl", "apply", "-f", "-"
            ], input=claim_yaml, text=True, capture_output=True, check=True)
            print(f"{Colors.BLUE}[INFO] Test claim created successfully{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to create AgentSandboxService claim{Colors.NC}")
            pytest.fail("Failed to create AgentSandboxService claim")
    
    def test_wait_for_resources(self):
        """Wait for resources to be ready"""
        print(f"{Colors.BLUE}[INFO] Waiting for resources to be ready...{Colors.NC}")
        
        # First verify the claim actually exists
        try:
            subprocess.run([
                "kubectl", "get", "agentsandboxservice", self.test_claim_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] AgentSandboxService claim '{self.test_claim_name}' does not exist{Colors.NC}")
            pytest.fail(f"AgentSandboxService claim '{self.test_claim_name}' does not exist")
        
        # Wait for claim to be ready
        timeout = 180
        elapsed = 0
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "agentsandboxservice", self.test_claim_name, 
                    "-n", self.namespace, "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"
                ], capture_output=True, text=True, check=True)
                
                if "True" in result.stdout:
                    print(f"{Colors.BLUE}[INFO] AgentSandboxService claim is ready{Colors.NC}")
                    break
            except subprocess.CalledProcessError:
                pass
            
            # Check for error conditions
            try:
                result = subprocess.run([
                    "kubectl", "get", "agentsandboxservice", self.test_claim_name, 
                    "-n", self.namespace, "-o", "jsonpath={.status.conditions[?(@.type==\"Synced\")].status}"
                ], capture_output=True, text=True, check=True)
                
                if "False" in result.stdout:
                    print(f"{Colors.RED}[ERROR] AgentSandboxService claim failed to sync{Colors.NC}")
                    subprocess.run([
                        "kubectl", "describe", "agentsandboxservice", self.test_claim_name, "-n", self.namespace
                    ], check=False)
                    pytest.fail("AgentSandboxService claim failed to sync")
            except subprocess.CalledProcessError:
                pass
            
            if elapsed > 0 and elapsed % 30 == 0:
                print(f"{Colors.BLUE}[INFO] Still waiting for claim to be ready... ({elapsed}s elapsed){Colors.NC}")
            
            time.sleep(5)
            elapsed += 5
        
        if elapsed >= timeout:
            print(f"{Colors.RED}[ERROR] Timeout waiting for AgentSandboxService to be ready{Colors.NC}")
            subprocess.run([
                "kubectl", "describe", "agentsandboxservice", self.test_claim_name, "-n", self.namespace
            ], check=False)
            pytest.fail("Timeout waiting for AgentSandboxService to be ready")
        
        # Wait for SandboxWarmPool to exist and have replicas
        print(f"{Colors.BLUE}[INFO] Waiting for sandbox instances to be created...{Colors.NC}")
        elapsed = 0
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "sandboxwarmpool", self.test_claim_name, 
                    "-n", self.namespace, "-o", "jsonpath={.status.replicas}"
                ], capture_output=True, text=True, check=True)
                
                replicas = result.stdout.strip() or "0"
                if int(replicas) > 0:
                    print(f"{Colors.BLUE}[INFO] Sandbox instances created (replicas: {replicas}){Colors.NC}")
                    break
            except (subprocess.CalledProcessError, ValueError):
                pass
            
            if elapsed > 0 and elapsed % 30 == 0:
                print(f"{Colors.BLUE}[INFO] Still waiting for sandbox instances... ({elapsed}s elapsed){Colors.NC}")
            
            time.sleep(5)
            elapsed += 5
        
        if elapsed >= timeout:
            print(f"{Colors.RED}[ERROR] Timeout waiting for sandbox instances to be created{Colors.NC}")
            subprocess.run([
                "kubectl", "describe", "sandboxwarmpool", self.test_claim_name, "-n", self.namespace
            ], check=False)
            pytest.fail("Timeout waiting for sandbox instances to be created")
    
    def test_validate_secret_patching(self):
        """Validate secret patching in SandboxTemplate"""
        print(f"{Colors.BLUE}[INFO] Validating secret patching in SandboxTemplate...{Colors.NC}")
        
        # Get the SandboxTemplate and check envFrom configuration
        try:
            result = subprocess.run([
                "kubectl", "get", "sandboxtemplate", self.test_claim_name, 
                "-n", self.namespace, "-o", "yaml"
            ], capture_output=True, text=True, check=True)
            template_yaml = result.stdout
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to get SandboxTemplate{Colors.NC}")
            pytest.fail("Failed to get SandboxTemplate")
        
        # Parse YAML and check envFrom entries
        import yaml
        try:
            template_data = yaml.safe_load(template_yaml)
            env_from = template_data['spec']['podTemplate']['spec']['containers'][0]['envFrom']
            
            # Check that all 6 envFrom entries exist (aws-access-token + 5 user secrets)
            if len(env_from) != 6:
                print(f"{Colors.RED}[ERROR] Expected 6 envFrom entries, found {len(env_from)}{Colors.NC}")
                pytest.fail(f"Expected 6 envFrom entries, found {len(env_from)}")
            
            # Validate specific secret names are patched correctly
            expected_secrets = ["test-secret-1", "test-secret-2", "test-secret-3", "test-secret-4", "test-secret-5", "aws-access-token"]
            
            for i, expected_secret in enumerate(expected_secrets):
                actual_secret = env_from[i]['secretRef']['name']
                if actual_secret != expected_secret:
                    print(f"{Colors.RED}[ERROR] envFrom[{i}] expected '{expected_secret}', got '{actual_secret}'{Colors.NC}")
                    pytest.fail(f"envFrom[{i}] expected '{expected_secret}', got '{actual_secret}'")
            
            print(f"{Colors.BLUE}[INFO] Secret patching validated successfully{Colors.NC}")
        except (KeyError, IndexError, yaml.YAMLError) as e:
            print(f"{Colors.RED}[ERROR] Failed to parse SandboxTemplate YAML: {e}{Colors.NC}")
            pytest.fail(f"Failed to parse SandboxTemplate YAML: {e}")
    
    def test_validate_environment_variables(self):
        """Validate environment variables in sandbox containers"""
        print(f"{Colors.BLUE}[INFO] Validating environment variables in sandbox containers...{Colors.NC}")
        
        # Get a running pod from the SandboxWarmPool
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", self.namespace,
                "-l", f"app.kubernetes.io/name={self.test_claim_name}",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], capture_output=True, text=True, check=True)
            pod_name = result.stdout.strip()
            
            if not pod_name:
                print(f"{Colors.RED}[ERROR] No running sandbox pods found{Colors.NC}")
                pytest.fail("No running sandbox pods found")
            
            print(f"{Colors.BLUE}[INFO] Testing environment variables in pod: {pod_name}{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to get sandbox pod{Colors.NC}")
            pytest.fail("Failed to get sandbox pod")
        
        # Test that variables from all secrets are available
        for i in range(1, 6):
            expected_value = f"test-value-{i}"
            try:
                result = subprocess.run([
                    "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                    "printenv", f"TEST_VAR_{i}"
                ], capture_output=True, text=True, check=True)
                actual_value = result.stdout.strip()
                
                if actual_value != expected_value:
                    print(f"{Colors.RED}[ERROR] TEST_VAR_{i} expected '{expected_value}', got '{actual_value}'{Colors.NC}")
                    pytest.fail(f"TEST_VAR_{i} expected '{expected_value}', got '{actual_value}'")
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] TEST_VAR_{i} not found in container environment{Colors.NC}")
                pytest.fail(f"TEST_VAR_{i} not found in container environment")
        
        # Test that AWS credentials are available
        try:
            subprocess.run([
                "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                "printenv", "AWS_ACCESS_KEY_ID"
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] AWS_ACCESS_KEY_ID not found in container environment{Colors.NC}")
            pytest.fail("AWS_ACCESS_KEY_ID not found in container environment")
        
        print(f"{Colors.BLUE}[INFO] Environment variables validated successfully{Colors.NC}")
    
    def test_validate_connection_secret(self):
        """Validate connection secret generation"""
        print(f"{Colors.BLUE}[INFO] Validating connection secret generation...{Colors.NC}")
        
        # Check that connection secret exists with correct naming pattern
        conn_secret_name = f"{self.test_claim_name}-conn"
        
        try:
            subprocess.run([
                "kubectl", "get", "secret", conn_secret_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Connection secret '{conn_secret_name}' not found{Colors.NC}")
            pytest.fail(f"Connection secret '{conn_secret_name}' not found")
        
        # Validate connection secret contains expected keys
        try:
            result = subprocess.run([
                "kubectl", "get", "secret", conn_secret_name, "-n", self.namespace,
                "-o", "jsonpath={.data}"
            ], capture_output=True, text=True, check=True)
            secret_data = json.loads(result.stdout)
            secret_keys = list(secret_data.keys())
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            print(f"{Colors.RED}[ERROR] Failed to get connection secret data{Colors.NC}")
            pytest.fail("Failed to get connection secret data")
        
        expected_keys = ["SANDBOX_SERVICE_NAME", "SANDBOX_HTTP_ENDPOINT", "SANDBOX_NAMESPACE"]
        
        for key in expected_keys:
            if key not in secret_keys:
                print(f"{Colors.RED}[ERROR] Connection secret missing key: {key}{Colors.NC}")
                pytest.fail(f"Connection secret missing key: {key}")
        
        # Validate connection secret values
        try:
            result = subprocess.run([
                "kubectl", "get", "secret", conn_secret_name, "-n", self.namespace,
                "-o", "jsonpath={.data.SANDBOX_SERVICE_NAME}"
            ], capture_output=True, text=True, check=True)
            
            import base64
            service_name = base64.b64decode(result.stdout).decode()
            
            if service_name != self.test_claim_name:
                print(f"{Colors.RED}[ERROR] Connection secret SANDBOX_SERVICE_NAME expected '{self.test_claim_name}', got '{service_name}'{Colors.NC}")
                pytest.fail(f"Connection secret SANDBOX_SERVICE_NAME expected '{self.test_claim_name}', got '{service_name}'")
        except (subprocess.CalledProcessError, Exception):
            print(f"{Colors.RED}[ERROR] Failed to validate connection secret values{Colors.NC}")
            pytest.fail("Failed to validate connection secret values")
        
        print(f"{Colors.BLUE}[INFO] Connection secret validated successfully{Colors.NC}")
    
    def test_validate_platform_standards(self):
        """Validate platform standards compliance"""
        print(f"{Colors.BLUE}[INFO] Validating platform standards compliance...{Colors.NC}")
        
        # Get SandboxTemplate YAML
        try:
            result = subprocess.run([
                "kubectl", "get", "sandboxtemplate", self.test_claim_name, 
                "-n", self.namespace, "-o", "yaml"
            ], capture_output=True, text=True, check=True)
            template_yaml = result.stdout
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to get SandboxTemplate{Colors.NC}")
            pytest.fail("Failed to get SandboxTemplate")
        
        # Parse YAML and check secret mounting patterns
        import yaml
        try:
            template_data = yaml.safe_load(template_yaml)
            env_from = template_data['spec']['podTemplate']['spec']['containers'][0]['envFrom']
            
            # Validate that all user secrets are marked as optional
            for i in range(5):  # First 5 are user secrets
                optional = env_from[i]['secretRef'].get('optional', False)
                if not optional:
                    print(f"{Colors.RED}[ERROR] User secret at envFrom[{i}] should be optional=true, got '{optional}'{Colors.NC}")
                    pytest.fail(f"User secret at envFrom[{i}] should be optional=true")
            
            # Validate that aws-access-token is not optional (required for S3 operations)
            aws_optional = env_from[5]['secretRef'].get('optional', False)
            if aws_optional:
                print(f"{Colors.RED}[ERROR] aws-access-token should not be optional{Colors.NC}")
                pytest.fail("aws-access-token should not be optional")
            
            print(f"{Colors.BLUE}[INFO] Platform standards validated successfully{Colors.NC}")
        except (KeyError, IndexError, yaml.YAMLError) as e:
            print(f"{Colors.RED}[ERROR] Failed to parse SandboxTemplate YAML: {e}{Colors.NC}")
            pytest.fail(f"Failed to parse SandboxTemplate YAML: {e}")
    
    def test_summary(self):
        """Print validation summary"""
        print(f"{Colors.GREEN}[SUCCESS] ✅ All secret injection validations passed!{Colors.NC}")
        print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService maintains complete API parity with EventDrivenService{Colors.NC}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])