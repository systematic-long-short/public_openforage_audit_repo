// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";
import "./helpers/ForageGovernorV2.sol";
import "./helpers/ForageGovernorV3.sol";
import "./helpers/ForageGovernorV2BadLayout.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ============================================================
// TC-09: UUPS Upgrade and Proxy Security
// Requirements: R-01, R-51, R-53, R-54
// ============================================================
contract ForageGovernor_TC09_UpgradeAndProxySecurity is ForageGovernorTestBase {
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ---- 1: Implementation direct init reverts InvalidInitialization (R-01) ----

    /// @dev R-01: Calling initialize() directly on the implementation contract
    ///      (not through the proxy) must revert InvalidInitialization because
    ///      the constructor calls _disableInitializers().
    function test_TC09_implDirectInitReverts() public {
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

    // ---- 2: Non-timelock calls upgradeToAndCall -> reverts Unauthorized (R-51) ----

    /// @dev R-51: Non-timelock calling upgradeToAndCall must revert Unauthorized.
    function test_TC09_nonTimelockUpgradeReverts() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        governor.upgradeToAndCall(address(implV2), "");
    }

    // ---- 3: Random EOA calls upgradeToAndCall -> reverts (R-51) ----

    /// @dev R-51: Random address (not timelock, not guardian, not proposer) calling
    ///      upgradeToAndCall must revert Unauthorized.
    function test_TC09_randomEOAUpgradeReverts() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        address randomUser = makeAddr("randomUser");

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ForageGovernor.Unauthorized.selector));
        governor.upgradeToAndCall(address(implV2), "");
    }

    // ---- 4: Timelock calls upgradeToAndCall -> succeeds, new impl active (R-51) ----

    /// @dev R-51: Timelock calling upgradeToAndCall succeeds. After upgrade,
    ///      the new implementation is active (version() returns 2).
    function test_TC09_timelockUpgradeSucceeds() public {
        ForageGovernorV2 implV2 = new ForageGovernorV2();

        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV2), "");

        // Verify new implementation is active via version()
        ForageGovernorV2 upgradedGov = ForageGovernorV2(payable(address(governor)));
        assertEq(upgradedGov.versionV2(), 2, "version must be 2 after upgrade");
    }

    // ---- 5: ForageGovernor does NOT have owner() function (R-53) ----

    /// @dev R-53: ForageGovernor does not inherit Ownable and has no owner() function.
    ///      Calling owner() on the governor must fail (no such function selector).
    function test_TC09_notOwnable() public {
        // ForageGovernor does NOT have owner() -- there is no Ownable in its inheritance.
        // We attempt a low-level call with the owner() selector. It should revert.
        bytes memory callData = abi.encodeWithSignature("owner()");
        (bool success,) = address(governor).staticcall(callData);
        assertFalse(success, "ForageGovernor must not have owner() -- not Ownable");
    }

    // ---- 6: Storage layout append-only: v1->v2 preserves state (R-54) ----

    /// @dev R-54: Upgrading to V2 (which appends a storage variable) preserves all
    ///      existing state: guardian permissions, quorum, threshold, active proposal count.
    function test_TC09_storageLayoutAppendOnlyPreservesState() public {
        // Record state before upgrade
        bool g1Before = guardianModuleContract.isGuardian(guardian1);
        uint256 g1PermsBefore = guardianModuleContract.getGuardianPermissions(guardian1);
        uint256 activeCountBefore = governor.activeProposalCount();
        address[] memory guardiansBefore = guardianModuleContract.getGuardians();

        // Upgrade to V2
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV2), "");

        // Verify all state preserved
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 must still be guardian after upgrade");
        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian1),
            g1PermsBefore,
            "guardian1 permissions must be preserved"
        );
        assertEq(governor.activeProposalCount(), activeCountBefore, "activeProposalCount must be preserved");
        assertEq(
            guardianModuleContract.getGuardians().length,
            guardiansBefore.length,
            "guardian list length must be preserved"
        );
        assertEq(g1Before, true, "guardian1 was guardian before upgrade");
    }

    // ---- 7: Storage layout collision: v2 with reordered vars (negative test, R-54) ----

    /// @dev R-54 (negative): Upgrading to an implementation with variables inserted
    ///      in the middle of the storage layout corrupts existing state. This proves
    ///      that append-only layout discipline is critical.
    ///      ForageGovernorV2BadLayout inserts `insertedVar` before `_maxActiveProposals`,
    ///      shifting all ForageGovernor-specific storage slots.
    function test_TC09_negativeStorageLayoutCorruption() public {
        // Verify known state before upgrade
        assertEq(governor.maxActiveProposals(), 10, "maxActiveProposals must be 10 before upgrade");

        // Upgrade to bad-layout implementation
        ForageGovernorV2BadLayout badImpl = new ForageGovernorV2BadLayout();

        // The bad layout contract has no access control in _authorizeUpgrade,
        // so we can call from timelock to simulate a real upgrade path
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(badImpl), "");

        // After upgrade with shifted layout, _maxActiveProposals reads from wrong slot.
        // The insertedVar occupies what was _maxActiveProposals' slot.
        ForageGovernorV2BadLayout badGov = ForageGovernorV2BadLayout(payable(address(governor)));

        // version() is a pure function — works regardless of storage layout
        assertEq(badGov.versionV2BadLayout(), 99, "bad layout version must return 99");

        // _maxActiveProposals now reads from a different slot due to the shift.
        // The value should be corrupted (not 10).
        assertNotEq(
            badGov.readMaxActiveProposals(), 10, "maxActiveProposals must be corrupted after bad layout upgrade"
        );
    }

    // ---- 8: Upgrade-after-upgrade: v1->v2->v3 works, state preserved (R-54) ----

    /// @dev R-54: Multi-generation upgrade chain preserves state throughout.
    ///      Upgrade v1->v2, then v2->v3. Verify state preserved at each step.
    function test_TC09_upgradeAfterUpgradeChain() public {
        // Record state on v1
        address[] memory guardiansBefore = guardianModuleContract.getGuardians();

        // Upgrade to V2
        ForageGovernorV2 implV2 = new ForageGovernorV2();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV2), "");

        ForageGovernorV2 govV2 = ForageGovernorV2(payable(address(governor)));
        assertEq(govV2.versionV2(), 2, "must be v2 after first upgrade");
        assertEq(
            guardianModuleContract.getGuardians().length, guardiansBefore.length, "guardian count preserved v1->v2"
        );

        // Upgrade to V3
        ForageGovernorV3 implV3 = new ForageGovernorV3();
        vm.prank(address(timelock));
        governor.upgradeToAndCall(address(implV3), "");

        ForageGovernorV3 govV3 = ForageGovernorV3(payable(address(governor)));
        assertEq(govV3.versionV3(), 3, "must be v3 after second upgrade");
        assertEq(
            guardianModuleContract.getGuardians().length, guardiansBefore.length, "guardian count preserved v1->v2->v3"
        );
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 preserved through upgrade chain");
        assertTrue(guardianModuleContract.isGuardian(guardian4), "guardian4 preserved through upgrade chain");
    }

    // ---- 9: proxiableUUID returns ERC1967 implementation slot (R-54) ----

    /// @dev R-54: proxiableUUID() must return the ERC1967 implementation storage slot.
    ///      proxiableUUID has notDelegated modifier, so call on implementation directly.
    function test_TC09_proxiableUUIDReturnsERC1967Slot() public view {
        bytes32 uuid = implementation.proxiableUUID();
        assertEq(uuid, ERC1967_IMPL_SLOT, "proxiableUUID must return ERC1967 implementation slot");
    }

    // ---- 10: ImplV2 direct init reverts (R-01) ----

    /// @dev R-01: A freshly deployed V2 implementation also has _disableInitializers()
    ///      via the inherited constructor. Direct init must revert.
    function test_TC09_implV2DirectInitReverts() public {
        ForageGovernorV2 freshImplV2 = new ForageGovernorV2();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        freshImplV2.initialize(
            address(token),
            address(timelock),
            DEFAULT_VOTING_DELAY,
            DEFAULT_VOTING_PERIOD,
            DEFAULT_THRESHOLD_BPS,
            DEFAULT_QUORUM_BPS,
            address(0)
        );
    }
}

// ============================================================
// TC-10: View Functions
// Requirements: R-33, R-56, R-63, F-21 through F-36
// ============================================================
contract ForageGovernor_TC10_ViewFunctions is ForageGovernorTestBase {
    // ---- 1: token() returns ForageToken address (F-21) ----

    /// @dev F-21: token() must return the MockForageTokenVotes address used during init.
    function test_TC10_tokenReturnsForageTokenAddress() public view {
        assertEq(address(governor.token()), address(token), "token() must return ForageToken address");
    }

    // ---- 2: votingDelay() returns correct value (F-34) ----

    /// @dev F-34: votingDelay() must return DEFAULT_VOTING_DELAY (0 in launch phase).
    function test_TC10_votingDelayReturnsCorrectValue() public view {
        assertEq(governor.votingDelay(), DEFAULT_VOTING_DELAY, "votingDelay() must return 0 (launch phase)");
    }

    // ---- 3: votingPeriod() returns correct value (F-35) ----

    /// @dev F-35: votingPeriod() must return DEFAULT_VOTING_PERIOD (3600 in launch phase).
    function test_TC10_votingPeriodReturnsCorrectValue() public view {
        assertEq(
            governor.votingPeriod(), DEFAULT_VOTING_PERIOD, "votingPeriod() must return 3600 (launch phase, 1 hour)"
        );
    }

    // ---- 4: proposalThreshold() == totalSupply * thresholdBps / 10000 (F-36, R-56) ----

    /// @dev F-36, R-56: proposalThreshold() must equal totalSupply * proposalThresholdBps / 10000.
    ///      With 100M supply and 100 bps: 1,000,000 FORAGE (1e24 wei).
    function test_TC10_proposalThresholdPercentageBased() public view {
        uint256 expected = TOTAL_SUPPLY * DEFAULT_THRESHOLD_BPS / 10_000;
        assertEq(
            governor.proposalThreshold(), expected, "proposalThreshold must equal totalSupply * thresholdBps / 10000"
        );
    }

    // ---- 5: quorum(block.number) == getPastTotalSupply * quorumBps / 10000 (F-23, R-33) ----

    /// @dev F-23, R-33: quorum() must return getPastTotalSupply * quorumBps / 10000.
    ///      With 100M supply and 400 bps: 4,000,000 FORAGE.
    function test_TC10_quorumPercentageBased() public view {
        uint256 expected = TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10_000;
        assertEq(
            governor.quorum(block.number - 1), expected, "quorum must equal getPastTotalSupply * quorumBps / 10000"
        );
    }

    // ---- 6: state() lifecycle: Pending -> Active -> Succeeded -> Queued -> Executed (F-24) ----

    /// @dev F-24: Verify state() returns correct ProposalState across the full lifecycle.
    ///      Uses explicit proposal params (not _createProposal helper) so we can track
    ///      the description hash for queue/execute operations.
    function test_TC10_stateLifecycle() public {
        // Build proposal params explicitly
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        string memory description = "TC10 lifecycle test";
        bytes32 descHash = keccak256(bytes(description));

        // Create proposal
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // state() == Pending immediately after creation
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending),
            "state must be Pending after creation"
        );

        // Advance past voting delay -> Active
        vm.roll(block.number + governor.votingDelay() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Active),
            "state must be Active after voting delay"
        );

        // Cast enough For votes to pass
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For

        // Advance past voting period -> Succeeded
        vm.roll(block.number + governor.votingPeriod() + 1);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "state must be Succeeded after voting period with enough For votes"
        );

        // Queue -> Queued
        governor.queue(targets, values, calldatas, descHash);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            "state must be Queued after queue"
        );

        // Advance past timelock delay, execute -> Executed
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descHash);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed),
            "state must be Executed after execute"
        );
    }

    // ---- 7: proposalVotes() returns correct tallies after voting (F-25) ----

    /// @dev F-25: After casting votes, proposalVotes() must return correct tallies.
    function test_TC10_proposalVotesReturnsTallies() public {
        uint256 proposalId = _createProposal();

        // Advance to Active
        vm.roll(block.number + governor.votingDelay() + 1);

        // voter1 votes For (5M)
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // voter2 votes Against (3M)
        vm.prank(voter2);
        governor.castVote(proposalId, 0);

        // voter3 votes Abstain (2M)
        vm.prank(voter3);
        governor.castVote(proposalId, 2);

        // Check tallies
        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);

        assertEq(forVotes, 5_000_000 * 1e18, "forVotes must equal voter1's 5M tokens");
        assertEq(against, 3_000_000 * 1e18, "againstVotes must equal voter2's 3M tokens");
        assertEq(abstain, 2_000_000 * 1e18, "abstainVotes must equal voter3's 2M tokens");
    }

    // ---- 8: proposalProposer() returns correct address (F-26) ----

    /// @dev F-26: proposalProposer() must return the address that created the proposal.
    function test_TC10_proposalProposerReturnsCorrectAddress() public {
        uint256 proposalId = _createProposal();
        assertEq(governor.proposalProposer(proposalId), proposer, "proposalProposer must return the proposer's address");
    }

    // ---- 9: proposalSnapshot() == creation block + votingDelay (F-27) ----

    /// @dev F-27: proposalSnapshot() returns the vote start block.
    ///      In OZ Governor, proposalSnapshot() == creation block + votingDelay.
    ///      This is the block at which voting power is snapshotted via getPastVotes.
    ///      R-17 says "snapshot block == block.number at creation" — in OZ terms, this
    ///      means the snapshot for voting power determination is set at propose() time
    ///      to (creation + votingDelay), which is correct per OZ Governor semantics.
    function test_TC10_proposalSnapshotReturnsCreationBlockPlusVotingDelay() public {
        uint256 blockBefore = block.number;
        uint256 proposalId = _createProposal();

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        // OZ inherited (L2 line 281): proposalSnapshot() returns voteStart = creationBlock + votingDelay
        assertEq(
            snapshot,
            blockBefore + governor.votingDelay(),
            "proposalSnapshot must equal creationBlock + votingDelay (OZ inherited)"
        );
    }

    // ---- 10: proposalDeadline() == snapshot + votingPeriod (F-28) ----

    /// @dev F-28: proposalDeadline() must equal proposalSnapshot() + votingPeriod().
    function test_TC10_proposalDeadlineEqualsSnapshotPlusVotingPeriod() public {
        uint256 proposalId = _createProposal();

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        uint256 deadline = governor.proposalDeadline(proposalId);
        assertEq(deadline, snapshot + governor.votingPeriod(), "proposalDeadline must equal snapshot + votingPeriod");
    }

    // ---- 11: hasVoted() returns true for voters, false for non-voters (F-30) ----

    /// @dev F-30: hasVoted() must return true for addresses that voted and false for those that did not.
    function test_TC10_hasVotedCorrectness() public {
        uint256 proposalId = _createProposal();

        // Advance to Active
        vm.roll(block.number + governor.votingDelay() + 1);

        // Before voting
        assertFalse(governor.hasVoted(proposalId, voter1), "voter1 has not voted yet");
        assertFalse(governor.hasVoted(proposalId, voter2), "voter2 has not voted yet");
        assertFalse(governor.hasVoted(proposalId, nonGuardian), "nonGuardian has not voted");

        // voter1 votes
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // After voter1 votes
        assertTrue(governor.hasVoted(proposalId, voter1), "voter1 has voted");
        assertFalse(governor.hasVoted(proposalId, voter2), "voter2 still has not voted");
        assertFalse(governor.hasVoted(proposalId, nonGuardian), "nonGuardian still has not voted");
    }

    // ---- 12: isGuardian() / getGuardianPermissions() / getGuardians() correct values (F-31, F-32, F-33) ----

    /// @dev F-31, F-32, F-33: Guardian view functions return correct values after initialization.
    function test_TC10_guardianViewFunctions() public view {
        // isGuardian (F-31)
        assertTrue(guardianModuleContract.isGuardian(guardian1), "guardian1 is a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian2), "guardian2 is a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian3), "guardian3 is a guardian");
        assertTrue(guardianModuleContract.isGuardian(guardian4), "guardian4 is a guardian");
        assertFalse(guardianModuleContract.isGuardian(nonGuardian), "nonGuardian is not a guardian");
        assertFalse(guardianModuleContract.isGuardian(attacker), "attacker is not a guardian");

        // getGuardianPermissions (F-32)
        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian1),
            14,
            "guardian1 has CANCEL+EMERGENCY+PROPOSE (14, OF-19-001)"
        );
        assertEq(guardianModuleContract.getGuardianPermissions(guardian2), 1, "guardian2 has PAUSE only (1)");
        assertEq(guardianModuleContract.getGuardianPermissions(guardian3), 2, "guardian3 has CANCEL only (2)");
        assertEq(guardianModuleContract.getGuardianPermissions(guardian4), 4, "guardian4 has EMERGENCY only (4)");
        assertEq(guardianModuleContract.getGuardianPermissions(nonGuardian), 0, "nonGuardian has 0 permissions");

        // getGuardians (F-33)
        address[] memory guardians = guardianModuleContract.getGuardians();
        assertEq(guardians.length, 4, "must have exactly 4 guardians");
    }

    // ---- 13: governor.getVotes() returns voting power at timepoint (F-22) ----

    /// @dev F-22: governor.getVotes(account, timepoint) returns voting power at a past block.
    ///      Tests the governor's getVotes view function from GovernorVotesUpgradeable.
    function test_TC10_getVotesReturnsCurrentVotingPower() public {
        // Advance 1 block so we have a valid past timepoint
        vm.roll(block.number + 1);
        uint256 timepoint = block.number - 1;

        uint256 proposerVotes = governor.getVotes(proposer, timepoint);
        assertEq(proposerVotes, PROPOSER_TOKENS, "governor.getVotes must return proposer's voting power");

        uint256 voter1Votes = governor.getVotes(voter1, timepoint);
        assertEq(voter1Votes, 5_000_000 * 1e18, "governor.getVotes must return voter1's voting power");

        uint256 nonVoterVotes = governor.getVotes(attacker, timepoint);
        assertEq(nonVoterVotes, 0, "governor.getVotes must return 0 for account with no delegated tokens");
    }

    // ---- 14: proposalEta() returns correct value (F-29) ----

    /// @dev F-29: proposalEta() returns 0 before queueing and correct eta after queueing.
    function test_TC10_proposalEtaReturnsCorrectValue() public {
        // Build proposal params
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
        string memory description = "TC10 eta test";
        bytes32 descHash = keccak256(bytes(description));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Before queueing, eta should be 0
        assertEq(governor.proposalEta(proposalId), 0, "proposalEta must be 0 before queueing");

        // Pass and queue
        _passProposal(proposalId);
        governor.queue(targets, values, calldatas, descHash);

        // After queueing, eta should be > 0 and >= block.timestamp + TIMELOCK_MIN_DELAY
        uint256 eta = governor.proposalEta(proposalId);
        assertTrue(eta > 0, "proposalEta must be non-zero after queueing");
        assertGe(eta, block.timestamp + TIMELOCK_MIN_DELAY, "proposalEta must be >= now + timelockDelay");
    }
}
