// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

// ============================================================
// TC-21: Emergency Bypass (Absence of)
// ============================================================
contract TimelockController_TC21_EmergencyBypass is TimelockControllerTestBase {
    function test_TC21_noEmergencyExecute() public {
        // There is no function on TimelockController that allows skipping the delay.
        // With delay=0 (launch phase), operations are immediately Ready and executable.
        // Use a non-zero delay to test that the delay cannot be bypassed.
        uint256 testDelay = 100;
        bytes memory data = _doSomethingCalldata();

        // Schedule an operation with non-zero delay
        bytes32 salt = keccak256("no_emergency");
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, testDelay);

        // Try to execute immediately (should fail — not Ready)
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                _encodeStateBitmap(TimelockController.OperationState.Ready)
            )
        );
        _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);

        // Operation is still Waiting — no emergency bypass exists
        assertEq(
            uint256(timelock.getOperationState(id)),
            uint256(TimelockController.OperationState.Waiting),
            "No emergency bypass: operation must remain Waiting"
        );
    }

    function test_TC21_scheduleAlwaysEnforcesMinDelay() public {
        // Launch phase: MIN_DELAY=0, so delay=0 is valid. Verify it is accepted.
        bytes memory data = _doSomethingCalldata();
        bytes32 salt0 = keccak256("delay_zero_launch");
        bytes32 id0 = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt0, 0);
        assertTrue(timelock.isOperationPending(id0), "delay=0 must be accepted in launch phase");

        // Deploy a production-configured timelock to test min delay enforcement
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        vm.prank(deployer);
        TimelockController prodTimelock = new TimelockController(PRODUCTION_DELAY, proposers, executors, address(0));

        // Even deployer cannot schedule with delay=0 on production timelock
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 0, PRODUCTION_DELAY)
        );
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), bytes32(0), 0);

        // Also try delay=1 (still below production minimum)
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 1, PRODUCTION_DELAY)
        );
        prodTimelock.schedule(address(mockTarget), 0, data, bytes32(0), keccak256("delay1"), 1);
    }

    function test_TC21_noZeroDelayOverride() public {
        // Verify that updateDelay cannot be called directly to set delay to 0
        // (must go through scheduled operation)
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, deployer));
        timelock.updateDelay(0);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, attacker));
        timelock.updateDelay(0);

        // Even if someone could call updateDelay, it would still need to go through scheduling
        // which is subject to the current delay
        assertEq(timelock.getMinDelay(), MIN_DELAY, "Min delay must remain unchanged");
    }

    function test_TC21_governorDirectPause() public {
        // Governor can directly pause MockPausable (emergency path)
        vm.prank(governor);
        mockPausable.pause();
        assertTrue(mockPausable.paused(), "Governor must be able to directly pause");
    }

    function test_TC21_governorDirectUnpause() public {
        // First pause
        vm.prank(governor);
        mockPausable.pause();

        // Governor can directly unpause
        vm.prank(governor);
        mockPausable.unpause();
        assertFalse(mockPausable.paused(), "Governor must be able to directly unpause");
    }

    function test_TC21_attackerCannotDirectPause() public {
        vm.prank(attacker);
        vm.expectRevert(MockPausable.Unauthorized.selector);
        mockPausable.pause();

        vm.prank(deployer);
        vm.expectRevert(MockPausable.Unauthorized.selector);
        mockPausable.pause();
    }

    function test_TC21_timelockCanPauseViaScheduled() public {
        // TimelockController (as owner) can also pause, but via scheduled operation
        bytes memory data = abi.encodeCall(MockPausable.pause, ());
        bytes32 salt = keccak256("timelock_pause");

        _scheduleOperation(address(mockPausable), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(mockPausable), 0, data, bytes32(0), salt);

        assertTrue(mockPausable.paused(), "Timelock must be able to pause via scheduled operation");
    }
}
