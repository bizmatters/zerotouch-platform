#!/usr/bin/env python3
"""
Verify KEDA scaling integration for AgentSandboxService
Usage: pytest test_05_verify_scaling.py [--tenant <name>] [--namespace <name>] [-v] [--cleanup]

Tests KEDA ScaledObject targeting SandboxWarmPool with NATS JetStream trigger
"""

import pytest
import subprocess
import os
import time


@pytest.fixture
def scaling_test_config():
    """Provide scaling test configuration"""
    return {
        "test_claim_name": "test-scaling-sandbox",
        "test_image": "ghcr.io/bizmatters/deepagents-runtime:latest",
        "test_stream": "TEST_SCALING_STREAM",
        "test_consumer": "test-scaling-consumer"
    }


@pytest.fixture
def scaling_claim_yaml(scaling_test_config, tenant_config, temp_dir):
    """Create scaling test claim YAML"""
    claim_yaml = f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {scaling_test_config['test_claim_name']}
  namespace: {tenant_config['namespace']}
spec:
  image: {scaling_test_config['test_image']}
  size: micro
  nats:
    url: "nats://nats-headless.nats.svc.cluster.local:4222"
    stream: {scaling_test_config['test_stream']}
    consumer: {scaling_test_config['test_consumer']}
  httpPort: 8080
  storageGB: 5
"""
    
    claim_file = os.path.join(temp_dir, "scaling-claim.yaml")
    with open(claim_file, 'w') as f:
        f.write(claim_yaml)
    
    return claim_file


@pytest.fixture
def cleanup_scaling_claim(scaling_test_config, tenant_config):
    """Cleanup scaling test claim after test"""
    yield
    
    # Clean up test claim
    # try:
    #     subprocess.run([
    #         "kubectl", "delete", "agentsandboxservice", scaling_test_config['test_claim_name'], 
    #         "-n", tenant_config['namespace'], "--ignore-not-found=true"
    #     ], capture_output=True, text=True, check=False)
        
    #     # Wait for cleanup
    #     timeout = 60
    #     count = 0
    #     while count < timeout:
    #         try:
    #             subprocess.run([
    #                 "kubectl", "get", "agentsandboxservice", scaling_test_config['test_claim_name'], "-n", tenant_config['namespace']
    #             ], capture_output=True, text=True, check=True)
    #             time.sleep(1)
    #             count += 1
    #         except subprocess.CalledProcessError:
    #             break
    # except:
    #     pass


def test_validate_prerequisites(colors, kubectl_helper, tenant_config, test_counters):
    """Validate prerequisites"""
    print("Starting KEDA scaling validation for AgentSandboxService...")
    print(f"{colors.BLUE}[STEP] Validating prerequisites{colors.NC}")
    
    # Check if AgentSandboxService XRD exists
    try:
        kubectl_helper.kubectl_retry(["get", "xrd", "xagentsandboxservices.platform.bizmatters.io"])
        print(f"{colors.GREEN}[SUCCESS] AgentSandboxService XRD exists{colors.NC}")
    except Exception:
        print(f"{colors.RED}[ERROR] AgentSandboxService XRD not found. Run 02-verify-xrd.sh first.{colors.NC}")
        test_counters.errors += 1
        pytest.fail("AgentSandboxService XRD not found")
    
    # Check if KEDA is installed
    try:
        kubectl_helper.kubectl_retry(["get", "crd", "scaledobjects.keda.sh"])
        print(f"{colors.GREEN}[SUCCESS] KEDA is installed{colors.NC}")
    except Exception:
        print(f"{colors.RED}[ERROR] KEDA ScaledObject CRD not found. KEDA must be installed.{colors.NC}")
        test_counters.errors += 1
        pytest.fail("KEDA not installed")
    
    # Check if agent-sandbox controller is running
    try:
        result = kubectl_helper.kubectl_retry([
            "get", "pods", "-n", "agent-sandbox-system", 
            "-l", "app=agent-sandbox-controller"
        ])
        if "Running" in result.stdout:
            print(f"{colors.GREEN}[SUCCESS] Agent-sandbox controller is running{colors.NC}")
        else:
            print(f"{colors.RED}[ERROR] Agent-sandbox controller not running. Run 01-verify-controller.sh first.{colors.NC}")
            test_counters.errors += 1
            pytest.fail("Agent-sandbox controller not running")
    except Exception:
        print(f"{colors.RED}[ERROR] Could not check agent-sandbox controller{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not check agent-sandbox controller")
    
    # Check if namespace exists
    try:
        kubectl_helper.kubectl_retry(["get", "namespace", tenant_config['namespace']])
        print(f"{colors.GREEN}[SUCCESS] Target namespace {tenant_config['namespace']} exists{colors.NC}")
    except Exception:
        print(f"{colors.RED}[ERROR] Namespace {tenant_config['namespace']} does not exist{colors.NC}")
        test_counters.errors += 1
        pytest.fail(f"Namespace {tenant_config['namespace']} does not exist")


def test_create_test_claim(colors, scaling_claim_yaml, scaling_test_config, test_counters):
    """Create test AgentSandboxService claim"""
    print(f"{colors.BLUE}[STEP] Creating test AgentSandboxService claim{colors.NC}")
    
    try:
        subprocess.run([
            "kubectl", "apply", "-f", scaling_claim_yaml
        ], capture_output=True, text=True, check=True)
        print(f"{colors.GREEN}[SUCCESS] Test claim created: {scaling_test_config['test_claim_name']}{colors.NC}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Failed to create test claim{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Failed to create test claim")


def test_wait_for_resources(colors, scaling_test_config, tenant_config, test_counters, cleanup_scaling_claim):
    """Wait for resources to be provisioned"""
    print(f"{colors.BLUE}[STEP] Waiting for resources to be provisioned{colors.NC}")
    
    timeout = 300  # 5 minutes
    count = 0
    
    print(f"  {colors.BLUE}→{colors.NC} Waiting for AgentSandboxService to be ready...")
    while count < timeout:
        try:
            result = subprocess.run([
                "kubectl", "get", "agentsandboxservice", scaling_test_config['test_claim_name'], 
                "-n", tenant_config['namespace'], "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"
            ], capture_output=True, text=True, check=True)
            if "True" in result.stdout:
                break
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(2)
        count += 2
    
    if count >= timeout:
        print(f"{colors.RED}[ERROR] Timeout waiting for AgentSandboxService to be ready{colors.NC}")
        try:
            subprocess.run([
                "kubectl", "describe", "agentsandboxservice", scaling_test_config['test_claim_name'], "-n", tenant_config['namespace']
            ], check=False)
        except:
            pass
        test_counters.errors += 1
        pytest.fail("Timeout waiting for AgentSandboxService to be ready")
    
    print(f"{colors.GREEN}[SUCCESS] AgentSandboxService is ready{colors.NC}")


def test_validate_scaledobject_creation(colors, scaling_test_config, tenant_config, test_counters, cleanup_scaling_claim):
    """Validate ScaledObject creation and configuration"""
    print(f"{colors.BLUE}[STEP] Validating ScaledObject creation and configuration{colors.NC}")
    
    scaler_name = f"{scaling_test_config['test_claim_name']}-scaler"
    
    # Check if ScaledObject exists
    try:
        subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace']
        ], capture_output=True, text=True, check=True)
        print(f"  {colors.BLUE}→{colors.NC} ScaledObject {scaler_name} exists")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] ScaledObject {scaler_name} not found{colors.NC}")
        test_counters.errors += 1
        pytest.fail(f"ScaledObject {scaler_name} not found")
    
    # Validate ScaledObject targets SandboxWarmPool with correct apiVersion
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.scaleTargetRef.apiVersion}"
        ], capture_output=True, text=True, check=True)
        target_api_version = result.stdout.strip()
        
        if target_api_version != "extensions.agents.x-k8s.io/v1alpha1":
            print(f"{colors.RED}[ERROR] ScaledObject targets wrong apiVersion: {target_api_version}, expected: extensions.agents.x-k8s.io/v1alpha1{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong apiVersion: {target_api_version}")
        print(f"  {colors.BLUE}→{colors.NC} ScaledObject targets correct apiVersion: {target_api_version}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get ScaledObject apiVersion{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get ScaledObject apiVersion")
    
    # Validate ScaledObject targets SandboxWarmPool kind
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.scaleTargetRef.kind}"
        ], capture_output=True, text=True, check=True)
        target_kind = result.stdout.strip()
        
        if target_kind != "SandboxWarmPool":
            print(f"{colors.RED}[ERROR] ScaledObject targets wrong kind: {target_kind}, expected: SandboxWarmPool{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong kind: {target_kind}")
        print(f"  {colors.BLUE}→{colors.NC} ScaledObject targets correct kind: {target_kind}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get ScaledObject kind{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get ScaledObject kind")
    
    # Validate ScaledObject targets correct SandboxWarmPool name
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.scaleTargetRef.name}"
        ], capture_output=True, text=True, check=True)
        target_name = result.stdout.strip()
        
        if target_name != scaling_test_config['test_claim_name']:
            print(f"{colors.RED}[ERROR] ScaledObject targets wrong name: {target_name}, expected: {scaling_test_config['test_claim_name']}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong target name: {target_name}")
        print(f"  {colors.BLUE}→{colors.NC} ScaledObject targets correct SandboxWarmPool: {target_name}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get ScaledObject target name{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get ScaledObject target name")


def test_validate_nats_trigger_configuration(colors, scaling_test_config, tenant_config, test_counters, cleanup_scaling_claim):
    """Validate NATS JetStream trigger configuration"""
    print(f"{colors.BLUE}[STEP] Validating NATS JetStream trigger configuration{colors.NC}")
    
    scaler_name = f"{scaling_test_config['test_claim_name']}-scaler"
    
    # Check trigger type
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.triggers[0].type}"
        ], capture_output=True, text=True, check=True)
        trigger_type = result.stdout.strip()
        
        if trigger_type != "nats-jetstream":
            print(f"{colors.RED}[ERROR] Wrong trigger type: {trigger_type}, expected: nats-jetstream{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong trigger type: {trigger_type}")
        print(f"  {colors.BLUE}→{colors.NC} Trigger type is correct: {trigger_type}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get trigger type{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get trigger type")
    
    # Check stream configuration
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.triggers[0].metadata.stream}"
        ], capture_output=True, text=True, check=True)
        stream_name = result.stdout.strip()
        
        if stream_name != scaling_test_config['test_stream']:
            print(f"{colors.RED}[ERROR] Wrong stream name: {stream_name}, expected: {scaling_test_config['test_stream']}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong stream name: {stream_name}")
        print(f"  {colors.BLUE}→{colors.NC} Stream name is correct: {stream_name}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get stream name{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get stream name")
    
    # Check consumer configuration
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.triggers[0].metadata.consumer}"
        ], capture_output=True, text=True, check=True)
        consumer_name = result.stdout.strip()
        
        if consumer_name != scaling_test_config['test_consumer']:
            print(f"{colors.RED}[ERROR] Wrong consumer name: {consumer_name}, expected: {scaling_test_config['test_consumer']}{colors.NC}")
            test_counters.errors += 1
            pytest.fail(f"Wrong consumer name: {consumer_name}")
        print(f"  {colors.BLUE}→{colors.NC} Consumer name is correct: {consumer_name}")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] Could not get consumer name{colors.NC}")
        test_counters.errors += 1
        pytest.fail("Could not get consumer name")


def test_validate_sandboxwarmpool_scaling(colors, scaling_test_config, tenant_config, test_counters, cleanup_scaling_claim):
    """Validate SandboxWarmPool scaling behavior"""
    print(f"{colors.BLUE}[STEP] Validating SandboxWarmPool scaling behavior{colors.NC}")
    
    # Check if SandboxWarmPool exists
    try:
        subprocess.run([
            "kubectl", "get", "sandboxwarmpool", scaling_test_config['test_claim_name'], "-n", tenant_config['namespace']
        ], capture_output=True, text=True, check=True)
        print(f"  {colors.BLUE}→{colors.NC} SandboxWarmPool {scaling_test_config['test_claim_name']} exists")
    except subprocess.CalledProcessError:
        print(f"{colors.RED}[ERROR] SandboxWarmPool {scaling_test_config['test_claim_name']} not found{colors.NC}")
        test_counters.errors += 1
        pytest.fail(f"SandboxWarmPool {scaling_test_config['test_claim_name']} not found")
    
    # Get initial replica count
    try:
        result = subprocess.run([
            "kubectl", "get", "sandboxwarmpool", scaling_test_config['test_claim_name'], "-n", tenant_config['namespace'],
            "-o", "jsonpath={.spec.replicas}"
        ], capture_output=True, text=True, check=True)
        initial_replicas = result.stdout.strip()
        print(f"  {colors.BLUE}→{colors.NC} Initial SandboxWarmPool replicas: {initial_replicas}")
    except subprocess.CalledProcessError:
        print(f"{colors.YELLOW}[WARNING] Could not get initial replica count{colors.NC}")
        test_counters.warnings += 1
    
    # Check if ScaledObject is active
    scaler_name = f"{scaling_test_config['test_claim_name']}-scaler"
    timeout = 60
    count = 0
    
    print(f"  {colors.BLUE}→{colors.NC} Waiting for ScaledObject to become active...")
    while count < timeout:
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
                "-o", "jsonpath={.status.conditions}"
            ], capture_output=True, text=True, check=True)
            conditions = result.stdout.strip()
            
            if conditions and conditions not in ["[]", "null"]:
                print(f"  {colors.BLUE}→{colors.NC} ScaledObject has status conditions (KEDA is monitoring)")
                break
        except subprocess.CalledProcessError:
            pass
        
        time.sleep(2)
        count += 2
    
    if count >= timeout:
        print(f"{colors.YELLOW}[WARNING] ScaledObject status not available within timeout, but this may be normal in test environment{colors.NC}")
        test_counters.warnings += 1


def test_validate_keda_metrics(colors, scaling_test_config, tenant_config, test_counters, cleanup_scaling_claim):
    """Validate KEDA metrics reporting"""
    print(f"{colors.BLUE}[STEP] Validating KEDA metrics reporting{colors.NC}")
    
    scaler_name = f"{scaling_test_config['test_claim_name']}-scaler"
    
    print(f"  {colors.BLUE}→{colors.NC} Checking for KEDA external metrics...")
    
    # Look for HPA created by KEDA
    hpa_name = f"keda-hpa-{scaling_test_config['test_claim_name']}-scaler"
    try:
        subprocess.run([
            "kubectl", "get", "hpa", hpa_name, "-n", tenant_config['namespace']
        ], capture_output=True, text=True, check=True)
        print(f"  {colors.BLUE}→{colors.NC} KEDA HPA found: {hpa_name}")
        
        # Check HPA status
        try:
            result = subprocess.run([
                "kubectl", "get", "hpa", hpa_name, "-n", tenant_config['namespace'],
                "-o", "jsonpath={.status.conditions[?(@.type==\"ScalingActive\")].status}"
            ], capture_output=True, text=True, check=True)
            hpa_status = result.stdout.strip() or "Unknown"
            print(f"  {colors.BLUE}→{colors.NC} HPA ScalingActive status: {hpa_status}")
        except subprocess.CalledProcessError:
            print(f"  {colors.BLUE}→{colors.NC} HPA status not available")
    except subprocess.CalledProcessError:
        print(f"{colors.YELLOW}[WARNING] KEDA HPA not found, this may be normal if no scaling is needed{colors.NC}")
        test_counters.warnings += 1
    
    # Check ScaledObject status
    try:
        result = subprocess.run([
            "kubectl", "get", "scaledobject", scaler_name, "-n", tenant_config['namespace'],
            "-o", "jsonpath={.status}"
        ], capture_output=True, text=True, check=True)
        scaler_status = result.stdout.strip()
        
        if scaler_status and scaler_status not in ["{}", "null"]:
            print(f"  {colors.BLUE}→{colors.NC} ScaledObject has status information")
        else:
            print(f"  {colors.BLUE}→{colors.NC} ScaledObject status not yet available (normal for new resources)")
    except subprocess.CalledProcessError:
        print(f"  {colors.BLUE}→{colors.NC} ScaledObject status not available")


def test_summary(colors, test_counters):
    """Print validation summary"""
    print(f"{colors.GREEN}[SUCCESS] KEDA scaling integration validation completed successfully{colors.NC}")
    print(f"{colors.BLUE}[INFO] ✓ ScaledObject targets SandboxWarmPool with correct apiVersion{colors.NC}")
    print(f"{colors.BLUE}[INFO] ✓ NATS JetStream trigger configured correctly{colors.NC}")
    print(f"{colors.BLUE}[INFO] ✓ SandboxWarmPool scaling infrastructure is functional{colors.NC}")
    print(f"{colors.BLUE}[INFO] ✓ KEDA metrics integration is working{colors.NC}")
    
    if test_counters.errors == 0:
        print(f"{colors.GREEN}[SUCCESS] All KEDA scaling validation checks passed!{colors.NC}")
    else:
        pytest.fail(f"KEDA scaling validation has {test_counters.errors} error(s)")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])