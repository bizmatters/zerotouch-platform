#!/usr/bin/env python3
"""
Validation script for Checkpoint 1: Infrastructure Components Deployed

Verifies:
- All ArgoCD applications in Synced and Healthy status
- HCCM pod running in kube-system namespace
- Cert-Manager pods running in cert-manager namespace
- External-DNS pod running with Hetzner provider configuration
- All required secrets (hcloud, external-dns-hetzner) present and synced
"""

import subprocess
import json
import sys
import time

def run_kubectl(cmd):
    """Run kubectl command and return output"""
    try:
        result = subprocess.run(f"kubectl {cmd}", shell=True, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error running kubectl {cmd}: {result.stderr}")
            return None
        return result.stdout.strip()
    except Exception as e:
        print(f"Exception running kubectl {cmd}: {e}")
        return None

def check_argocd_apps():
    """Check ArgoCD applications status"""
    print("Checking ArgoCD applications...")
    
    apps = ["hcloud-ccm", "cert-manager", "external-dns"]
    for app in apps:
        output = run_kubectl(f"get application {app} -n argocd -o json")
        if not output:
            print(f"❌ ArgoCD application {app} not found")
            return False
            
        try:
            app_data = json.loads(output)
            sync_status = app_data.get("status", {}).get("sync", {}).get("status")
            health_status = app_data.get("status", {}).get("health", {}).get("status")
            
            if sync_status != "Synced":
                print(f"❌ {app} sync status: {sync_status} (expected: Synced)")
                return False
            if health_status != "Healthy":
                print(f"❌ {app} health status: {health_status} (expected: Healthy)")
                return False
            print(f"✅ {app}: Synced and Healthy")
        except json.JSONDecodeError:
            print(f"❌ Failed to parse {app} status")
            return False
    
    return True

def check_pods():
    """Check required pods are running"""
    print("\nChecking pod status...")
    
    # Check HCCM pod
    output = run_kubectl("get pods -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager -o json")
    if not output:
        print("❌ HCCM pods not found")
        return False
    
    try:
        pods_data = json.loads(output)
        hccm_pods = pods_data.get("items", [])
        if not hccm_pods:
            print("❌ No HCCM pods found")
            return False
        
        for pod in hccm_pods:
            phase = pod.get("status", {}).get("phase")
            if phase != "Running":
                print(f"❌ HCCM pod {pod['metadata']['name']} status: {phase}")
                return False
        print(f"✅ HCCM: {len(hccm_pods)} pod(s) running")
    except json.JSONDecodeError:
        print("❌ Failed to parse HCCM pod status")
        return False
    
    # Check Cert-Manager pods
    output = run_kubectl("get pods -n cert-manager -o json")
    if not output:
        print("❌ Cert-Manager pods not found")
        return False
    
    try:
        pods_data = json.loads(output)
        cm_pods = pods_data.get("items", [])
        running_pods = [p for p in cm_pods if p.get("status", {}).get("phase") == "Running"]
        if len(running_pods) < 3:  # cert-manager, webhook, cainjector
            print(f"❌ Cert-Manager: only {len(running_pods)} pods running (expected: 3)")
            return False
        print(f"✅ Cert-Manager: {len(running_pods)} pods running")
    except json.JSONDecodeError:
        print("❌ Failed to parse Cert-Manager pod status")
        return False
    
    # Check External-DNS pod
    output = run_kubectl("get pods -n kube-system -l app.kubernetes.io/name=external-dns -o json")
    if not output:
        print("❌ External-DNS pods not found")
        return False
    
    try:
        pods_data = json.loads(output)
        dns_pods = pods_data.get("items", [])
        if not dns_pods:
            print("❌ No External-DNS pods found")
            return False
        
        for pod in dns_pods:
            phase = pod.get("status", {}).get("phase")
            if phase != "Running":
                print(f"❌ External-DNS pod {pod['metadata']['name']} status: {phase}")
                return False
        print(f"✅ External-DNS: {len(dns_pods)} pod(s) running")
    except json.JSONDecodeError:
        print("❌ Failed to parse External-DNS pod status")
        return False
    
    return True

def check_secrets():
    """Check required secrets are present and synced"""
    print("\nChecking secrets...")
    
    secrets = [
        ("hcloud", "kube-system"),
        ("external-dns-hetzner", "kube-system")
    ]
    
    for secret_name, namespace in secrets:
        output = run_kubectl(f"get secret {secret_name} -n {namespace} -o json")
        if not output:
            print(f"❌ Secret {secret_name} not found in {namespace}")
            return False
        
        try:
            secret_data = json.loads(output)
            if not secret_data.get("data"):
                print(f"❌ Secret {secret_name} has no data")
                return False
            print(f"✅ Secret {secret_name} present in {namespace}")
        except json.JSONDecodeError:
            print(f"❌ Failed to parse secret {secret_name}")
            return False
    
    # Check ExternalSecret sync status
    external_secrets = [
        ("hetzner-api-token", "kube-system"),
        ("hetzner-dns-token", "kube-system")
    ]
    
    for es_name, namespace in external_secrets:
        output = run_kubectl(f"get externalsecret {es_name} -n {namespace} -o json")
        if not output:
            print(f"❌ ExternalSecret {es_name} not found in {namespace}")
            return False
        
        try:
            es_data = json.loads(output)
            conditions = es_data.get("status", {}).get("conditions", [])
            ready_condition = next((c for c in conditions if c.get("type") == "Ready"), None)
            
            if not ready_condition or ready_condition.get("status") != "True":
                print(f"❌ ExternalSecret {es_name} not ready")
                return False
            print(f"✅ ExternalSecret {es_name} synced")
        except json.JSONDecodeError:
            print(f"❌ Failed to parse ExternalSecret {es_name}")
            return False
    
    return True

def main():
    """Main validation function"""
    print("=== Checkpoint 1: Infrastructure Components Validation ===\n")
    
    success = True
    
    # Check ArgoCD applications
    if not check_argocd_apps():
        success = False
    
    # Check pods
    if not check_pods():
        success = False
    
    # Check secrets
    if not check_secrets():
        success = False
    
    print("\n" + "="*60)
    if success:
        print("✅ CHECKPOINT 1 PASSED: All infrastructure components deployed and healthy")
        sys.exit(0)
    else:
        print("❌ CHECKPOINT 1 FAILED: Some components are not ready")
        sys.exit(1)

if __name__ == "__main__":
    main()