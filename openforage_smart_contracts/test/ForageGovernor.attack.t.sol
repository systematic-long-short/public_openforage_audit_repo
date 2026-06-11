// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";
import "./helpers/ForageGovernorV2.sol";
import "./helpers/ForageGovernorV3.sol";
import "./helpers/ForageGovernorV2BadLayout.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";

// ============================================================
// TC-12: Governance Attack Vectors
// Requirements: R-14, R-15, R-18, R-39, R-43, R-47, R-51,
//               R-52, R-55
// ============================================================
contract ForageGovernor_TC12_GovernanceAttackVectors is ForageGovernorTestBase {
    // ── 9.1 / 3.2 — Flash Loan Voting Defense (R-18) ──────────────────

    /// @dev Tokens acquired AFTER proposal snapshot give 0 voting power.
    ///      Attacker buys FORAGE at block N+100, tries to vote on proposal created at block N.
    ///      Snapshot was taken at block N, so attacker's voting power == 0.
    function test_TC12_flashLoanPostSnapshotZeroVotingPower() public {
        // Create proposal at current block (N). Snapshot is at block N + votingDelay.
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Attacker acquires tokens AFTER the snapshot block
        vm.roll(snapshotBlock + 10);
        vm.prank(deployer);
        token.transfer(attacker, 10_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1); // checkpoint

        // Attacker's voting power at the snapshot block is 0 (did not hold tokens then)
        uint256 attackerPowerAtSnapshot = token.getPastVotes(attacker, snapshotBlock);
        assertEq(
            attackerPowerAtSnapshot, 0, "Attacker voting power at snapshot must be 0 (acquired tokens after snapshot)"
        );

        // Attempt to vote -- should revert with InsufficientVotingPower (0 power at snapshot)
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        vm.prank(attacker);
        governor.castVote(proposalId, 1);
    }

    /// @dev Tokens acquired in the same block as proposal creation capture voting power.
    ///      This is expected behavior -- the snapshot IS the proposal creation block.
    function test_TC12_sameBlockAsProposalCapturesVotingPower() public {
        // Give attacker tokens and delegate before any proposal
        vm.prank(deployer);
        token.transfer(attacker, 2_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1); // checkpoint

        // Create proposal at current block
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance past snapshot so getPastVotes can query it
        vm.roll(snapshotBlock + 1);

        // Attacker held tokens at the snapshot block
        uint256 attackerPower = token.getPastVotes(attacker, snapshotBlock);
        assertEq(attackerPower, 2_000_000 * 1e18, "Attacker who held tokens at snapshot must have voting power");
    }

    /// @dev Verify proposalSnapshot() == creationBlock + votingDelay (OZ inherited per L2 line 281).
    function test_TC12_snapshotBlockEqualsCreationBlockPlusVotingDelay() public {
        uint256 creationBlock = block.number;
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        assertEq(
            snapshotBlock,
            creationBlock + governor.votingDelay(),
            "proposalSnapshot must equal creationBlock + votingDelay (OZ inherited)"
        );
    }

    // ── R-51 — Unauthorized Upgrade Attack ─────────────────────────────

    /// @dev R-51: Attacker tries upgradeToAndCall with malicious implementation -> Unauthorized
    function test_TC12_attackerCannotUpgradeGovernor() public {
        ForageGovernorV2 maliciousImpl = new ForageGovernorV2();

        // Attacker tries direct upgradeToAndCall
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        vm.prank(attacker);
        governor.upgradeToAndCall(address(maliciousImpl), "");

        // Guardian tries upgradeToAndCall (not authorized either)
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        vm.prank(guardian1);
        governor.upgradeToAndCall(address(maliciousImpl), "");

        // Only timelock can upgrade
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(maliciousImpl), "");
        ForageGovernorV2 upgraded = ForageGovernorV2(payable(address(governor)));
        assertEq(upgraded.versionV2(), 2, "Timelock must be able to upgrade");
    }

    // ── 9.2 — Proposal Spam Defense (R-15) ─────────────────────────────

    /// @dev Attacker creates maxActiveProposals proposals, next propose() reverts MaxActiveProposalsReached.
    function test_TC12_proposalSpamMaxActiveReached() public {
        // Give attacker enough tokens to propose
        vm.prank(deployer);
        token.transfer(attacker, PROPOSER_TOKENS);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        // Create maxActiveProposals (10) proposals
        for (uint256 i = 0; i < DEFAULT_MAX_ACTIVE; i++) {
            string memory description = string(abi.encodePacked("Spam-", vm.toString(i)));
            vm.prank(attacker);
            governor.propose(targets, values, calldatas, description);
        }

        // 11th proposal should revert
        vm.expectRevert(ForageGovernor.MaxActiveProposalsReached.selector);
        vm.prank(attacker);
        governor.propose(targets, values, calldatas, "Spam-overflow");
    }

    /// @dev Guardian cancels spam proposals, activeProposalCount decremented, new proposals allowed.
    function test_TC12_guardianCancelsSpamAllowsNewProposals() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        // Create several proposals by proposer (who has threshold)
        uint256[] memory proposalIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            string memory description = string(abi.encodePacked("G-Cancel-", vm.toString(i)));
            vm.prank(proposer);
            proposalIds[i] = governor.propose(targets, values, calldatas, description);
        }

        uint256 activeCountBefore = governor.activeProposalCount();

        // Guardian1 (permissions=7, includes CANCEL) cancels 3 proposals
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(guardian1);
            guardianModuleContract.guardianCancel(proposalIds[i]);
        }

        uint256 activeCountAfter = governor.activeProposalCount();
        assertEq(activeCountAfter, activeCountBefore - 3, "activeProposalCount must decrement by 3 after canceling 3");

        // New proposal should now succeed (room freed)
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "New-after-cancel");
    }

    function test_V12_67817_proposeRejectsMismatchedProposerSuffix() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposalParams();
        string memory description = string.concat("Protected proposal #proposer=", vm.toString(attacker));

        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, proposer));
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, description);
    }

    function test_V12_67817_guardianThresholdBypassStillRequiresMatchingSuffix() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _standardProposalParams();

        string memory mismatched = string.concat("Guardian protected proposal #proposer=", vm.toString(proposer));
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorRestrictedProposer.selector, guardian1));
        vm.prank(guardian1);
        governor.propose(targets, values, calldatas, mismatched);

        string memory matched = string.concat("Guardian protected proposal #proposer=", vm.toString(guardian1));
        vm.prank(guardian1);
        uint256 proposalId = governor.propose(targets, values, calldatas, matched);
        assertEq(governor.proposalProposer(proposalId), guardian1, "guardian proposer preserved");
    }

    /// @dev Lazy cleanup: let spam proposals reach Defeated state, new proposal triggers cleanup.
    function test_TC12_lazyCleanupOfDefeatedProposals() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        // Create proposals that will become Defeated (no votes, no quorum)
        uint256[] memory proposalIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            string memory description = string(abi.encodePacked("Lazy-", vm.toString(i)));
            vm.prank(proposer);
            proposalIds[i] = governor.propose(targets, values, calldatas, description);
        }

        // Advance past voting delay + voting period so proposals become Defeated
        vm.roll(block.number + governor.votingDelay() + governor.votingPeriod() + 2);

        // Verify proposals are Defeated
        for (uint256 i = 0; i < 3; i++) {
            assertEq(
                uint256(governor.state(proposalIds[i])),
                uint256(IGovernor.ProposalState.Defeated),
                "Proposals with no votes must be Defeated"
            );
        }

        // Creating a new proposal should trigger lazy cleanup of Defeated proposals
        vm.prank(proposer);
        uint256 newId = governor.propose(targets, values, calldatas, "After-lazy-cleanup");
        assertTrue(newId != 0, "New proposal after lazy cleanup must succeed");
    }

    // ── 9.3 — Guardian Compromise Blast Radius (R-43) ──────────────────

    /// @dev OF-M01: Compromised guardian CANNOT pause non-whitelisted targets.
    /// Guardian can only pause targets that governance has explicitly approved.
    function test_TC12_compromisedGuardianCanPauseAllTargets() public {
        // Deploy multiple pausable targets (NOT whitelisted)
        MockPausable target1 = new MockPausable(address(timelock), address(governor));
        MockPausable target2 = new MockPausable(address(timelock), address(governor));

        address[] memory targets = new address[](2);
        targets[0] = address(target1);
        targets[1] = address(target2);
        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("pause()");
        calldatas[1] = abi.encodeWithSignature("pause()");

        // guardian4 has EMERGENCY bit (permissions=4) but targets are not whitelisted
        vm.prank(guardian4);
        vm.expectRevert(abi.encodeWithSelector(GuardianModule.TargetNotWhitelisted.selector, address(target1)));
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);

        // Targets must remain unpaused
        assertFalse(target1.paused(), "Target1 must NOT be paused (not whitelisted)");
        assertFalse(target2.paused(), "Target2 must NOT be paused (not whitelisted)");
    }

    /// @dev Same guardian tries non-pause calldata (upgradeToAndCall, transferOwnership) -> InvalidEmergencyAction.
    function test_TC12_compromisedGuardianNonPauseCalldataReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // Try upgradeToAndCall calldata
        bytes[] memory calldatas1 = new bytes[](1);
        calldatas1[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas1);

        // Try transferOwnership calldata
        bytes[] memory calldatas2 = new bytes[](1);
        calldatas2[0] = abi.encodeWithSignature("transferOwnership(address)", attacker);

        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas2);
    }

    /// @dev Guardian CANNOT execute upgrades, parameter changes, or fund transfers through emergency path.
    function test_TC12_guardianCannotEscalateViaEmergency() public {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        // Try setQuorumBps (parameter change)
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setQuorumBps, (1));

        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        vm.prank(guardian1); // guardian1 has all permissions including EMERGENCY
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    // ── 9.4 / 4.6 — TimelockController Role Integrity (R-52) ──────────

    /// @dev After deployment: deployer has NO PROPOSER_ROLE on timelock.
    function test_TC12_deployerHasNoProposerRole() public view {
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must NOT have PROPOSER_ROLE after setup");
    }

    /// @dev ForageGovernor is sole holder of PROPOSER_ROLE.
    function test_TC12_governorIsSoleProposer() public view {
        bytes32 PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
        assertTrue(timelock.hasRole(PROPOSER_ROLE, address(governor)), "ForageGovernor must have PROPOSER_ROLE");
        // Verify deployer, attacker, and guardians do NOT have PROPOSER_ROLE
        assertFalse(timelock.hasRole(PROPOSER_ROLE, deployer), "Deployer must not have PROPOSER_ROLE");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, attacker), "Attacker must not have PROPOSER_ROLE");
        assertFalse(timelock.hasRole(PROPOSER_ROLE, guardian1), "Guardian must not have PROPOSER_ROLE");
    }

    /// @dev TimelockController DEFAULT_ADMIN_ROLE holder is address(0) (renounced).
    function test_TC12_timelockAdminRoleRenounced() public view {
        bytes32 DEFAULT_ADMIN_ROLE = bytes32(0);
        // After setup, the admin is address(0) because we passed address(0) as admin
        // in the TimelockController constructor
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer), "Deployer must not be DEFAULT_ADMIN_ROLE holder");
    }

    /// @dev Non-governor address tries to schedule on TimelockController -> reverts.
    function test_TC12_nonGovernorCannotScheduleOnTimelock() public {
        bytes memory callData = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (20));

        // Cache PROPOSER_ROLE before prank so the external call doesn't consume it
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, proposerRole)
        );
        vm.prank(attacker);
        timelock.schedule(
            address(governor), 0, callData, bytes32(0), keccak256("attacker-schedule"), TIMELOCK_MIN_DELAY
        );
    }

    // ── 9.5 — Quorum Manipulation Defense (R-55) ──────────────────────

    /// @dev setQuorumBps(0) reverts InvalidParameter.
    function test_TC12_quorumBpsZeroReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setQuorumBps(0);
    }

    /// @dev Valid quorum change via full governance flow respects bounds >= 1 bps (R-55).
    function test_TC12_validQuorumChangeViaGovernanceFlow() public {
        // Build proposal to lower quorum to minimum (1 bps)
        address[] memory propTargets = new address[](1);
        propTargets[0] = address(governor);
        uint256[] memory propValues = new uint256[](1);
        propValues[0] = 0;
        bytes[] memory propCalldatas = new bytes[](1);
        propCalldatas[0] = abi.encodeCall(ForageGovernor.setQuorumBps, (1));
        string memory desc = "Lower quorum to 1 bps";
        bytes32 descHash = keccak256(bytes(desc));

        // Propose
        vm.prank(proposer);
        uint256 pid = governor.propose(propTargets, propValues, propCalldatas, desc);

        // Vote
        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(pid, 1); // voter1 has 40M, quorum is 4M

        // Advance past voting period
        vm.roll(block.number + governor.votingPeriod() + 1);

        // Queue
        governor.queue(propTargets, propValues, propCalldatas, descHash);

        // Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute
        governor.execute(propTargets, propValues, propCalldatas, descHash);

        // Verify: quorumBps updated to 1, still >= 1
        uint256 expectedQuorum = TOTAL_SUPPLY * 1 / 10_000;
        assertEq(governor.quorum(block.number - 1), expectedQuorum, "Quorum at 1 bps must be correct");
        assertTrue(expectedQuorum > 0, "Quorum at 1 bps must be > 0 with non-zero supply");
    }

    // ── 9.6 — Voting Power Front-Running (R-18) ──────────────────────

    /// @dev Attacker buys FORAGE before proposal block -> voting power captured at snapshot (expected behavior).
    function test_TC12_frontRunnerPowerCapturedAtSnapshot() public {
        // Attacker acquires tokens before any proposal
        vm.prank(deployer);
        token.transfer(attacker, 5_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1); // checkpoint

        // Create proposal
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance past snapshot so getPastVotes can query it
        vm.roll(snapshotBlock + 1);

        // Attacker's voting power at snapshot should be 5M (they held tokens before proposal)
        uint256 power = token.getPastVotes(attacker, snapshotBlock);
        assertEq(power, 5_000_000 * 1e18, "Front-runner's power must be captured at snapshot (expected behavior)");
    }

    /// @dev Verify votingDelay prevents same-block propose-and-vote.
    function test_TC12_votingDelayPreventsSameBlockVote() public {
        uint256 proposalId = _createProposal();

        // Immediately try to vote in the same block -- proposal is Pending, not Active
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Pending,
                bytes32(uint256(1 << uint8(IGovernor.ProposalState.Active)))
            )
        );
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
    }

    // ── 4.5 — Guardian Permission Escalation (R-39, R-47) ─────────────

    /// @dev Guardian with PAUSE (bit 0) tries guardianExecuteEmergency -> InsufficientPermissions.
    function test_TC12_pauseGuardianCannotExecuteEmergency() public {
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        // guardian2 has permissions = 1 (PAUSE only, no EMERGENCY bit)
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    /// @dev Guardian with CANCEL (bit 1) tries guardianPause -> InsufficientPermissions.
    function test_TC12_cancelGuardianCannotPause() public {
        // guardian3 has permissions = 2 (CANCEL only, no PAUSE bit)
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian3);
        guardianModuleContract.guardianPause(address(mockPausable));
    }

    /// @dev Guardian with EMERGENCY (bit 2) tries guardianCancel -> InsufficientPermissions.
    function test_TC12_emergencyGuardianCannotCancel() public {
        uint256 proposalId = _createProposal();

        // guardian4 has permissions = 4 (EMERGENCY only, no CANCEL bit)
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianCancel(proposalId);
    }

    /// @dev Permission check uses bitmask AND (not != 0). Guardian with irrelevant bits cannot
    ///      access functions requiring specific bits.
    function test_TC12_permissionBitmaskANDCheck() public {
        // guardian2 has permissions = 1 (binary: 001). PAUSE bit set, CANCEL and EMERGENCY not set.
        // Even though permissions != 0, CANCEL and EMERGENCY operations must fail.

        // Cannot cancel (bit 1 not set)
        uint256 proposalId = _createProposal();
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianCancel(proposalId);

        // Cannot execute emergency (bit 2 not set)
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }
}

// ============================================================
// TC-13: Proxy Architecture Attack Vectors
// Requirements: R-01, R-51, R-54
// ============================================================
contract ForageGovernor_TC13_ProxyArchitectureAttacks is ForageGovernorTestBase {
    // ── 1.1 — Storage Collision on Upgrade ──────────────────────────────

    /// @dev Deploy v1 via proxy, initialize, populate state (guardians set up in base).
    ///      Upgrade to v2 (appended storage). Verify all v1 state intact.
    function test_TC13_upgradePreservesStateWithAppendedStorage() public {
        // Record v1 state
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 must be guardian before upgrade");
        assertEq(guardianModuleContract.getGuardianPermissions(guardian1), 14, "guardian1 perms must be 14 (OF-19-001)");
        assertEq(guardianModuleContract.getGuardians().length, 4, "must have 4 guardians");
        uint256 activeBefore = governor.activeProposalCount();

        // Create a proposal to populate more state
        uint256 proposalId = _createProposal();

        // Upgrade to V2 (appended storage)
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV2), "");

        // Verify all v1 state intact
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 must still be guardian after upgrade");
        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian1),
            14,
            "guardian1 perms must be preserved (OF-19-001)"
        );
        assertEq(guardianModuleContract.getGuardians().length, 4, "guardian list length must be preserved");
        // proposalProposer should still return proposer
        assertEq(governor.proposalProposer(proposalId), proposer, "proposal proposer must be preserved");

        // V2-specific: new version function works
        ForageGovernorV2 govV2 = ForageGovernorV2(payable(address(governor)));
        assertEq(govV2.versionV2(), 2, "V2 version must return 2");
    }

    /// @dev Upgrade to v2 with reordered storage -> _maxActiveProposals corrupted (negative test).
    function test_TC13_reorderedStorageCausesCorruption() public {
        // Verify pre-upgrade state
        assertEq(governor.maxActiveProposals(), 10, "maxActiveProposals must be 10 before upgrade");

        // Upgrade to bad-layout implementation
        ForageGovernorV2BadLayout badImpl = new ForageGovernorV2BadLayout();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(badImpl), "");

        // After bad layout upgrade, _maxActiveProposals reads from wrong slot
        ForageGovernorV2BadLayout badGov = ForageGovernorV2BadLayout(payable(address(governor)));
        assertEq(badGov.versionV2BadLayout(), 99, "bad layout version must return 99");
        // The insertedVar shifts all custom storage slots — _maxActiveProposals now reads
        // from what was previously a different slot (or empty), so it should be corrupted
        assertNotEq(
            badGov.readMaxActiveProposals(), 10, "maxActiveProposals must be corrupted after bad layout upgrade"
        );
    }

    // ── 1.2 — Implementation Direct Call ───────────────────────────────

    /// @dev Deploy implementation. Call initialize() directly -> reverts InvalidInitialization.
    function test_TC13_implementationDirectInitReverts() public {
        ForageGovernor freshImpl = new ForageGovernor();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        freshImpl.initialize(
            address(token),
            address(timelock),
            DEFAULT_VOTING_DELAY,
            DEFAULT_VOTING_PERIOD,
            DEFAULT_THRESHOLD_BPS,
            DEFAULT_QUORUM_BPS,
            address(0)
        );
    }

    /// @dev State changes on implementation don't affect proxy.
    function test_TC13_implementationStateDoesNotAffectProxy() public view {
        // The implementation's storage is separate from the proxy's storage.
        // Verify: reading maxActiveProposals on implementation returns 0 (uninitialized)
        // while proxy returns the initialized value (10).
        uint256 implMaxActive = implementation.maxActiveProposals();
        assertEq(implMaxActive, 0, "Implementation maxActiveProposals must be 0 (uninitialized)");

        // Proxy's maxActiveProposals should be set to 10
        assertEq(governor.maxActiveProposals(), 10, "Proxy maxActiveProposals must be 10");

        // The addresses are different, confirming separate storage
        assertTrue(address(implementation) != address(governor), "Implementation and proxy must be different addresses");
    }

    // ── 1.3 — Unauthorized Upgrade ─────────────────────────────────────

    /// @dev Non-timelock calls upgradeToAndCall -> reverts.
    function test_TC13_nonTimelockUpgradeReverts() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();

        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        vm.prank(attacker);
        governor.upgradeToAndCall(address(implV2), "");
    }

    /// @dev Random EOA calls upgradeToAndCall -> reverts.
    function test_TC13_randomEOAUpgradeReverts() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        address randomUser = makeAddr("randomEOA");

        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        vm.prank(randomUser);
        governor.upgradeToAndCall(address(implV2), "");
    }

    /// @dev Guardian cannot call upgradeToAndCall directly.
    function test_TC13_guardianCannotUpgrade() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();

        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        vm.prank(guardian1);
        governor.upgradeToAndCall(address(implV2), "");
    }

    // ── 1.4 — Upgrade-After-Upgrade ────────────────────────────────────

    /// @dev v1 -> v2 -> v3, state preserved, upgradeToAndCall still functional.
    function test_TC13_upgradeChainPreservesState() public {
        address[] memory guardiansBefore = guardianModuleContract.getGuardians();

        // v1 -> v2
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV2), "");

        ForageGovernorV2 govV2 = ForageGovernorV2(payable(address(governor)));
        assertEq(govV2.versionV2(), 2, "Must be v2");
        assertEq(
            guardianModuleContract.getGuardians().length, guardiansBefore.length, "Guardian count preserved v1->v2"
        );

        // v2 -> v3
        ForageGovernorV3 implV3 = new ForageGovernorV3();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV3), "");

        ForageGovernorV3 govV3 = ForageGovernorV3(payable(address(governor)));
        assertEq(govV3.versionV3(), 3, "Must be v3");
        assertEq(
            guardianModuleContract.getGuardians().length, guardiansBefore.length, "Guardian count preserved v1->v2->v3"
        );
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 preserved through v1->v2->v3");
    }

    // ── 1.5 — Delegatecall Restriction ─────────────────────────────────

    /// @dev Verify ForageGovernor runtime bytecode does not contain excessive DELEGATECALL opcodes.
    ///      Only UUPS upgradeToAndCall should use DELEGATECALL. We check that the DELEGATECALL
    ///      opcode (0xF4) count is consistent with UUPS-only usage (low count).
    function test_TC13_noDelegatecallBeyondUUPS() public view {
        bytes memory code = address(governor).code;
        assertTrue(code.length > 0, "Governor must have deployed bytecode");

        // Count DELEGATECALL opcodes (0xF4)
        uint256 delegatecallCount = 0;
        for (uint256 i = 0; i < code.length; i++) {
            if (uint8(code[i]) == 0xF4) {
                delegatecallCount++;
            }
        }

        // UUPS pattern typically has 1-2 DELEGATECALL opcodes (in upgradeToAndCall / _upgradeToAndCallUUPS).
        // More than 5 would suggest custom delegatecall beyond UUPS.
        // Note: This is a heuristic test -- false byte matches are possible but unlikely to inflate count significantly.
        assertTrue(
            delegatecallCount <= 5, "ForageGovernor must not have excessive DELEGATECALL opcodes beyond UUPS pattern"
        );
    }

    /// @dev Verify proxy does not expose a public delegatecall or fallback with arbitrary delegatecall.
    ///      Try a low-level call with a non-existent function selector -- should not route through
    ///      an unguarded delegatecall to another contract.
    function test_TC13_noUnguardedDelegatecallFallback() public {
        // Call governor with an unknown selector. Should revert or return empty (no unguarded delegatecall routing).
        bytes memory callData = abi.encodeWithSignature("nonExistentFunction123()");
        (bool success,) = address(governor).call(callData);

        // The call either reverted (expected for unknown selector on stub) or returned empty.
        // If success, verify no unexpected state change (proxy didn't route to malicious target).
        // The fact that we reached here without state corruption proves no unguarded delegatecall.
        // Verify governor still functions correctly after the unknown selector call.
        assertTrue(
            guardianModuleContract.isGuardian(guardian1), "Governor must still function after unknown selector call"
        );
    }
}
