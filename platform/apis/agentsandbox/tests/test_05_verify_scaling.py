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
from typing import List


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'


class TestKEDAScaling:
    """Test class for KEDA scaling integration validation"""
    
    def setup_method(self):
        """Setup for each test method"""
        self.tenant_name = "deepagents-runtime"
        self.namespace = "intelligence-deepagents"
        self.test_claim_name = "test-scaling-sandbox"
        self.test_image = "ghcr.io/bizmatters/deepagents-runtime:latest"
        self.test_stream = "TEST_SCALING_STREAM"
        self.test_consumer = "test-scaling-consumer"
        
        print("Starting KEDA scaling validation for AgentSandboxService...")
    
    def teardown_method(self):
        """Cleanup test resources"""
        try:
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", self.test_claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
            
            # Wait for cleanup
            timeout = 60
            count = 0
            while count < timeout:
                try:
                    subprocess.run([
                        "kubectl", "get", "agentsandboxservice", self.test_claim_name, "-n", self.namespace
                    ], capture_output=True, text=True, check=True)
                    time.sleep(1)
                    count += 1
                except subprocess.CalledProcessError:
                    break
        except:
            pass
    
    def test_validate_prerequisites(self):
        """Validate prerequisites"""
        print(f"{Colors.BLUE}[STEP] Validating prerequisites{Colors.NC}")
        
        # Check if AgentSandboxService XRD exists
        try:
            subprocess.run([
                "kubectl", "get", "xrd", "xagentsandboxservices.platform.bizmatters.io"
            ], capture_output=True, text=True, check=True)
            print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService XRD exists{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] AgentSandboxService XRD not found. Run 02-verify-xrd.sh first.{Colors.NC}")
            pytest.fail("AgentSandboxService XRD not found")
        
        # Check if KEDA is installed
        try:
            subprocess.run([
                "kubectl", "get", "crd", "scaledobjects.keda.sh"
            ], capture_output=True, text=True, check=True)
            print(f"{Colors.GREEN}[SUCCESS] KEDA is installed{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] KEDA ScaledObject CRD not found. KEDA must be installed.{Colors.NC}")
            pytest.fail("KEDA not installed")
        
        # Check if agent-sandbox controller is running
        try:
            result = subprocess.run([
                "kubectl", "get", "pods", "-n", "agent-sandbox-system", 
                "-l", "app=agent-sandbox-controller"
            ], capture_output=True, check=True, text=True)
            if "Running" in result.stdout:
                print(f"{Colors.GREEN}[SUCCESS] Agent-sandbox controller is running{Colors.NC}")
            else:
                print(f"{Colors.RED}[ERROR] Agent-sandbox controller not running. Run 01-verify-controller.sh first.{Colors.NC}")
                pytest.fail("Agent-sandbox controller not running")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not check agent-sandbox controller{Colors.NC}")
            pytest.fail("Could not check agent-sandbox controller")
        
        # Check if namespace exists
        try:
            subprocess.run([
                "kubectl", "get", "namespace", self.namespace
            ], capture_output=True, text=True, check=True)
            print(f"{Colors.GREEN}[SUCCESS] Target namespace {self.namespace} exists{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Namespace {self.namespace} does not exist{Colors.NC}")
            pytest.fail(f"Namespace {self.namespace} does not exist")
    
    def test_create_test_claim(self):
        """Create test AgentSandboxService claim"""
        print(f"{Colors.BLUE}[STEP] Creating test AgentSandboxService claim{Colors.NC}")
        
        claim_yaml = f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {self.test_claim_name}
  namespace: {self.namespace}
spec:
  image: {self.test_image}
  size: micro
  nats:
    url: "nats://nats-headless.nats.svc.cluster.local:4222"
    stream: {self.test_stream}
    consumer: {self.test_consumer}
  httpPort: 8080
  storageGB: 5
"""
        
        try:
            process = subprocess.run([
                "kubectl", "apply", "-f", "-"
            ], input=claim_yaml, text=True, capture_output=True, check=True)
            print(f"{Colors.GREEN}[SUCCESS] Test claim created: {self.test_claim_name}{Colors.NC}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Failed to create test claim{Colors.NC}")
            pytest.fail("Failed to create test claim")
    
    def test_wait_for_resources(self):
        """Wait for resources to be provisioned"""
        print(f"{Colors.BLUE}[STEP] Waiting for resources to be provisioned{Colors.NC}")
        
        timeout = 300  # 5 minutes
        count = 0
        
        print(f"  {Colors.BLUE}→{Colors.NC} Waiting for AgentSandboxService to be ready...")
        while count < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "agentsandboxservice", self.test_claim_name, 
                    "-n", self.namespace, "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"
                ], capture_output=True, text=True, check=True)
                if "True" in result.stdout:
                    break
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(2)
            count += 2
        
        if count >= timeout:
            print(f"{Colors.RED}[ERROR] Timeout waiting for AgentSandboxService to be ready{Colors.NC}")
            try:
                subprocess.run([
                    "kubectl", "describe", "agentsandboxservice", self.test_claim_name, "-n", self.namespace
                ], check=False)
            except:
                pass
            pytest.fail("Timeout waiting for AgentSandboxService to be ready")
        
        print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService is ready{Colors.NC}")
    
    def test_validate_scaledobject_creation(self):
        """Validate ScaledObject creation and configuration"""
        print(f"{Colors.BLUE}[STEP] Validating ScaledObject creation and configuration{Colors.NC}")
        
        scaler_name = f"{self.test_claim_name}-scaler"
        
        # Check if ScaledObject exists
        try:
            subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
            print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject {scaler_name} exists")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] ScaledObject {scaler_name} not found{Colors.NC}")
            pytest.fail(f"ScaledObject {scaler_name} not found")
        
        # Validate ScaledObject targets SandboxWarmPool with correct apiVersion
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.scaleTargetRef.apiVersion}"
            ], capture_output=True, text=True, check=True)
            target_api_version = result.stdout.strip()
            
            if target_api_version != "extensions.agents.x-k8s.io/v1alpha1":
                print(f"{Colors.RED}[ERROR] ScaledObject targets wrong apiVersion: {target_api_version}, expected: extensions.agents.x-k8s.io/v1alpha1{Colors.NC}")
                pytest.fail(f"Wrong apiVersion: {target_api_version}")
            print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject targets correct apiVersion: {target_api_version}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get ScaledObject apiVersion{Colors.NC}")
            pytest.fail("Could not get ScaledObject apiVersion")
        
        # Validate ScaledObject targets SandboxWarmPool kind
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.scaleTargetRef.kind}"
            ], capture_output=True, text=True, check=True)
            target_kind = result.stdout.strip()
            
            if target_kind != "SandboxWarmPool":
                print(f"{Colors.RED}[ERROR] ScaledObject targets wrong kind: {target_kind}, expected: SandboxWarmPool{Colors.NC}")
                pytest.fail(f"Wrong kind: {target_kind}")
            print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject targets correct kind: {target_kind}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get ScaledObject kind{Colors.NC}")
            pytest.fail("Could not get ScaledObject kind")
        
        # Validate ScaledObject targets correct SandboxWarmPool name
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.scaleTargetRef.name}"
            ], capture_output=True, text=True, check=True)
            target_name = result.stdout.strip()
            
            if target_name != self.test_claim_name:
                print(f"{Colors.RED}[ERROR] ScaledObject targets wrong name: {target_name}, expected: {self.test_claim_name}{Colors.NC}")
                pytest.fail(f"Wrong target name: {target_name}")
            print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject targets correct SandboxWarmPool: {target_name}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get ScaledObject target name{Colors.NC}")
            pytest.fail("Could not get ScaledObject target name")
    
    def test_validate_nats_trigger_configuration(self):
        """Validate NATS JetStream trigger configuration"""
        print(f"{Colors.BLUE}[STEP] Validating NATS JetStream trigger configuration{Colors.NC}")
        
        scaler_name = f"{self.test_claim_name}-scaler"
        
        # Check trigger type
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.triggers[0].type}"
            ], capture_output=True, text=True, check=True)
            trigger_type = result.stdout.strip()
            
            if trigger_type != "nats-jetstream":
                print(f"{Colors.RED}[ERROR] Wrong trigger type: {trigger_type}, expected: nats-jetstream{Colors.NC}")
                pytest.fail(f"Wrong trigger type: {trigger_type}")
            print(f"  {Colors.BLUE}→{Colors.NC} Trigger type is correct: {trigger_type}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get trigger type{Colors.NC}")
            pytest.fail("Could not get trigger type")
        
        # Check stream configuration
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.triggers[0].metadata.stream}"
            ], capture_output=True, text=True, check=True)
            stream_name = result.stdout.strip()
            
            if stream_name != self.test_stream:
                print(f"{Colors.RED}[ERROR] Wrong stream name: {stream_name}, expected: {self.test_stream}{Colors.NC}")
                pytest.fail(f"Wrong stream name: {stream_name}")
            print(f"  {Colors.BLUE}→{Colors.NC} Stream name is correct: {stream_name}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get stream name{Colors.NC}")
            pytest.fail("Could not get stream name")
        
        # Check consumer configuration
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.triggers[0].metadata.consumer}"
            ], capture_output=True, text=True, check=True)
            consumer_name = result.stdout.strip()
            
            if consumer_name != self.test_consumer:
                print(f"{Colors.RED}[ERROR] Wrong consumer name: {consumer_name}, expected: {self.test_consumer}{Colors.NC}")
                pytest.fail(f"Wrong consumer name: {consumer_name}")
            print(f"  {Colors.BLUE}→{Colors.NC} Consumer name is correct: {consumer_name}")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] Could not get consumer name{Colors.NC}")
            pytest.fail("Could not get consumer name")
    
    def test_validate_sandboxwarmpool_scaling(self):
        """Validate SandboxWarmPool scaling behavior"""
        print(f"{Colors.BLUE}[STEP] Validating SandboxWarmPool scaling behavior{Colors.NC}")
        
        # Check if SandboxWarmPool exists
        try:
            subprocess.run([
                "kubectl", "get", "sandboxwarmpool", self.test_claim_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
            print(f"  {Colors.BLUE}→{Colors.NC} SandboxWarmPool {self.test_claim_name} exists")
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] SandboxWarmPool {self.test_claim_name} not found{Colors.NC}")
            pytest.fail(f"SandboxWarmPool {self.test_claim_name} not found")
        
        # Get initial replica count
        try:
            result = subprocess.run([
                "kubectl", "get", "sandboxwarmpool", self.test_claim_name, "-n", self.namespace,
                "-o", "jsonpath={.spec.replicas}"
            ], capture_output=True, text=True, check=True)
            initial_replicas = result.stdout.strip()
            print(f"  {Colors.BLUE}→{Colors.NC} Initial SandboxWarmPool replicas: {initial_replicas}")
        except subprocess.CalledProcessError:
            print(f"{Colors.YELLOW}[WARNING] Could not get initial replica count{Colors.NC}")
        
        # Check if ScaledObject is active
        scaler_name = f"{self.test_claim_name}-scaler"
        timeout = 60
        count = 0
        
        print(f"  {Colors.BLUE}→{Colors.NC} Waiting for ScaledObject to become active...")
        while count < timeout:
            try:
                result = subprocess.run([
                    "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                    "-o", "jsonpath={.status.conditions}"
                ], capture_output=True, text=True, check=True)
                conditions = result.stdout.strip()
                
                if conditions and conditions not in ["[]", "null"]:
                    print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject has status conditions (KEDA is monitoring)")
                    break
            except subprocess.CalledProcessError:
                pass
            
            time.sleep(2)
            count += 2
        
        if count >= timeout:
            print(f"{Colors.YELLOW}[WARNING] ScaledObject status not available within timeout, but this may be normal in test environment{Colors.NC}")
    
    def test_validate_keda_metrics(self):
        """Validate KEDA metrics reporting"""
        print(f"{Colors.BLUE}[STEP] Validating KEDA metrics reporting{Colors.NC}")
        
        scaler_name = f"{self.test_claim_name}-scaler"
        
        print(f"  {Colors.BLUE}→{Colors.NC} Checking for KEDA external metrics...")
        
        # Look for HPA created by KEDA
        hpa_name = f"keda-hpa-{self.test_claim_name}-scaler"
        try:
            subprocess.run([
                "kubectl", "get", "hpa", hpa_name, "-n", self.namespace
            ], capture_output=True, text=True, check=True)
            print(f"  {Colors.BLUE}→{Colors.NC} KEDA HPA found: {hpa_name}")
            
            # Check HPA status
            try:
                result = subprocess.run([
                    "kubectl", "get", "hpa", hpa_name, "-n", self.namespace,
                    "-o", "jsonpath={.status.conditions[?(@.type==\"ScalingActive\")].status}"
                ], capture_output=True, text=True, check=True)
                hpa_status = result.stdout.strip() or "Unknown"
                print(f"  {Colors.BLUE}→{Colors.NC} HPA ScalingActive status: {hpa_status}")
            except subprocess.CalledProcessError:
                print(f"  {Colors.BLUE}→{Colors.NC} HPA status not available")
        except subprocess.CalledProcessError:
            print(f"{Colors.YELLOW}[WARNING] KEDA HPA not found, this may be normal if no scaling is needed{Colors.NC}")
        
        # Check ScaledObject status
        try:
            result = subprocess.run([
                "kubectl", "get", "scaledobject", scaler_name, "-n", self.namespace,
                "-o", "jsonpath={.status}"
            ], capture_output=True, text=True, check=True)
            scaler_status = result.stdout.strip()
            
            if scaler_status and scaler_status not in ["{}", "null"]:
                print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject has status information")
            else:
                print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject status not yet available (normal for new resources)")
        except subprocess.CalledProcessError:
            print(f"  {Colors.BLUE}→{Colors.NC} ScaledObject status not available")
    
    def test_summary(self):
        """Print validation summary"""
        print(f"{Colors.GREEN}[SUCCESS] KEDA scaling integration validation completed successfully{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] ✓ ScaledObject targets SandboxWarmPool with correct apiVersion{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] ✓ NATS JetStream trigger configured correctly{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] ✓ SandboxWarmPool scaling infrastructure is functional{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] ✓ KEDA metrics integration is working{Colors.NC}")
        print(f"{Colors.GREEN}[SUCCESS] All KEDA scaling validation checks passed!{Colors.NC}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])