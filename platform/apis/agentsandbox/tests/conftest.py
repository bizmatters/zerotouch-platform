#!/usr/bin/env python3
"""
Common pytest fixtures for AgentSandbox tests
"""

import pytest
import subprocess
import tempfile
import os
import time
from typing import List


class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'


class KubectlHelper:
    """Helper class for kubectl operations with retry logic"""
    
    @staticmethod
    def kubectl_cmd(args: List[str], timeout: int = 15) -> subprocess.CompletedProcess:
        """Execute kubectl command with timeout"""
        cmd = ["kubectl"] + args
        try:
            return subprocess.run(cmd, timeout=timeout, capture_output=True, text=True, check=True)
        except subprocess.TimeoutExpired:
            raise Exception(f"kubectl command timed out after {timeout}s")
    
    @staticmethod
    def kubectl_retry(args: List[str], max_attempts: int = 20, verbose: bool = False) -> subprocess.CompletedProcess:
        """Execute kubectl command with retry logic"""
        for attempt in range(1, max_attempts + 1):
            try:
                return KubectlHelper.kubectl_cmd(args, timeout=15)
            except Exception as e:
                if attempt < max_attempts:
                    delay = attempt * 2
                    if verbose:
                        print(f"{Colors.YELLOW}⚠️  kubectl command failed (attempt {attempt}/{max_attempts}). Retrying in {delay}s...{Colors.NC}")
                    time.sleep(delay)
                else:
                    raise Exception(f"kubectl command failed after {max_attempts} attempts: {e}")


@pytest.fixture
def colors():
    """Provide Colors class for test output formatting"""
    return Colors


@pytest.fixture
def kubectl_helper():
    """Provide KubectlHelper for kubectl operations"""
    return KubectlHelper


@pytest.fixture
def test_namespace():
    """Create and cleanup test namespace"""
    namespace = f"agentsandbox-test-{os.getpid()}"
    
    # Create namespace
    try:
        subprocess.run(["kubectl", "create", "namespace", namespace], 
                     capture_output=True, text=True, check=False)
    except:
        pass
    
    yield namespace
    
    # Cleanup namespace
    try:
        subprocess.run(["kubectl", "delete", "namespace", namespace, "--ignore-not-found=true"], 
                     capture_output=True, text=True, check=False)
    except:
        pass


@pytest.fixture
def temp_dir():
    """Create and cleanup temporary directory"""
    temp_dir = tempfile.mkdtemp()
    yield temp_dir
    
    # Cleanup temp files
    import shutil
    try:
        shutil.rmtree(temp_dir)
    except:
        pass


@pytest.fixture
def test_counters():
    """Provide error and warning counters"""
    class Counters:
        def __init__(self):
            self.errors = 0
            self.warnings = 0
    
    return Counters()


@pytest.fixture
def tenant_config():
    """Provide default tenant configuration"""
    return {
        "tenant_name": "deepagents-runtime",
        "namespace": "intelligence-deepagents"
    }


@pytest.fixture
def test_claim_name():
    """Generate unique test claim name"""
    return f"test-persistence-{os.getpid()}"