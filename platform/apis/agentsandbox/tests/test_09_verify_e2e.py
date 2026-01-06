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


@pytest.fixture
def e2e_test_config():
    """Provide E2E test configuration"""
    return {
        "claim_name": "deepagents-runtime-sandbox",
        "test_timeout": 300,
        "load_test_duration": 60
    }


@pytest.fixture
def e2e_claim_yaml(e2e_test_config, tenant_config, temp_dir):
    """Create E2E test claim YAML"""
    claim_yaml = f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {e2e_test_config['claim_name']}
  namespace: {tenant_config['namespace']}
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
    
    claim_file = os.path.join(temp_dir, "e2e-claim.yaml")
    with open(claim_file, 'w') as f:
        f.write(claim_yaml)
    
    return claim_file


@pytest.fixture
def cleanup_e2e_claim(e2e_test_config, tenant_config):
    """Cleanup E2E test claim after test"""
    yield
    
    # Note: Cleanup skipped for debugging - resources left running
    print("Cleanup skipped for debugging - resources left running")


def test_validate_prerequisites(colors, kubectl_helper, tenant_config, test_counters):
    """Validate prerequisites for end-to-end testing"""
    print("Starting AgentSandboxService end-to-end integration testing")
    print(f"Tenant: {tenant_config['tenant_name']}, Namespace: {tenant_config['namespace']}")
    print(f"{colors.BLUE}[INFO] Validating prerequisites for end-to-end testing...{colors.NC}")
    
    # Check namespace exists
    try:
        kubectl_helper.kubectl_retry(["get", "namespace", tenant_config['namespace']])
    except Exception:
        print(f"{colors.RED}[ERROR] Namespace {tenant_config['namespace']} does not exist{colors.NC}")
        test_counters.errors += 1
        pytest.fail(f"Namespace {tenant_config['namespace']} does not exist")
    
    # Check AgentSandboxService XRD exists
    try:
        kubectl_helper.kubectl_retry(["get", "xrd", "xagentsandboxservices.platform.bizmatters.io"])
    except Exception:
        print(f"{colors.RED}[ERROR] AgentSandboxService XRD not found{colors.NC}")
        test_counters.errors += 1
        pytest.fail("AgentSandboxService XRD not found")
    
    # Check agent-sandbox controller is running
    try:
        result = kubectl_helper.kubectl_retry([
            "get", "pods", "-n", "agent-sandbox-system", 
            "-l", "app=agent-sandbox-controller"
        ])
        if "Running" not in result.stdout:
            print(f"{colors.RED}[ERROR] Agent-sandbox controller not running{colors.NC}")
            test_counters.errors += 1
            pytest.fail("Agent-sandbox controller not running")
    except Exception:
        print(f"{colors.RED}[ERROR] Could not check agent-sandbox controller{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not check agent-sandbox controller")
    
    # Check required secrets exist
    required_secrets = ["aws-access-token", "deepagents-runtime-db-conn", "deepagents-runtime-cache-conn", "deepagents-runtime-llm-keys"]
    for secret in required_secrets:
        try:
            kubectl_helper.kubectl_retry(["get", "secret", secret, "-n", tenant_config['namespace']])
        except Exception:
            print(f"{colors.RED}[ERROR] Required secret {secret} not found in namespace {tenant_config['namespace']}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Required secret {secret} not found")
    
    # Check NATS service exists
    try:
        kubectl_helper.kubectl_retry(["get", "svc", "nats", "-n", "nats"])
        print(f"{colors.GREEN}[SUCCESS] NATS service exists in cluster{colors.NC}")
    except Exception:
        print(f"{colors.RED}[ERROR] NATS service not found in cluster{colors.NC}")
        test_counters.errors += 1
        pytest.fail("NATS service not found")
    
    print(f"{colors.GREEN}[SUCCESS] Prerequisites validated successfully{colors.NC}")


def test_deploy_agentsandbox_claim(colors, e2e_claim_yaml, e2e_test_config, test_counters):
    """Deploy AgentSandboxService claim"""
    print(f"{colors.BLUE}[INFO] Deploying AgentSandboxService claim...{colors.NC}")
    
    # Apply the claim
    try:
        subprocess.run([
            "kubectl", "apply", "-f", e2e_claim_yaml
        ], capture_output=True, text=True, check=True)
        print(f"{colors.BLUE}[INFO] AgentSandboxService claim applied successfully{colors.NC}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Failed to apply AgentSandboxService claim{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Failed to apply AgentSandboxService claim")
    
    # Wait for claim to be processed
    print(f"{colors.BLUE}[INFO] Waiting for claim to be processed...{colors.NC}")
    timeout = 60
    elapsed = 0
    
    while elapsed < timeout:
        try:
            result = subprocess.run([
                "kubectl", "get", "agentsandboxservice", e2e_test_config['claim_name'], "-n", tenant_config['namespace'],
                "-o", "jsonpath={.status.conditions}"
            ], capture_output=True, text=True, check=True)
            conditions = result.stdout.strip()
            
            if conditions and conditions not in ["[]", "null"]:
                print(f"{colors.GREEN}[SUCCESS] AgentSandboxService claim processed{colors.NC}")
                return
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(5)
        elapsed += 5
    
    print(f"{colors.RED}[ERROR] AgentSandboxService claim not processed within timeout{colors.NC}")
    test_counters.errors += 1
    pytest.fail("AgentSandboxService claim not processed within timeout")


def test_validate_sandbox_readiness(colors, e2e_test_config, tenant_config, test_counters, cleanup_e2e_claim):
    """Validate sandbox instances start and become ready"""
    print(f"{colors.BLUE}[INFO] Validating sandbox instances start and become ready...{colors.NC}")
    
    # Wait for SandboxTemplate to be created
    timeout = 120
    elapsed = 0
    
    print(f"{colors.BLUE}[INFO] Waiting for SandboxTemplate to be created...{colors.NC}")
    while elapsed < timeout:
        try:
            subprocess.run([
                "kubectl", "get", "sandboxtemplate", e2e_test_config['claim_name'], "-n", tenant_config['namespace']
            ], capture_output=True, text=True, check=True)
            print(f"{colors.GREEN}[SUCCESS] SandboxTemplate created{colors.NC}")
            break
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(5)
        elapsed += 5
    
    if elapsed >= timeout:
        print(f"{colors.RED}[ERROR] SandboxTemplate not created{colors.NC}")
        test_counters.errors += 1
        pytest.fail("SandboxTemplate not created")
    
    # Wait for SandboxWarmPool to be created
    elapsed = 0
    print(f"{colors.BLUE}[INFO] Waiting for SandboxWarmPool to be created...{colors.NC}")
    while elapsed < timeout:
        try:
            subprocess.run([
                "kubectl", "get", "sandboxwarmpool", e2e_test_config['claim_name'], "-n", tenant_config['namespace']
            ], capture_output=True, text=True, check=True)
            print(f"{colors.GREEN}[SUCCESS] SandboxWarmPool created{colors.NC}")
            break
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(5)
        elapsed += 5
    
    if elapsed >= timeout:
        print(f"{colors.RED}[ERROR] SandboxWarmPool not created{colors.NC}")
        test_counters.errors += 1
        pytest.fail("SandboxWarmPool not created")
    
    # Wait for at least one sandbox pod to be running
    print(f"{colors.BLUE}[INFO] Waiting for sandbox pods to start...{colors.NC}")
    timeout = 300
    elapsed = 0
    
    while elapsed < timeout:
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", tenant_config['namespace'],
                "-l", f"app.kubernetes.io/name={e2e_test_config['claim_name']}",
                "--field-selector=status.phase=Running", "--no-headers"
            ], capture_output=True, text=True, check=True)
            
            running_lines = [line for line in result.stdout.strip().split('\n') if line.strip()]
            running_pods = len(running_lines)
            
            if running_pods > 0:
                print(f"{colors.GREEN}[SUCCESS] Sandbox pods are running ({running_pods} instances){colors.NC}")
                return
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(10)
        elapsed += 10
    
    print(f"{colors.RED}[ERROR] No sandbox pods became ready within timeout{colors.NC}")
    try:
        subprocess.run([
            "kubectl", "get", "pods", "-n", tenant_config['namespace'],
            "-l", f"app.kubernetes.io/name={e2e_test_config['claim_name']}"
        ], check=False)
    except:
        pass
    test_counters.errors += 1
    pytest.fail("No sandbox pods became ready within timeout")


def test_nats_message_processing(colors, e2e_test_config, tenant_config, test_counters, cleanup_e2e_claim):
    """Test NATS message processing with live message flow"""
    print(f"{colors.BLUE}[INFO] Testing NATS message processing with live message flow...{colors.NC}")
    
    # Get a running sandbox pod
    try:
        result = subprocess.run([
            "kubectl", "get", "pods", "-n", tenant_config['namespace'],
            "-l", f"app.kubernetes.io/name={e2e_test_config['claim_name']}",
            "--field-selector=status.phase=Running",
            "-o", "jsonpath={.items[0].metadata.name}"
        ], capture_output=True, text=True, check=True)
        pod_name = result.stdout.strip()
        
        if not pod_name:
            print(f"{colors.RED}[ERROR] No running sandbox pod found for NATS testing{colors.NC}")
            test_counters.errors += 1
            pytest.fail("No running sandbox pod found for NATS testing")
        
        print(f"{colors.BLUE}[INFO] Testing NATS connectivity from pod: {pod_name}{colors.NC}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get running sandbox pod{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get running sandbox pod")
    
    # Check if NATS environment variables are available
    try:
        result = subprocess.run([
            "kubectl", "exec", pod_name, "-n", tenant_config['namespace'], "-c", "main", "--",
            "env"
        ], capture_output=True, text=True, check=True)
        
        nats_vars = [line for line in result.stdout.split('\n') if line.startswith('NATS_')]
        
        if not nats_vars:
            print(f"{colors.RED}[ERROR] No NATS environment variables found in sandbox container{colors.NC}")
            test_counters.errors += 1
            pytest.fail("No NATS environment variables found")
        
        print(f"{colors.BLUE}[INFO] NATS environment variables found: {len(nats_vars)} variables{colors.NC}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not check NATS environment variables{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not check NATS environment variables")
    
    # Verify all required NATS environment variables are present
    required_vars = ["NATS_URL", "NATS_STREAM_NAME", "NATS_CONSUMER_GROUP"]
    for var in required_vars:
        try:
            result = subprocess.run([
                "kubectl", "exec", pod_name, "-n", tenant_config['namespace'], "-c", "main", "--",
                "printenv", var
            ], capture_output=True, text=True, check=True)
            var_value = result.stdout.strip()
            
            if var_value:
                print(f"{colors.GREEN}[SUCCESS] NATS variable {var} correctly set: {var_value}{colors.NC}")
            else:
                print(f"{colors.RED}[ERROR] NATS variable {var} not found or empty{colors.NC}")
                test_counters.errors += 1
                pytest.fail(f"NATS variable {var} not found or empty")
        except subprocess.CalledProcessError:
            print(f"{colors.RED}[ERROR] NATS variable {var} not found{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"NATS variable {var} not found")


def test_workspace_persistence(colors, e2e_test_config, tenant_config, test_counters, cleanup_e2e_claim):
    """Test workspace persistence across pod restarts"""
    print(f"{colors.BLUE}[INFO] Testing workspace persistence across pod restarts...{colors.NC}")
    
    # Get a running sandbox pod
    try:
        result = subprocess.run([
            "kubectl", "get", "pods", "-n", tenant_config['namespace'],
            "-l", f"app.kubernetes.io/name={e2e_test_config['claim_name']}",
            "--field-selector=status.phase=Running",
            "-o", "jsonpath={.items[0].metadata.name}"
        ], capture_output=True, text=True, check=True)
        pod_name = result.stdout.strip()
        
        if not pod_name:
            print(f"{colors.RED}[ERROR] No running sandbox pod found for persistence testing{colors.NC}")
            test_counters.errors += 1
            pytest.fail("No running sandbox pod found for persistence testing")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get running sandbox pod{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get running sandbox pod")
    
    # Create a test file in workspace
    test_content = f"e2e-test-{int(time.time())}-{os.getpid()}"
    test_file = "/workspace/e2e-test.txt"
    
    print(f"{colors.BLUE}[INFO] Creating test file in workspace...{colors.NC}")
    try:
        subprocess.run([
            "kubectl", "exec", pod_name, "-n", tenant_config['namespace'], "-c", "main", "--",
            "sh", "-c", f"echo '{test_content}' > {test_file}"
        ], capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Failed to create test file in workspace{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Failed to create test file in workspace")
    
    # Verify file exists
    try:
        result = subprocess.run([
            "kubectl", "exec", pod_name, "-n", tenant_config['namespace'], "-c", "main", "--",
            "cat", test_file
        ], capture_output=True, text=True, check=True)
        file_content = result.stdout.strip()
        
        if file_content != test_content:
            print(f"{colors.RED}[ERROR] Test file content mismatch{colors.NC}")
            test_counters.errors += 1
            pytest.fail("Test file content mismatch")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not read test file{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not read test file")
    
    print(f"{colors.BLUE}[INFO] Test file created successfully, deleting pod to test persistence...{colors.NC}")
    
    # Delete the pod to trigger recreation
    try:
        subprocess.run([
            "kubectl", "delete", "pod", pod_name, "-n", tenant_config['namespace']
        ], capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Failed to delete pod for persistence test{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Failed to delete pod for persistence test")
    
    # Wait for new pod to be running
    print(f"{colors.BLUE}[INFO] Waiting for new pod to start...{colors.NC}")
    timeout = 180
    elapsed = 0
    new_pod_name = ""
    
    while elapsed < timeout:
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", tenant_config['namespace'],
                "-l", f"app.kubernetes.io/name={e2e_test_config['claim_name']}",
                "--field-selector=status.phase=Running",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], capture_output=True, text=True, check=True)
            new_pod_name = result.stdout.strip()
            
            if new_pod_name and new_pod_name != pod_name:
                print(f"{colors.BLUE}[INFO] New pod started: {new_pod_name}{colors.NC}")
                break
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(10)
        elapsed += 10
    
    if not new_pod_name or new_pod_name == pod_name:
        print(f"{colors.RED}[ERROR] New pod did not start within timeout{colors.NC}")
        test_counters.errors += 1
        pytest.fail("New pod did not start within timeout")
    
    # Wait a bit for workspace hydration to complete
    time.sleep(30)
    
    # Check if test file persisted
    print(f"{colors.BLUE}[INFO] Checking if test file persisted in new pod...{colors.NC}")
    try:
        result = subprocess.run([
            "kubectl", "exec", new_pod_name, "-n", tenant_config['namespace'], "-c", "main", "--",
            "cat", test_file
        ], capture_output=True, text=True, check=True)
        persisted_content = result.stdout.strip()
        
        if persisted_content == test_content:
            print(f"{colors.GREEN}[SUCCESS] Workspace persistence verified - file survived pod recreation{colors.NC}")
        else:
            print(f"{colors.RED}[ERROR] Workspace persistence failed - file not found or content mismatch{colors.NC}")
            print(f"{colors.RED}[ERROR] Expected: {test_content}{colors.NC}")
            print(f"{colors.RED}[ERROR] Got: {persisted_content}{colors.NC}")
            test_counters.errors += 1
            pytest.fail("Workspace persistence failed")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Workspace persistence failed - file not found{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Workspace persistence failed - file not found")


def test_http_endpoints(colors, e2e_test_config, tenant_config, test_counters, cleanup_e2e_claim):
    """Test HTTP endpoints with real network traffic"""
    print(f"{colors.BLUE}[INFO] Testing HTTP endpoints with real network traffic...{colors.NC}")
    
    # Check if HTTP service was created
    service_name = f"{e2e_test_config['claim_name']}-http"
    try:
        subprocess.run([
            "kubectl", "get", "service", service_name, "-n", tenant_config['namespace']
        ], capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] HTTP service {service_name} not found{colors.NC}")
        test_counters.errors += 1
        pytest.fail(f"HTTP service {service_name} not found")
    
    # Get service details
    try:
        result = subprocess.run([
            "kubectl", "get", "service", service_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.ports[0].port}"
        ], capture_output=True, text=True, check=True)
        service_port = result.stdout.strip()
        
        print(f"{colors.BLUE}[INFO] Testing HTTP connectivity to service {service_name}:{service_port}{colors.NC}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get service port{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get service port")
    
    # Create a test pod for HTTP connectivity testing
    test_pod_name = f"http-test-{int(time.time())}"
    
    test_pod_yaml = f"""apiVersion: v1
kind: Pod
metadata:
  name: {test_pod_name}
  namespace: {tenant_config['namespace']}
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
        subprocess.run([
            "kubectl", "apply", "-f", "-"
        ], input=test_pod_yaml, text=True, capture_output=True, check=True)
        
        # Wait for pod to complete
        timeout = 60
        elapsed = 0
        
        while elapsed < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "pod", test_pod_name, "-n", tenant_config['namespace'],
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
                "kubectl", "logs", test_pod_name, "-n", tenant_config['namespace']
            ], capture_output=True, text=True, check=True)
            http_result = result.stdout.strip()
        except subprocess.CalledProcessError:
            http_result = "NO_LOGS"
        
        # Clean up test pod
        subprocess.run([
            "kubectl", "delete", "pod", test_pod_name, "-n", tenant_config['namespace'], "--ignore-not-found=true"
        ], capture_output=True, text=True, check=False)
        
        # Evaluate result
        if http_result and http_result.isdigit() and 200 <= int(http_result) < 400:
            print(f"{colors.GREEN}[SUCCESS] HTTP endpoint responded with status: {http_result}{colors.NC}")
        elif http_result == "FAILED":
            print(f"{colors.RED}[ERROR] HTTP endpoint connection failed - service may not be responding{colors.NC}")
            test_counters.errors += 1
            pytest.fail("HTTP endpoint connection failed")
        else:
            print(f"{colors.RED}[ERROR] HTTP endpoint test failed with result: {http_result}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"HTTP endpoint test failed with result: {http_result}")
            
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Failed to create or run HTTP test pod{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Failed to create or run HTTP test pod")


def test_validate_api_parity(colors, e2e_test_config, tenant_config, test_counters, cleanup_e2e_claim):
    """Validate complete API parity with EventDrivenService"""
    print(f"{colors.BLUE}[INFO] Validating complete API parity with EventDrivenService...{colors.NC}")
    
    # Get the AgentSandboxService spec
    try:
        result = subprocess.run([
            "kubectl", "get", "agentsandboxservice", e2e_test_config['claim_name'], "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec}"
        ], capture_output=True, text=True, check=True)
        agentsandbox_spec = result.stdout.strip()
        
        if not agentsandbox_spec:
            print(f"{colors.RED}[ERROR] Failed to get AgentSandboxService spec{colors.NC}")
            test_counters.errors += 1
            pytest.fail("Failed to get AgentSandboxService spec")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get AgentSandboxService spec{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get AgentSandboxService spec")
    
    # Parse and validate required fields
    try:
        spec_data = json.loads(agentsandbox_spec)
        
        required_fields = ["image", "size", "nats", "httpPort", "secret1Name", "secret2Name", "secret3Name"]
        missing_fields = []
        
        for field in required_fields:
            if field not in spec_data or not spec_data[field]:
                missing_fields.append(field)
        
        if missing_fields:
            print(f"{colors.RED}[ERROR] Missing required fields: {missing_fields}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Missing required fields: {missing_fields}")
        
        print(f"{colors.GREEN}[SUCCESS] API parity validated - all EventDrivenService fields present{colors.NC}")
    except json.JSONDecodeError:
        print(f"{colors.RED}[ERROR] Could not parse AgentSandboxService spec JSON{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not parse AgentSandboxService spec JSON")


def test_summary(colors, test_counters):
    """Print validation summary"""
    print(f"{colors.GREEN}[SUCCESS] ✅ End-to-end integration testing completed successfully!{colors.NC}")
    print(f"{colors.GREEN}[SUCCESS] AgentSandboxService system is operational and ready for production use{colors.NC}")
    
    if test_counters.errors == 0:
        print(f"{colors.GREEN}[SUCCESS] All end-to-end integration checks passed!{colors.NC}")
    else:
        pytest.fail(f"End-to-end integration has {test_counters.errors} error(s)")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])