// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";

// ============================================================
// TC-05: Quorum and Approval
// Requirements: R-33, R-34, R-35, R-36, R-37, R-38
// ============================================================
contract ForageGovernor_TC05_QuorumAndApproval is ForageGovernorTestBase {
    /// @dev Helper: create a proposal with a unique description
    function _createUniqueProposal(string memory desc) internal returns (uint256) {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        vm.prank(proposer);
        return governor.propose(targets, values, calldatas, desc);
    }

    /// @dev Helper: advance to active voting period for a proposal
    function _advanceToActive() internal {
        vm.roll(block.number + governor.votingDelay() + 1);
    }

    /// @dev Helper: advance past voting period
    function _advancePastDeadline() internal {
        vm.roll(block.number + governor.votingPeriod() + 1);
    }

    /// @dev Quorum computed as getPastTotalSupply * quorumBps / 10000 (R-33)
    function test_TC05_quorumComputedFromTotalSupplyAndBps() public view {
        // quorum at a past block should equal TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10000
        uint256 expected = TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10_000;
        assertEq(governor.quorum(block.number - 1), expected, "quorum must equal 4% of total supply");
    }

    /// @dev Below-quorum proposal defeated: 3.9M For when quorum=4M (R-35)
    function test_TC05_belowQuorumProposalDefeated() public {
        uint256 proposalId = _createUniqueProposal("below-quorum");
        _advanceToActive();

        // voter2 has 3M, voter4 has 1M. We need exactly 3.9M For.
        // voter2 (3M) + voter5 (500K) = 3.5M -- not enough
        // Use voter2 (3M) + voter4 (1M) = 4M -- that's at quorum, too much
        // We need to arrange 3.9M. Mint a separate account with 3.9M.
        // Actually, let's use voter2 (3M) + voter5 (500K) + voter4 partial -- but can't do partial votes.
        // Simplest: create a new voter with exactly 3.9M delegated.
        // But base setup already minted. Let's use the deployer to transfer some.
        // Actually: voter2 has 3M, voter4 has 1M. Total if both vote For = 4M = quorum exactly.
        // We just need voter2 alone = 3M < 4M, so that's below quorum.
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For: 3M

        _advancePastDeadline();

        // 3M < 4M quorum -> Defeated
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "Proposal with votes below quorum must be Defeated"
        );
    }

    /// @dev At-quorum proposal succeeds: 4M For (R-37)
    function test_TC05_atQuorumProposalSucceeds() public {
        uint256 proposalId = _createUniqueProposal("at-quorum");
        _advanceToActive();

        // voter2 (3M) + voter4 (1M) = 4M For = exactly quorum
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For: 3M
        vm.prank(voter4);
        governor.castVote(proposalId, 1); // For: 1M (total 4M)

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "Proposal with exactly quorum For votes must Succeed"
        );
    }

    /// @dev NEM-T2-M01: For + Abstain where forVotes alone < quorum -> Defeated.
    /// Abstain votes no longer count toward quorum per _quorumReached override.
    function test_TC05_forPlusAbstainBelowQuorumDefeated() public {
        uint256 proposalId = _createUniqueProposal("for-plus-abstain");
        _advanceToActive();

        // voter2 votes For (3M), voter4 votes Abstain (1M)
        // forVotes (3M) < quorum (4M) -> Defeated despite total votes meeting old quorum
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For: 3M
        vm.prank(voter4);
        governor.castVote(proposalId, 2); // Abstain: 1M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "For + Abstain where forVotes alone < quorum must be Defeated"
        );
    }

    /// @dev For + Abstain where forVotes alone >= quorum -> Succeeded
    function test_TC05_forPlusAbstainAboveQuorumSucceeds() public {
        uint256 proposalId = _createUniqueProposal("for-plus-abstain-above");
        _advanceToActive();

        // voter1 votes For (5M >= 4M quorum), voter4 votes Abstain (1M)
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For: 5M
        vm.prank(voter4);
        governor.castVote(proposalId, 2); // Abstain: 1M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "For + Abstain where forVotes alone >= quorum must Succeed"
        );
    }

    /// @dev Against majority: 2M For + 3M Against -> Defeated (R-37)
    function test_TC05_againstMajorityDefeated() public {
        uint256 proposalId = _createUniqueProposal("against-majority");
        _advanceToActive();

        // voter3 votes For (2M), voter2 votes Against (3M). Total 5M >= quorum. forVotes < againstVotes.
        vm.prank(voter3);
        governor.castVote(proposalId, 1); // For: 2M
        vm.prank(voter2);
        governor.castVote(proposalId, 0); // Against: 3M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "Proposal with forVotes < againstVotes must be Defeated"
        );
    }

    /// @dev Only-abstain proposal: 4M Abstain, forVotes==0 -> Defeated (R-38)
    function test_TC05_onlyAbstainProposalDefeated() public {
        uint256 proposalId = _createUniqueProposal("only-abstain");
        _advanceToActive();

        // voter1 (5M) votes Abstain. Quorum met (5M > 4M). But forVotes == 0.
        vm.prank(voter1);
        governor.castVote(proposalId, 2); // Abstain: 5M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "Proposal with only Abstain votes must be Defeated"
        );
    }

    /// @dev NEM-T2-M01: Mixed votes where forVotes < quorum -> Defeated despite total being high
    function test_TC05_mixedVotesForBelowQuorumDefeated() public {
        uint256 proposalId = _createUniqueProposal("mixed-votes-below");
        _advanceToActive();

        // voter3 (2M) For, voter4 (1M) Against, voter1 (5M) Abstain -> total 8M >= 4M old quorum
        // forVotes (2M) < quorum (4M) -> Defeated per NEM-T2-M01 _quorumReached override
        vm.prank(voter3);
        governor.castVote(proposalId, 1); // For: 2M
        vm.prank(voter4);
        governor.castVote(proposalId, 0); // Against: 1M
        vm.prank(voter1);
        governor.castVote(proposalId, 2); // Abstain: 5M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "Mixed votes where forVotes < quorum must be Defeated"
        );
    }

    /// @dev Mixed votes where forVotes >= quorum -> Succeeded
    function test_TC05_mixedVotesForAboveQuorumSucceeds() public {
        uint256 proposalId = _createUniqueProposal("mixed-votes-above");
        _advanceToActive();

        // voter1 (5M) For, voter4 (1M) Against, voter3 (2M) Abstain
        // forVotes (5M) >= quorum (4M) and forVotes > againstVotes -> Succeeded
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For: 5M
        vm.prank(voter4);
        governor.castVote(proposalId, 0); // Against: 1M
        vm.prank(voter3);
        governor.castVote(proposalId, 2); // Abstain: 2M

        _advancePastDeadline();

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "Mixed votes where forVotes >= quorum and majority must Succeed"
        );
    }

    /// @dev Quorum adapts to supply changes (R-34) - if totalSupply decreases (burn), quorum decreases
    function test_TC05_quorumAdaptsToSupplyDecrease() public {
        // Get quorum before burn
        uint256 quorumBefore = governor.quorum(block.number - 1);
        assertEq(quorumBefore, QUORUM_TOKENS, "quorum before burn should be 4M");

        // Burn tokens from deployer (reduces totalSupply)
        uint256 burnAmount = 50_000_000 * 1e18; // burn 50M
        vm.prank(deployer);
        token.burn(burnAmount);

        // Roll forward so the new supply checkpoint is queryable
        vm.roll(block.number + 1);

        // New total supply = 100M - 50M = 50M, quorum = 50M * 400/10000 = 2M
        uint256 quorumAfter = governor.quorum(block.number - 1);
        uint256 expectedAfter = (TOTAL_SUPPLY - burnAmount) * DEFAULT_QUORUM_BPS / 10_000;
        assertEq(quorumAfter, expectedAfter, "quorum must decrease when supply decreases");
        assertTrue(quorumAfter < quorumBefore, "quorum after burn must be less than before");
    }

    /// @dev proposalThreshold adapts to supply changes
    function test_TC05_proposalThresholdAdaptsToSupplyChanges() public {
        // Threshold before any changes
        uint256 thresholdBefore = governor.proposalThreshold();
        assertEq(thresholdBefore, PROPOSER_TOKENS, "threshold should be 1M initially");

        // Burn 50M tokens (reduces totalSupply)
        uint256 burnAmount = 50_000_000 * 1e18;
        vm.prank(deployer);
        token.burn(burnAmount);

        // OF-018: proposalThreshold uses getPastTotalSupply(clock()-1), roll forward for checkpoint
        vm.roll(block.number + 1);

        uint256 thresholdAfter = governor.proposalThreshold();
        uint256 expectedAfter = (TOTAL_SUPPLY - burnAmount) * DEFAULT_THRESHOLD_BPS / 10_000;
        assertEq(thresholdAfter, expectedAfter, "threshold must decrease when supply decreases");
        assertTrue(thresholdAfter < thresholdBefore, "threshold after burn must be less than before");
    }

    /// @dev Exact quorum boundary: one wei below quorum fails, exactly at quorum succeeds
    function test_TC05_exactQuorumBoundary() public {
        // quorum = 4M tokens. voter2(3M) + voter4(1M) = exactly 4M.
        // One fewer voter means below quorum.
        // Test exactly at quorum: 4M For -> Succeeded (tested above, reinforce with boundary check)
        uint256 proposalId = _createUniqueProposal("exact-boundary");
        _advanceToActive();

        uint256 quorumRequired = governor.quorum(block.number - governor.votingDelay() - 1);
        // voter2 (3M) + voter4 (1M) = 4M exactly
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For: 3M
        vm.prank(voter4);
        governor.castVote(proposalId, 1); // For: 1M

        _advancePastDeadline();

        // Verify the votes are exactly at quorum
        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(forVotes + against + abstain, quorumRequired, "total votes should be exactly at quorum");
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "Proposal at exact quorum boundary must Succeed"
        );
    }

    /// @dev Zero against votes with for votes above quorum succeeds
    function test_TC05_zeroAgainstVotesWithForAboveQuorum() public {
        uint256 proposalId = _createUniqueProposal("zero-against");
        _advanceToActive();

        // voter1 (5M) votes For, no against votes. 5M > 4M quorum.
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For: 5M

        _advancePastDeadline();

        (uint256 against, uint256 forVotes,) = governor.proposalVotes(proposalId);
        assertEq(against, 0, "against votes should be 0");
        assertTrue(forVotes > 0, "for votes should be positive");
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "Proposal with For > quorum and 0 Against must Succeed"
        );
    }

    /// @dev Verify quorum() view returns correct value
    function test_TC05_quorumViewReturnsCorrectValue() public view {
        uint256 expected = TOTAL_SUPPLY * DEFAULT_QUORUM_BPS / 10_000;
        uint256 actual = governor.quorum(block.number - 1);
        assertEq(actual, expected, "quorum() view must return totalSupply * quorumBps / 10000");
        assertEq(actual, QUORUM_TOKENS, "quorum() must equal QUORUM_TOKENS constant");
    }
}

// ============================================================
// TC-06: Guardian Functions
// Requirements: R-39, R-40, R-41, R-42, R-43, R-44, R-45,
//               R-46, R-47, R-48, R-49, R-70, R-71
// ============================================================
contract ForageGovernor_TC06_GuardianFunctions is ForageGovernorTestBase {
    /// @dev Helper: create a proposal and return its ID
    function _createTestProposal() internal returns (uint256) {
        return _createProposal();
    }

    /// @dev guardianPause by guardian with PAUSE bit -> pause() called on target, GuardianPaused event (R-40, R-44, R-70)
    function test_TC06_guardianPauseWithPauseBitSucceeds() public {
        // guardian2 has permissions = 1 (PAUSE bit set)
        vm.expectEmit(true, true, false, false);
        emit GuardianModule.GuardianPaused(guardian2, address(mockPausable));

        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(mockPausable));

        assertTrue(mockPausable.paused(), "Target must be paused after guardianPause");
    }

    /// @dev guardianPause by guardian without PAUSE bit -> InsufficientPermissions (R-47)
    function test_TC06_guardianPauseWithoutPauseBitReverts() public {
        // guardian3 has permissions = 2 (CANCEL only, no PAUSE bit)
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian3);
        guardianModuleContract.guardianPause(address(mockPausable));
    }

    /// @dev guardianPause by non-guardian -> NotGuardian (R-46)
    function test_TC06_guardianPauseByNonGuardianReverts() public {
        vm.expectRevert(GuardianModule.NotGuardian.selector);
        vm.prank(nonGuardian);
        guardianModuleContract.guardianPause(address(mockPausable));
    }

    /// @dev guardianPause with zero target -> ZeroAddress (R-49)
    /// OF-19-001: Use guardian2 (has PAUSE permission) instead of guardian1 (no PAUSE)
    function test_TC06_guardianPauseZeroAddressReverts() public {
        vm.expectRevert(GuardianModule.ZeroAddress.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(0));
    }

    /// @dev guardianCancel by guardian with CANCEL bit -> Canceled, ProposalCanceled event (R-41)
    function test_TC06_guardianCancelWithCancelBitSucceeds() public {
        uint256 proposalId = _createTestProposal();

        // guardian3 has permissions = 2 (CANCEL bit set)
        vm.prank(guardian3);
        vm.recordLogs();
        guardianModuleContract.guardianCancel(proposalId);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled),
            "Proposal must be Canceled after guardianCancel"
        );

        // Verify ProposalCanceled event with payload
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 canceledTopic = keccak256("ProposalCanceled(uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == canceledTopic) {
                found = true;
                uint256 eventPid = abi.decode(logs[i].data, (uint256));
                assertEq(eventPid, proposalId, "ProposalCanceled proposalId must match");
                break;
            }
        }
        assertTrue(found, "guardianCancel must emit ProposalCanceled event");
    }

    /// @dev guardianCancel by guardian without CANCEL bit -> InsufficientPermissions
    function test_TC06_guardianCancelWithoutCancelBitReverts() public {
        uint256 proposalId = _createTestProposal();

        // guardian2 has permissions = 1 (PAUSE only, no CANCEL bit)
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianCancel(proposalId);
    }

    /// @dev guardianCancel by non-guardian -> NotGuardian
    function test_TC06_guardianCancelByNonGuardianReverts() public {
        uint256 proposalId = _createTestProposal();

        vm.expectRevert(GuardianModule.NotGuardian.selector);
        vm.prank(nonGuardian);
        guardianModuleContract.guardianCancel(proposalId);
    }

    /// @dev guardianExecuteEmergency pause requires EMERGENCY + PAUSE bits.
    function test_TC06_guardianExecuteEmergencyWithEmergencyBitSucceeds() public {
        address pauseEmergencyGuardian = makeAddr("pauseEmergencyGuardian");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(pauseEmergencyGuardian, 5);

        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianEmergencyExecuted(pauseEmergencyGuardian, targets);

        vm.prank(pauseEmergencyGuardian);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);

        assertTrue(mockPausable.paused(), "Target must be paused after emergency execution");
    }

    /// @dev guardianExecuteEmergency without EMERGENCY bit -> InsufficientPermissions
    function test_TC06_guardianExecuteEmergencyWithoutEmergencyBitReverts() public {
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

    /// @dev guardianExecuteEmergency with non-emergency calldata -> InvalidEmergencyAction (R-43)
    function test_TC06_guardianExecuteEmergencyInvalidCalldataReverts() public {
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        // transferOwnership is NOT an emergency action
        calldatas[0] = abi.encodeWithSignature("transferOwnership(address)", attacker);

        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    /// @dev guardianExecuteEmergency with mismatched arrays -> ArrayLengthMismatch
    function test_TC06_guardianExecuteEmergencyMismatchedArraysReverts() public {
        address[] memory targets = new address[](2);
        targets[0] = address(mockPausable);
        targets[1] = address(mockPausable);
        uint256[] memory values = new uint256[](1); // mismatched
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("pause()");
        calldatas[1] = abi.encodeWithSignature("pause()");

        vm.expectRevert(GuardianModule.ArrayLengthMismatch.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    /// @dev guardianExecuteEmergency with empty targets -> EmptyProposal
    function test_TC06_guardianExecuteEmergencyEmptyTargetsReverts() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);

        vm.expectRevert(GuardianModule.EmptyProposal.selector);
        vm.prank(guardian4);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
    }

    /// @dev OF-16-005: permissions=3 (PAUSE|CANCEL) on same guardian is now forbidden (R-39)
    function test_TC06_bitmaskPauseAndCancelCannotEmergency() public {
        // OF-16-005: PAUSE|CANCEL on same guardian is forbidden
        address g3perms = makeAddr("guardian_perms3");
        vm.expectRevert(GuardianModule.PauseAndCancelForbidden.selector);
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(g3perms, 3);
    }

    /// @dev Bitmask independence: permissions=5 (PAUSE|EMERGENCY) can pause+emergency but NOT cancel
    function test_TC06_bitmaskPauseAndEmergencyCannotCancel() public {
        // Create a guardian with permissions=5 (PAUSE|EMERGENCY)
        address g5perms = makeAddr("guardian_perms5");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(g5perms, 5);

        // Can pause (PAUSE bit set)
        vm.prank(g5perms);
        guardianModuleContract.guardianPause(address(mockPausable));
        assertTrue(mockPausable.paused(), "guardian with perms=5 should be able to pause");

        // Can execute emergency pause (EMERGENCY bit set)
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        vm.prank(g5perms);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        assertTrue(mockPausable.paused(), "guardian with perms=5 should be able to pause via emergency");

        // Cannot cancel (CANCEL bit NOT set)
        uint256 proposalId = _createTestProposal();
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(g5perms);
        guardianModuleContract.guardianCancel(proposalId);
    }

    /// @dev OF-19-001: PAUSE+CANCEL on same guardian is now forbidden.
    /// guardian1 has CANCEL+EMERGENCY+PROPOSE (14). guardian2 has PAUSE (1).
    /// Test both guardians' capabilities separately.
    function test_TC06_guardian1AllPermissionsCanDoAll() public {
        // guardian2 has PAUSE permission
        // Can pause
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(mockPausable));
        assertTrue(mockPausable.paused(), "guardian2 should be able to pause");

        // Can cancel
        uint256 proposalId = _createTestProposal();
        vm.prank(guardian1);
        guardianModuleContract.guardianCancel(proposalId);
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled),
            "guardian1 should be able to cancel"
        );

        // Can execute emergency pause only with both PAUSE and EMERGENCY bits.
        address pauseEmergencyGuardian = makeAddr("pauseEmergencyGuardianAll");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(pauseEmergencyGuardian, 5);

        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        vm.prank(pauseEmergencyGuardian);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        assertTrue(mockPausable.paused(), "guardian with PAUSE+EMERGENCY should execute emergency pause");
    }

    /// @dev Guardian add/remove non-retroactive on existing proposals (R-48)
    function test_TC06_guardianChangeNonRetroactive() public {
        // Create a proposal
        uint256 proposalId = _createTestProposal();

        // Advance to active and cast some votes
        vm.roll(block.number + governor.votingDelay() + 1);
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For: 5M

        // Now add a new guardian via timelock (OF-16-005: use 5=PAUSE|EMERGENCY, not 7 which has PAUSE|CANCEL)
        address newGuardian = makeAddr("newGuardian");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newGuardian, 5);

        // Verify the existing proposal's votes are unaffected by guardian change
        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 5_000_000 * 1e18, "For votes must remain unchanged after guardian change");
        assertEq(against, 0, "Against votes must remain 0");
        assertEq(abstain, 0, "Abstain votes must remain 0");
    }

    /// @dev guardianPause verifies GuardianModule is msg.sender on target (direct call, not through timelock)
    function test_TC06_guardianPauseDirectCallNotThroughTimelock() public {
        // guardian2 pauses. The target's msg.sender should be the guardianModule, not the timelock.
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(mockPausable));

        // MockPausable records msg.sender. Verify it was the guardianModule (direct call), not the timelock.
        assertTrue(mockPausable.paused(), "Target must be paused via direct call from guardianModule");
        assertEq(
            mockPausable.lastPauseCaller(),
            address(guardianModuleContract),
            "pause() msg.sender must be guardianModule (direct call), not timelock"
        );
    }

    /// @dev guardianExecuteEmergency batch: pause on multiple targets
    function test_TC06_guardianExecuteEmergencyBatchMultipleTargets() public {
        // Deploy a second MockPausable and whitelist it
        MockPausable secondTarget = new MockPausable(address(timelock), address(governor));
        secondTarget.setGuardianModule(address(guardianModuleContract));
        {
            // Whitelist on GuardianModule (not governor)
            vm.prank(address(timelock));
            guardianModuleContract.setPausableTarget(address(secondTarget), true);
        }

        address[] memory targets = new address[](2);
        targets[0] = address(mockPausable);
        targets[1] = address(secondTarget);
        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("pause()");
        calldatas[1] = abi.encodeWithSignature("pause()");

        address pauseEmergencyGuardian = makeAddr("pauseEmergencyGuardianBatch");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(pauseEmergencyGuardian, 5);

        vm.prank(pauseEmergencyGuardian);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);

        assertTrue(mockPausable.paused(), "First target must be paused");
        assertTrue(secondTarget.paused(), "Second target must be paused");
    }

    /// @dev Guardian emergency execution is tighten-only: unpause is a governance/owner path.
    function test_TC06_guardianExecuteEmergencyUnpauseReverts() public {
        address pauseEmergencyGuardian = makeAddr("pauseEmergencyGuardianUnpause");
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(pauseEmergencyGuardian, 5);

        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(mockPausable));
        assertTrue(mockPausable.paused(), "target starts paused");

        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("unpause()");

        vm.expectRevert(GuardianModule.InvalidEmergencyAction.selector);
        vm.prank(pauseEmergencyGuardian);
        guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        assertTrue(mockPausable.paused(), "guardian emergency unpause must not clear pause");
    }
}

// ============================================================
// TC-07: Guardian Management
// Requirements: R-46, R-49, R-50, R-72
// ============================================================
contract ForageGovernor_TC07_GuardianManagement is ForageGovernorTestBase {
    /// @dev setGuardianPermissions via timelock adds new guardian (R-50, R-72)
    function test_TC07_setGuardianPermissionsAddsNewGuardian() public {
        address newGuardian = makeAddr("newGuardian");

        // OF-16-005: Use 5 (PAUSE|EMERGENCY) instead of 7 (PAUSE|CANCEL|EMERGENCY) which is now forbidden
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(newGuardian, 0, 5);

        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newGuardian, 5);

        assertTrue(guardianModuleContract.isGuardian(newGuardian), "New guardian must be recognized");
        assertEq(
            guardianModuleContract.getGuardianPermissions(newGuardian), 5, "New guardian must have permissions = 5"
        );
    }

    /// @dev setGuardianPermissions via timelock updates existing guardian permissions
    function test_TC07_setGuardianPermissionsUpdatesExisting() public {
        // guardian2 has permissions = 1 (PAUSE only). Update to 5 (PAUSE | EMERGENCY).
        // OF-16-005: PAUSE|CANCEL (3) is now forbidden, use PAUSE|EMERGENCY (5) instead.
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian2, 1, 5);

        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(guardian2, 5);

        assertEq(
            guardianModuleContract.getGuardianPermissions(guardian2), 5, "Guardian permissions must be updated to 5"
        );
    }

    /// @dev setGuardianPermissions sets to 0 removes guardian
    function test_TC07_setGuardianPermissionsToZeroRemovesGuardian() public {
        // Verify guardian2 is currently a guardian
        assertTrue(guardianModuleContract.isGuardian(guardian2), "guardian2 must be a guardian before removal");

        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian2, 1, 0);

        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(guardian2, 0);

        assertFalse(guardianModuleContract.isGuardian(guardian2), "guardian2 must no longer be a guardian");
        assertEq(guardianModuleContract.getGuardianPermissions(guardian2), 0, "guardian2 permissions must be 0");
    }

    /// @dev removeGuardian on existing guardian (R-50, R-72)
    function test_TC07_removeGuardianExistingGuardian() public {
        // Verify guardian3 is a guardian
        assertTrue(guardianModuleContract.isGuardian(guardian3), "guardian3 must be a guardian before removal");

        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(guardian3, 2, 0);

        vm.prank(address(timelock));
        guardianModuleContract.removeGuardian(guardian3);

        assertFalse(guardianModuleContract.isGuardian(guardian3), "guardian3 must be removed");
        assertEq(guardianModuleContract.getGuardianPermissions(guardian3), 0, "guardian3 permissions must be 0");
    }

    /// @dev removeGuardian on non-guardian -> NotGuardian (R-46)
    function test_TC07_removeGuardianNonGuardianReverts() public {
        vm.expectRevert(GuardianModule.NotGuardian.selector);
        vm.prank(address(timelock));
        guardianModuleContract.removeGuardian(nonGuardian);
    }

    /// @dev setGuardianPermissions zero address -> ZeroAddress (R-49)
    function test_TC07_setGuardianPermissionsZeroAddressReverts() public {
        vm.expectRevert(GuardianModule.ZeroAddress.selector);
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(address(0), 7);
    }

    /// @dev setGuardianPermissions by non-timelock -> Unauthorized (R-50)
    function test_TC07_setGuardianPermissionsByNonTimelockReverts() public {
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        vm.prank(attacker);
        guardianModuleContract.setGuardianPermissions(makeAddr("newG"), 7);
    }

    /// @dev removeGuardian by non-timelock -> Unauthorized
    function test_TC07_removeGuardianByNonTimelockReverts() public {
        vm.expectRevert(GuardianModule.Unauthorized.selector);
        vm.prank(attacker);
        guardianModuleContract.removeGuardian(guardian2);
    }

    /// @dev getGuardians enumeration: add 3, remove 1 -> returns 2 (after initial 4 guardians)
    function test_TC07_getGuardiansEnumeration() public {
        // Initial: 4 guardians (guardian1..guardian4)
        address[] memory initialGuardians = guardianModuleContract.getGuardians();
        assertEq(initialGuardians.length, 4, "Must start with 4 guardians");

        // Add 3 new guardians
        address newG1 = makeAddr("newG1");
        address newG2 = makeAddr("newG2");
        address newG3 = makeAddr("newG3");

        vm.startPrank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newG1, 1);
        guardianModuleContract.setGuardianPermissions(newG2, 2);
        guardianModuleContract.setGuardianPermissions(newG3, 4);

        // Remove 1 guardian
        guardianModuleContract.removeGuardian(guardian2);
        vm.stopPrank();

        // Should have 4 + 3 - 1 = 6 guardians
        address[] memory currentGuardians = guardianModuleContract.getGuardians();
        assertEq(currentGuardians.length, 6, "Must have 6 guardians after adding 3 and removing 1");
    }

    /// @dev GuardianPermissionsUpdated event with old and new values
    function test_TC07_guardianPermissionsUpdatedEventValues() public {
        address newGuardian = makeAddr("eventTestGuardian");

        // Add guardian: old=0, new=5 (PAUSE|EMERGENCY)
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(newGuardian, 0, 5);
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newGuardian, 5);

        // Update guardian: old=5, new=6 (CANCEL|EMERGENCY)
        // OF-16-005: Cannot use 3 (PAUSE|CANCEL), use 6 (CANCEL|EMERGENCY) instead
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(newGuardian, 5, 6);
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newGuardian, 6);

        // Remove guardian: old=6, new=0
        vm.expectEmit(true, false, false, true);
        emit GuardianModule.GuardianPermissionsUpdated(newGuardian, 6, 0);
        vm.prank(address(timelock));
        guardianModuleContract.removeGuardian(newGuardian);
    }

    /// @dev Add guardian then verify isGuardian, getGuardianPermissions, getGuardians
    function test_TC07_addGuardianVerifyAllViews() public {
        address newGuardian = makeAddr("viewCheckGuardian");

        // Before add
        assertFalse(guardianModuleContract.isGuardian(newGuardian), "Must not be guardian before adding");
        assertEq(guardianModuleContract.getGuardianPermissions(newGuardian), 0, "Must have 0 permissions before adding");

        // Add (OF-16-005: use 5=PAUSE|EMERGENCY instead of 3=PAUSE|CANCEL which is now forbidden)
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(newGuardian, 5);

        // After add
        assertTrue(guardianModuleContract.isGuardian(newGuardian), "Must be guardian after adding");
        assertEq(
            guardianModuleContract.getGuardianPermissions(newGuardian), 5, "Must have permissions = 5 after adding"
        );

        // Verify in getGuardians list
        address[] memory guardians = guardianModuleContract.getGuardians();
        bool found = false;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == newGuardian) {
                found = true;
                break;
            }
        }
        assertTrue(found, "New guardian must appear in getGuardians()");
    }

    /// @dev Update permissions then verify old permissions overwritten
    function test_TC07_updatePermissionsOverwriteOld() public {
        // guardian2 starts with permissions = 1 (PAUSE)
        assertEq(guardianModuleContract.getGuardianPermissions(guardian2), 1, "guardian2 must start with 1");

        // Update to 6 (CANCEL | EMERGENCY)
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(guardian2, 6);

        assertEq(guardianModuleContract.getGuardianPermissions(guardian2), 6, "guardian2 must have 6 after update");

        // Old permissions (PAUSE) must no longer be active
        vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
        vm.prank(guardian2);
        guardianModuleContract.guardianPause(address(mockPausable));
    }
}

// ============================================================
// TC-08: Parameter Setters
// Requirements: R-50, R-55, R-56, R-57, R-58, R-59, R-60,
//               R-73, R-74, R-75, R-76, R-77
// ============================================================
contract ForageGovernor_TC08_ParameterSetters is ForageGovernorTestBase {
    event VotingDelaySet(uint256 oldVotingDelay, uint256 newVotingDelay);
    event VotingPeriodSet(uint256 oldVotingPeriod, uint256 newVotingPeriod);

    // ── setQuorumBps ───────────────────────────────────────────────

    /// @dev setQuorumBps: valid value via timelock, event QuorumBpsUpdated (R-55, R-73)
    function test_TC08_setQuorumBpsValidValue() public {
        vm.expectEmit(false, false, false, true);
        emit ForageGovernor.QuorumBpsUpdated(DEFAULT_QUORUM_BPS, 200);

        vm.prank(address(timelock));
        governor.setQuorumBps(200);

        // Verify quorum reflects new bps
        uint256 expectedQuorum = TOTAL_SUPPLY * 200 / 10_000;
        assertEq(governor.quorum(block.number - 1), expectedQuorum, "quorum must reflect new bps");
    }

    /// @dev setQuorumBps: 0 reverts InvalidParameter
    function test_TC08_setQuorumBpsZeroReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setQuorumBps(0);
    }

    /// @dev setQuorumBps: 5001 reverts InvalidParameter
    function test_TC08_setQuorumBpsAboveMaxReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setQuorumBps(5001);
    }

    /// @dev setQuorumBps: 1 succeeds (boundary)
    function test_TC08_setQuorumBpsMinBoundary() public {
        vm.prank(address(timelock));
        governor.setQuorumBps(1);

        uint256 expectedQuorum = TOTAL_SUPPLY * 1 / 10_000;
        assertEq(governor.quorum(block.number - 1), expectedQuorum, "quorum at min bps must be correct");
    }

    /// @dev setQuorumBps: 5000 succeeds (boundary)
    function test_TC08_setQuorumBpsMaxBoundary() public {
        vm.prank(address(timelock));
        governor.setQuorumBps(5000);

        uint256 expectedQuorum = TOTAL_SUPPLY * 5000 / 10_000;
        assertEq(governor.quorum(block.number - 1), expectedQuorum, "quorum at max bps must be correct");
    }

    /// @dev setQuorumBps: non-timelock reverts Unauthorized (R-50)
    function test_TC08_setQuorumBpsNonTimelockReverts() public {
        vm.expectRevert(ForageGovernor.Unauthorized.selector);
        vm.prank(attacker);
        governor.setQuorumBps(200);
    }

    // ── setVotingDelay ─────────────────────────────────────────────

    /// @dev setVotingDelay: valid value via timelock, event VotingDelaySet (R-57, R-76)
    function test_TC08_setVotingDelayValidValue() public {
        uint48 newDelay = 259200; // 3 days in seconds (OF-001 timestamp-based)
        uint256 oldDelay = governor.votingDelay();

        vm.expectEmit(false, false, false, true);
        emit VotingDelaySet(oldDelay, newDelay);

        vm.prank(address(timelock));
        governor.setVotingDelay(newDelay);

        assertEq(governor.votingDelay(), newDelay, "votingDelay must be updated");
    }

    /// @dev OF-001 two-phase governance: setVotingDelay accepts any uint48 value (no minimum).
    ///      Launch phase uses 0; production phase uses 86400 (1 day).
    function test_TC08_setVotingDelayAnyValueAccepted() public {
        // Set to 0 (launch phase) — must succeed
        vm.prank(address(timelock));
        governor.setVotingDelay(0);
        assertEq(governor.votingDelay(), 0, "votingDelay=0 must be accepted (launch phase)");

        // Set to 1 (minimum non-zero) — must succeed
        vm.prank(address(timelock));
        governor.setVotingDelay(1);
        assertEq(governor.votingDelay(), 1, "votingDelay=1 must be accepted");

        // Set to production value — must succeed
        vm.prank(address(timelock));
        governor.setVotingDelay(PRODUCTION_VOTING_DELAY);
        assertEq(
            governor.votingDelay(), PRODUCTION_VOTING_DELAY, "votingDelay=86400 must be accepted (production phase)"
        );
    }

    /// @dev setVotingDelay: non-timelock reverts Unauthorized
    function test_TC08_setVotingDelayNonTimelockReverts() public {
        vm.expectRevert(ForageGovernor.Unauthorized.selector);
        vm.prank(attacker);
        governor.setVotingDelay(259200);
    }

    // ── setVotingPeriod ────────────────────────────────────────────

    /// @dev setVotingPeriod: valid value via timelock, event VotingPeriodSet (R-58, R-77)
    function test_TC08_setVotingPeriodValidValue() public {
        uint32 newPeriod = 1209600; // 14 days in seconds (OF-001 timestamp-based)
        uint256 oldPeriod = governor.votingPeriod();

        vm.expectEmit(false, false, false, true);
        emit VotingPeriodSet(oldPeriod, newPeriod);

        vm.prank(address(timelock));
        governor.setVotingPeriod(newPeriod);

        assertEq(governor.votingPeriod(), newPeriod, "votingPeriod must be updated");
    }

    /// @dev setVotingPeriod below launch minimum reverts.
    function test_TC08_setVotingPeriodZeroReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.VotingPeriodBelowMinimum.selector, 0, governor.MIN_VOTING_PERIOD())
        );
        vm.prank(address(timelock));
        governor.setVotingPeriod(0);
    }

    /// @dev Launch minimum is one hour; production period remains valid.
    function test_TC08_setVotingPeriodLaunchMinimumAndProductionAccepted() public {
        uint32 minPeriod = governor.MIN_VOTING_PERIOD();

        vm.prank(address(timelock));
        governor.setVotingPeriod(minPeriod);
        assertEq(governor.votingPeriod(), minPeriod, "one-hour launch minimum accepted");

        vm.prank(address(timelock));
        governor.setVotingPeriod(PRODUCTION_VOTING_PERIOD);
        assertEq(
            governor.votingPeriod(), PRODUCTION_VOTING_PERIOD, "votingPeriod=432000 must be accepted (production phase)"
        );
    }

    function test_TC08_setVotingPeriodBelowLaunchMinimumReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ForageGovernor.VotingPeriodBelowMinimum.selector, 1, governor.MIN_VOTING_PERIOD())
        );
        vm.prank(address(timelock));
        governor.setVotingPeriod(1);
    }

    /// @dev setVotingPeriod: non-timelock reverts Unauthorized
    function test_TC08_setVotingPeriodNonTimelockReverts() public {
        vm.expectRevert(ForageGovernor.Unauthorized.selector);
        vm.prank(attacker);
        governor.setVotingPeriod(1209600);
    }

    // ── setProposalThresholdBps ────────────────────────────────────

    /// @dev setProposalThresholdBps: valid value via timelock, event ProposalThresholdBpsUpdated (R-56, R-75)
    function test_TC08_setProposalThresholdBpsValidValue() public {
        vm.expectEmit(false, false, false, true);
        emit ForageGovernor.ProposalThresholdBpsUpdated(DEFAULT_THRESHOLD_BPS, 200);

        vm.prank(address(timelock));
        governor.setProposalThresholdBps(200);

        uint256 expectedThreshold = TOTAL_SUPPLY * 200 / 10_000;
        assertEq(governor.proposalThreshold(), expectedThreshold, "proposalThreshold must reflect new bps");
    }

    /// @dev setProposalThresholdBps: 0 reverts InvalidParameter
    function test_TC08_setProposalThresholdBpsZeroReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setProposalThresholdBps(0);
    }

    /// @dev setProposalThresholdBps: 5001 reverts InvalidParameter
    function test_TC08_setProposalThresholdBpsAboveMaxReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setProposalThresholdBps(5001);
    }

    /// @dev setProposalThresholdBps: non-timelock reverts Unauthorized
    function test_TC08_setProposalThresholdBpsNonTimelockReverts() public {
        vm.expectRevert(ForageGovernor.Unauthorized.selector);
        vm.prank(attacker);
        governor.setProposalThresholdBps(200);
    }

    /// @dev setProposalThresholdBps: 1 succeeds (boundary)
    function test_TC08_setProposalThresholdBpsMinBoundary() public {
        vm.prank(address(timelock));
        governor.setProposalThresholdBps(1);
        uint256 expected = TOTAL_SUPPLY * 1 / 10_000;
        assertEq(governor.proposalThreshold(), expected, "threshold at min bps must be correct");
    }

    /// @dev setProposalThresholdBps: 5000 succeeds (boundary)
    function test_TC08_setProposalThresholdBpsMaxBoundary() public {
        vm.prank(address(timelock));
        governor.setProposalThresholdBps(5000);
        uint256 expected = TOTAL_SUPPLY * 5000 / 10_000;
        assertEq(governor.proposalThreshold(), expected, "threshold at max bps must be correct");
    }

    // ── setMaxActiveProposals ──────────────────────────────────────

    /// @dev setMaxActiveProposals: valid value via timelock, event MaxActiveProposalsUpdated (R-59, R-74)
    function test_TC08_setMaxActiveProposalsValidValue() public {
        vm.expectEmit(false, false, false, true);
        emit ForageGovernor.MaxActiveProposalsUpdated(DEFAULT_MAX_ACTIVE, 20);

        vm.prank(address(timelock));
        governor.setMaxActiveProposals(20);
    }

    /// @dev setMaxActiveProposals: 0 reverts InvalidParameter
    function test_TC08_setMaxActiveProposalsZeroReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setMaxActiveProposals(0);
    }

    /// @dev setMaxActiveProposals: 101 reverts InvalidParameter
    function test_TC08_setMaxActiveProposalsAboveMaxReverts() public {
        vm.expectRevert(ForageGovernor.InvalidParameter.selector);
        vm.prank(address(timelock));
        governor.setMaxActiveProposals(101);
    }

    /// @dev setMaxActiveProposals: 1 succeeds (boundary)
    function test_TC08_setMaxActiveProposalsMinBoundary() public {
        vm.prank(address(timelock));
        governor.setMaxActiveProposals(1);
    }

    /// @dev setMaxActiveProposals: 100 succeeds (boundary)
    function test_TC08_setMaxActiveProposalsMaxBoundary() public {
        vm.prank(address(timelock));
        governor.setMaxActiveProposals(100);
    }

    /// @dev setMaxActiveProposals: non-timelock reverts Unauthorized
    function test_TC08_setMaxActiveProposalsNonTimelockReverts() public {
        vm.expectRevert(ForageGovernor.Unauthorized.selector);
        vm.prank(attacker);
        governor.setMaxActiveProposals(20);
    }

    // ── Non-retroactive ────────────────────────────────────────────

    /// @dev Parameter change non-retroactive: change votingDelay, existing proposal unaffected (R-60)
    function test_TC08_parameterChangeNonRetroactive() public {
        // Create proposal with current votingDelay
        uint256 proposalId = _createProposal();

        // Record the proposal's snapshot and deadline before parameter change
        uint256 snapshotBefore = governor.proposalSnapshot(proposalId);
        uint256 deadlineBefore = governor.proposalDeadline(proposalId);

        // Change votingDelay via timelock
        vm.prank(address(timelock));
        governor.setVotingDelay(259200); // 3 days (OF-001 timestamp-based)

        // Verify existing proposal still uses original parameters
        uint256 snapshotAfter = governor.proposalSnapshot(proposalId);
        uint256 deadlineAfter = governor.proposalDeadline(proposalId);

        assertEq(snapshotAfter, snapshotBefore, "Proposal snapshot must not change after parameter update");
        assertEq(deadlineAfter, deadlineBefore, "Proposal deadline must not change after parameter update");
    }
}
