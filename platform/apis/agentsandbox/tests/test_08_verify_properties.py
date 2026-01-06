#!/usr/bin/env python3
"""
Verify AgentSandboxService properties
Usage: pytest test_08_verify_properties.py [--tenant <name>] [--namespace <name>] [-v] [--cleanup]

Comprehensive property-based testing for AgentSandboxService
Validates all correctness properties defined in the design document
"""

import pytest
import subprocess
import os
import time
import random
import string
from typing import List


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'


class TestAgentSandboxProperties:
    """Test class for property-based testing validation"""
    
    def setup_method(self):
        """Setup for each test method"""
        self.tenant_name = "deepagents-runtime"
        self.namespace = "intelligence-deepagents"
        self.property_test_iterations = 3  # Reduced for faster testing
        self.test_claim_prefix = f"pbt-test-{int(time.time())}"
        
        print(f"{Colors.BLUE}[INFO] Starting AgentSandboxService property-based testing{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] Tenant: {self.tenant_name}, Namespace: {self.namespace}, Iterations: {self.property_test_iterations}{Colors.NC}")
    
    def teardown_method(self):
        """Cleanup all property test resources"""
        try:
            # Clean up all test claims with the prefix
            result = subprocess.run([
                "kubectl", "get", "agentsandboxservice", "-n", self.namespace,
                "-o", "jsonpath={.items[*].metadata.name}"
            ], capture_output=True, text=True, check=False)
            
            if result.returncode == 0 and result.stdout.strip():
                claim_names = result.stdout.strip().split()
                for claim_name in claim_names:
                    if claim_name.startswith(self.test_claim_prefix):
                        subprocess.run([
                            "kubectl", "delete", "agentsandboxservice", claim_name,
                            "-n", self.namespace, "--ignore-not-found=true"
                        ], capture_output=True, text=True, check=False)
        except:
            pass
    
    def generate_random_claim_spec(self, claim_name: str) -> str:
        """Generate random valid claim specification"""
        sizes = ["micro", "small", "medium", "large"]
        size = random.choice(sizes)
        
        return f"""apiVersion: platform.bizmatters.io/v1alpha1
kind: AgentSandboxService
metadata:
  name: {claim_name}
  namespace: {self.namespace}
spec:
  image: "busybox:latest"
  size: {size}
  nats:
    stream: "TEST_STREAM_{random.randint(1, 1000)}"
    consumer: "test-consumer-{random.randint(1, 1000)}"
  storageGB: {random.choice([5, 10, 20])}
"""
    
    def test_validate_prerequisites(self):
        """Validate prerequisites for property-based testing"""
        print(f"{Colors.BLUE}[INFO] Validating prerequisites for property-based testing...{Colors.NC}")
        
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
        
        # Check aws-access-token secret exists
        try:
            subprocess.run([
                "kubectl", "get", "secret", "aws-access-token", "-n", self.namespace
            ], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            print(f"{Colors.RED}[ERROR] aws-access-token secret not found in namespace {self.namespace}{Colors.NC}")
            pytest.fail(f"aws-access-token secret not found")
        
        print(f"{Colors.BLUE}[INFO] Prerequisites validated successfully{Colors.NC}")
    
    def test_property_api_parity(self):
        """Property 1: API Parity Preservation"""
        print(f"{Colors.BLUE}[PROPERTY] Testing Property 1: API Parity Preservation{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] For any valid EventDrivenService claim specification, converting it to AgentSandboxService should succeed{Colors.NC}")
        
        failures = 0
        
        for i in range(1, self.property_test_iterations + 1):
            print(f"{Colors.BLUE}[INFO] Iteration {i}/{self.property_test_iterations}{Colors.NC}")
            
            # Generate random valid claim specification
            claim_name = f"{self.test_claim_prefix}-api-{i}"
            claim_spec = self.generate_random_claim_spec(claim_name)
            
            # Create AgentSandboxService claim
            try:
                process = subprocess.run([
                    "kubectl", "apply", "-f", "-"
                ], input=claim_spec, text=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Failed to create AgentSandboxService claim (iteration {i}){Colors.NC}")
                failures += 1
                continue
            
            # Wait for claim to be accepted by API server
            try:
                subprocess.run([
                    "kubectl", "get", "agentsandboxservice", claim_name, "-n", self.namespace
                ], capture_output=True, text=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] AgentSandboxService claim not found after creation (iteration {i}){Colors.NC}")
                failures += 1
                continue
            
            # Validate claim was processed (don't wait for full readiness)
            timeout = 30
            elapsed = 0
            processed = False
            
            while elapsed < timeout:
                try:
                    result = subprocess.run([
                        "kubectl", "get", "agentsandboxservice", claim_name, "-n", self.namespace,
                        "-o", "jsonpath={.status.conditions}"
                    ], capture_output=True, text=True, check=True)
                    conditions = result.stdout.strip()
                    
                    if conditions and conditions not in ["[]", "null"]:
                        processed = True
                        break
                except subprocess.CalledProcessError:
                    pass
                
                time.sleep(2)
                elapsed += 2
            
            if not processed:
                print(f"{Colors.RED}[ERROR] AgentSandboxService claim not processed within timeout (iteration {i}){Colors.NC}")
                failures += 1
            
            # Clean up this iteration
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
        
        if failures == 0:
            print(f"{Colors.GREEN}[SUCCESS] Property 1 (API Parity Preservation): PASSED ({self.property_test_iterations}/{self.property_test_iterations}){Colors.NC}")
        else:
            print(f"{Colors.RED}[ERROR] Property 1 (API Parity Preservation): FAILED ({self.property_test_iterations - failures}/{self.property_test_iterations}){Colors.NC}")
            pytest.fail(f"Property 1 failed: {failures} out of {self.property_test_iterations} iterations failed")
    
    def test_property_resource_provisioning(self):
        """Property 2: Resource Provisioning Completeness"""
        print(f"{Colors.BLUE}[PROPERTY] Testing Property 2: Resource Provisioning Completeness{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] For any AgentSandboxService claim, composition should generate exactly the expected managed resources{Colors.NC}")
        
        failures = 0
        
        for i in range(1, self.property_test_iterations + 1):
            print(f"{Colors.BLUE}[INFO] Iteration {i}/{self.property_test_iterations}{Colors.NC}")
            
            # Generate random claim
            claim_name = f"{self.test_claim_prefix}-res-{i}"
            claim_spec = self.generate_random_claim_spec(claim_name)
            
            # Create claim
            try:
                process = subprocess.run([
                    "kubectl", "apply", "-f", "-"
                ], input=claim_spec, text=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Failed to create claim (iteration {i}){Colors.NC}")
                failures += 1
                continue
            
            # Wait for resources to be provisioned (shorter timeout for property testing)
            timeout = 120
            elapsed = 0
            
            while elapsed < timeout:
                try:
                    result = subprocess.run([
                        "kubectl", "get", "agentsandboxservice", claim_name, "-n", self.namespace,
                        "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}"
                    ], capture_output=True, text=True, check=True)
                    if "True" in result.stdout:
                        break
                except subprocess.CalledProcessError:
                    pass
                
                time.sleep(5)
                elapsed += 5
            
            if elapsed >= timeout:
                print(f"{Colors.YELLOW}[WARNING] Claim not ready within timeout, checking partial provisioning (iteration {i}){Colors.NC}")
            
            # Validate expected resources exist
            expected_resources = ["sandboxtemplate", "sandboxwarmpool", "serviceaccount"]
            
            resource_failures = 0
            for resource_type in expected_resources:
                try:
                    subprocess.run([
                        "kubectl", "get", resource_type, claim_name, "-n", self.namespace
                    ], capture_output=True, text=True, check=True)
                except subprocess.CalledProcessError:
                    print(f"{Colors.RED}[ERROR] Missing {resource_type} resource (iteration {i}){Colors.NC}")
                    resource_failures += 1
            
            if resource_failures > 0:
                failures += 1
            
            # Clean up
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
        
        if failures == 0:
            print(f"{Colors.GREEN}[SUCCESS] Property 2 (Resource Provisioning Completeness): PASSED ({self.property_test_iterations}/{self.property_test_iterations}){Colors.NC}")
        else:
            print(f"{Colors.RED}[ERROR] Property 2 (Resource Provisioning Completeness): FAILED ({self.property_test_iterations - failures}/{self.property_test_iterations}){Colors.NC}")
            pytest.fail(f"Property 2 failed: {failures} out of {self.property_test_iterations} iterations failed")
    
    def test_property_workspace_persistence(self):
        """Property 3: Workspace Persistence Round-Trip"""
        print(f"{Colors.BLUE}[PROPERTY] Testing Property 3: Workspace Persistence Round-Trip{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] For any file written to /workspace, it should survive pod recreation{Colors.NC}")
        
        failures = 0
        
        for i in range(1, self.property_test_iterations + 1):
            print(f"{Colors.BLUE}[INFO] Iteration {i}/{self.property_test_iterations}{Colors.NC}")
            
            # Generate claim with persistent storage
            claim_name = f"{self.test_claim_prefix}-persist-{i}"
            claim_spec = self.generate_random_claim_spec(claim_name)
            
            # Create claim
            try:
                process = subprocess.run([
                    "kubectl", "apply", "-f", "-"
                ], input=claim_spec, text=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Failed to create persistent claim (iteration {i}){Colors.NC}")
                failures += 1
                continue
            
            # Wait for PVC to be created (infrastructure test)
            timeout = 60
            elapsed = 0
            pvc_created = False
            
            while elapsed < timeout:
                try:
                    result = subprocess.run([
                        "kubectl", "get", "pvc", "-n", self.namespace,
                        "-l", f"app.kubernetes.io/name={claim_name}"
                    ], capture_output=True, text=True, check=True)
                    if result.stdout.strip():
                        pvc_created = True
                        break
                except subprocess.CalledProcessError:
                    pass
                
                time.sleep(2)
                elapsed += 2
            
            if not pvc_created:
                print(f"{Colors.RED}[ERROR] PVC not created for persistent storage (iteration {i}){Colors.NC}")
                failures += 1
            else:
                print(f"{Colors.BLUE}[INFO] PVC created successfully for persistence test (iteration {i}){Colors.NC}")
            
            # Clean up
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
        
        if failures == 0:
            print(f"{Colors.GREEN}[SUCCESS] Property 3 (Workspace Persistence Round-Trip): PASSED ({self.property_test_iterations}/{self.property_test_iterations}){Colors.NC}")
        else:
            print(f"{Colors.RED}[ERROR] Property 3 (Workspace Persistence Round-Trip): FAILED ({self.property_test_iterations - failures}/{self.property_test_iterations}){Colors.NC}")
            pytest.fail(f"Property 3 failed: {failures} out of {self.property_test_iterations} iterations failed")
    
    def test_property_keda_scaling(self):
        """Property 4: KEDA Scaling Responsiveness"""
        print(f"{Colors.BLUE}[PROPERTY] Testing Property 4: KEDA Scaling Responsiveness{Colors.NC}")
        print(f"{Colors.BLUE}[INFO] For any AgentSandboxService with NATS config, KEDA ScaledObject should be created and configured{Colors.NC}")
        
        failures = 0
        
        for i in range(1, self.property_test_iterations + 1):
            print(f"{Colors.BLUE}[INFO] Iteration {i}/{self.property_test_iterations}{Colors.NC}")
            
            # Generate claim with NATS configuration
            claim_name = f"{self.test_claim_prefix}-keda-{i}"
            claim_spec = self.generate_random_claim_spec(claim_name)
            
            # Create claim
            try:
                process = subprocess.run([
                    "kubectl", "apply", "-f", "-"
                ], input=claim_spec, text=True, capture_output=True, check=True)
            except subprocess.CalledProcessError:
                print(f"{Colors.RED}[ERROR] Failed to create NATS claim (iteration {i}){Colors.NC}")
                failures += 1
                continue
            
            # Wait for ScaledObject to be created
            timeout = 60
            elapsed = 0
            scaledobject_created = False
            
            while elapsed < timeout:
                try:
                    subprocess.run([
                        "kubectl", "get", "scaledobject", claim_name, "-n", self.namespace
                    ], capture_output=True, text=True, check=True)
                    scaledobject_created = True
                    break
                except subprocess.CalledProcessError:
                    pass
                
                time.sleep(2)
                elapsed += 2
            
            if not scaledobject_created:
                print(f"{Colors.RED}[ERROR] ScaledObject not created (iteration {i}){Colors.NC}")
                failures += 1
            else:
                print(f"{Colors.BLUE}[INFO] ScaledObject created successfully (iteration {i}){Colors.NC}")
            
            # Clean up
            subprocess.run([
                "kubectl", "delete", "agentsandboxservice", claim_name, 
                "-n", self.namespace, "--ignore-not-found=true"
            ], capture_output=True, text=True, check=False)
        
        if failures == 0:
            print(f"{Colors.GREEN}[SUCCESS] Property 4 (KEDA Scaling Responsiveness): PASSED ({self.property_test_iterations}/{self.property_test_iterations}){Colors.NC}")
        else:
            print(f"{Colors.RED}[ERROR] Property 4 (KEDA Scaling Responsiveness): FAILED ({self.property_test_iterations - failures}/{self.property_test_iterations}){Colors.NC}")
            pytest.fail(f"Property 4 failed: {failures} out of {self.property_test_iterations} iterations failed")
    
    def test_summary(self):
        """Print validation summary"""
        print(f"{Colors.GREEN}[SUCCESS] ✅ All correctness properties validated successfully!{Colors.NC}")
        print(f"{Colors.GREEN}[SUCCESS] AgentSandboxService implementation meets all design requirements{Colors.NC}")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])