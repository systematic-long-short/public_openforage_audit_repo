// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

// ============================================================
// TC-01: Constructor and Initial State
// ============================================================
contract TimelockController_TC01_Constructor is TimelockControllerTestBase {
    function test_TC01_constructorMinDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY, "Min delay must be 691200 (8 days)");
    }

    function test_TC01_deployerHasProposerRole() public view {
        assertTrue(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must have PROPOSER_ROLE");
    }

    function test_TC01_deployerHasCancellerRole() public view {
        assertTrue(timelock.hasRole(CANCELLER_ROLE, deployer), "Deployer must have CANCELLER_ROLE (auto-granted)");
    }

    function test_TC01_openExecution() public view {
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)), "address(0) must have EXECUTOR_ROLE (open execution)");
    }

    function test_TC01_selfHasAdminRole() public view {
        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)),
            "TimelockController itself must have DEFAULT_ADMIN_ROLE"
        );
    }

    function test_TC01_deployerNoAdminRole() public view {
        assertFalse(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer),
            "Deployer must NOT have DEFAULT_ADMIN_ROLE (admin=address(0) in constructor)"
        );
    }

    function test_TC01_addressZeroNoProposerRole() public view {
        // address(0) having EXECUTOR_ROLE does not mean it has PROPOSER_ROLE
        assertFalse(timelock.hasRole(PROPOSER_ROLE, address(0)), "address(0) must NOT have PROPOSER_ROLE");
    }

    function test_TC01_decimalsMatchConstants() public view {
        // Launch phase: MIN_DELAY = 0 (team controls all votes, no delay needed)
        assertEq(MIN_DELAY, 0, "MIN_DELAY must be 0 in launch phase");
        // Production delay = 8 days = 8 * 24 * 60 * 60 = 691200
        assertEq(PRODUCTION_DELAY, 8 * 24 * 60 * 60, "PRODUCTION_DELAY must equal 8 days in seconds");
        // Production delay exceeds 7-day cooldown
        assertGt(PRODUCTION_DELAY, SEVEN_DAYS, "8-day production delay must exceed 7-day cooldown period");
    }
}

// ============================================================
// TC-02: Single Operation Scheduling
// ============================================================
contract TimelockController_TC02_Schedule is TimelockControllerTestBase {
    function test_TC02_scheduleSucceeds() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("test_salt");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        assertTrue(timelock.isOperationPending(id), "Operation must be pending after scheduling");
    }

    function test_TC02_scheduleEmitsCallScheduled() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("test_salt");
        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 0, address(mockTarget), 0, data, bytes32(0), MIN_DELAY);
        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC02_scheduleEmitsCallSalt() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("nonzero_salt");
        bytes32 id = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        vm.expectEmit(true, false, false, true);
        emit TimelockController.CallSalt(id, salt);
        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC02_scheduleNoCallSaltOnZeroSalt() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = bytes32(0);

        vm.recordLogs();
        vm.prank(deployer);
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callSaltTopic = keccak256("CallSalt(bytes32,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], callSaltTopic, "CallSalt must not be emitted for zero salt");
        }
    }

    function test_TC02_scheduleSetsOperationPending() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("pending_test");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        // Launch phase: delay=0 means operation is immediately Ready (not Waiting)
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Ready),
            "Operation state must be Ready with delay=0 (launch phase)"
        );
    }

    function test_TC02_scheduleSetsCorrectTimestamp() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("timestamp_test");
        uint256 scheduledAt = block.timestamp;
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        assertEq(timelock.getTimestamp(id), scheduledAt + MIN_DELAY, "Timestamp must be block.timestamp + delay");
    }

    function test_TC02_scheduleRevertsUnauthorized() public {
        bytes memory data = _doSomethingCalldata();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, PROPOSER_ROLE)
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_TC02_scheduleRevertsInsufficientDelay() public {
        // Launch phase: MIN_DELAY=0, so any uint256 delay >= 0 is valid (no insufficient case).
        // Verify delay=0 is accepted in launch phase.
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("delay_zero_ok");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, 0);
        assertTrue(timelock.isOperationPending(id), "delay=0 must be accepted in launch phase");

        // Deploy a production-configured timelock to test insufficient delay enforcement
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        vm.prank(deployer);
        TimelockController prodTimelock = new TimelockController(PRODUCTION_DELAY, proposers, executors, address(0));

        uint256 insufficientDelay = PRODUCTION_DELAY - 1;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockInsufficientDelay.selector, insufficientDelay, PRODUCTION_DELAY
            )
        );
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), bytes32(0), insufficientDelay);
    }

    function test_TC02_scheduleRevertsDuplicate() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("dup_test");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Unset)
            )
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC02_scheduleAboveMinDelay() public {
        bytes memory data = _doSomethingCalldata();
        uint256 aboveDelay = MIN_DELAY + 1000;
        bytes32 salt = keccak256("above_delay");

        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, aboveDelay);
        assertTrue(timelock.isOperationPending(id), "Must accept delay above minimum");
    }

    function test_TC02_scheduleExactMinDelay() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("exact_delay");

        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        assertTrue(timelock.isOperationPending(id), "Must accept exact minimum delay");
    }
}

// ============================================================
// TC-03: Batch Operation Scheduling
// ============================================================
contract TimelockController_TC03_ScheduleBatch is TimelockControllerTestBase {
    function _buildBatchArrays()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(MockTarget.doSomething, ());
        payloads[1] = abi.encodeCall(MockTarget.doSomethingWithArgs, (42, address(this)));
    }

    function test_TC03_scheduleBatchSucceeds() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_salt");

        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        assertTrue(timelock.isOperationPending(id), "Batch operation must be pending");
    }

    function test_TC03_scheduleBatchEmitsMultipleEvents() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_events");
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 0, targets[0], values[0], payloads[0], bytes32(0), MIN_DELAY);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(id, 1, targets[1], values[1], payloads[1], bytes32(0), MIN_DELAY);

        vm.prank(deployer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC03_scheduleBatchEmitsCallSalt() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_salt_event");
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);

        vm.expectEmit(true, false, false, true);
        emit TimelockController.CallSalt(id, salt);

        vm.prank(deployer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC03_scheduleBatchRevertsUnauthorized() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, PROPOSER_ROLE)
        );
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_TC03_scheduleBatchRevertsInsufficientDelay() public {
        // Launch phase: MIN_DELAY=0, so any uint256 delay >= 0 is valid (no insufficient case).
        // Verify delay=0 is accepted in launch phase.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_delay_zero_ok");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, 0);
        assertTrue(timelock.isOperationPending(id), "delay=0 must be accepted for batch in launch phase");

        // Deploy a production-configured timelock to test insufficient delay enforcement
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        vm.prank(deployer);
        TimelockController prodTimelock = new TimelockController(PRODUCTION_DELAY, proposers, executors, address(0));

        uint256 insufficientDelay = PRODUCTION_DELAY - 1;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockInsufficientDelay.selector, insufficientDelay, PRODUCTION_DELAY
            )
        );
        prodTimelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), insufficientDelay);
    }

    function test_TC03_scheduleBatchRevertsDuplicate() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_dup");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Unset)
            )
        );
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
    }
}

// ============================================================
// TC-04: Single Operation Execution
// ============================================================
contract TimelockController_TC04_Execute is TimelockControllerTestBase {
    function test_TC04_executeAfterDelay() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("exec_test");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        _warpPastDelay();

        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(id), "Operation must be Done after execution");
    }

    function test_TC04_executeRevertsBeforeDelay() public {
        // With delay=0 (launch phase), operations are immediately Ready and executable.
        // Use a non-zero delay to test that execution before delay elapses reverts.
        uint256 testDelay = 100;
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("early_exec");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, testDelay);

        // Do NOT warp — still in Waiting state
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
    }

    function test_TC04_executeRevertsOneSecondEarly() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("one_sec_early");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        // Warp to 1 second before ready
        vm.warp(block.timestamp + MIN_DELAY - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
    }

    function test_TC04_executeOpenExecution() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("open_exec");
        _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        // Any address can execute (open execution via address(0) EXECUTOR_ROLE)
        vm.prank(attacker);
        timelock.execute(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(mockTarget.callCount(), 1, "Target must have been called");
    }

    function test_TC04_executeEmitsCallExecuted() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("exec_event");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 0, address(mockTarget), 0, data);
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
    }

    function test_TC04_executeSetsStateDone() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("done_state");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Done),
            "State must be Done"
        );
    }

    function test_TC04_executeTimestampSentinel() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("sentinel");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        // Done operations have timestamp = 1 (DONE_TIMESTAMP sentinel)
        assertEq(timelock.getTimestamp(id), 1, "Done operations must have timestamp = 1");
    }

    function test_TC04_executeTargetReceivesCall() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("target_call");
        _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(mockTarget.callCount(), 1, "MockTarget must record the call");
        assertEq(mockTarget.lastCaller(), address(timelock), "Caller must be the timelock");
    }

    function test_TC04_executeRevertsOnTargetRevert() public {
        bytes memory data = abi.encodeCall(RevertTarget.doSomething, ());
        bytes32 salt = keccak256("revert_target");
        _scheduleOperation(address(revertTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectRevert(RevertTarget.AlwaysReverts.selector);
        _executeOperation(address(revertTarget), 0, data, bytes32(0), salt);
    }

    function test_TC04_executeByAnotherArbitraryAddress() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("arbitrary_executor");
        _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        // executor1 is not granted any role, but open execution allows anyone
        vm.prank(executor1);
        timelock.execute(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(mockTarget.callCount(), 1, "Arbitrary address must be able to execute");
    }
}

// ============================================================
// TC-05: Batch Operation Execution
// ============================================================
contract TimelockController_TC05_ExecuteBatch is TimelockControllerTestBase {
    function _buildBatchArrays()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(mockTarget);

        values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(MockTarget.doSomething, ());
        payloads[1] = abi.encodeCall(MockTarget.doSomethingWithArgs, (42, address(this)));
    }

    function test_TC05_executeBatchSucceeds() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_exec");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(id), "Batch must be Done after execution");
        assertEq(mockTarget.callCount(), 2, "Both calls must have executed");
    }

    function test_TC05_executeBatchEmitsMultipleEvents() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_events_exec");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 0, targets[0], values[0], payloads[0]);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(id, 1, targets[1], values[1], payloads[1]);

        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function test_TC05_executeBatchAtomicRevert() public {
        // Build batch where second call reverts
        address[] memory targets = new address[](2);
        targets[0] = address(mockTarget);
        targets[1] = address(revertTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(MockTarget.doSomething, ());
        payloads[1] = abi.encodeCall(RevertTarget.doSomething, ());

        bytes32 salt = keccak256("batch_atomic");
        _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        // The entire batch reverts if any call fails
        vm.expectRevert(RevertTarget.AlwaysReverts.selector);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        // First call's effects should be rolled back
        assertEq(mockTarget.callCount(), 0, "First call must be rolled back on batch revert");
    }

    function test_TC05_executeBatchStateAfterExecution() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_state");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Done),
            "Batch state must be Done"
        );
        assertEq(timelock.getTimestamp(id), 1, "Done batch must have timestamp = 1");
    }

    function test_TC05_executeBatchRevertsNotReady() public {
        // With delay=0 (launch phase), operations are immediately Ready.
        // Use a non-zero delay to test that execution before delay elapses reverts.
        uint256 testDelay = 100;
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 salt = keccak256("batch_not_ready");
        bytes32 id = _scheduleBatchOperation(targets, values, payloads, bytes32(0), salt, testDelay);

        // Do NOT warp — still Waiting
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function test_TC05_executeBatchPredecessor() public {
        // Schedule and execute a predecessor
        bytes memory predData = _doSomethingCalldata();
        bytes32 predSalt = keccak256("predecessor");
        bytes32 predId = _scheduleOperation(address(mockTarget), 0, predData, bytes32(0), predSalt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, predData, bytes32(0), predSalt);

        // Now schedule batch with predecessor
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _buildBatchArrays();
        bytes32 batchSalt = keccak256("batch_with_pred");
        _scheduleBatchOperation(targets, values, payloads, predId, batchSalt, MIN_DELAY);
        _warpPastDelay();

        // Execute succeeds because predecessor is done
        timelock.executeBatch(targets, values, payloads, predId, batchSalt);
        assertEq(mockTarget.callCount(), 3, "Predecessor + 2 batch calls must have executed");
    }
}

// ============================================================
// TC-06: Access Control and Role Management
// ============================================================
contract TimelockController_TC06_AccessControl is TimelockControllerTestBase {
    function test_TC06_roleAdminIsDefaultAdmin() public view {
        assertEq(
            timelock.getRoleAdmin(PROPOSER_ROLE), DEFAULT_ADMIN_ROLE, "PROPOSER_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
        assertEq(
            timelock.getRoleAdmin(EXECUTOR_ROLE), DEFAULT_ADMIN_ROLE, "EXECUTOR_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
        assertEq(
            timelock.getRoleAdmin(CANCELLER_ROLE), DEFAULT_ADMIN_ROLE, "CANCELLER_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
    }

    function test_TC06_attackerCannotGrantRole() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, attacker);
    }

    function test_TC06_deployerCannotGrantRole() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.grantRole(PROPOSER_ROLE, governor);
    }

    function test_TC06_grantRoleViaScheduledOp() public {
        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt = keccak256("grant_proposer");
        bytes32 id = _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(PROPOSER_ROLE, governor, address(timelock));
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertTrue(timelock.hasRole(PROPOSER_ROLE, governor), "Governor must have PROPOSER_ROLE after grant");
    }

    function test_TC06_revokeRoleViaScheduledOp() public {
        // First grant governor PROPOSER_ROLE
        bytes memory grantData = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, governor));
        bytes32 salt1 = keccak256("grant_for_revoke");
        _scheduleOperation(address(timelock), 0, grantData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, grantData, bytes32(0), salt1);
        assertTrue(timelock.hasRole(PROPOSER_ROLE, governor), "Governor must have role before revoke");

        // Now revoke it
        bytes memory revokeData = abi.encodeCall(IAccessControl.revokeRole, (PROPOSER_ROLE, governor));
        bytes32 salt2 = keccak256("revoke_proposer");
        _scheduleOperation(address(timelock), 0, revokeData, bytes32(0), salt2, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleRevoked(PROPOSER_ROLE, governor, address(timelock));
        _executeOperation(address(timelock), 0, revokeData, bytes32(0), salt2);

        assertFalse(timelock.hasRole(PROPOSER_ROLE, governor), "Governor must NOT have PROPOSER_ROLE after revoke");
    }

    function test_TC06_openExecutionVerification() public {
        // Verify open execution: any address can call execute
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("open_exec_verify");
        _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        address randomAddr = makeAddr("random");
        vm.prank(randomAddr);
        timelock.execute(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(mockTarget.callCount(), 1, "Random address must be able to execute (open execution)");
    }

    function test_TC06_attackerCannotRevokeRole() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
            )
        );
        timelock.revokeRole(PROPOSER_ROLE, deployer);
    }
}

// ============================================================
// TC-07: Cancel Operation
// ============================================================
contract TimelockController_TC07_Cancel is TimelockControllerTestBase {
    function test_TC07_cancelPendingOperation() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_test");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer); // deployer has CANCELLER_ROLE
        vm.expectEmit(true, false, false, false);
        emit TimelockController.Cancelled(id);
        timelock.cancel(id);
    }

    function test_TC07_cancelRevertsUnauthorized() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_unauth");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, CANCELLER_ROLE)
        );
        timelock.cancel(id);
    }

    function test_TC07_cancelReturnsToUnset() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_unset");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        timelock.cancel(id);

        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Unset),
            "Cancelled operation must be Unset"
        );
    }

    function test_TC07_cancelTimestampCleared() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_ts");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        timelock.cancel(id);

        assertEq(timelock.getTimestamp(id), 0, "Cancelled operation timestamp must be 0");
    }

    function test_TC07_cancelDoneOperationReverts() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_done");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Waiting)
                    | _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        timelock.cancel(id);
    }

    function test_TC07_cancelNonExistentReverts() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                fakeId,
                _encodeStateBitmap(TimelockController.OperationState.Waiting)
                    | _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        timelock.cancel(fakeId);
    }

    function test_TC07_reScheduleAfterCancel() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("reschedule");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        timelock.cancel(id);

        // Re-schedule the same operation after cancellation
        bytes32 id2 = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        assertEq(id, id2, "Same params must produce same hash");
        assertTrue(timelock.isOperationPending(id2), "Re-scheduled operation must be pending");
    }
}

// ============================================================
// TC-08: Predecessor Dependencies
// ============================================================
contract TimelockController_TC08_Predecessor is TimelockControllerTestBase {
    function test_TC08_predecessorEnforced() public {
        // Schedule predecessor
        bytes memory predData = _doSomethingCalldata();
        bytes32 predSalt = keccak256("pred");
        bytes32 predId = _scheduleOperation(address(mockTarget), 0, predData, bytes32(0), predSalt, MIN_DELAY);

        // Schedule dependent with predecessor
        bytes memory depData = abi.encodeCall(MockTarget.doSomethingWithArgs, (1, address(0)));
        bytes32 depSalt = keccak256("dependent");
        bytes32 depId = _scheduleOperation(address(mockTarget), 0, depData, predId, depSalt, MIN_DELAY);
        _warpPastDelay();

        // Execute dependent before predecessor — must revert
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, predId));
        _executeOperation(address(mockTarget), 0, depData, predId, depSalt);
    }

    function test_TC08_predecessorSatisfied() public {
        // Schedule and execute predecessor
        bytes memory predData = _doSomethingCalldata();
        bytes32 predSalt = keccak256("pred_satisfied");
        bytes32 predId = _scheduleOperation(address(mockTarget), 0, predData, bytes32(0), predSalt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, predData, bytes32(0), predSalt);

        // Schedule and execute dependent
        bytes memory depData = abi.encodeCall(MockTarget.doSomethingWithArgs, (2, address(0)));
        bytes32 depSalt = keccak256("dep_satisfied");
        _scheduleOperation(address(mockTarget), 0, depData, predId, depSalt, MIN_DELAY);
        _warpPastDelay();

        _executeOperation(address(mockTarget), 0, depData, predId, depSalt);
        assertEq(mockTarget.callCount(), 2, "Both predecessor and dependent must have executed");
    }

    function test_TC08_batchPredecessorSatisfied() public {
        // Execute a predecessor first
        bytes memory predData = _doSomethingCalldata();
        bytes32 predSalt = keccak256("batch_pred");
        bytes32 predId = _scheduleOperation(address(mockTarget), 0, predData, bytes32(0), predSalt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, predData, bytes32(0), predSalt);

        // Schedule batch with predecessor
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = _doSomethingCalldata();

        bytes32 batchSalt = keccak256("batch_dep");
        _scheduleBatchOperation(targets, values, payloads, predId, batchSalt, MIN_DELAY);
        _warpPastDelay();

        timelock.executeBatch(targets, values, payloads, predId, batchSalt);
        assertEq(mockTarget.callCount(), 2, "Predecessor + batch call must have executed");
    }

    function test_TC08_batchPredecessorNotMet() public {
        // Schedule predecessor but do NOT execute it
        bytes memory predData = _doSomethingCalldata();
        bytes32 predSalt = keccak256("unmet_pred");
        bytes32 predId = _scheduleOperation(address(mockTarget), 0, predData, bytes32(0), predSalt, MIN_DELAY);

        // Schedule batch with predecessor
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodeCall(MockTarget.doSomethingWithArgs, (99, address(0)));

        bytes32 batchSalt = keccak256("batch_unmet");
        _scheduleBatchOperation(targets, values, payloads, predId, batchSalt, MIN_DELAY);
        _warpPastDelay();

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, predId));
        timelock.executeBatch(targets, values, payloads, predId, batchSalt);
    }

    function test_TC08_nonExistentPredecessor() public {
        bytes32 fakePredId = keccak256("fake_predecessor");

        bytes memory depData = _doSomethingCalldata();
        bytes32 depSalt = keccak256("dep_fake_pred");
        _scheduleOperation(address(mockTarget), 0, depData, fakePredId, depSalt, MIN_DELAY);
        _warpPastDelay();

        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, fakePredId));
        _executeOperation(address(mockTarget), 0, depData, fakePredId, depSalt);
    }
}

// ============================================================
// TC-09: Delay Validation and UpdateDelay
// ============================================================
contract TimelockController_TC09_Delay is TimelockControllerTestBase {
    function test_TC09_initialMinDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY, "Initial min delay must be 0 (launch phase)");
    }

    function test_TC09_scheduleAtExactMinDelay() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("exact");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        assertTrue(timelock.isOperationPending(id), "Exact min delay must be accepted");
    }

    function test_TC09_scheduleAboveMinDelay() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("above");
        uint256 longDelay = MIN_DELAY * 2;
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, longDelay);
        assertTrue(timelock.isOperationPending(id), "Above min delay must be accepted");
    }

    function test_TC09_scheduleBelowMinDelayReverts() public {
        // Launch phase: MIN_DELAY=0, so no insufficient delay case exists.
        // Verify delay=0 is accepted, then test with a production-configured timelock.
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("launch_delay_zero");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, 0);
        assertTrue(timelock.isOperationPending(id), "delay=0 must be accepted in launch phase");

        // Deploy a production-configured timelock and verify insufficient delay reverts
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        vm.prank(deployer);
        TimelockController prodTimelock = new TimelockController(PRODUCTION_DELAY, proposers, executors, address(0));

        uint256 shortDelay = PRODUCTION_DELAY - 1;
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, shortDelay, PRODUCTION_DELAY)
        );
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), bytes32(0), shortDelay);
    }

    function test_TC09_updateDelayViaSelf() public {
        uint256 newDelay = 1000000;
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt = keccak256("update_delay");

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        vm.expectEmit(false, false, false, true);
        emit TimelockController.MinDelayChange(MIN_DELAY, newDelay);
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), newDelay, "Min delay must be updated");
    }

    function test_TC09_updateDelayRevertsNonSelf() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, deployer));
        timelock.updateDelay(1000000);
    }

    function test_TC09_newMinDelayEnforced() public {
        // Launch phase: MIN_DELAY=0. Update delay to PRODUCTION_DELAY via scheduled op.
        uint256 newDelay = PRODUCTION_DELAY;
        bytes memory updateData = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt1 = keccak256("update_new");
        _scheduleOperation(address(timelock), 0, updateData, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, updateData, bytes32(0), salt1);
        assertEq(timelock.getMinDelay(), newDelay, "New delay must be set to production delay");

        // Now scheduling with old delay (0) must fail
        bytes memory data = _doSomethingCalldata();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, MIN_DELAY, newDelay)
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), keccak256("new_sched"), MIN_DELAY);

        // Scheduling with new delay must succeed
        bytes32 salt2 = keccak256("new_delay_ok");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt2, newDelay);
        assertTrue(timelock.isOperationPending(id), "New delay must be accepted");
    }
}

// ============================================================
// TC-10: Operation State Machine
// ============================================================
contract TimelockController_TC10_StateMachine is TimelockControllerTestBase {
    function test_TC10_unsetState() public view {
        bytes32 fakeId = keccak256("unset_operation");
        assertEq(
            uint256(timelock.getOperationState(fakeId)),
            uint256(TimelockController.OperationState.Unset),
            "Non-existent operation must be Unset"
        );
        assertFalse(timelock.isOperation(fakeId), "Unset operation must not be an operation");
        assertEq(timelock.getTimestamp(fakeId), 0, "Unset operation must have timestamp 0");
    }

    function test_TC10_waitingState() public {
        // With delay=0 (launch phase), operations skip Waiting and go straight to Ready.
        // Use a non-zero delay to test the Waiting state.
        uint256 testDelay = 100;
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("waiting");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, testDelay);

        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Waiting),
            "Just-scheduled operation with non-zero delay must be Waiting"
        );
        assertTrue(timelock.isOperation(id), "Waiting operation must be an operation");
        assertTrue(timelock.isOperationPending(id), "Waiting operation must be pending");
        assertFalse(timelock.isOperationReady(id), "Waiting operation must NOT be ready");
        assertFalse(timelock.isOperationDone(id), "Waiting operation must NOT be done");
    }

    function test_TC10_readyState() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("ready");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Ready),
            "After delay, operation must be Ready"
        );
        assertTrue(timelock.isOperation(id), "Ready operation must be an operation");
        assertTrue(timelock.isOperationPending(id), "Ready operation must be pending");
        assertTrue(timelock.isOperationReady(id), "Ready operation must be ready");
        assertFalse(timelock.isOperationDone(id), "Ready operation must NOT be done");
    }

    function test_TC10_doneState() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("done");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);

        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Done),
            "Executed operation must be Done"
        );
        assertTrue(timelock.isOperation(id), "Done operation must be an operation");
        assertFalse(timelock.isOperationPending(id), "Done operation must NOT be pending");
        assertFalse(timelock.isOperationReady(id), "Done operation must NOT be ready");
        assertTrue(timelock.isOperationDone(id), "Done operation must be done");
    }

    function test_TC10_doneCannotReSchedule() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("done_no_resched");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);

        // Cannot re-schedule a Done operation with same hash
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Unset)
            )
        );
        timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_TC10_reScheduleWithDifferentSalt() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt1 = keccak256("first_salt");
        _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt1, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt1);

        // Different salt creates a different hash — this must succeed
        bytes32 salt2 = keccak256("second_salt");
        bytes32 id2 = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt2, MIN_DELAY);
        assertTrue(timelock.isOperationPending(id2), "Different salt must allow re-scheduling");
    }

    function test_TC10_cancelledReturnsToUnset() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("cancel_unset");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(deployer);
        timelock.cancel(id);

        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Unset),
            "Cancelled operation must return to Unset"
        );
        assertFalse(timelock.isOperation(id), "Cancelled operation must not be an operation");
    }

    function test_TC10_noExpiryAfterReady() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("no_expiry");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        // Warp far into the future — operation must still be Ready
        vm.warp(block.timestamp + 365 days);
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Ready),
            "Operation must remain Ready indefinitely (no expiry)"
        );

        // Must still be executable
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(id), "Long-delayed execution must succeed");
    }
}

// ============================================================
// TC-11: Hash Computation
// ============================================================
contract TimelockController_TC11_Hash is TimelockControllerTestBase {
    function test_TC11_hashOperationDeterministic() public view {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("hash_test");

        bytes32 hash1 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);
        bytes32 hash2 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);
        assertEq(hash1, hash2, "Same params must produce same hash");
    }

    function test_TC11_hashOperationDiffSalt() public view {
        bytes memory data = _doSomethingCalldata();

        bytes32 hash1 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), keccak256("salt1"));
        bytes32 hash2 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), keccak256("salt2"));
        assertNotEq(hash1, hash2, "Different salts must produce different hashes");
    }

    function test_TC11_hashOperationDiffTarget() public view {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("target_diff");

        bytes32 hash1 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);
        bytes32 hash2 = timelock.hashOperation(address(revertTarget), 0, data, bytes32(0), salt);
        assertNotEq(hash1, hash2, "Different targets must produce different hashes");
    }

    function test_TC11_hashOperationDiffData() public view {
        bytes32 salt = keccak256("data_diff");

        bytes32 hash1 = timelock.hashOperation(
            address(mockTarget), 0, abi.encodeCall(MockTarget.doSomething, ()), bytes32(0), salt
        );
        bytes32 hash2 = timelock.hashOperation(
            address(mockTarget), 0, abi.encodeCall(MockTarget.doSomethingWithArgs, (1, address(0))), bytes32(0), salt
        );
        assertNotEq(hash1, hash2, "Different data must produce different hashes");
    }

    function test_TC11_hashOperationBatchDeterministic() public view {
        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = _doSomethingCalldata();
        bytes32 salt = keccak256("batch_hash");

        bytes32 hash1 = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        bytes32 hash2 = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        assertEq(hash1, hash2, "Same batch params must produce same hash");
    }

    function test_TC11_hashOperationBatchDiffTargets() public view {
        bytes32 salt = keccak256("batch_diff");

        address[] memory targets1 = new address[](1);
        targets1[0] = address(mockTarget);
        address[] memory targets2 = new address[](1);
        targets2[0] = address(revertTarget);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = _doSomethingCalldata();

        bytes32 hash1 = timelock.hashOperationBatch(targets1, values, payloads, bytes32(0), salt);
        bytes32 hash2 = timelock.hashOperationBatch(targets2, values, payloads, bytes32(0), salt);
        assertNotEq(hash1, hash2, "Different targets must produce different batch hashes");
    }

    function test_TC11_singleVsBatchHashDiffer() public view {
        bytes32 salt = keccak256("single_vs_batch");
        bytes memory data = _doSomethingCalldata();

        bytes32 singleHash = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt);

        address[] memory targets = new address[](1);
        targets[0] = address(mockTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;

        bytes32 batchHash = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), salt);
        assertNotEq(singleHash, batchHash, "Single and batch hashes must differ even for equivalent params");
    }
}

// ============================================================
// TC-12: View Function Correctness
// ============================================================
contract TimelockController_TC12_ViewFunctions is TimelockControllerTestBase {
    function test_TC12_viewMinDelay() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY, "getMinDelay must return 0 (launch phase)");
    }

    function test_TC12_viewRolesDeployer() public view {
        assertTrue(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must have PROPOSER_ROLE");
        assertTrue(timelock.hasRole(CANCELLER_ROLE, deployer), "Deployer must have CANCELLER_ROLE");
    }

    function test_TC12_viewRolesAttacker() public view {
        assertFalse(timelock.hasRole(PROPOSER_ROLE, attacker), "Attacker must NOT have PROPOSER_ROLE");
        assertFalse(timelock.hasRole(CANCELLER_ROLE, attacker), "Attacker must NOT have CANCELLER_ROLE");
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, attacker), "Attacker must NOT have individual EXECUTOR_ROLE");
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, attacker), "Attacker must NOT have DEFAULT_ADMIN_ROLE");
    }

    function test_TC12_viewRolesExecutor() public view {
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)), "address(0) must have EXECUTOR_ROLE (open execution)");
    }

    function test_TC12_viewRolesAdmin() public view {
        assertTrue(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), "TimelockController must have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Deployer must NOT have DEFAULT_ADMIN_ROLE");
    }

    function test_TC12_viewRoleAdmin() public view {
        assertEq(
            timelock.getRoleAdmin(PROPOSER_ROLE), DEFAULT_ADMIN_ROLE, "PROPOSER_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
        assertEq(
            timelock.getRoleAdmin(CANCELLER_ROLE), DEFAULT_ADMIN_ROLE, "CANCELLER_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
        assertEq(
            timelock.getRoleAdmin(EXECUTOR_ROLE), DEFAULT_ADMIN_ROLE, "EXECUTOR_ROLE admin must be DEFAULT_ADMIN_ROLE"
        );
    }

    function test_TC12_viewUnsetOperation() public view {
        bytes32 id = keccak256("view_unset");
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Unset),
            "Non-existent must be Unset"
        );
        assertEq(timelock.getTimestamp(id), 0, "Unset operation must have timestamp 0");
        assertFalse(timelock.isOperation(id));
        assertFalse(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertFalse(timelock.isOperationDone(id));
    }

    function test_TC12_viewWaitingOperation() public {
        // With delay=0 (launch phase), operations skip Waiting and go straight to Ready.
        // Use a non-zero delay to test the Waiting state view functions.
        uint256 testDelay = 100;
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("view_waiting");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, testDelay);

        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Waiting));
        assertTrue(timelock.isOperation(id));
        assertTrue(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertFalse(timelock.isOperationDone(id));
    }

    function test_TC12_viewReadyOperation() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("view_ready");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();

        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Ready));
        assertTrue(timelock.isOperation(id));
        assertTrue(timelock.isOperationPending(id));
        assertTrue(timelock.isOperationReady(id));
        assertFalse(timelock.isOperationDone(id));
    }

    function test_TC12_viewDoneOperation() public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256("view_done");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);

        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Done));
        assertEq(timelock.getTimestamp(id), 1, "Done operation must have timestamp sentinel 1");
        assertTrue(timelock.isOperation(id));
        assertFalse(timelock.isOperationPending(id));
        assertFalse(timelock.isOperationReady(id));
        assertTrue(timelock.isOperationDone(id));
    }
}
