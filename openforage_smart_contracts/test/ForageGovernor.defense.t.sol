// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/ForageGovernorTestBase.sol";
import "./helpers/ProposeAndVoteAttacker.sol";
import "./helpers/MockWithdrawable.sol";

// ============================================================
// TC-14: Full Governance Defense
// Requirements: R-52, R-78
// NOTE: These tests verify the defense-in-depth scenario with
//       a real TimelockController and timelock delay. Since the
//       ForageGovernor stub reverts on all custom logic, these
//       tests will fail in setUp (expected — stub not implemented).
// ============================================================
contract ForageGovernor_TC14_FullGovernanceDefense is ForageGovernorTestBase {
    /// @dev Helper: create a malicious proposal (targeting governor upgrade to attacker-controlled impl)
    function _createMaliciousProposal() internal returns (uint256, bytes32) {
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        // Malicious: upgrade to attacker-controlled implementation
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");
        string memory description = "Malicious proposal: upgrade to attacker impl";
        bytes32 descHash = keccak256(bytes(description));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        return (proposalId, descHash);
    }

    /// @dev Malicious proposal created, passes vote, queued into timelock.
    ///      Verify proposalEta is TIMELOCK_MIN_DELAY in the future (8 days).
    function test_TC14_maliciousProposalQueuedWithTimelockDelay() public {
        (uint256 proposalId, bytes32 descHash) = _createMaliciousProposal();

        // Pass the proposal
        _passProposal(proposalId);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Succeeded),
            "Proposal must be Succeeded after passing vote"
        );

        // Queue into timelock
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        governor.queue(targets, values, calldatas, descHash);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            "Proposal must be Queued after queue()"
        );

        // Verify proposalEta is 8 days in the future
        uint256 eta = governor.proposalEta(proposalId);
        assertTrue(eta > 0, "proposalEta must be non-zero after queueing");
        assertGe(
            eta - block.timestamp, TIMELOCK_MIN_DELAY, "proposalEta must be at least TIMELOCK_MIN_DELAY in the future"
        );
    }

    /// @dev During 8-day delay, depositor exit window exists.
    ///      Verify proposalEta - current time >= 8 days.
    function test_TC14_timelockDelayProvidesExitWindow() public {
        (uint256 proposalId, bytes32 descHash) = _createMaliciousProposal();
        _passProposal(proposalId);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        governor.queue(targets, values, calldatas, descHash);

        uint256 eta = governor.proposalEta(proposalId);
        uint256 exitWindow = eta - block.timestamp;

        // Exit window must be at least 8 days (TIMELOCK_MIN_DELAY = 691200 seconds)
        assertGe(exitWindow, TIMELOCK_MIN_DELAY, "Exit window must be >= 8 days");
    }

    /// @dev Guardian with CANCEL permission cancels malicious proposal during timelock window.
    function test_TC14_guardianCancelsDuringTimelockWindow() public {
        (uint256 proposalId, bytes32 descHash) = _createMaliciousProposal();
        _passProposal(proposalId);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        governor.queue(targets, values, calldatas, descHash);

        // Advance partway through timelock (3 days)
        vm.warp(block.timestamp + 3 days);

        // Guardian1 (permissions=7, includes CANCEL) cancels the malicious proposal
        vm.prank(guardian1);
        guardianModuleContract.guardianCancel(proposalId);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Canceled),
            "Proposal must be Canceled after guardian cancellation"
        );
    }

    /// @dev After cancellation, proposal state is Canceled (terminal).
    function test_TC14_canceledProposalIsTerminal() public {
        (uint256 proposalId, bytes32 descHash) = _createMaliciousProposal();
        _passProposal(proposalId);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        governor.queue(targets, values, calldatas, descHash);

        vm.prank(guardian1);
        guardianModuleContract.guardianCancel(proposalId);

        // Verify state is Canceled
        assertEq(
            uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled), "State must be Canceled"
        );

        // Try to execute -- should fail since it's canceled (governor rejects before reaching timelock)
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Canceled,
                // execute expects Succeeded(4) or Queued(5) = (1<<4)|(1<<5) = 0x30
                bytes32(uint256(0x30))
            )
        );
        governor.execute(targets, values, calldatas, descHash);
    }

    /// @dev Verify timelock delay provides genuine exit window.
    ///      proposalEta - current time >= 8 days at time of queueing.
    function test_TC14_genuineExitWindow() public {
        (uint256 proposalId, bytes32 descHash) = _createMaliciousProposal();
        _passProposal(proposalId);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");

        uint256 queueTimestamp = block.timestamp;
        governor.queue(targets, values, calldatas, descHash);

        uint256 eta = governor.proposalEta(proposalId);

        // The ETA must be at least 8 days after the queue timestamp
        assertGe(eta, queueTimestamp + TIMELOCK_MIN_DELAY, "ETA must be >= queueTimestamp + 8 days");
    }

    /// @dev Proposal that passed legitimately can be executed after delay.
    ///      Uses a safe parameter-change payload (not the malicious upgrade payload).
    function test_TC14_legitimateProposalExecutedAfterDelay() public {
        // Create a legitimate proposal (parameter change, not an upgrade)
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (20));
        string memory description = "Legitimate proposal: set max to 20";
        bytes32 descHash = keccak256(bytes(description));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descHash);

        // Advance past timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute -- should succeed
        governor.execute(targets, values, calldatas, descHash);

        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed),
            "Legitimate proposal must be Executed after timelock delay"
        );
    }

    /// @dev OF-001 production phase: depositor exit flow during 8-day timelock window.
    ///      Deploys a separate governor+timelock with PRODUCTION_TIMELOCK_DELAY (691200s = 8 days)
    ///      to verify the exit window works in production. In launch phase (delay=0), this
    ///      protection relies on the team controlling all votes — no timelock window needed.
    function test_TC14_depositorExitFlowDuringTimelockWindow() public {
        MockWithdrawable withdrawable = new MockWithdrawable();
        address depositor = makeAddr("depositor");

        // Deploy production timelock + governor with 8-day delay
        (ForageGovernor prodGovernor,) = _deployProductionGovernor();

        // Build malicious proposal params
        address[] memory targets = new address[](1);
        targets[0] = address(prodGovernor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", attacker, "");
        bytes32 descHash = keccak256(bytes("Malicious proposal: upgrade to attacker impl"));

        uint256 proposalId;
        {
            vm.prank(proposer);
            proposalId =
                prodGovernor.propose(targets, values, calldatas, "Malicious proposal: upgrade to attacker impl");

            // Pass the proposal through voting
            vm.roll(block.number + prodGovernor.votingDelay() + 1);
            vm.prank(voter1);
            prodGovernor.castVote(proposalId, 1); // 5M For > 4M quorum
            vm.roll(block.number + prodGovernor.votingPeriod() + 1);
        }

        // Queue into production timelock
        uint256 queueTime = block.timestamp;
        prodGovernor.queue(targets, values, calldatas, descHash);

        uint256 eta = prodGovernor.proposalEta(proposalId);
        assertGe(eta - queueTime, PRODUCTION_TIMELOCK_DELAY, "Exit window must be >= 8 days");

        // Depositor sees malicious proposal and immediately requests withdrawal (7-day cooldown)
        vm.prank(depositor);
        withdrawable.requestWithdrawal();

        // After 7 days: depositor executes withdrawal (cooldown met, still before 8-day eta)
        vm.warp(queueTime + 7 days);
        assertTrue(block.timestamp < eta, "Depositor exits before malicious execution");

        vm.prank(depositor);
        withdrawable.executeWithdrawal();
        assertTrue(withdrawable.hasExecutedWithdrawal(depositor), "Depositor must have executed withdrawal");

        // Depositor redeems (atRISKUSD -> RISKUSD -> USDC equivalent)
        vm.prank(depositor);
        withdrawable.redeem();
        assertTrue(withdrawable.hasRedeemed(depositor), "Depositor must have redeemed");

        // Proposal is still Queued (not yet executable)
        assertEq(
            uint256(prodGovernor.state(proposalId)),
            uint256(IGovernor.ProposalState.Queued),
            "Proposal must still be Queued when depositor exits"
        );
    }

    /// @dev Internal helper: deploy a separate governor+timelock with production-phase delays.
    ///      Returns (prodGovernor, prodTimelock).
    function _deployProductionGovernor() internal returns (ForageGovernor, TimelockController) {
        address[] memory prodProposers = new address[](1);
        prodProposers[0] = deployer; // temp proposer
        address[] memory prodExecutors = new address[](1);
        prodExecutors[0] = address(0); // open execution

        TimelockController prodTimelock =
            new TimelockController(PRODUCTION_TIMELOCK_DELAY, prodProposers, prodExecutors, address(0));

        ForageGovernor prodImpl = new ForageGovernor();
        bytes memory prodInitData = abi.encodeCall(
            ForageGovernor.initialize,
            (
                address(token),
                address(prodTimelock),
                PRODUCTION_VOTING_DELAY,
                PRODUCTION_VOTING_PERIOD,
                DEFAULT_THRESHOLD_BPS,
                DEFAULT_QUORUM_BPS,
                address(0)
            )
        );
        ERC1967Proxy prodProxy = new ERC1967Proxy(address(prodImpl), prodInitData);
        ForageGovernor prodGovernor = ForageGovernor(payable(address(prodProxy)));

        // Grant PROPOSER_ROLE
        {
            bytes32 role = keccak256("PROPOSER_ROLE");
            bytes memory data = abi.encodeCall(prodTimelock.grantRole, (role, address(prodGovernor)));
            bytes32 salt = keccak256("grant_proposer_prod");
            vm.prank(deployer);
            prodTimelock.schedule(address(prodTimelock), 0, data, bytes32(0), salt, PRODUCTION_TIMELOCK_DELAY);
            vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY);
            prodTimelock.execute(address(prodTimelock), 0, data, bytes32(0), salt);
        }

        // Grant CANCELLER_ROLE
        {
            bytes32 role = keccak256("CANCELLER_ROLE");
            bytes memory data = abi.encodeCall(prodTimelock.grantRole, (role, address(prodGovernor)));
            bytes32 salt = keccak256("grant_canceller_prod");
            vm.prank(deployer);
            prodTimelock.schedule(address(prodTimelock), 0, data, bytes32(0), salt, PRODUCTION_TIMELOCK_DELAY);
            vm.warp(block.timestamp + PRODUCTION_TIMELOCK_DELAY);
            prodTimelock.execute(address(prodTimelock), 0, data, bytes32(0), salt);
        }

        return (prodGovernor, prodTimelock);
    }

    /// @dev After 8-day timelock, malicious proposal executes. Demonstrates the attack succeeds
    ///      but depositor has already exited. Uses a parameter change as executable malicious payload.
    function test_TC14_maliciousProposalExecutesAfterDelay() public {
        // Create a malicious proposal that drastically reduces maxActiveProposals to 1
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (1));
        string memory description = "Malicious: reduce maxActiveProposals to 1";
        bytes32 descHash = keccak256(bytes(description));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        _passProposal(proposalId);

        governor.queue(targets, values, calldatas, descHash);

        // Advance past 8-day timelock delay
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        // Execute the malicious proposal
        governor.execute(targets, values, calldatas, descHash);

        // Verify: malicious action executed (maxActiveProposals changed to 1)
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Executed),
            "Malicious proposal must be Executed after timelock delay"
        );
        assertEq(governor.maxActiveProposals(), 1, "Malicious payload must have executed");
    }
}

// ============================================================
// TC-15: Front-Running and Sandwich Attacks
// Requirements: R-17, R-18
// ============================================================
contract ForageGovernor_TC15_FrontRunningAndSandwich is ForageGovernorTestBase {
    // ── Sandwich Attack on Voting ──────────────────────────────────────

    /// @dev Attacker acquires FORAGE before snapshot (block N-1), delegates to self.
    ///      Votes at N+votingDelay+1. Voting power reflects holdings at snapshot N (includes tokens at N-1).
    function test_TC15_sandwichAttackerVotingPowerAtSnapshot() public {
        // Attacker acquires tokens at current block (this will be "before" the proposal snapshot)
        vm.prank(deployer);
        token.transfer(attacker, 5_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1); // checkpoint

        // Create proposal (snapshot will include attacker's tokens)
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance past snapshot so getPastVotes can query it
        vm.roll(snapshotBlock + 1);

        // Verify attacker has voting power at snapshot
        uint256 attackerPower = token.getPastVotes(attacker, snapshotBlock);
        assertEq(
            attackerPower, 5_000_000 * 1e18, "Attacker who acquired before snapshot must have voting power at snapshot"
        );

        // Attacker can cast vote with their snapshot-based power
        vm.prank(attacker);
        governor.castVote(proposalId, 1); // For

        assertTrue(governor.hasVoted(proposalId, attacker), "Attacker must be able to vote with pre-snapshot tokens");
    }

    /// @dev After voting, attacker sells all FORAGE -> vote already cast, immutable.
    function test_TC15_voteImmutableAfterSelling() public {
        // Give attacker tokens and delegate
        vm.prank(deployer);
        token.transfer(attacker, 5_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        // Create proposal and advance to active
        uint256 proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);

        // Attacker votes
        vm.prank(attacker);
        governor.castVote(proposalId, 1);

        // Record vote tallies before selling
        (uint256 againstBefore, uint256 forBefore, uint256 abstainBefore) = governor.proposalVotes(proposalId);

        // Attacker sells ALL tokens
        vm.prank(attacker);
        token.transfer(deployer, 5_000_000 * 1e18);
        assertEq(token.balanceOf(attacker), 0, "Attacker must have 0 tokens after selling");

        // Vote tallies must be unchanged -- the vote is immutable
        (uint256 againstAfter, uint256 forAfter, uint256 abstainAfter) = governor.proposalVotes(proposalId);
        assertEq(forAfter, forBefore, "For votes must be unchanged after attacker sells tokens");
        assertEq(againstAfter, againstBefore, "Against votes must be unchanged after attacker sells tokens");
        assertEq(abstainAfter, abstainBefore, "Abstain votes must be unchanged after attacker sells tokens");
    }

    /// @dev Second attacker tries to use first attacker's sold tokens -> voting power at snapshot was 0.
    function test_TC15_secondAttackerZeroPowerForPostSnapshotTokens() public {
        // First attacker acquires tokens before proposal
        vm.prank(deployer);
        token.transfer(attacker, 5_000_000 * 1e18);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        // Create proposal
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance to active
        vm.roll(snapshotBlock + 1);

        // First attacker votes
        vm.prank(attacker);
        governor.castVote(proposalId, 1);

        // First attacker sells to second attacker
        address attacker2 = makeAddr("attacker2");
        vm.prank(attacker);
        token.transfer(attacker2, 5_000_000 * 1e18);
        vm.prank(attacker2);
        token.delegate(attacker2);
        vm.roll(block.number + 1);

        // Second attacker's voting power at the snapshot block is 0
        uint256 attacker2Power = token.getPastVotes(attacker2, snapshotBlock);
        assertEq(
            attacker2Power, 0, "Second attacker's voting power at snapshot must be 0 (acquired tokens after snapshot)"
        );
    }

    // ── Proposal Timing Attack ─────────────────────────────────────────

    /// @dev Attacker proposes and tries to castVote in same transaction via contract
    ///      -> reverts (proposal is Pending, not Active due to votingDelay).
    function test_TC15_proposeAndVoteSameTransactionReverts() public {
        // Give attacker tokens for proposing
        vm.prank(deployer);
        token.transfer(attacker, PROPOSER_TOKENS);
        vm.prank(attacker);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        // Deploy ProposeAndVoteAttacker contract
        ProposeAndVoteAttacker attackContract = new ProposeAndVoteAttacker(address(governor));

        // Transfer tokens to attacker contract
        vm.prank(attacker);
        token.transfer(address(attackContract), PROPOSER_TOKENS);

        // Delegate tokens in the attack contract to itself so it has voting power for proposal threshold
        vm.prank(address(attackContract));
        token.delegate(address(attackContract));
        vm.roll(block.number + 1); // checkpoint

        // Build proposal params
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));

        // castVote reverts because proposal is Pending (GovernorUnexpectedProposalState)
        // Error propagates through AttackContract's external call
        uint256 proposalId = governor.hashProposal(targets, values, calldatas, keccak256(bytes("Atomic attack")));
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernor.GovernorUnexpectedProposalState.selector,
                proposalId,
                IGovernor.ProposalState.Pending,
                bytes32(uint256(1 << uint8(IGovernor.ProposalState.Active)))
            )
        );
        attackContract.proposeAndVote(targets, values, calldatas, "Atomic attack", 1);
    }

    /// @dev Verify votingDelay prevents same-block propose-and-vote.
    function test_TC15_votingDelayPreventsSameBlockVoting() public {
        uint256 proposalId = _createProposal();

        // Immediately in the same block, try to vote
        // Reverts because proposal is Pending, not Active (GovernorUnexpectedProposalState)
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

        // Verify proposal is Pending (not Active)
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Pending),
            "Proposal must be Pending immediately after creation"
        );
    }

    /// @dev Verify proposalSnapshot() == creationBlock + votingDelay (OZ inherited per L2 line 281).
    function test_TC15_snapshotIsAtProposeBlockPlusVotingDelay() public {
        uint256 creationBlock = block.number;
        uint256 proposalId = _createProposal();

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        assertEq(
            snapshot,
            creationBlock + governor.votingDelay(),
            "proposalSnapshot must equal creationBlock + votingDelay (OZ inherited)"
        );
    }

    // ── Delegation Timing Attack ───────────────────────────────────────

    /// @dev Alice holds tokens delegated to Bob. Alice redelegates to self before snapshot.
    ///      Verify: at snapshot, Alice has power (not Bob).
    function test_TC15_delegationTimingAttack() public {
        // Setup: voter3 (Alice) delegates to voter4 (Bob)
        vm.prank(voter3);
        token.delegate(voter4);
        vm.roll(block.number + 1); // checkpoint

        // Before snapshot: Alice redelegates to self
        vm.prank(voter3);
        token.delegate(voter3);
        vm.roll(block.number + 1); // checkpoint

        // Create proposal
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance to snapshot block
        vm.roll(snapshotBlock + 1);

        // At snapshot, voter3 (Alice) has her own power back
        uint256 alicePower = token.getPastVotes(voter3, snapshotBlock);
        assertEq(
            alicePower, 2_000_000 * 1e18, "Alice must have her own voting power after redelegation before snapshot"
        );

        // voter4 (Bob) lost the delegated power (he still has his own 1M)
        uint256 bobPower = token.getPastVotes(voter4, snapshotBlock);
        assertEq(bobPower, 1_000_000 * 1e18, "Bob must only have his own voting power after Alice redelegated away");
    }

    /// @dev Delegation AFTER snapshot does not affect voting power for that proposal.
    function test_TC15_delegationAfterSnapshotNoEffect() public {
        // Create proposal
        uint256 proposalId = _createProposal();
        uint256 snapshotBlock = governor.proposalSnapshot(proposalId);

        // Advance past snapshot so getPastVotes can query it
        vm.roll(snapshotBlock + 1);

        // Record power at snapshot before any delegation change
        uint256 voter3PowerBefore = token.getPastVotes(voter3, snapshotBlock);

        // Advance further past snapshot
        vm.roll(snapshotBlock + 10);

        // voter3 delegates to attacker AFTER snapshot
        vm.prank(voter3);
        token.delegate(attacker);
        vm.roll(block.number + 1);

        // voter3's power at the SNAPSHOT block is unchanged
        uint256 voter3PowerAfter = token.getPastVotes(voter3, snapshotBlock);
        assertEq(
            voter3PowerAfter, voter3PowerBefore, "Delegation after snapshot must not change voting power at snapshot"
        );
    }

    /// @dev delegateBySig disabled on ForageToken — always reverts with "delegateBySig disabled".
    function test_TC15_delegateBySigDisabled() public {
        vm.expectRevert("delegateBySig disabled");
        token.delegateBySig(
            voter1, // delegatee
            0, // nonce
            block.timestamp + 1 hours, // expiry
            27, // v
            bytes32(uint256(1)), // r
            bytes32(uint256(2)) // s
        );
    }

    /// @dev Verify that a voter who delegated to someone else cannot double-vote.
    ///      If voter3 delegates to voter1, only voter1 can vote with that power.
    function test_TC15_delegatorCannotDoubleVote() public {
        // voter3 delegates to voter1
        vm.prank(voter3);
        token.delegate(voter1);
        vm.roll(block.number + 1);

        // Create proposal and advance to active
        uint256 proposalId = _createProposal();
        vm.roll(block.number + governor.votingDelay() + 1);

        // voter1 votes (with their own power + voter3's delegated power)
        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        // voter3 tries to vote -- their voting power is 0 (delegated to voter1)
        // Reverts with InsufficientVotingPower because voter3's getVotes == 0
        vm.expectRevert(ForageGovernor.InsufficientVotingPower.selector);
        vm.prank(voter3);
        governor.castVote(proposalId, 1);
    }
}
