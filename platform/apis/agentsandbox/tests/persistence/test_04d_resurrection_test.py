#!/usr/bin/env python3
"""
Test Resurrection (Pod Recreation with Data Persistence)
Validates stable identity and data persistence across pod recreation
Usage: pytest test_04d_resurrection_test.py -v
"""

import pytest
import time


class TestResurrectionTest:

    def test_pod_resurrection_with_data_persistence(self, ready_claim_manager, workspace_manager, k8s, colors):
        """Test: Pod resurrection maintains stable identity and data persistence"""
        test_claim_name = "test-resurrection-4d"
        namespace = "intelligence-deepagents"
        print(f"{colors.BLUE}Testing Pod Resurrection with Data Persistence{colors.NC}")
        
        # Step 1: Create claim and get initial pod
        start_time = time.time()
        pod_name = ready_claim_manager(test_claim_name, "RESURRECTION_STREAM")
        original_pod_uid = k8s.get_pod_uid(pod_name)
        
        print(f"{colors.BLUE}Original Pod: {pod_name} (UID: {original_pod_uid[:8]}...){colors.NC}")
        
        # Step 2: Validate stable network identity
        service_name = f"{test_claim_name}-http"
        assert k8s.service_exists(service_name), f"Service {service_name} not found"
        print(f"{colors.GREEN}✓ Stable network identity confirmed: Service '{service_name}' exists{colors.NC}")
        
        # Step 3: Write test data using workspace_manager fixture
        test_data = f"resurrection-{original_pod_uid[:8]}"
        workspace_manager(test_claim_name, namespace, "resurrection.txt", test_data)
        print(f"{colors.GREEN}✓ Test data written: {test_data}{colors.NC}")
        
        # Step 4: Delete pod to trigger resurrection using ready_claim_manager fixture
        print(f"{colors.BLUE}Deleting pod to trigger resurrection...{colors.NC}")
        ready_claim_manager.delete(test_claim_name, namespace)
        
        # Step 5: Wait for resurrection using ready_claim_manager fixture
        print(f"{colors.BLUE}Waiting for pod resurrection...{colors.NC}")
        time.sleep(10)
        new_pod_name = ready_claim_manager(test_claim_name, "RESURRECTION_STREAM")
        new_pod_uid = k8s.get_pod_uid(new_pod_name)
        
        resurrection_latency = time.time() - start_time
        print(f"{colors.BLUE}New Pod: {new_pod_name} (UID: {new_pod_uid[:8]}...){colors.NC}")
        print(f"{colors.GREEN}✓ Resurrection Latency: {resurrection_latency:.2f}s{colors.NC}")
        
        # Step 6: Validate data persistence using workspace_manager fixture
        actual_data = workspace_manager.read(test_claim_name, namespace, "resurrection.txt")
        assert actual_data == test_data, f"Data persistence failed. Expected: {test_data}, Got: {actual_data}"
        print(f"{colors.GREEN}✓ Data persisted: {test_data}{colors.NC}")
        
        # Step 7: Validate stable identity maintained
        assert k8s.service_exists(service_name), f"Service {service_name} lost after resurrection"
        print(f"{colors.GREEN}✓ Stable network identity maintained{colors.NC}")
        
        print(f"{colors.GREEN}✓ Resurrection Test Complete{colors.NC}")

    def test_multiple_resurrections(self, ready_claim_manager, workspace_manager, colors):
        """Test: Multiple pod resurrections maintain consistency"""
        test_claim_name = "test-multi-resurrection-4d"
        namespace = "intelligence-deepagents"
        print(f"{colors.BLUE}Testing Multiple Resurrections{colors.NC}")
        
        # Create claim using ready_claim_manager fixture
        pod_name = ready_claim_manager(test_claim_name, "MULTI_RESURRECTION_STREAM")
        
        resurrection_data = []
        
        # Perform 3 resurrection cycles
        for i in range(3):
            print(f"{colors.BLUE}Resurrection cycle {i+1}/3{colors.NC}")
            
            # Write unique data for this cycle using workspace_manager fixture
            test_data = f"cycle-{i+1}-{int(time.time())}"
            workspace_manager(test_claim_name, namespace, f"cycle-{i+1}.txt", test_data)
            
            resurrection_data.append({"file": f"cycle-{i+1}.txt", "data": test_data})
            
            # Delete and recreate pod (except on last cycle) using ready_claim_manager fixture
            if i < 2:
                ready_claim_manager.delete(test_claim_name, namespace)
                time.sleep(5)
                pod_name = ready_claim_manager(test_claim_name, "MULTI_RESURRECTION_STREAM")
        
        # Validate all data persisted using workspace_manager fixture
        for cycle_data in resurrection_data:
            actual_data = workspace_manager.read(test_claim_name, namespace, cycle_data['file'])
            assert actual_data == cycle_data["data"], f"Data persistence failed for {cycle_data['file']}"
            print(f"{colors.GREEN}✓ Cycle data persisted: {cycle_data['data']}{colors.NC}")
        
        print(f"{colors.GREEN}✓ Multiple Resurrections Test Complete{colors.NC}")