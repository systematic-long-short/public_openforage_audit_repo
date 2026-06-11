// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";

// ============================================================
// TC-16: Fuzz Tests
// Requirements: R-14, R-18, R-33, R-34, R-55, R-56, R-57,
//               R-58, R-59, R-63
// NOTE: Since setUp relies on ForageGovernor.initialize() which
//       is a stub, these tests will fail during setUp (expected).
//       Once the implementation exists, fuzz tests will exercise
//       correctness across a wide range of inputs.
// ============================================================
contract ForageGovernor_TC16_FuzzTests is ForageGovernorTestBase {
    // ── Fuzz 1: Voting Power at Snapshot (R-18, R-63) ──────────────────

    /// @dev Fuzz balance in [0, deployer balance]. Delegate to self. Create proposal.
    ///      Verify getVotes at snapshot == balance.
    function testFuzz_votingPowerAtSnapshot(uint256 balance) external {
        uint256 deployerBalance = token.balanceOf(deployer);
        balance = bound(balance, 0, deployerBalance);

        // Transfer from deployer (who has the remainder tokens) to a fresh account
        address fuzzer = makeAddr("fuzzer");
        vm.prank(deployer);
        token.transfer(fuzzer, balance);
        vm.prank(fuzzer);
        token.delegate(fuzzer);
        vm.roll(block.number + 1); // checkpoint

        // Create proposal from proposer (who has threshold)
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance to snapshot
        vm.roll(snapshotBlock + 1);

        // Verify voting power at snapshot equals transferred balance
        uint256 power = token.getPastVotes(fuzzer, snapshotBlock);
        assertEq(power, balance, "Voting power at snapshot must equal token balance");
    }

    // ── Fuzz 2: Quorum Calculation (R-33, R-34) ────────────────────────

    /// @dev Fuzz quorumBps in [1, 5000]. Deploy fresh governor with fuzzed quorumBps.
    ///      Verify quorum == totalSupply * quorumBps / 10000.
    function testFuzz_quorumCalculation(uint256 quorumBps) external {
        quorumBps = bound(quorumBps, 1, 5000);

        // Set the quorum to fuzzed value
        vm.prank(address(timelock));
        governor.setQuorumBps(quorumBps);

        // Verify quorum calculation
        uint256 expectedQuorum = TOTAL_SUPPLY * quorumBps / 10_000;
        uint256 actualQuorum = governor.quorum(block.number - 1);
        assertEq(actualQuorum, expectedQuorum, "quorum must equal totalSupply * quorumBps / 10000");
    }

    // ── Fuzz 3: Proposal Threshold Calculation (R-14, R-56) ────────────

    /// @dev Fuzz thresholdBps in [1, 5000]. Verify proposalThreshold == totalSupply * thresholdBps / 10000.
    function testFuzz_proposalThresholdCalculation(uint256 thresholdBps) external {
        thresholdBps = bound(thresholdBps, 1, 5000);

        // Set threshold to fuzzed value
        vm.prank(address(timelock));
        governor.setProposalThresholdBps(thresholdBps);

        // Verify threshold calculation
        uint256 expectedThreshold = TOTAL_SUPPLY * thresholdBps / 10_000;
        uint256 actualThreshold = governor.proposalThreshold();
        assertEq(actualThreshold, expectedThreshold, "proposalThreshold must equal totalSupply * thresholdBps / 10000");
    }

    // ── Fuzz 4: Parameter Bounds — QuorumBps (R-55) ────────────────────

    /// @dev Fuzz quorumBps across full uint256 range.
    ///      If [1, 5000]: setQuorumBps succeeds. If outside: reverts InvalidParameter.
    function testFuzz_parameterBoundsQuorum(uint256 quorumBps) external {
        if (quorumBps >= 1 && quorumBps <= 5000) {
            // Should succeed
            vm.prank(address(timelock));
            governor.setQuorumBps(quorumBps);

            uint256 expectedQuorum = TOTAL_SUPPLY * quorumBps / 10_000;
            assertEq(governor.quorum(block.number - 1), expectedQuorum, "quorum must match after valid setQuorumBps");
        } else {
            // Should revert
            vm.expectRevert(ForageGovernor.InvalidParameter.selector);
            vm.prank(address(timelock));
            governor.setQuorumBps(quorumBps);
        }
    }

    // ── Fuzz 5: Parameter Bounds — ThresholdBps (R-56) ─────────────────

    /// @dev Fuzz thresholdBps across full uint256 range.
    ///      If [1, 5000]: setProposalThresholdBps succeeds. If outside: reverts InvalidParameter.
    function testFuzz_parameterBoundsThreshold(uint256 thresholdBps) external {
        if (thresholdBps >= 1 && thresholdBps <= 5000) {
            vm.prank(address(timelock));
            governor.setProposalThresholdBps(thresholdBps);

            uint256 expectedThreshold = TOTAL_SUPPLY * thresholdBps / 10_000;
            assertEq(governor.proposalThreshold(), expectedThreshold, "threshold must match after valid set");
        } else {
            vm.expectRevert(ForageGovernor.InvalidParameter.selector);
            vm.prank(address(timelock));
            governor.setProposalThresholdBps(thresholdBps);
        }
    }

    // ── Fuzz 6: Parameter Bounds — VotingDelay (R-57) ──────────────────

    /// @dev Fuzz votingDelay across uint48 range.
    ///      OF-001: No hardcoded minimum — all uint48 values are accepted.
    ///      Launch phase uses 0; production phase uses 86400 (1 day).
    function testFuzz_parameterBoundsVotingDelay(uint48 votingDelay_) external {
        // All uint48 values should succeed (no minimum enforced)
        vm.prank(address(timelock));
        governor.setVotingDelay(votingDelay_);
        assertEq(governor.votingDelay(), votingDelay_, "votingDelay must be updated to fuzzed value");
    }

    // ── Fuzz 7: Parameter Bounds — VotingPeriod (R-58) ─────────────────

    /// @dev Fuzz votingPeriod across uint32 range.
    ///      Launch phase uses 3600 (1h); production phase uses 432000 (5d).
    function testFuzz_parameterBoundsVotingPeriod(uint32 votingPeriod_) external {
        uint32 minPeriod = governor.MIN_VOTING_PERIOD();
        if (votingPeriod_ >= minPeriod) {
            vm.prank(address(timelock));
            governor.setVotingPeriod(votingPeriod_);
            assertEq(governor.votingPeriod(), votingPeriod_, "votingPeriod must be updated to fuzzed value");
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ForageGovernor.VotingPeriodBelowMinimum.selector, votingPeriod_, governor.MIN_VOTING_PERIOD()
                )
            );
            vm.prank(address(timelock));
            governor.setVotingPeriod(votingPeriod_);
        }
    }

    // ── Fuzz 8: Parameter Bounds — MaxActiveProposals (R-59) ───────────

    /// @dev Fuzz maxActive across full uint256 range.
    ///      If [1, 100]: succeeds. If outside: reverts InvalidParameter.
    function testFuzz_parameterBoundsMaxActive(uint256 maxActive) external {
        if (maxActive >= 1 && maxActive <= 100) {
            vm.prank(address(timelock));
            governor.setMaxActiveProposals(maxActive);
            // Setter succeeds -- no revert
        } else {
            vm.expectRevert(ForageGovernor.InvalidParameter.selector);
            vm.prank(address(timelock));
            governor.setMaxActiveProposals(maxActive);
        }
    }

    // ── Fuzz 9: Guardian Permission Bitmask (R-39) ─────────────────────

    /// @dev Fuzz permissions. Handles OF-16-014 (InvalidPermissionBitmask for > MAX_VALID_PERMISSIONS),
    ///      OF-16-005 (PauseAndCancelForbidden when both PAUSE and CANCEL bits set), and valid bitmasks.
    ///      Pause/unpause emergency actions require both PAUSE and EMERGENCY bits.
    function testFuzz_guardianPermissionBitmask(uint256 permissions) external {
        address fuzzGuardian = makeAddr("fuzzGuardian");

        // Cache MAX_VALID_PERMISSIONS before vm.prank (view calls consume prank)
        uint256 maxValid = guardianModuleContract.MAX_VALID_PERMISSIONS();
        bool hasPause = (permissions & 1) != 0;
        bool hasCancel = (permissions & 2) != 0;

        // OF-16-014: permissions > MAX_VALID_PERMISSIONS must revert
        if (permissions > maxValid) {
            vm.expectRevert(GuardianModule.InvalidPermissionBitmask.selector);
            vm.prank(address(timelock));
            guardianModuleContract.setGuardianPermissions(fuzzGuardian, permissions);
            return;
        }

        // OF-16-005: PAUSE|CANCEL on same guardian is forbidden
        if (hasPause && hasCancel) {
            vm.expectRevert(GuardianModule.PauseAndCancelForbidden.selector);
            vm.prank(address(timelock));
            guardianModuleContract.setGuardianPermissions(fuzzGuardian, permissions);
            return;
        }

        // Valid permission: set guardian
        vm.prank(address(timelock));
        guardianModuleContract.setGuardianPermissions(fuzzGuardian, permissions);

        // isGuardian should be true iff permissions != 0
        bool expectedIsGuardian = permissions != 0;
        assertEq(
            guardianModuleContract.isGuardian(fuzzGuardian),
            expectedIsGuardian,
            "isGuardian must equal (permissions != 0)"
        );

        // Verify stored permissions
        assertEq(
            guardianModuleContract.getGuardianPermissions(fuzzGuardian),
            permissions,
            "getGuardianPermissions must return the exact fuzzed value"
        );

        bool hasEmergency = (permissions & 4) != 0;

        if (permissions == 0) {
            // Non-guardian must get NotGuardian on all guardian functions
            vm.expectRevert(GuardianModule.NotGuardian.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianPause(address(mockPausable));

            uint256 proposalId = _createProposal();
            vm.expectRevert(GuardianModule.NotGuardian.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianCancel(proposalId);

            address[] memory emTargets = new address[](1);
            emTargets[0] = address(mockPausable);
            uint256[] memory emValues = new uint256[](1);
            emValues[0] = 0;
            bytes[] memory emCalldatas = new bytes[](1);
            emCalldatas[0] = abi.encodeWithSignature("pause()");

            vm.expectRevert(GuardianModule.NotGuardian.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianExecuteEmergency(emTargets, emValues, emCalldatas);
            return;
        }

        // Test PAUSE capability
        if (hasPause) {
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianPause(address(mockPausable));
        } else {
            vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianPause(address(mockPausable));
        }

        // Test CANCEL capability (need a proposal to cancel)
        uint256 proposalId = _createProposal();
        if (hasCancel) {
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianCancel(proposalId);
        } else {
            vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianCancel(proposalId);
        }

        // Test EMERGENCY capability
        address[] memory targets = new address[](1);
        targets[0] = address(mockPausable);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("pause()");

        if (hasEmergency && hasPause) {
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        } else {
            vm.expectRevert(GuardianModule.InsufficientPermissions.selector);
            vm.prank(fuzzGuardian);
            guardianModuleContract.guardianExecuteEmergency(targets, values, calldatas);
        }
    }

    // ── Fuzz 10: Vote Count Integrity (R-63) ──────────────────────────

    /// @dev Fuzz for/against/abstain weights. Multiple voters cast votes.
    ///      Verify proposalVotes() returns exact sums. No overflow for realistic values.
    function testFuzz_voteCountIntegrity(uint256 forWeight, uint256 againstWeight, uint256 abstainWeight) external {
        // Bound weights to be reasonable (each voter can have at most some portion of supply)
        // We distribute among 3 fresh voters to avoid interfering with existing setup
        forWeight = bound(forWeight, 0, 30_000_000 * 1e18);
        againstWeight = bound(againstWeight, 0, 30_000_000 * 1e18);
        abstainWeight = bound(abstainWeight, 0, 30_000_000 * 1e18);

        // Skip if total exceeds what deployer can transfer
        uint256 totalNeeded = forWeight + againstWeight + abstainWeight;
        uint256 deployerBalance = token.balanceOf(deployer);
        if (totalNeeded > deployerBalance) return;

        // Create 3 fresh voters with fuzzed balances
        address forVoter = makeAddr("forVoter");
        address againstVoter = makeAddr("againstVoter");
        address abstainVoter = makeAddr("abstainVoter");

        vm.startPrank(deployer);
        if (forWeight > 0) token.transfer(forVoter, forWeight);
        if (againstWeight > 0) token.transfer(againstVoter, againstWeight);
        if (abstainWeight > 0) token.transfer(abstainVoter, abstainWeight);
        vm.stopPrank();

        // Delegate to self
        if (forWeight > 0) {
            vm.prank(forVoter);
            token.delegate(forVoter);
        }
        if (againstWeight > 0) {
            vm.prank(againstVoter);
            token.delegate(againstVoter);
        }
        if (abstainWeight > 0) {
            vm.prank(abstainVoter);
            token.delegate(abstainVoter);
        }
        vm.roll(block.number + 1); // checkpoint

        // Create proposal and advance to active
        uint256 proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);

        // Cast votes
        if (forWeight > 0) {
            vm.prank(forVoter);
            governor.castVote(proposalId, 1); // For
        }
        if (againstWeight > 0) {
            vm.prank(againstVoter);
            governor.castVote(proposalId, 0); // Against
        }
        if (abstainWeight > 0) {
            vm.prank(abstainVoter);
            governor.castVote(proposalId, 2); // Abstain
        }

        // Verify exact vote counts
        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);

        assertEq(forVotes, forWeight, "For votes must equal exact for weight");
        assertEq(against, againstWeight, "Against votes must equal exact against weight");
        assertEq(abstain, abstainWeight, "Abstain votes must equal exact abstain weight");
    }

    // ── Fuzz 11: Threshold Enforcement (R-14) ──────────────────────────

    /// @dev Fuzz: verify proposalThreshold enforcement. Accounts below threshold cannot propose.
    function testFuzz_thresholdEnforcement(uint256 balance) external {
        balance = bound(balance, 0, token.balanceOf(deployer));

        address fuzzer = makeAddr("thresholdFuzzer");
        if (balance > 0) {
            vm.prank(deployer);
            token.transfer(fuzzer, balance);
            vm.prank(fuzzer);
            token.delegate(fuzzer);
            vm.roll(block.number + 1);
        }

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        uint256 threshold = governor.proposalThreshold();

        if (balance >= threshold) {
            // Should be able to propose
            vm.prank(fuzzer);
            uint256 proposalId = governor.propose(targets, values, calldatas, "fuzz-threshold");
            assertTrue(proposalId != 0, "Account at/above threshold must be able to propose");
        } else {
            // Should revert
            vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
            vm.prank(fuzzer);
            governor.propose(targets, values, calldatas, "fuzz-threshold");
        }
    }

    // ── Fuzz 12: Supply-Adaptation (R-33, R-55) ────────────────────────

    /// @dev Fuzz: quorum adapts correctly after burns reduce total supply.
    function testFuzz_quorumAdaptsToSupply(uint256 burnAmount) external {
        uint256 deployerBalance = token.balanceOf(deployer);
        burnAmount = bound(burnAmount, 0, deployerBalance);

        if (burnAmount > 0) {
            vm.prank(deployer);
            token.burn(burnAmount);
        }
        vm.roll(block.number + 1); // checkpoint

        uint256 newSupply = token.totalSupply();
        uint256 expectedQuorum = newSupply * DEFAULT_QUORUM_BPS / 10_000;
        uint256 actualQuorum = governor.quorum(block.number - 1);
        assertEq(actualQuorum, expectedQuorum, "quorum must adapt to new totalSupply after burn");
    }

    // ── Fuzz 13: Delegation Aggregation (R-18, R-63) ─────────────────

    /// @dev Fuzz: verify voting power aggregation when multiple delegators delegate to one delegatee.
    function testFuzz_delegationAggregation(uint256 amount1, uint256 amount2) external {
        uint256 deployerBalance = token.balanceOf(deployer);
        amount1 = bound(amount1, 1, deployerBalance / 3);
        amount2 = bound(amount2, 1, deployerBalance / 3);

        address delegator1 = makeAddr("delegator1");
        address delegator2 = makeAddr("delegator2");
        address delegatee = makeAddr("delegatee");

        // Transfer tokens to delegators
        vm.startPrank(deployer);
        token.transfer(delegator1, amount1);
        token.transfer(delegator2, amount2);
        vm.stopPrank();

        // Both delegate to the same delegatee
        vm.prank(delegator1);
        token.delegate(delegatee);
        vm.prank(delegator2);
        token.delegate(delegatee);
        vm.roll(block.number + 1); // checkpoint

        // Delegatee's voting power must equal the sum of both delegations
        uint256 delegateePower = token.getVotes(delegatee);
        assertEq(delegateePower, amount1 + amount2, "Delegatee voting power must equal sum of all delegations");

        // Each delegator has 0 voting power (delegated away)
        assertEq(token.getVotes(delegator1), 0, "Delegator1 must have 0 voting power after delegation");
        assertEq(token.getVotes(delegator2), 0, "Delegator2 must have 0 voting power after delegation");
    }
}
