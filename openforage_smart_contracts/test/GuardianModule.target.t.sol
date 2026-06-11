// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/GuardianModule.sol";
import "../src/hyperliquid/HLTradingBridge.sol";
import "./mocks/MockUSDC.sol";

contract TargetPausableForGuardian {
    bool public paused;

    function pause() external {
        paused = true;
    }
}

contract TargetGovernorForGuardian {
    address public guardianModule;

    function setGuardianModule(address guardianModule_) external {
        guardianModule = guardianModule_;
    }
}

contract GuardianModule_TargetRecovery is Test {
    GuardianModule internal guardianModule;
    HLTradingBridge internal bridge;
    MockUSDC internal usdc;
    TargetPausableForGuardian internal pausableTarget;
    TargetGovernorForGuardian internal governor;

    address internal timelock = makeAddr("timelock");
    address internal coldCustody = makeAddr("cold-custody");
    address internal custodySuccessor = makeAddr("custody-successor");
    address internal votingDelegation = makeAddr("voting-delegation");
    address internal delegationSuccessor = makeAddr("delegation-successor");
    address internal largeDelegator = makeAddr("large-delegator");
    address internal governorSlot = makeAddr("governor-slot");
    address internal uncommittedTarget = makeAddr("uncommitted-target");
    address internal keeper = makeAddr("keeper");
    address internal executor = makeAddr("executor");
    address internal riskusdVault = makeAddr("riskusd-vault");
    address internal usdcTreasury = makeAddr("usdc-treasury");
    address internal custodianRegistry = makeAddr("custodian-registry");
    address[7] internal guardians;

    function setUp() public {
        governor = new TargetGovernorForGuardian();

        address[] memory initialGuardians = new address[](7);
        uint256[] memory permissions = new uint256[](7);
        for (uint256 i; i < 7; ++i) {
            guardians[i] = makeAddr(string.concat("guardian-", vm.toString(i)));
            initialGuardians[i] = guardians[i];
            permissions[i] = 1 << 0;
        }

        GuardianModule implementation = new GuardianModule();
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (address(governor), timelock, initialGuardians, permissions));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        guardianModule = GuardianModule(address(proxy));
        governor.setGuardianModule(address(guardianModule));

        pausableTarget = new TargetPausableForGuardian();

        usdc = new MockUSDC();
        HLTradingBridge bridgeImplementation = new HLTradingBridge();
        bytes memory bridgeInit = abi.encodeCall(
            HLTradingBridge.initialize,
            (
                address(usdc),
                riskusdVault,
                usdcTreasury,
                custodianRegistry,
                timelock,
                keeper,
                executor,
                address(guardianModule),
                HLTradingBridge.RouteConfig({
                    coldAccount: makeAddr("cold-account"),
                    hyperliquidSourceAccount: bytes32(uint256(uint160(makeAddr("hyperliquid-source")))),
                    withdrawalChainSelector: uint64(421_614)
                })
            )
        );
        bridge = HLTradingBridge(address(new ERC1967Proxy(address(bridgeImplementation), bridgeInit)));
    }

    function test_TSCGB_A20_oneOfSevenPausesAndGuardianPowersAreTightenOnly() public {
        vm.prank(timelock);
        guardianModule.setPausableTarget(address(pausableTarget), true);

        vm.prank(guardians[2]);
        guardianModule.guardianPause(address(pausableTarget));
        assertTrue(pausableTarget.paused(), "any one guardian must pause a whitelisted target");

        vm.prank(guardians[2]);
        vm.expectRevert(GuardianModule.GuardianCannotLoosen.selector);
        guardianModule.guardianLoosenCap(address(pausableTarget), bytes4(keccak256("setCap(uint256)")), 10_000);

        vm.prank(guardians[2]);
        vm.expectRevert(GuardianModule.GuardianCannotMoveFunds.selector);
        guardianModule.guardianMoveFunds(address(pausableTarget), makeAddr("recipient"), 1);
    }

    function test_TSCGB_A21_successorRegistryIsGovernanceOnlyAndCoversCustodySlot() public {
        bytes32 custodySlot = guardianModule.SLOT_CUSTODY_EXECUTOR();

        vm.prank(guardians[0]);
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        guardianModule.setPreCommittedSuccessor(custodySlot, coldCustody, custodySuccessor);

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(custodySlot, coldCustody, custodySuccessor);

        assertEq(
            guardianModule.preCommittedSuccessor(custodySlot, coldCustody),
            custodySuccessor,
            "governance-set custody successor missing"
        );
    }

    function test_TSCGB_A20_guardianEmergencyBridgePortMatchesTargetTightenOnlySelectors() public {
        vm.startPrank(timelock);
        guardianModule.setGuardianPermissions(guardians[0], guardianModule.PERMISSION_CAN_EXECUTE_EMERGENCY());
        guardianModule.setPausableTarget(address(bridge), true);
        vm.stopPrank();

        address[] memory targets = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory calldatas = new bytes[](4);
        for (uint256 i; i < targets.length; ++i) {
            targets[i] = address(bridge);
        }
        calldatas[0] = abi.encodeWithSignature("freezeAttestations()");
        calldatas[1] = abi.encodeWithSignature("shrinkPerBlockDeployCap(uint256)", 500_000e6);
        calldatas[2] = abi.encodeWithSignature("shrinkPerDayDeployCap(uint256)", 4_000_000e6);
        calldatas[3] = abi.encodeWithSignature("tightenReturnCapitalCaps(uint16,uint16)", uint16(500), uint16(750));

        vm.prank(guardians[0]);
        guardianModule.guardianExecuteEmergency(targets, values, calldatas);

        assertTrue(bridge.directionalFreeze(), "guardian module must freeze bridge attestations");
        assertEq(bridge.perBlockDeployCap(), 500_000e6, "guardian module must shrink per-block bridge cap");
        assertEq(bridge.perDayDeployCap(), 4_000_000e6, "guardian module must shrink per-day bridge cap");
        assertEq(bridge.returnPerCallCapBps(), 500, "guardian module must tighten per-call return cap");
        assertEq(bridge.returnPerDayCapBps(), 750, "guardian module must tighten per-day return cap");

        address[] memory loosenTargets = new address[](1);
        uint256[] memory loosenValues = new uint256[](1);
        bytes[] memory loosenCalldatas = new bytes[](1);
        loosenTargets[0] = address(bridge);
        loosenCalldatas[0] = abi.encodeWithSignature("shrinkPerBlockDeployCap(uint256)", 500_001e6);

        vm.prank(guardians[0]);
        guardianModule.guardianExecuteEmergency(loosenTargets, loosenValues, loosenCalldatas);
        assertEq(bridge.perBlockDeployCap(), 500_000e6, "guardian module must not loosen bridge caps");
    }

    function test_TSCGB_A20_removedProtocolTreasuryEmergencySelectorIsRejected() public {
        vm.startPrank(timelock);
        guardianModule.setGuardianPermissions(guardians[0], guardianModule.PERMISSION_CAN_EXECUTE_EMERGENCY());
        guardianModule.setPausableTarget(address(bridge), true);
        vm.stopPrank();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(bridge);
        calldatas[0] = abi.encodeWithSignature("shrinkLossRateCapBps(uint256)", 1_000);

        vm.prank(guardians[0]);
        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        guardianModule.guardianExecuteEmergency(targets, values, calldatas);
    }

    function test_TSCGB_A20_guardianEmergencyUnpauseIsRejected() public {
        vm.startPrank(timelock);
        guardianModule.setGuardianPermissions(guardians[0], guardianModule.PERMISSION_CAN_EXECUTE_EMERGENCY());
        guardianModule.setPausableTarget(address(bridge), true);
        vm.stopPrank();

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(bridge);
        calldatas[0] = abi.encodeWithSignature("unpause()");

        vm.prank(guardians[0]);
        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        guardianModule.guardianExecuteEmergency(targets, values, calldatas);
    }

    function test_TSCGB_A21_successorRegistryCoversAllRequiredSlotClasses() public {
        bytes32[4] memory slots = [
            guardianModule.SLOT_GUARDIAN_SEAT(),
            guardianModule.SLOT_VOTING_DELEGATION(),
            guardianModule.SLOT_LARGE_DELEGATOR(),
            guardianModule.SLOT_GOVERNOR()
        ];
        address[4] memory current = [guardians[0], votingDelegation, largeDelegator, governorSlot];
        address[4] memory successors = [
            makeAddr("guardian-successor"),
            delegationSuccessor,
            makeAddr("large-delegator-successor"),
            makeAddr("governor-successor")
        ];

        vm.startPrank(timelock);
        for (uint256 i; i < slots.length; ++i) {
            guardianModule.setPreCommittedSuccessor(slots[i], current[i], successors[i]);
        }
        vm.stopPrank();

        for (uint256 i; i < slots.length; ++i) {
            assertEq(
                guardianModule.preCommittedSuccessor(slots[i], current[i]),
                successors[i],
                "successor slot class missing"
            );
        }
    }

    function test_TSCGB_A22_fourOfSevenAcceleratesOnlyToPrecommittedSuccessorWithTenMinuteFloor() public {
        bytes32 custodySlot = guardianModule.SLOT_CUSTODY_EXECUTOR();

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(custodySlot, coldCustody, custodySuccessor);

        vm.prank(guardians[0]);
        vm.expectRevert(GuardianModule.SuccessorNotPreCommitted.selector);
        guardianModule.proposeAcceleratedRotation(custodySlot, coldCustody, uncommittedTarget);

        vm.prank(guardians[0]);
        bytes32 operationId = guardianModule.proposeAcceleratedRotation(custodySlot, coldCustody, custodySuccessor);

        for (uint256 i; i < 3; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(operationId);
        }
        assertFalse(guardianModule.acceleratedRotationReady(operationId), "3 of 7 must not reach quorum");

        vm.prank(guardians[3]);
        guardianModule.approveAcceleratedRotation(operationId);

        assertTrue(guardianModule.acceleratedRotationReady(operationId), "4 of 7 must reach quorum");
        assertGe(
            guardianModule.acceleratedRotationReadyAt(operationId),
            block.timestamp + 10 minutes,
            "accelerated rotation floor must be at least 10 minutes"
        );
    }

    function test_TSCGB_A22_routineCustodyRotationUsesVoteAndEightDayTimelock() public {
        bytes32 custodySlot = guardianModule.SLOT_CUSTODY_EXECUTOR();

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(custodySlot, coldCustody, custodySuccessor);

        vm.prank(address(governor));
        bytes32 operationId = guardianModule.proposeRoutineRotation(custodySlot, coldCustody, custodySuccessor);

        vm.prank(timelock);
        vm.expectRevert(GuardianModule.FinalizeDelayNotElapsed.selector);
        guardianModule.finalizeRoutineRotation(operationId);

        vm.warp(block.timestamp + 8 days);

        vm.prank(timelock);
        guardianModule.finalizeRoutineRotation(operationId);

        assertEq(
            guardianModule.activeSlotHolder(custodySlot),
            custodySuccessor,
            "routine custody rotation must finalize only after vote/timelock"
        );
    }

    function test_TSCGB_A23_fourOfSevenRotatesGuardianSeatToPrecommittedSuccessor() public {
        bytes32 guardianSeatSlot = guardianModule.SLOT_GUARDIAN_SEAT();
        address replacement = makeAddr("guardian-seat-successor");

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(guardianSeatSlot, guardians[6], replacement);

        vm.prank(guardians[0]);
        bytes32 operationId = guardianModule.proposeAcceleratedRotation(guardianSeatSlot, guardians[6], replacement);
        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(operationId);
        }

        vm.warp(guardianModule.acceleratedRotationReadyAt(operationId));
        guardianModule.executeAcceleratedRotation(operationId);

        assertEq(guardianModule.guardianAt(6), replacement, "guardian seat must rotate to precommitted successor");
        assertEq(guardianModule.guardianCount(), 7, "rotation must preserve seven guardian seats");
    }

    function test_TSCGB_A23_fourOfSevenRotatesCapturedVotingDelegationToPrecommittedSuccessor() public {
        bytes32 delegationSlot = guardianModule.SLOT_VOTING_DELEGATION();

        vm.prank(timelock);
        guardianModule.setPreCommittedSuccessor(delegationSlot, votingDelegation, delegationSuccessor);

        vm.prank(guardians[0]);
        bytes32 operationId =
            guardianModule.proposeAcceleratedRotation(delegationSlot, votingDelegation, delegationSuccessor);
        for (uint256 i; i < 4; ++i) {
            vm.prank(guardians[i]);
            guardianModule.approveAcceleratedRotation(operationId);
        }

        vm.warp(guardianModule.acceleratedRotationReadyAt(operationId));
        guardianModule.executeAcceleratedRotation(operationId);

        assertEq(
            guardianModule.activeSlotHolder(delegationSlot),
            delegationSuccessor,
            "captured voting delegation must rotate to precommitted successor"
        );
    }
}
