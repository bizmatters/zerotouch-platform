#!/usr/bin/env python3
"""
Cleanup script to delete all test AgentSandboxService claims
Usage: python cleanup_test_claims.py
"""

import subprocess
import time
import sys

def run_kubectl(args, check=True):
    """Execute kubectl command"""
    cmd = ["kubectl"] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=check)

def cleanup_test_claims():
    """Delete all test claims in intelligence-deepagents namespace"""
    namespace = "intelligence-deepagents"
    
    print("🧹 Cleaning up all test claims in intelligence-deepagents namespace...")
    
    try:
        # Get all AgentSandboxService claims
        result = run_kubectl([
            "get", "agentsandboxservice", "-n", namespace, 
            "--no-headers", "-o", "custom-columns=NAME:.metadata.name"
        ])
        
        claim_names = [name.strip() for name in result.stdout.split('\n') if name.strip()]
        test_claims = [name for name in claim_names if name.startswith('test-')]
        
        if not test_claims:
            print("✓ No test claims found")
            return
        
        print(f"Found {len(test_claims)} test claims to delete:")
        for claim in test_claims:
            print(f"  - {claim}")
        
        # Delete each test claim
        for claim_name in test_claims:
            print(f"Deleting claim: {claim_name}")
            run_kubectl([
                "delete", "agentsandboxservice", claim_name, 
                "-n", namespace, "--ignore-not-found=true"
            ])
        
        print("✓ All test claims deleted")
        
        # Wait for cleanup
        print("⏳ Waiting 15 seconds for cleanup to complete...")
        time.sleep(15)
        
        # Show remaining test pods
        print("📋 Checking remaining test pods:")
        result = run_kubectl([
            "get", "pods", "-n", namespace, "--no-headers"
        ], check=False)
        
        if result.returncode == 0:
            pods = [line for line in result.stdout.split('\n') if line.strip() and line.startswith('test-')]
            if pods:
                print("Remaining test pods (should be terminating):")
                for pod in pods:
                    print(f"  {pod}")
            else:
                print("✓ No test pods remaining")
        
        print("🎉 Cleanup complete!")
        
    except subprocess.CalledProcessError as e:
        print(f"❌ Error during cleanup: {e}")
        print(f"Command output: {e.stdout}")
        print(f"Command error: {e.stderr}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    cleanup_test_claims()