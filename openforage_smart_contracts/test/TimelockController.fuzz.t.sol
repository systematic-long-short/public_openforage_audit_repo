// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/TimelockControllerTestBase.sol";

// ============================================================
// TC-19: Fuzz Tests
// ============================================================
contract TimelockController_TC19_Fuzz is TimelockControllerTestBase {
    function testFuzz_scheduleDelayBoundary(uint256 delay) public {
        bytes memory data = _doSomethingCalldata();
        // Use a unique salt based on the fuzzed delay to avoid duplicate scheduling
        bytes32 salt = keccak256(abi.encodePacked("fuzz_delay", delay));

        if (delay < MIN_DELAY) {
            // Below minimum: must revert
            vm.prank(deployer);
            vm.expectRevert(
                abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, delay, MIN_DELAY)
            );
            timelock.schedule(address(mockTarget), 0, data, bytes32(0), salt, delay);
        } else {
            // At or above minimum: must succeed
            // Bound delay to avoid overflow in timestamp calculation
            delay = bound(delay, MIN_DELAY, type(uint256).max - block.timestamp);
            bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, delay);
            assertTrue(timelock.isOperationPending(id), "Valid delay must produce pending operation");
        }
    }

    function testFuzz_executionTiming(uint256 warpSeconds) public {
        bytes memory data = _doSomethingCalldata();
        bytes32 salt = keccak256(abi.encodePacked("fuzz_timing", warpSeconds));
        bytes32 id = _scheduleOperation(address(mockTarget), 0, data, bytes32(0), salt, MIN_DELAY);

        uint256 readyTimestamp = block.timestamp + MIN_DELAY;
        // Bound warp to reasonable range to avoid overflow
        warpSeconds = bound(warpSeconds, 0, 365 days);
        vm.warp(block.timestamp + warpSeconds);

        if (block.timestamp < readyTimestamp) {
            // Before ready: must revert
            vm.expectRevert(
                abi.encodeWithSelector(
                    TimelockController.TimelockUnexpectedOperationState.selector,
                    id,
                    _encodeStateBitmap(TimelockController.OperationState.Ready)
                )
            );
            _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
        } else {
            // At or after ready: must succeed
            _executeOperation(address(mockTarget), 0, data, bytes32(0), salt);
            assertTrue(timelock.isOperationDone(id), "Operation must be Done after execution");
        }
    }

    function testFuzz_updateDelay(uint256 newDelay) public {
        // R-03: updateDelay can set any uint256 value — only the scheduling
        // must go through the current minimum delay via a scheduled self-targeted operation
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (newDelay));
        bytes32 salt = keccak256(abi.encodePacked("fuzz_update", newDelay));

        _scheduleOperation(address(timelock), 0, data, bytes32(0), salt, MIN_DELAY);
        _warpPastDelay();
        _executeOperation(address(timelock), 0, data, bytes32(0), salt);

        assertEq(timelock.getMinDelay(), newDelay, "getMinDelay must return the new value");

        // Verify subsequent schedule enforces the new delay
        // Bound to reasonable range to avoid timestamp overflow in schedule()
        if (newDelay <= 365 days) {
            bytes memory data2 = abi.encodeCall(MockTarget.doSomething, ());
            bytes32 salt2 = keccak256(abi.encodePacked("post_update", newDelay));

            if (newDelay > 0) {
                // Scheduling with delay < newDelay must revert
                vm.prank(deployer);
                vm.expectRevert();
                timelock.schedule(address(mockTarget), 0, data2, bytes32(0), salt2, newDelay - 1);
            }

            // Scheduling with exact newDelay must succeed
            vm.prank(deployer);
            timelock.schedule(address(mockTarget), 0, data2, bytes32(0), salt2, newDelay);
        }
    }

    function testFuzz_saltUniqueness(bytes32 salt1, bytes32 salt2) public view {
        vm.assume(salt1 != salt2);

        bytes memory data = _doSomethingCalldata();
        bytes32 hash1 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt1);
        bytes32 hash2 = timelock.hashOperation(address(mockTarget), 0, data, bytes32(0), salt2);

        assertNotEq(hash1, hash2, "Different salts must produce different hashes");
    }
}
