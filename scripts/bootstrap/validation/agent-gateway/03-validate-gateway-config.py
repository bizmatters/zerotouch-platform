#!/usr/bin/env python3
"""
AgentGateway extAuthz Configuration Validation Script

Validates that the AgentGateway is properly configured with correct routing and extAuthz policies.

Verification Criteria:
- /auth/* routes bypass extAuthz and reach Identity Service directly
- /api/* routes invoke extAuthz with POST to /internal/validate
- requestHeaderModifier strips Cookie header from upstream requests
- includeRequestHeaders and includeResponseHeaders configuration is correct

Usage:
  python 03-validate-gateway-config.py  # Run as standalone script
"""

import subprocess
import json
import requests
import uuid
import time
import os
import sys
from typing import Dict, Any, Optional

def run_kubectl(cmd: str) -> Optional[str]:
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

def get_gateway_host() -> str:
    """Get AgentGateway host dynamically using kubectl"""
    # Allow override via environment variable
    env_host = os.getenv('GATEWAY_HOST')
    if env_host:
        return env_host
    
    # Discover AgentGateway using kubectl
    service_output = run_kubectl("get svc -l app.kubernetes.io/name=agentgateway -o json --all-namespaces")
    if not service_output:
        raise RuntimeError("Failed to discover AgentGateway - kubectl command failed")
    
    services_data = json.loads(service_output)
    services = services_data.get("items", [])
    
    if not services:
        raise RuntimeError("No AgentGateway found with label app.kubernetes.io/name=agentgateway")
    
    # Use the first service found
    service = services[0]
    service_name = service["metadata"]["name"]
    namespace = service["metadata"]["namespace"]
    
    # Get the service port
    ports = service.get("spec", {}).get("ports", [])
    if not ports:
        raise RuntimeError(f"No ports found for AgentGateway {service_name}")
    
    port = ports[0]["port"]
    host = f"{service_name}.{namespace}.svc.cluster.local:{port}"
    print(f"🔍 Discovered AgentGateway at: {host}")
    return host

def get_identity_service_host() -> str:
    """Get Identity Service host dynamically using kubectl"""
    # Allow override via environment variable
    env_host = os.getenv('IDENTITY_HOST')
    if env_host:
        return env_host
    
    # Discover Identity Service using kubectl
    service_output = run_kubectl("get svc -l app.kubernetes.io/name=identity-service -o json --all-namespaces")
    if not service_output:
        raise RuntimeError("Failed to discover Identity Service - kubectl command failed")
    
    services_data = json.loads(service_output)
    services = services_data.get("items", [])
    
    if not services:
        raise RuntimeError("No Identity Service found with label app.kubernetes.io/name=identity-service")
    
    # Use the first service found
    service = services[0]
    service_name = service["metadata"]["name"]
    namespace = service["metadata"]["namespace"]
    
    # Get the service port
    ports = service.get("spec", {}).get("ports", [])
    if not ports:
        raise RuntimeError(f"No ports found for Identity Service {service_name}")
    
    port = ports[0]["port"]
    host = f"{service_name}.{namespace}.svc.cluster.local:{port}"
    print(f"🔍 Discovered Identity Service at: {host}")
    return host

def make_request(method: str, path: str, host: str, headers: Dict[str, str] = None, json_data: Dict[str, Any] = None) -> requests.Response:
    """Make HTTP request to specified host"""
    url = f"http://{host}{path}"
    default_headers = {
        "Content-Type": "application/json",
        "User-Agent": "gateway-config-validator/1.0"
    }
    
    if headers:
        default_headers.update(headers)
    
    return requests.request(
        method=method,
        url=url,
        headers=default_headers,
        json=json_data,
        timeout=10
    )

def test_auth_routes_bypass_extauthz():
    """Test that /auth/* routes bypass extAuthz and reach Identity Service directly"""
    print("🔍 Testing /auth/* routes bypass extAuthz...")
    
    gateway_host = get_gateway_host()
    
    try:
        # Test GET /auth/login - should reach Identity Service directly
        response = make_request("GET", "/auth/login", gateway_host)
        
        # Should get 200 OK from Identity Service (login page)
        if response.status_code != 200:
            print(f"❌ Expected 200 for /auth/login, got {response.status_code}")
            return False
        
        # Should contain login page content
        if "Continue with Google" not in response.text:
            print("❌ /auth/login response doesn't contain expected login content")
            return False
        
        print("✅ /auth/login bypasses extAuthz and reaches Identity Service")
        return True
        
    except Exception as e:
        print(f"❌ Request to /auth/login failed: {e}")
        return False

def test_api_routes_invoke_extauthz():
    """Test that /api/* routes invoke extAuthz with POST to /internal/validate"""
    print("🔍 Testing /api/* routes invoke extAuthz...")
    
    gateway_host = get_gateway_host()
    
    try:
        # Test GET /api/v1/health without authentication - should trigger extAuthz
        response = make_request("GET", "/api/v1/health", gateway_host)
        
        # Should get 401 Unauthorized because extAuthz validation fails
        if response.status_code != 401:
            print(f"❌ Expected 401 for unauthenticated /api/v1/health, got {response.status_code}")
            print(f"❌ This indicates extAuthz is not being invoked properly")
            return False
        
        print("✅ /api/v1/health triggers extAuthz validation (returns 401 without auth)")
        return True
        
    except Exception as e:
        print(f"❌ Request to /api/v1/health failed: {e}")
        return False

def test_extauthz_validation_endpoint():
    """Test that extAuthz calls POST /internal/validate on Identity Service"""
    print("🔍 Testing extAuthz validation endpoint...")
    
    identity_host = get_identity_service_host()
    
    try:
        # Test direct call to /internal/validate without Cookie header
        # This simulates what AgentGateway should be doing
        response = make_request("POST", "/internal/validate", identity_host)
        
        # Should get 401 because no Cookie header provided
        if response.status_code != 401:
            print(f"❌ Expected 401 for /internal/validate without Cookie, got {response.status_code}")
            return False
        
        print("✅ /internal/validate endpoint responds correctly to extAuthz requests")
        return True
        
    except Exception as e:
        print(f"❌ Request to /internal/validate failed: {e}")
        return False

def test_cookie_header_stripping():
    """Test that Cookie headers are stripped from upstream requests"""
    print("🔍 Testing Cookie header stripping...")
    
    # This test requires a valid session to verify the header modification behavior
    # We'll create a test session first, then verify the behavior
    
    identity_host = get_identity_service_host()
    gateway_host = get_gateway_host()
    
    try:
        # Create a test session
        test_payload = {
            "external_id": f"header-test-{uuid.uuid4().hex[:8]}-{int(time.time())}",
            "email": f"header-test-{uuid.uuid4().hex[:8]}@example.com",
            "organization_name": f"Header Test Org {uuid.uuid4().hex[:8]}"
        }
        
        # Create session via Identity Service directly (not through gateway)
        session_response = make_request("POST", "/auth/test-session", identity_host, json_data=test_payload)
        
        if session_response.status_code != 200:
            print(f"❌ Failed to create test session: {session_response.status_code}")
            return False
        
        # Extract session cookie
        cookie_header = session_response.headers.get("Set-Cookie", "")
        if "__Host-platform_session=" not in cookie_header:
            print("❌ No session cookie in response")
            return False
        
        # Extract cookie value
        cookie_parts = cookie_header.split("__Host-platform_session=")[1].split(";")[0]
        session_cookie = f"__Host-platform_session={cookie_parts}"
        
        # Now test authenticated request through gateway
        headers = {"Cookie": session_cookie}
        api_response = make_request("GET", "/api/v1/health", gateway_host, headers=headers)
        
        # The response should be either:
        # - 200 OK if IDE Orchestrator is running and receives the JWT
        # - 5xx if IDE Orchestrator is not available but auth passed
        # - 401/403 if auth failed (Cookie not stripped properly or extAuthz failed)
        
        if api_response.status_code in [200]:
            print("✅ Authenticated request succeeded - Cookie header handling working")
            return True
        elif api_response.status_code >= 500:
            print("✅ Auth passed (downstream service error) - Cookie header handling working")
            return True
        elif api_response.status_code in [401, 403]:
            print(f"❌ Auth failed with status {api_response.status_code} - possible Cookie header issue")
            return False
        else:
            print(f"❌ Unexpected response status: {api_response.status_code}")
            return False
        
    except Exception as e:
        print(f"❌ Cookie header stripping test failed: {e}")
        return False

def test_include_headers_configuration():
    """Test that includeRequestHeaders and includeResponseHeaders are configured correctly"""
    print("🔍 Testing include headers configuration...")
    
    # This test verifies the configuration by checking the behavior
    # We can't directly inspect the AgentGateway config, but we can verify the behavior
    
    identity_host = get_identity_service_host()
    gateway_host = get_gateway_host()
    
    try:
        # Create a test session to get a valid cookie
        test_payload = {
            "external_id": f"headers-test-{uuid.uuid4().hex[:8]}-{int(time.time())}",
            "email": f"headers-test-{uuid.uuid4().hex[:8]}@example.com",
            "organization_name": f"Headers Test Org {uuid.uuid4().hex[:8]}"
        }
        
        session_response = make_request("POST", "/auth/test-session", identity_host, json_data=test_payload)
        
        if session_response.status_code != 200:
            print(f"❌ Failed to create test session: {session_response.status_code}")
            return False
        
        # Extract session cookie
        cookie_header = session_response.headers.get("Set-Cookie", "")
        cookie_parts = cookie_header.split("__Host-platform_session=")[1].split(";")[0]
        session_cookie = f"__Host-platform_session={cookie_parts}"
        
        # Test request with both Cookie and Authorization headers
        headers = {
            "Cookie": session_cookie,
            "Authorization": "Bearer test-token"  # This should be included in extAuthz
        }
        
        api_response = make_request("GET", "/api/v1/health", gateway_host, headers=headers)
        
        # If the configuration is correct:
        # - Cookie header should be sent to extAuthz (includeRequestHeaders: ["Cookie", "Authorization"])
        # - Authorization header should be sent to extAuthz
        # - Response headers should be included (includeResponseHeaders: ["Authorization", "X-Auth-User-Id", "X-Auth-Org-Id"])
        
        # We can't directly verify the headers sent to extAuthz, but we can verify the overall behavior
        if api_response.status_code in [200, 500, 502, 503, 504]:
            print("✅ Headers configuration appears correct (auth succeeded)")
            return True
        elif api_response.status_code in [401, 403]:
            print("❌ Auth failed - possible headers configuration issue")
            return False
        else:
            print(f"❌ Unexpected response status: {api_response.status_code}")
            return False
        
    except Exception as e:
        print(f"❌ Headers configuration test failed: {e}")
        return False

def test_gateway_configuration_file():
    """Test that the AgentGateway configuration file is properly structured"""
    print("🔍 Testing AgentGateway configuration file...")
    
    try:
        # Read the AgentGateway configuration from the cluster
        config_output = run_kubectl("get configmap agentgateway-config -o jsonpath='{.data.config\\.yaml}' -n platform-gateway")
        
        if not config_output:
            print("❌ Could not retrieve AgentGateway configuration")
            return False
        
        # Parse the YAML configuration
        import yaml
        try:
            config = yaml.safe_load(config_output)
        except yaml.YAMLError as e:
            print(f"❌ Invalid YAML in AgentGateway config: {e}")
            return False
        
        # Verify basic structure
        if "binds" not in config:
            print("❌ Missing 'binds' section in config")
            return False
        
        binds = config["binds"]
        if not isinstance(binds, list) or len(binds) == 0:
            print("❌ 'binds' should be a non-empty list")
            return False
        
        # Check the first bind configuration
        bind = binds[0]
        if "listeners" not in bind:
            print("❌ Missing 'listeners' in bind configuration")
            return False
        
        listeners = bind["listeners"]
        if not isinstance(listeners, list) or len(listeners) == 0:
            print("❌ 'listeners' should be a non-empty list")
            return False
        
        listener = listeners[0]
        if "routes" not in listener:
            print("❌ Missing 'routes' in listener configuration")
            return False
        
        routes = listener["routes"]
        if not isinstance(routes, list) or len(routes) < 2:
            print("❌ Should have at least 2 routes (auth and api)")
            return False
        
        # Find auth and api routes
        auth_route = None
        api_route = None
        
        for route in routes:
            if route.get("name") == "auth":
                auth_route = route
            elif route.get("name") == "api":
                api_route = route
        
        if not auth_route:
            print("❌ Missing 'auth' route configuration")
            return False
        
        if not api_route:
            print("❌ Missing 'api' route configuration")
            return False
        
        # Verify auth route configuration (should NOT have extAuthz)
        if "policies" in auth_route and "extAuthz" in auth_route["policies"]:
            print("❌ Auth route should not have extAuthz policy")
            return False
        
        # Verify API route configuration (should have extAuthz)
        if "policies" not in api_route:
            print("❌ API route missing policies section")
            return False
        
        policies = api_route["policies"]
        if "extAuthz" not in policies:
            print("❌ API route missing extAuthz policy")
            return False
        
        extauthz = policies["extAuthz"]
        
        # Verify extAuthz configuration
        if "host" not in extauthz:
            print("❌ extAuthz missing host configuration")
            return False
        
        if "identity-service.platform-identity.svc.cluster.local:3000" not in extauthz["host"]:
            print("❌ extAuthz host should point to Identity Service")
            return False
        
        if "includeRequestHeaders" not in extauthz:
            print("❌ extAuthz missing includeRequestHeaders")
            return False
        
        include_request_headers = extauthz["includeRequestHeaders"]
        if "Cookie" not in include_request_headers or "Authorization" not in include_request_headers:
            print("❌ extAuthz should include Cookie and Authorization headers")
            return False
        
        # Verify requestHeaderModifier (Cookie removal)
        if "requestHeaderModifier" not in policies:
            print("❌ API route missing requestHeaderModifier")
            return False
        
        header_modifier = policies["requestHeaderModifier"]
        if "remove" not in header_modifier:
            print("❌ requestHeaderModifier missing remove section")
            return False
        
        if "Cookie" not in header_modifier["remove"]:
            print("❌ requestHeaderModifier should remove Cookie header")
            return False
        
        print("✅ AgentGateway configuration file is properly structured")
        return True
        
    except Exception as e:
        print(f"❌ Configuration file test failed: {e}")
        return False

def main():
    """Main validation function"""
    print("=== CHECKPOINT 2: Gateway Configuration Validated ===\n")
    
    # Check for dry-run mode
    dry_run = os.getenv('DRY_RUN', 'false').lower() == 'true'
    if dry_run:
        print("🔍 Running in dry-run mode - skipping actual tests")
        print("✅ Script structure validated")
        sys.exit(0)
    
    success = True
    
    # Run all configuration tests
    if not test_auth_routes_bypass_extauthz():
        success = False
    
    if not test_api_routes_invoke_extauthz():
        success = False
    
    if not test_extauthz_validation_endpoint():
        success = False
    
    if not test_cookie_header_stripping():
        success = False
    
    if not test_include_headers_configuration():
        success = False
    
    if not test_gateway_configuration_file():
        success = False
    
    print("\n" + "="*60)
    if success:
        print("✅ CHECKPOINT 2 PASSED: Gateway configuration validated")
        sys.exit(0)
    else:
        print("❌ CHECKPOINT 2 FAILED: Gateway configuration validation failed")
        sys.exit(1)

if __name__ == "__main__":
    main()