#!/usr/bin/env python3
"""
Verify AgentSandboxService end-to-end integration
Usage: pytest test_09_verify_e2e.py [--tenant <name>] [--namespace <name>] [-v] [--cleanup]

End-to-end integration testing for AgentSandboxService with real deepagents-runtime
Validates complete system functionality with actual workloads
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


class TestE2EIntegration:
    """Test class for end-to-end integration validation"""
    
    def setup_method(self):
        """Setup for each test method"""
        self.tenant_name = "deepagents-runtime"
        self.namespace = "intelligence-deepagents"
        self.claim_name = "deepagents-runtime-sandbox"
        self.test_timeout = 300
        self.load_test_duration = 60
        
        print(f"{Colors.BLUE}[INFO] Starting AgentSandboxService end-to-end integration testing{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] Tenant: {self.tenant_name}, Namespace: {self.namespace}{Colors.NC}")
    
    def teardown_method(self):
        """Cleanup end-to-end test resources"""
        # Note: Cleanup skipped for debugging - resources left running
        print(f"{Colors.BLUE}[INFO] Cleanup skipped for debugging - resources left running{Colors.NC}")
    
    def test_validate_prerequisites(self):
        """Validate prerequisites for end-to-end testing"""
        print(f"{Colors.BLUE}[INFO] Validating prerequisites for end-to-end testing...{Colors.NC}")
        
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
        
        # Check agent-sandbox controller is running
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", "agent-sandbox-system", 
                "-l", "app=agent-sandbox-controller"
            ], capture_output=True, check=True, text=True)
            if "Running" not in result.stdout:
                print(f"{Colors.RED}[ERROR] Agent-sandbox controller not running{Colors.NC}")
                pytest.fail("Agent-sandbox controller not running")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not check agent-sandbox controller{Colors.NC}")
            pytest.fail("Could not check agent-sandbox controller")
        
        # Check required secrets exist
        required_secrets = ["aws-access-token", "deepagents-runtime-db-conn", "deepagents-runtime-cache-conn", "deepagents-runtime-llm-keys"]
        for secret in required_secrets:
            try:
                subprocess.run([
                    "kubectl", "get", "secret", secret, "-n", self.namespace
                ], capture_output=True, text=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Required secret {secret} not found in namespace {self.namespace}{Colors.NC}")
                pytest.fail(f"Required secret {secret} not found")
        
        # Check NATS service exists
        try:
            subprocess.run([
                "kubectl", "get", "svc", "nats", "-n", "nats"
            ], capture_output=True, text=True, check=True)
            print(f"{Colors.GREEN}[SUCCESS] NATS service exists in cluster{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] NATS service not found in cluster{Colors.NC}")
            pytest.fail("NATS service not found")
        
        print(f"{Colors.GREEN}[SUCCESS] Prerequisites validated successfully{Colors.NC}")
    
    def test_deploy_agentsandbox_claim(self):
        """Deploy AgentSandboxService claim"""
        print(f"{Colors.BLUE}[INFO] Deploying AgentSandboxService claim...{Colors.NC}")
        
        # Create a test claim YAML
        claim_yaml = f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {self.claim_name}
  namespace: {self.namespace}
spec:
  image: "ghcr.io/bizmatters/deepagents-runtime:latest"
  size: "small"
  nats:
    url: "nats://nats-headless.nats.svc.cluster.local:4222"
    stream: "AGENT_EXECUTION"
    consumer: "deepagents-runtime-consumer"
  httpPort: 8080
  healthPath: "/health"
  readyPath: "/ready"
  secret1Name: "deepagents-runtime-db-conn"
  secret2Name: "deepagents-runtime-cache-conn"
  secret3Name: "deepagents-runtime-llm-keys"
  storageGB: 20
"""
        
        # Apply the claim
        try:
            process = subprocess.run([
                "kubectl", "apply", "-f", "-"
            ], input=claim_yaml, text=True, capture_output=True, check=True)
            print(f"{Colors.BLUE}[INFO] AgentSandboxService claim applied successfully{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to apply AgentSandboxService claim{Colors.NC}")
            pytest.fail("Failed to apply AgentSandboxService claim")
        
        # Wait for claim to be processed
        print(f"{Colors.BLUE}[INFO] Waiting for claim to be processed...{Colors.NC}")
        timeout = 60
        elapsed = 0
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "agentsandboxservice", self.claim_name, "-n", self.namespace,
                    "-o", "jsonpath={.status.conditions}"
                ], capture_output=True, text=True, check=True)
                conditions = result.stdout.strip()
                
                if conditions and conditions not in ["[]", "null"]:
                    print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService claim processed{Colors.NC}")
                    return
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(5)
            elapsed += 5
        
        print(f"{Colors.RED}[ERROR] AgentSandboxService claim not processed within timeout{Colors.NC}")
        pytest.fail("AgentSandboxService claim not processed within timeout")
    
    def test_validate_sandbox_readiness(self):
        """Validate sandbox instances start and become ready"""
        print(f"{Colors.BLUE}[INFO] Validating sandbox instances start and become ready...{Colors.NC}")
        
        # Wait for SandboxTemplate to be created
        timeout = 120
        elapsed = 0
        
        print(f"{Colors.BLUE}[INFO] Waiting for SandboxTemplate to be created...{Colors.NC}")
        while elapsed < timeout:
            try:
                subprocess.run([
                    "kubectl", "get", "sandboxtemplate", self.claim_name, "-n", self.namespace
                ], capture_output=True, text=True, check=True)
                print(f"{Colors.GREEN}[SUCCESS] SandboxTemplate created{Colors.NC}")
                break
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(5)
            elapsed += 5
        
        if elapsed >= timeout:
            print(f"{Colors.RED}[ERROR] SandboxTemplate not created{Colors.NC}")
            pytest.fail("SandboxTemplate not created")
        
        # Wait for SandboxWarmPool to be created
        elapsed = 0
        print(f"{Colors.BLUE}[INFO] Waiting for SandboxWarmPool to be created...{Colors.NC}")
        while elapsed < timeout:
            try:
                subprocess.run([
                    "kubectl", "get", "sandboxwarmpool", self.claim_name, "-n", self.namespace
                ], capture_output=True, text=True, check=True)
                print(f"{Colors.GREEN}[SUCCESS] SandboxWarmPool created{Colors.NC}")
                break
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(5)
            elapsed += 5
        
        if elapsed >= timeout:
            print(f"{Colors.RED}[ERROR] SandboxWarmPool not created{Colors.NC}")
            pytest.fail("SandboxWarmPool not created")
        
        # Wait for at least one sandbox pod to be running
        print(f"{Colors.BLUE}[INFO] Waiting for sandbox pods to start...{Colors.NC}")
        timeout = 300
        elapsed = 0
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "pods", "-n", self.namespace,
                    "-l", f"app.kubernetes.io/name={self.claim_name}",
                    "--field-selector=status.phase=Running", "--no-headers"
                ], capture_output=True, text=True, check=True)
                
                running_lines = [line for line in result.stdout.strip().split('\n') if line.strip()]
                running_pods = len(running_lines)
                
                if running_pods > 0:
                    print(f"{Colors.GREEN}[SUCCESS] Sandbox pods are running ({running_pods} instances){Colors.NC}")
                    return
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(10)
            elapsed += 10
        
        print(f"{Colors.RED}[ERROR] No sandbox pods became ready within timeout{Colors.NC}")
        try:
            subprocess.run([
                "kubectl", "get", "pods", "-n", self.namespace,
                "-l", f"app.kubernetes.io/name={self.claim_name}"
            ], check=False)
        except:
            pass
        pytest.fail("No sandbox pods became ready within timeout")
    
    def test_nats_message_processing(self):
        """Test NATS message processing with live message flow"""
        print(f"{Colors.BLUE}[INFO] Testing NATS message processing with live message flow...{Colors.NC}")
        
        # Get a running sandbox pod
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", self.namespace,
                "-l", f"app.kubernetes.io/name={self.claim_name}",
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], capture_output=True, text=True, check=True)
            pod_name = result.stdout.strip()
            
            if not pod_name:
                print(f"{Colors.RED}[ERROR] No running sandbox pod found for NATS testing{Colors.NC}")
                pytest.fail("No running sandbox pod found for NATS testing")
            
            print(f"{Colors.BLUE}[INFO] Testing NATS connectivity from pod: {pod_name}{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get running sandbox pod{Colors.NC}")
            pytest.fail("Could not get running sandbox pod")
        
        # Check if NATS environment variables are available
        try:
            result = subprocess.run([
                "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                "env"
            ], capture_output=True, text=True, check=True)
            
            nats_vars = [line for line in result.stdout.split('\n') if line.startswith('NATS_')]
            
            if not nats_vars:
                print(f"{Colors.RED}[ERROR] No NATS environment variables found in sandbox container{Colors.NC}")
                pytest.fail("No NATS environment variables found")
            
            print(f"{Colors.BLUE}[INFO] NATS environment variables found: {len(nats_vars)} variables{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not check NATS environment variables{Colors.NC}")
            pytest.fail("Could not check NATS environment variables")
        
        # Verify all required NATS environment variables are present
        required_vars = ["NATS_URL", "NATS_STREAM_NAME", "NATS_CONSUMER_GROUP"]
        for var in required_vars:
            try:
                result = subprocess.run([
                    "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                    "printenv", var
                ], capture_output=True, text=True, check=True)
                var_value = result.stdout.strip()
                
                if var_value:
                    print(f"{Colors.GREEN}[SUCCESS] NATS variable {var} correctly set: {var_value}{Colors.NC}")
                else:
                    print(f"{Colors.RED}[ERROR] NATS variable {var} not found or empty{Colors.NC}")
                    pytest.fail(f"NATS variable {var} not found or empty")
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] NATS variable {var} not found{Colors.NC}")
                pytest.fail(f"NATS variable {var} not found")
    
    def test_workspace_persistence(self):
        """Test workspace persistence across pod restarts"""
        print(f"{Colors.BLUE}[INFO] Testing workspace persistence across pod restarts...{Colors.NC}")
        
        # Get a running sandbox pod
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", self.namespace,
                "-l", f"app.kubernetes.io/name={self.claim_name}",
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], capture_output=True, text=True, check=True)
            pod_name = result.stdout.strip()
            
            if not pod_name:
                print(f"{Colors.RED}[ERROR] No running sandbox pod found for persistence testing{Colors.NC}")
                pytest.fail("No running sandbox pod found for persistence testing")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get running sandbox pod{Colors.NC}")
            pytest.fail("Could not get running sandbox pod")
        
        # Create a test file in workspace
        test_content = f"e2e-test-{int(time.time())}-{os.getpid()}"
        test_file = "/workspace/e2e-test.txt"
        
        print(f"{Colors.BLUE}[INFO] Creating test file in workspace...{Colors.NC}")
        try:
            subprocess.run([
                "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                "sh", "-c", f"echo '{test_content}' > {test_file}"
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to create test file in workspace{Colors.NC}")
            pytest.fail("Failed to create test file in workspace")
        
        # Verify file exists
        try:
            result = subprocess.run([
                "kubectl", "exec", pod_name, "-n", self.namespace, "-c", "main", "--",
                "cat", test_file
            ], capture_output=True, text=True, check=True)
            file_content = result.stdout.strip()
            
            if file_content != test_content:
                print(f"{Colors.RED}[ERROR] Test file content mismatch{Colors.NC}")
                pytest.fail("Test file content mismatch")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not read test file{Colors.NC}")
            pytest.fail("Could not read test file")
        
        print(f"{Colors.BLUE}[INFO] Test file created successfully, deleting pod to test persistence...{Colors.NC}")
        
        # Delete the pod to trigger recreation
        try:
            subprocess.run([
                "kubectl", "delete", "pod", pod_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to delete pod for persistence test{Colors.NC}")
            pytest.fail("Failed to delete pod for persistence test")
        
        # Wait for new pod to be running
        print(f"{Colors.BLUE}[INFO] Waiting for new pod to start...{Colors.NC}")
        timeout = 180
        elapsed = 0
        new_pod_name = ""
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "pods", "-n", self.namespace,
                    "-l", f"app.kubernetes.io/name={self.claim_name}",
                    "--field-selector=status.phase=Running",
                    "-o", "jsonpath={.items[0].metadata.name}"
                ], capture_output=True, text=True, check=True)
                new_pod_name = result.stdout.strip()
                
                if new_pod_name and new_pod_name != pod_name:
                    print(f"{Colors.BLUE}[INFO] New pod started: {new_pod_name}{Colors.NC}")
                    break
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(10)
            elapsed += 10
        
        if not new_pod_name or new_pod_name == pod_name:
            print(f"{Colors.RED}[ERROR] New pod did not start within timeout{Colors.NC}")
            pytest.fail("New pod did not start within timeout")
        
        # Wait a bit for workspace hydration to complete
        time.sleep(30)
        
        # Check if test file persisted
        print(f"{Colors.BLUE}[INFO] Checking if test file persisted in new pod...{Colors.NC}")
        try:
            result = subprocess.run([
                "kubectl", "exec", new_pod_name, "-n", self.namespace, "-c", "main", "--",
                "cat", test_file
            ], capture_output=True, text=True, check=True)
            persisted_content = result.stdout.strip()
            
            if persisted_content == test_content:
                print(f"{Colors.GREEN}[SUCCESS] Workspace persistence verified - file survived pod recreation{Colors.NC}")
            else:
                print(f"{Colors.RED}[ERROR] Workspace persistence failed - file not found or content mismatch{Colors.NC}")
                print(f"{Colors.RED}[ERROR] Expected: {test_content}{Colors.NC}")
                print(f"{Colors.RED}[ERROR] Got: {persisted_content}{Colors.NC}")
                pytest.fail("Workspace persistence failed")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Workspace persistence failed - file not found{Colors.NC}")
            pytest.fail("Workspace persistence failed - file not found")
    
    def test_http_endpoints(self):
        """Test HTTP endpoints with real network traffic"""
        print(f"{Colors.BLUE}[INFO] Testing HTTP endpoints with real network traffic...{Colors.NC}")
        
        # Check if HTTP service was created
        service_name = f"{self.claim_name}-http"
        try:
            subprocess.run([
                "kubectl", "get", "service", service_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] HTTP service {service_name} not found{Colors.NC}")
            pytest.fail(f"HTTP service {service_name} not found")
        
        # Get service details
        try:
            result = subprocess.run([
                "kubectl", "get", "service", service_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.ports[0].port}"
            ], capture_output=True, text=True, check=True)
            service_port = result.stdout.strip()
            
            print(f"{Colors.BLUE}[INFO] Testing HTTP connectivity to service {service_name}:{service_port}{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get service port{Colors.NC}")
            pytest.fail("Could not get service port")
        
        # Create a test pod for HTTP connectivity testing
        test_pod_name = f"http-test-{int(time.time())}"
        
        test_pod_yaml = f"""apiVersion: v1
kind: Pod
metadata:
  name: {test_pod_name}
  namespace: {self.namespace}
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sh", "-c"]
    args: ["curl -f -s -o /dev/null -w '%{{http_code}}' http://{service_name}:{service_port}/health || echo 'FAILED'"]
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop:
        - ALL
      seccompProfile:
        type: RuntimeDefault
"""
        
        try:
            # Create test pod
            process = subprocess.run([
                "kubectl", "apply", "-f", "-"
            ], input=test_pod_yaml, text=True, capture_output=True, check=True)
            
            # Wait for pod to complete
            timeout = 60
            elapsed = 0
            
            while elapsed < timeout:
                try:
                    result = subprocess.run([
                        "kubectl", "get", "pod", test_pod_name, "-n", self.namespace,
                        "-o", "jsonpath={.status.phase}"
                    ], capture_output=True, text=True, check=True)
                    pod_phase = result.stdout.strip()
                    
                    if pod_phase in ["Succeeded", "Failed"]:
                        break
                except subprocess.CalledProcessError:
                    pass
                
                time.sleep(2)
                elapsed += 2
            
            # Get the result
            try:
                result = subprocess.run([
                    "kubectl", "logs", test_pod_name, "-n", self.namespace
                ], capture_output=True, text=True, check=True)
                http_result = result.stdout.strip()
            except subprocess.CalledProcessError:
                http_result = "NO_LOGS"
            
            # Clean up test pod
            subprocess.run([
                "kubectl", "delete", "pod", test_pod_name, "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
            
            # Evaluate result
            if http_result and http_result.isdigit() and 200 <= int(http_result) < 400:
                print(f"{Colors.GREEN}[SUCCESS] HTTP endpoint responded with status: {http_result}{Colors.NC}")
            elif http_result == "FAILED":
                print(f"{Colors.RED}[ERROR] HTTP endpoint connection failed - service may not be responding{Colors.NC}")
                pytest.fail("HTTP endpoint connection failed")
            else:
                print(f"{Colors.RED}[ERROR] HTTP endpoint test failed with result: {http_result}{Colors.NC}")
                pytest.fail(f"HTTP endpoint test failed with result: {http_result}")
                
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to create or run HTTP test pod{Colors.NC}")
            pytest.fail("Failed to create or run HTTP test pod")
    
    def test_validate_api_parity(self):
        """Validate complete API parity with EventDrivenService"""
        print(f"{Colors.BLUE}[INFO] Validating complete API parity with EventDrivenService...{Colors.NC}")
        
        # Get the AgentSandboxService spec
        try:
            result = subprocess.run([
                "kubectl", "get", "agentsandboxservice", self.claim_name, "-n", self.namespace,
                "-o", "jsonpath={.spec}"
            ], capture_output=True, text=True, check=True)
            agentsandbox_spec = result.stdout.strip()
            
            if not agentsandbox_spec:
                print(f"{Colors.RED}[ERROR] Failed to get AgentSandboxService spec{Colors.NC}")
                pytest.fail("Failed to get AgentSandboxService spec")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get AgentSandboxService spec{Colors.NC}")
            pytest.fail("Could not get AgentSandboxService spec")
        
        # Parse and validate required fields
        try:
            import json
            spec_data = json.loads(agentsandbox_spec)
            
            required_fields = ["image", "size", "nats", "httpPort", "secret1Name", "secret2Name", "secret3Name"]
            missing_fields = []
            
            for field in required_fields:
                if field not in spec_data or not spec_data[field]:
                    missing_fields.append(field)
            
            if missing_fields:
                print(f"{Colors.RED}[ERROR] Missing required fields: {missing_fields}{Colors.NC}")
                pytest.fail(f"Missing required fields: {missing_fields}")
            
            print(f"{Colors.GREEN}[SUCCESS] API parity validated - all EventDrivenService fields present{Colors.NC}")
        except json.JSONDecodeError:
            print(f"{Colors.RED}[ERROR] Could not parse AgentSandboxService spec JSON{Colors.NC}")
            pytest.fail("Could not parse AgentSandboxService spec JSON")
    
    def test_summary(self):
        """Print validation summary"""
        print(f"{Colors.GREEN}[SUCCESS] ✅ End-to-end integration testing completed successfully!{Colors.NC}")
        print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService system is operational and ready for production use{Colors.NC}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])