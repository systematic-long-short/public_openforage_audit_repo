// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

// ============================================================
// TC-22: Event Emission Tests
// ============================================================
contract TimelockController_TC22_Events is TimelockControllerTestBase {
    function test_TC22_scheduleCallScheduledEvent() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("event_schedule");
        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 0, address(mockTarget), 0, data, bytes32(0), MIN_DELAY);

        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC22_scheduleCallSaltEvent() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("event_salt");
        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        vm.expectEmit(true, false, false, true);
        emit TimelockController.CallSalt(id, salt);

        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC22_scheduleZeroSaltNoEvent() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = bytes32(0);

        vm.recordLogs();
        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callSaltTopic = keccak256("CallSalt(bytes32,bytes32)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == callSaltTopic) {
                found = true;
            }
        }
        assertFalse(found, "CallSalt must NOT be emitted when salt is zero");
    }

    function test_TC22_scheduleBatchMultipleEvents() public {
        address[] memory targets = new address[](3);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);
        targets[2] = address(mockTarget);

        uint256[] memory values = new uint256[](3);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;

        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encodeCall(MockTarget.doSomething, ());
        payloads[1] = abi.encodeCall(MockTarget.doSomethingWithArgs, (1, address(0)));
        payloads[2] = abi.encodeCall(MockTarget.doSomethingWithArgs, (2, address(0)));

        bytes32 salt = keccak256("batch_multi_event");
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        // Expect 3 CallScheduled events + 1 CallSalt
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 0, targets[0], values[0], payloads[0], bytes32(0), MIN_DELAY);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 1, targets[1], values[1], payloads[1], bytes32(0), MIN_DELAY);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 2, targets[2], values[2], payloads[2], bytes32(0), MIN_DELAY);
        vm.expectEmit(true, false, false, true);
        emit TimelockController.CallSalt(id, salt);

        vm.prank(deployer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC22_executeCallExecutedEvent() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("event_execute");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 0, address(mockTarget), 0, data);

        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
    }

    function test_TC22_executeBatchMultipleEvents() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(MockTarget.doSomething, ());
        payloads[1] = abi.encodeCall(MockTarget.doSomethingWithArgs, (1, address(0)));

        bytes32 salt = keccak256("batch_exec_events");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 0, targets[0], values[0], payloads[0]);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 1, targets[1], values[1], payloads[1]);

        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function test_TC22_cancelCancelledEvent() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("event_cancel");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.expectEmit(true, false, false, false);
        emit TimelockController.Cancelled(id);

        vm.prank(deployer);
        timelock.cancel(id);
    }

    function test_TC22_updateDelayMinDelayChangeEvent() public {
        uint256 newDelay = 999999;
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt = keccak256("event_delay");

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(false, false, false, true);
        emit TimelockController.MinDelayChange(MIN_DELAY, newDelay);

        _executeOperation(address(timelock), 0, data, bytes32(0), salt);
    }

    function test_TC22_grantRoleEvent() public {
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt = keccak256("event_grant");

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(PROPOSER_ROLE, governor, address(timelock));

        _executeOperation(address(timelock), 0, data, bytes32(0), salt);
    }

    function test_TC22_revokeRoleEvent() public {
        // First grant governor PROPOSER_ROLE
        bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt1 = keccak256("event_grant_first");
        _scheduleOperation(address(timelock), 0, grantData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantData, bytes32(0), salt1);

        // Now revoke
        bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, governor));
        bytes32 salt2 = keccak256("event_revoke");
        _scheduleOperation(address(timelock), 0, revokeData, bytes32(0), salt2, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleRevoked(PROPOSER_ROLE, governor, address(timelock));

        _executeOperation(address(timelock), 0, revokeData, bytes32(0), salt2);
    }
}
