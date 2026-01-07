#!/usr/bin/env python3
"""
Test Container Validation (InitContainer, Sidecar, PreStop Hook)
Validates S3 hydration, backup sidecar, and preStop hook configuration
Usage: pytest test_04c_container_validation.py -v
"""

import pytest
import time


class TestContainerValidation:

    def test_initcontainer_s3_hydration(self, ready_claim_manager, workspace_manager, k8s, colors):
        """Test: InitContainer for S3 workspace hydration"""
        test_claim_name = "test-s3-hydration"
        namespace = "intelligence-deepagents"
        print(f"{colors.BLUE}Testing InitContainer S3 Hydration{colors.NC}")
        
        # Step 1: Pre-populate S3 with test data in the format InitContainer expects
        test_data = "s3-hydration-test-data"
        test_files = {"hydration-test.txt": test_data}
        workspace_manager.write_s3(test_claim_name, namespace, "workspace.tar.gz", test_files)
        
        # Step 2: Create claim - InitContainer should download from S3
        pod_name = ready_claim_manager(test_claim_name, "S3_HYDRATION_STREAM")
        
        # Step 3: Validate InitContainer downloaded S3 data to workspace
        actual_data = workspace_manager.read(test_claim_name, namespace, "hydration-test.txt")
        assert actual_data == test_data, f"S3 hydration failed. Expected: {test_data}, Got: {actual_data}"
        
        print(f"{colors.GREEN}✓ InitContainer S3 hydration validated: {test_data}{colors.NC}")

    def test_sidecar_backup_container(self, ready_claim_manager, workspace_manager, colors):
        """Test: Sidecar container for continuous workspace backup"""
        test_claim_name = "test-sidecar-backup"
        namespace = "intelligence-deepagents"
        print(f"{colors.BLUE}Testing Sidecar Backup Container{colors.NC}")
        
        # Step 1: Create claim and write data to workspace
        pod_name = ready_claim_manager(test_claim_name, "SIDECAR_BACKUP_STREAM")
        test_data = "sidecar-backup-test-data"
        workspace_manager(test_claim_name, namespace, "backup-test.txt", test_data)
        
        # Step 2: Wait for sidecar backup cycle (5 minutes)
        print(f"{colors.YELLOW}⏳ Waiting 5 minutes for sidecar backup cycle...{colors.NC}")
        time.sleep(300)
        
        # Step 3: Validate data exists in S3 (sidecar uploaded it)
        s3_data = workspace_manager.read_s3(test_claim_name, namespace, "backup-test.txt")
        assert s3_data == test_data, f"Sidecar backup failed. Expected: {test_data}, Got: {s3_data}"
        
        print(f"{colors.GREEN}✓ Sidecar backup container validated: {test_data}{colors.NC}")

    def test_prestop_hook_validation(self, ready_claim_manager, workspace_manager, k8s, colors):
        """Test: PreStop hook for graceful shutdown"""
        test_claim_name = "test-prestop-hook"
        namespace = "intelligence-deepagents"
        print(f"{colors.BLUE}Testing PreStop Hook Configuration{colors.NC}")
        
        # Step 1: Create claim and write data
        pod_name = ready_claim_manager(test_claim_name, "PRESTOP_HOOK_STREAM")
        test_data = "prestop-final-sync-data"
        workspace_manager(test_claim_name, namespace, "final-sync.txt", test_data)
        
        # Step 2: Delete pod to trigger preStop hook
        print(f"{colors.YELLOW}⚠️ Deleting pod to trigger preStop hook...{colors.NC}")
        k8s.delete_pod(pod_name, wait=True)
        
        # Step 3: Wait for preStop hook to complete
        time.sleep(30)
        
        # Step 4: Validate preStop hook synced data to S3
        s3_data = workspace_manager.read_s3(test_claim_name, namespace, "final-sync.txt")
        assert s3_data == test_data, f"PreStop hook sync failed. Expected: {test_data}, Got: {s3_data}"
        
        print(f"{colors.GREEN}✓ PreStop hook validated: {test_data}{colors.NC}")