// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/GuardianModule.sol";
import "../src/interfaces/IAllowlist.sol";
import "./mocks/MockAllowlist.sol";

contract GateGovernorForGuardian {
    address public guardianModule;

    function setGuardianModule(address guardianModule_) external {
        guardianModule = guardianModule_;
    }
}

contract GatePausableForGuardian {
    bool public paused;

    function pause() external {
        paused = true;
    }
}

contract GateAllowlistCapsForGuardian {
    address public revoked;
    uint32 public approvalsPerDayCap;

    function revoke(address account) external {
        revoked = account;
    }

    function shrinkApprovalsPerDayCap(uint32 newCap) external {
        approvalsPerDayCap = newCap;
    }
}

contract GuardianModuleGateTest is Test {
    GuardianModule internal guardianModule;
    GateGovernorForGuardian internal governor;
    GatePausableForGuardian internal pausableTarget;
    GateAllowlistCapsForGuardian internal allowlistCapsTarget;
    MockAllowlist internal allowlist;

    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal unverified = makeAddr("unverified");

    function setUp() public {
        governor = new GateGovernorForGuardian();

        address[] memory initialGuardians = new address[](1);
        uint256[] memory permissions = new uint256[](1);
        initialGuardians[0] = guardian;
        permissions[0] = 1 << 0;

        GuardianModule implementation = new GuardianModule();
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), timelock, initialGuardians, permissions));
        guardianModule = GuardianModule(address(new ERC1967Proxy(address(implementation), initData)));
        governor.setGuardianModule(address(guardianModule));

        allowlist = new MockAllowlist();
        allowlist.setAllAllowed(true);
        vm.prank(timelock);
        guardianModule.setAllowlist(address(allowlist));

        pausableTarget = new GatePausableForGuardian();
        vm.prank(timelock);
        guardianModule.setPausableTarget(address(pausableTarget), true);

        allowlistCapsTarget = new GateAllowlistCapsForGuardian();
        vm.prank(timelock);
        guardianModule.setPausableTarget(address(allowlistCapsTarget), true);
    }

    function test_gate_unverifiedGuardianPauseRevertsCallerNotAllowed() public {
        allowlist.setAllowed(guardian, false);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, guardian));
        guardianModule.guardianPause(address(pausableTarget));

        assertFalse(pausableTarget.paused(), "the pause body must not run for a denied caller");
    }

    function test_gate_deniedCallerVerdictPrecedesGuardianChecks() public {
        allowlist.setAllowed(unverified, false);

        vm.prank(unverified);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, unverified));
        guardianModule.guardianPause(address(pausableTarget));
    }

    function test_gate_allowedGuardianPauseSucceeds() public {
        allowlist.setAllAllowed(true);

        vm.prank(guardian);
        guardianModule.guardianPause(address(pausableTarget));

        assertTrue(pausableTarget.paused(), "an allowed guardian must pause a whitelisted target");
    }

    function test_extras_unverifiedGuardianSubjectRefused() public {
        allowlist.setAllowed(unverified, false);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, unverified));
        guardianModule.setGuardianPermissions(unverified, 1 << 0);
    }

    function test_extras_unverifiedSuccessorRefused() public {
        bytes32 custodySlot = guardianModule.SLOT_CUSTODY_EXECUTOR();
        allowlist.setAllowed(unverified, false);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(IAllowlist.CallerNotAllowed.selector, unverified));
        guardianModule.setPreCommittedSuccessor(custodySlot, guardian, unverified);
    }

    function test_extras_emergencyAllowlistSelectorsAreTyped() public {
        address victim = makeAddr("victim");
        uint256 emergencyPermission = guardianModule.PERMISSION_CAN_EXECUTE_EMERGENCY();

        vm.prank(timelock);
        guardianModule.setGuardianPermissions(guardian, emergencyPermission);

        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](2);
        targets[0] = address(allowlistCapsTarget);
        targets[1] = address(allowlistCapsTarget);
        calldatas[0] = abi.encodeWithSignature("revoke(address)", victim);
        calldatas[1] = abi.encodeWithSignature("shrinkApprovalsPerDayCap(uint32)", uint32(7));

        vm.prank(guardian);
        guardianModule.guardianExecuteEmergency(targets, values, calldatas);

        assertEq(allowlistCapsTarget.revoked(), victim, "revoke(address) must run through the typed path");
        assertEq(allowlistCapsTarget.approvalsPerDayCap(), 7, "shrinkApprovalsPerDayCap(uint32) must run typed");
    }

    function test_extras_emergencyOutOfRangeUint32Reverts() public {
        uint256 emergencyPermission = guardianModule.PERMISSION_CAN_EXECUTE_EMERGENCY();

        vm.prank(timelock);
        guardianModule.setGuardianPermissions(guardian, emergencyPermission);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(allowlistCapsTarget);
        calldatas[0] = abi.encodeWithSignature("shrinkApprovalsPerDayCap(uint32)", uint256(1) << 32);

        vm.prank(guardian);
        vm.expectRevert();
        guardianModule.guardianExecuteEmergency(targets, values, calldatas);
    }
}
