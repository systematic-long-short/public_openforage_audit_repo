// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";
import "./helpers/MockPausable.sol";

// ============================================================
// OF-M01: Guardian Target Whitelist Tests
// Verifies that guardianPause and guardianExecuteEmergency
// enforce a whitelist of approved pausable targets.
// ============================================================
contract ForageGovernor_OFM01_GuardianWhitelist is ForageGovernorTestBase {
    MockPausable public whitelistedTarget;
    MockPausable public nonWhitelistedTarget;
    address public pauseEmergencyGuardian;

    function setUp() public override {
        super.setUp();

        // Deploy two MockPausable targets — one to whitelist, one not
        whitelistedTarget = new MockPausable(address(timelock), address(governor));
        whitelistedTarget.setGuardianModule(address(guardianModuleContract));
        nonWhitelistedTarget = new MockPausable(address(timelock), address(governor));
        nonWhitelistedTarget.setGuardianModule(address(guardianModuleContract));

        // Whitelist only the first target via timelock (owner)
        // setPausableTarget is now on GuardianModule, gated by timelock
        _timelockExec(
            address(guardianModuleContract),
            abi.encodeWithSignature("setPausableTarget(address,bool)", address(whitelistedTarget), true)
        );

        pauseEmergencyGuardian = makeAddr("pauseEmergencyGuardian");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(pauseEmergencyGuardian, 5);
    }

    // ── Helper: Execute a call through timelock ──
    function _timelockExec(address target, bytes memory data) internal {
        bytes32 salt = keccak256(data);
        vm.prank(address(governor));
        timelock.schedule(target, 0, data, bytes32(0), salt, TIMELOCK_MIN_DELAY);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    // ── OF-M01-T1: guardianPause reverts on non-whitelisted target ──
    function test_OFM01_T1_pauseNonWhitelistedReverts() public {
        vm.prank(guardian2); // guardian2 has PAUSE permission
        vm.expectRevert(
            abi.encodeWithSelector(GuardianModule.TargetNotWhitelisted.selector, address(nonWhitelistedTarget))
        );
        guardianModuleContract.guardianPause(address(nonWhitelistedTarget));
    }

    // ── OF-M01-T2: guardianPause succeeds on whitelisted target ──
    function test_OFM01_T2_pauseWhitelistedSucceeds() public {
        vm.prank(guardian2); // guardian2 has PAUSE permission
        guardianModuleContract.guardianPause(address(whitelistedTarget));
        assertTrue(whitelistedTarget.paused(), "Target should be paused");
    }

    // ── OF-M01-T3: guardianExecuteEmergency reverts when any target is not whitelisted ──
    function test_OFM01_T3_emergencyNonWhitelistedReverts() public {
        address[] memory targets = new address[](2);
        targets[0] = address(whitelistedTarget);
        targets[1] = address(nonWhitelistedTarget); // not whitelisted

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("pause()");
        calldatas[1] = abi.encodeWithSignature("pause()");

        vm.prank(pauseEmergencyGuardian); // emergency pause path requires PAUSE + EMERGENCY
        vm.expectRevert(
            abi.encodeWithSelector(GuardianModule.TargetNotWhitelisted.selector, address(nonWhitelistedTarget))
        );
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    // ── OF-M01-T4: guardianExecuteEmergency succeeds when all targets are whitelisted ──
    function test_OFM01_T4_emergencyAllWhitelistedSucceeds() public {
        // Whitelist a second target
        MockPausable anotherTarget = new MockPausable(address(timelock), address(governor));
        anotherTarget.setGuardianModule(address(guardianModuleContract));
        _timelockExec(
            address(guardianModuleContract),
            abi.encodeWithSignature("setPausableTarget(address,bool)", address(anotherTarget), true)
        );

        address[] memory targets = new address[](2);
        targets[0] = address(whitelistedTarget);
        targets[1] = address(anotherTarget);

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("pause()");
        calldatas[1] = abi.encodeWithSignature("pause()");

        vm.prank(pauseEmergencyGuardian);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        assertTrue(whitelistedTarget.paused(), "First target should be paused");
        assertTrue(anotherTarget.paused(), "Second target should be paused");
    }

    // ── OF-M01-T5: setPausableTarget add/remove, only callable by executor (timelock) ──
    function test_OFM01_T5_setPausableTargetOnlyOwner() public {
        // Non-owner cannot set pausable target
        vm.prank(attacker);
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        guardianModuleContract.setPausableTarget(address(nonWhitelistedTarget), true);

        // Guardian cannot set pausable target
        vm.prank(guardian1);
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        guardianModuleContract.setPausableTarget(address(nonWhitelistedTarget), true);

        // Owner (timelock) can add a target
        _timelockExec(
            address(guardianModuleContract),
            abi.encodeWithSignature("setPausableTarget(address,bool)", address(nonWhitelistedTarget), true)
        );
        assertTrue(
            guardianModuleContract.isPausableTarget(address(nonWhitelistedTarget)), "Should be whitelisted after add"
        );

        // Owner (timelock) can remove a target
        _timelockExec(
            address(guardianModuleContract),
            abi.encodeWithSignature("setPausableTarget(address,bool)", address(nonWhitelistedTarget), false)
        );
        assertFalse(
            guardianModuleContract.isPausableTarget(address(nonWhitelistedTarget)),
            "Should not be whitelisted after remove"
        );
    }

    // ── OF-M01-T6: isPausableTarget returns correct state ──
    function test_OFM01_T6_isPausableTargetState() public view {
        assertTrue(
            guardianModuleContract.isPausableTarget(address(whitelistedTarget)), "Whitelisted target should return true"
        );
        assertFalse(
            guardianModuleContract.isPausableTarget(address(nonWhitelistedTarget)),
            "Non-whitelisted should return false"
        );
        assertFalse(guardianModuleContract.isPausableTarget(address(0)), "Zero address should return false");
    }

    // ── OF-M01-T7: guardianExecuteEmergency with unpause() is rejected before whitelist ──
    function test_OFM01_T7_emergencyUnpauseNonWhitelistedReverts() public {
        // Pause the whitelisted target first (valid)
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(whitelistedTarget));
        assertTrue(whitelistedTarget.paused(), "Should be paused");

        // Try to unpause a non-whitelisted target — should be rejected as non-tightening.
        address[] memory targets = new address[](1);
        targets[0] = address(nonWhitelistedTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("unpause()");

        vm.prank(pauseEmergencyGuardian);
        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    // ── OF-M01-T8: guardianExecuteEmergency unpause is rejected on whitelisted targets ──
    function test_OFM01_T8_emergencyUnpauseWhitelistedReverts() public {
        // Pause the whitelisted target first
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(whitelistedTarget));
        assertTrue(whitelistedTarget.paused(), "Should be paused");

        // Unpause via emergency on whitelisted target is not a guardian power.
        address[] memory targets = new address[](1);
        targets[0] = address(whitelistedTarget);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("unpause()");

        vm.prank(pauseEmergencyGuardian);
        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        assertTrue(whitelistedTarget.paused(), "guardian emergency must not unpause");
    }

    // ── OF-M01-T9: setPausableTarget reverts on address(0) with ZeroAddress error ──
    function test_OFM01_T9_setPausableTargetZeroAddressReverts() public {
        // Call setPausableTarget directly via vm.prank as the executor (timelock)
        // to verify the specific ZeroAddress() guard without timelock wrapping
        vm.prank(address(timelock));
        vm.expectRevert(GuardianModule.ZeroAddress.selector);
        guardianModuleContract.setPausableTarget(address(0), true);
    }
}
