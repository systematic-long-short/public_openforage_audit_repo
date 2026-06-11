// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";

contract UnsafeUninitializedERC1967Proxy is ERC1967Proxy {
    constructor(address implementation) ERC1967Proxy(implementation, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

contract OctaneGovernanceGuardianRed is ForageGovernorTestBase {
    uint256 private constant OVERSIZED_ACTION_COUNT = 101;
    uint256 private constant STALE_PROPOSAL_AGE = 31 days;

    function test_CHAINV06_rejectsProposalWithTooManyActions() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _proposalBatch(OVERSIZED_ACTION_COUNT);

        vm.expectRevert();
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "CHAIN-V06 oversized proposal action bundle");
    }

    function test_CHAINV06_staleQueuedProposalStopsConsumingActiveSlot() public {
        vm.prank(address(timelock));
        governor.setMaxActiveProposals(1);

        address[] memory stuckTargets = new address[](1);
        stuckTargets[0] = address(revertTarget);
        uint256[] memory stuckValues = new uint256[](1);
        bytes[] memory stuckCalldatas = new bytes[](1);
        stuckCalldatas[0] = abi.encodeCall(RevertTarget.doSomething, ());
        string memory stuckDescription = "CHAIN-V06 queued proposal that never executes";
        bytes32 stuckDescriptionHash = keccak256(bytes(stuckDescription));

        vm.prank(proposer);
        uint256 stuckProposalId = governor.propose(stuckTargets, stuckValues, stuckCalldatas, stuckDescription);
        _passProposal(stuckProposalId);
        governor.queue(stuckTargets, stuckValues, stuckCalldatas, stuckDescriptionHash);

        vm.warp(block.timestamp + STALE_PROPOSAL_AGE);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposalParams();
        vm.prank(proposer);
        uint256 replacementProposalId =
            governor.propose(targets, values, calldatas, "CHAIN-V06 replacement after stale queued expiry");

        assertTrue(replacementProposalId != 0, "stale queued proposal must not indefinitely block governance");
    }

    function test_CHAINW05_rejectsUninitializedGuardianModule() public {
        GuardianModule uninitializedModule =
            GuardianModule(address(new UnsafeUninitializedERC1967Proxy(address(new GuardianModule()))));

        vm.expectRevert();
        vm.prank(address(timelock));
        governor.setGuardianModule(address(uninitializedModule));
    }

    function test_CHAINW05_rejectsGuardianModuleWithMismatchedTimelockBinding() public {
        GuardianModule attackerControlledModule = _deployGuardianModule(address(governor), attacker, attacker, 4);

        vm.expectRevert();
        vm.prank(address(timelock));
        governor.setGuardianModule(address(attackerControlledModule));
    }

    function test_CHAINW18_rejectsGuardianModuleStillBoundToPreviousTimelockAfterMigration() public {
        TimelockController replacementTimelock = _deployReplacementTimelock(1 days);
        ForageGovernor migratedGovernor = _deployGovernorWithTimelock(address(replacementTimelock));
        GuardianModule staleTimelockModule =
            _deployGuardianModule(address(migratedGovernor), address(timelock), guardian3, 2);

        vm.expectRevert();
        vm.prank(address(replacementTimelock));
        migratedGovernor.setGuardianModule(address(staleTimelockModule));
    }

    function test_CHAINW22_emergencyPauseRequiresPausePermissionToo() public {
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        vm.expectRevert();
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    function test_CHAINW28_guardianCancelDetectsDeepNestedSelfEntrenchment() public {
        bytes memory protectedCall = abi.encodeCall(GuardianModule.setGuardianPermissions, (guardian3, 0));
        (address nestedTarget, bytes memory nestedCalldata) =
            _wrapInGovernorRelays(address(guardianModuleContract), protectedCall, 9);

        address[] memory targets = new address[](1);
        targets[0] = nestedTarget;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = nestedCalldata;

        vm.prank(proposer);
        uint256 proposalId =
            governor.propose(targets, values, calldatas, "CHAIN-W28 deeply wrapped guardian self-entrenchment");

        vm.expectRevert(GuardianModule.SelfTargetingGuardianMutation.selector);
        vm.prank(guardian3);
        guardianModuleContract.guardianCancel(proposalId);
    }

    function _proposalBatch(uint256 count)
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](count);
        values = new uint256[](count);
        calldatas = new bytes[](count);
        for (uint256 i; i < count;) {
            targets[i] = address(governor);
            calldatas[i] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (DEFAULT_MAX_ACTIVE));
            unchecked {
                ++i;
            }
        }
    }

    function _deployGuardianModule(
        address moduleGovernor,
        address moduleTimelock,
        address guardian,
        uint256 permissions
    ) private returns (GuardianModule) {
        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        uint256[] memory permissionList = new uint256[](1);
        permissionList[0] = permissions;
        bytes memory initData =
            abi.encodeCall(GuardianModule.initialize, (moduleGovernor, moduleTimelock, guardians, permissionList));
        return GuardianModule(address(new ERC1967Proxy(address(new GuardianModule()), initData)));
    }

    function _deployReplacementTimelock(uint256 minDelay) private returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = address(governor);
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        return new TimelockController(minDelay, proposers, executors, address(0));
    }

    function _deployGovernorWithTimelock(address timelockController) private returns (ForageGovernor) {
        ForageGovernor impl = new ForageGovernor();
        bytes memory initData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                timelockController,
                DEFAULT_VOTING_DELAY,
                DEFAULT_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        return ForageGovernor(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function _wrapInGovernorRelays(address target, bytes memory data, uint256 depth)
        private
        view
        returns (address wrappedTarget, bytes memory wrappedData)
    {
        wrappedTarget = target;
        wrappedData = data;
        for (uint256 i; i < depth;) {
            wrappedData = abi.encodeCall(ForageGovernor.relay, (wrappedTarget, 0, wrappedData));
            wrappedTarget = address(governor);
            unchecked {
                ++i;
            }
        }
    }
}
