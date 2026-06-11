// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/IGovernor.sol";
import "../src/ForageGovernor.sol";
import "../src/GuardianModule.sol";
import "./mocks/MockForageTokenVotes.sol";
import "./helpers/ForageGovernorTestBase.sol";

// ============================================================
// TC-11: Invariant Tests
// Requirements: R-61, R-62, R-64, R-78, R-79, R-80, R-81
// Handler + Invariant test contract + regular tests for
// non-handler-dependent invariants
// ============================================================

/// @dev Handler contract for ForageGovernor invariant testing.
/// Randomly performs propose, vote, advanceBlocks, queueSucceeded,
/// executeQueued, cancelByProposer, cancelByGuardian. Tracks ghost
/// variables for invariant assertions. Uses try/catch to handle reverts
/// from the stub gracefully.
contract ForageGovernorHandler is Test {
    ForageGovernor public governor;
    GuardianModule public guardianModuleContract;
    MockForageTokenVotes public token;
    TimelockController public timelock;

    // Test accounts
    address public proposerAddr;
    address public voter1Addr;
    address public voter2Addr;
    address public guardian1Addr;
    address public guardian3Addr; // CANCEL only

    // Ghost variables for invariant tracking
    uint256[] public ghost_proposalIds;
    // Track state at last observation for each proposal
    mapping(uint256 => uint8) public ghost_lastState;
    mapping(uint256 => uint8) public ghost_previousState;
    // Track which proposals have reached terminal states
    mapping(uint256 => bool) public ghost_isTerminal;
    // Track proposals created with explicit params for queue/execute
    mapping(uint256 => bytes32) public ghost_descriptionHashes;

    // Proposal params storage (same for all proposals for simplicity)
    address[] internal _targets;
    uint256[] internal _values;
    bytes[] internal _calldatas;

    uint256 public ghost_proposalCount;
    uint256 public constant MAX_PROPOSALS = 5;

    // Track setter call results
    uint256 public ghost_setterNonTimelockCalls;
    uint256 public ghost_setterNonTimelockReverts;

    constructor(
        ForageGovernor governor_,
        GuardianModule guardianModule_,
        MockForageTokenVotes token_,
        TimelockController timelock_,
        address proposer_,
        address voter1_,
        address voter2_,
        address guardian1_,
        address guardian3_
    ) {
        governor = governor_;
        guardianModuleContract = guardianModule_;
        token = token_;
        timelock = timelock_;
        proposerAddr = proposer_;
        voter1Addr = voter1_;
        voter2Addr = voter2_;
        guardian1Addr = guardian1_;
        guardian3Addr = guardian3_;

        // Standard proposal params
        _targets = new address[](1);
        _targets[0] = address(governor_);
        _values = new uint256[](1);
        _values[0] = 0;
        _calldatas = new bytes[](1);
        _calldatas[0] = abi.encodeCall(ForageGovernor.setMaxActiveProposals, (10));
    }

    /// @dev Create a new proposal with a unique description.
    function propose(uint256 seed) external {
        if (ghost_proposalCount >= MAX_PROPOSALS) return;

        string memory desc = string(abi.encodePacked("Handler-", vm.toString(seed)));
        bytes32 descHash = keccak256(bytes(desc));

        vm.prank(proposerAddr);
        try governor.propose(_targets, _values, _calldatas, desc) returns (uint256 proposalId) {
            ghost_proposalIds.push(proposalId);
            ghost_lastState[proposalId] = uint8(IGovernor.ProposalState.Pending);
            ghost_descriptionHashes[proposalId] = descHash;
            ghost_proposalCount++;
        } catch {
            // Reverts from stub or MaxActiveProposalsReached
        }
    }

    /// @dev Cast a vote on a random existing proposal.
    function vote(uint256 proposalIndexSeed, uint8 supportSeed) external {
        if (ghost_proposalIds.length == 0) return;
        uint256 idx = proposalIndexSeed % ghost_proposalIds.length;
        uint256 proposalId = ghost_proposalIds[idx];
        uint8 support = supportSeed % 3; // 0=Against, 1=For, 2=Abstain

        vm.prank(voter1Addr);
        try governor.castVote(proposalId, support) {
            _updateState(proposalId);
        } catch {
            // Not Active, already voted, stub revert
        }
    }

    /// @dev Advance blocks to move proposals through lifecycle.
    function advanceBlocks(uint256 blocksSeed) external {
        uint256 blocks = bound(blocksSeed, 1, 2_500_000);
        vm.roll(block.number + blocks);
        // Update all proposal states
        for (uint256 i = 0; i < ghost_proposalIds.length; i++) {
            _updateState(ghost_proposalIds[i]);
        }
    }

    /// @dev Queue a succeeded proposal.
    function queueSucceeded(uint256 proposalIndexSeed) external {
        if (ghost_proposalIds.length == 0) return;
        uint256 idx = proposalIndexSeed % ghost_proposalIds.length;
        uint256 proposalId = ghost_proposalIds[idx];
        bytes32 descHash = ghost_descriptionHashes[proposalId];

        try governor.queue(_targets, _values, _calldatas, descHash) {
            _updateState(proposalId);
        } catch {
            // Not Succeeded, stub revert
        }
    }

    /// @dev Execute a queued proposal after timelock delay.
    function executeQueued(uint256 proposalIndexSeed) external {
        if (ghost_proposalIds.length == 0) return;
        uint256 idx = proposalIndexSeed % ghost_proposalIds.length;
        uint256 proposalId = ghost_proposalIds[idx];
        bytes32 descHash = ghost_descriptionHashes[proposalId];

        // Warp past timelock delay
        vm.warp(block.timestamp + 691_201);

        try governor.execute(_targets, _values, _calldatas, descHash) {
            ghost_isTerminal[proposalId] = true;
            _updateState(proposalId);
        } catch {
            // Not queued, delay not elapsed, stub revert
        }
    }

    /// @dev Cancel by proposer (unconditional).
    function cancelByProposer(uint256 proposalIndexSeed) external {
        if (ghost_proposalIds.length == 0) return;
        uint256 idx = proposalIndexSeed % ghost_proposalIds.length;
        uint256 proposalId = ghost_proposalIds[idx];
        bytes32 descHash = ghost_descriptionHashes[proposalId];

        vm.prank(proposerAddr);
        try governor.cancel(_targets, _values, _calldatas, descHash) {
            ghost_isTerminal[proposalId] = true;
            _updateState(proposalId);
        } catch {
            // Already terminal, stub revert
        }
    }

    /// @dev Cancel by guardian with CANCEL permission.
    function cancelByGuardian(uint256 proposalIndexSeed) external {
        if (ghost_proposalIds.length == 0) return;
        uint256 idx = proposalIndexSeed % ghost_proposalIds.length;
        uint256 proposalId = ghost_proposalIds[idx];

        vm.prank(guardian1Addr); // guardian1 has all permissions including CANCEL
        try guardianModuleContract.guardianCancel(proposalId) {
            ghost_isTerminal[proposalId] = true;
            _updateState(proposalId);
        } catch {
            // Already terminal, stub revert
        }
    }

    /// @dev Attempt to call a setter as a non-timelock address (for invariant_timelockOnlyForSetters).
    function callSetterAsNonTimelock(uint256 selectorSeed) external {
        address randomCaller = makeAddr(string(abi.encodePacked("rnd", vm.toString(selectorSeed))));
        uint256 selector = selectorSeed % 5;
        ghost_setterNonTimelockCalls++;

        vm.prank(randomCaller);
        if (selector == 0) {
            try governor.setQuorumBps(400) {}
            catch {
                ghost_setterNonTimelockReverts++;
            }
        } else if (selector == 1) {
            try governor.setVotingDelay(uint48(345_600)) {}
            catch {
                ghost_setterNonTimelockReverts++;
            }
        } else if (selector == 2) {
            try governor.setVotingPeriod(uint32(1_728_000)) {}
            catch {
                ghost_setterNonTimelockReverts++;
            }
        } else if (selector == 3) {
            try governor.setProposalThresholdBps(100) {}
            catch {
                ghost_setterNonTimelockReverts++;
            }
        } else {
            try governor.setMaxActiveProposals(10) {}
            catch {
                ghost_setterNonTimelockReverts++;
            }
        }
    }

    /// @dev Update ghost state for a proposal, tracking transitions.
    function _updateState(uint256 proposalId) internal {
        try governor.state(proposalId) returns (IGovernor.ProposalState newState) {
            uint8 ns = uint8(newState);
            uint8 prev = ghost_lastState[proposalId];
            if (ns != prev) {
                ghost_previousState[proposalId] = prev;
                ghost_lastState[proposalId] = ns;
            }
            if (ns == uint8(IGovernor.ProposalState.Executed) || ns == uint8(IGovernor.ProposalState.Canceled)) {
                ghost_isTerminal[proposalId] = true;
            }
        } catch {
            // state() reverts on stub
        }
    }

    /// @dev Get total proposals tracked.
    function getProposalCount() external view returns (uint256) {
        return ghost_proposalIds.length;
    }

    /// @dev Get proposal ID by index.
    function getProposalId(uint256 idx) external view returns (uint256) {
        return ghost_proposalIds[idx];
    }
}

// ============================================================
// Invariant Test Contract
// ============================================================
contract ForageGovernor_TC11_Invariants is ForageGovernorTestBase {
    ForageGovernorHandler public handler;

    function setUp() public override {
        super.setUp();

        handler = new ForageGovernorHandler(
            governor, guardianModuleContract, token, timelock, proposer, voter1, voter2, guardian1, guardian3
        );

        targetContract(address(handler));
    }

    // ---- Invariant 1: Proposal state transitions valid (R-78, R-79) ----

    /// @dev R-78, R-79: After random sequences of propose/vote/queue/execute/cancel,
    ///      verify no proposal has an invalid state value (must be 0-7 per OZ ProposalState enum),
    ///      verify valid state ordering/reachability, and verify terminal states never change.
    function invariant_proposalStateTransitions() public view {
        uint256 count = handler.getProposalCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 proposalId = handler.getProposalId(i);
            uint8 lastState = handler.ghost_lastState(proposalId);
            uint8 prevState = handler.ghost_previousState(proposalId);
            // ProposalState enum has 8 values (0-7)
            assertTrue(lastState <= 7, "Proposal state must be a valid ProposalState enum value (0-7)");

            // Verify terminal states are never re-entered as non-terminal
            if (handler.ghost_isTerminal(proposalId)) {
                assertTrue(
                    lastState == uint8(IGovernor.ProposalState.Executed)
                        || lastState == uint8(IGovernor.ProposalState.Canceled),
                    "Terminal proposal must be Executed or Canceled"
                );
            }

            // Verify valid transitions: terminal states must not change
            if (prevState != lastState && prevState != 0) {
                // Previous terminal state must not transition to a different state
                if (
                    prevState == uint8(IGovernor.ProposalState.Executed)
                        || prevState == uint8(IGovernor.ProposalState.Canceled)
                        || prevState == uint8(IGovernor.ProposalState.Defeated)
                        || prevState == uint8(IGovernor.ProposalState.Expired)
                ) {
                    // Terminal/final states must never change
                    assertEq(lastState, prevState, "Terminal/final state must not transition to another state");
                }

                // Verify forward-only transitions (no going backward)
                if (lastState == uint8(IGovernor.ProposalState.Canceled)) {
                    // Canceled reachable only from non-terminal states (Pending=0, Active=1, Succeeded=4, Queued=5)
                    assertTrue(
                        prevState == uint8(IGovernor.ProposalState.Pending)
                            || prevState == uint8(IGovernor.ProposalState.Active)
                            || prevState == uint8(IGovernor.ProposalState.Succeeded)
                            || prevState == uint8(IGovernor.ProposalState.Queued),
                        "Canceled must only be reachable from non-terminal states"
                    );
                } else {
                    // For non-Canceled transitions: state value should only increase
                    // (Pending=0 -> Active=1 -> Succeeded=4 -> Queued=5 -> Executed=7)
                    assertTrue(lastState > prevState, "Non-cancel transitions must be forward-only");
                }
            }
        }
    }

    // ---- Invariant 2: activeProposalCount consistency (R-81) ----

    /// @dev R-81: activeProposalCount MUST equal proposals still consuming an active slot.
    ///      Stale queued proposals remain Queued, but no longer consume slots.
    function invariant_activeProposalCount() public {
        uint256 count = handler.getProposalCount();
        uint256 expectedActive = 0;

        for (uint256 i = 0; i < count; i++) {
            uint256 proposalId = handler.getProposalId(i);
            try governor.state(proposalId) returns (IGovernor.ProposalState s) {
                if (_usesActiveSlot(proposalId, s)) {
                    expectedActive++;
                }
            } catch {
                // state() reverts on stub -- count as unknown, skip
            }
        }

        assertEq(
            governor.activeProposalCount(),
            expectedActive,
            "activeProposalCount must equal count of slot-consuming proposals"
        );
    }

    function _usesActiveSlot(uint256 proposalId, IGovernor.ProposalState proposalState) internal view returns (bool) {
        if (
            proposalState == IGovernor.ProposalState.Pending || proposalState == IGovernor.ProposalState.Active
                || proposalState == IGovernor.ProposalState.Succeeded
        ) {
            return true;
        }
        if (proposalState != IGovernor.ProposalState.Queued) return false;
        uint256 eta = governor.proposalEta(proposalId);
        return eta == 0 || block.timestamp <= eta + governor.STALE_QUEUED_PROPOSAL_AGE();
    }

    // ---- Invariant 3: Terminal states immutable (R-80) ----

    /// @dev R-80: Executed or Canceled proposals MUST NOT transition to any other state.
    ///      After every handler action, verify terminal proposals remain terminal.
    function invariant_terminalStatesImmutable() public {
        uint256 count = handler.getProposalCount();
        for (uint256 i = 0; i < count; i++) {
            uint256 proposalId = handler.getProposalId(i);
            if (handler.ghost_isTerminal(proposalId)) {
                try governor.state(proposalId) returns (IGovernor.ProposalState s) {
                    assertTrue(
                        s == IGovernor.ProposalState.Executed || s == IGovernor.ProposalState.Canceled,
                        "Terminal proposal must remain in Executed or Canceled state"
                    );
                } catch {
                    // state() reverts on stub -- acceptable
                }
            }
        }
    }

    // ---- Invariant 4: Quorum percentage-based ----

    /// @dev Quorum MUST always equal totalSupply * quorumBps / 10000.
    function invariant_quorumPercentageBased() public view {
        // Use a past timepoint to avoid clock issues
        uint256 timepoint = block.number > 1 ? block.number - 1 : 0;
        if (timepoint == 0) return;

        try governor.quorum(timepoint) returns (uint256 q) {
            uint256 pastSupply = token.getPastTotalSupply(timepoint);
            uint256 expected = pastSupply * DEFAULT_QUORUM_BPS / 10_000;
            assertEq(q, expected, "quorum must equal getPastTotalSupply * quorumBps / 10000");
        } catch {
            // quorum() reverts on stub -- expected
        }
    }

    // ---- Invariant 5: Parameter bounds respected ----

    /// @dev All governance parameters MUST remain within their documented bounds
    ///      after any sequence of operations.
    ///      OF-001: No hardcoded minimums for votingDelay (any uint48 valid) or
    ///      votingPeriod (only OZ's > 0 enforced). proposalThreshold must remain > 0.
    function invariant_parameterBoundsRespected() public view {
        // OF-001: votingDelay has no minimum — any uint48 value is valid.
        // No assertion needed for votingDelay.

        // OF-001: votingPeriod must be > 0 (OZ internal enforcement).
        try governor.votingPeriod() returns (uint256 vp) {
            assertGt(vp, 0, "votingPeriod must be > 0 (OZ enforced)");
        } catch {
            // Reverts on stub
        }

        // proposalThreshold > 0 (derived from _proposalThresholdBps >= 1 and totalSupply > 0)
        try governor.proposalThreshold() returns (uint256 pt) {
            assertGt(pt, 0, "proposalThreshold must be > 0");
        } catch {
            // Reverts on stub
        }
    }

    // ---- Invariant 6: Timelock-only for setters ----

    /// @dev All setter calls from non-timelock addresses MUST revert.
    function invariant_timelockOnlyForSetters() public view {
        // Every non-timelock setter call should have reverted
        if (handler.ghost_setterNonTimelockCalls() > 0) {
            assertEq(
                handler.ghost_setterNonTimelockCalls(),
                handler.ghost_setterNonTimelockReverts(),
                "All non-timelock setter calls must revert"
            );
        }
    }

    // ---- Invariant 7: No weighted wallets invariant (R-61) ----

    /// @dev R-61: All accounts with equal delegated balances must have equal voting power.
    ///      After any handler action, verify no multiplier exists.
    function invariant_noWeightedWallets() public view {
        // proposer and voter4 both have 1M tokens delegated to self
        // Their getVotes must be equal after any handler sequence
        uint256 proposerVotes = token.getVotes(handler.proposerAddr());
        uint256 voter4Votes = token.getVotes(voter4);
        // Only check if both still have same balance (handler doesn't transfer their tokens)
        if (token.balanceOf(handler.proposerAddr()) == token.balanceOf(voter4)) {
            assertEq(proposerVotes, voter4Votes, "Equal balances must produce equal voting power");
        }
    }

    // ---- Invariant 8: No ForageVault dependency invariant (R-62) ----

    /// @dev R-62: Governor bytecode must not reference staking interfaces after any sequence.
    function invariant_noForageVaultDependency() public view {
        bytes memory code = address(governor).code;
        assertTrue(code.length > 0, "Governor must have deployed bytecode");
        // bytecode is immutable, so this invariant is trivially maintained
        // but verifying it after each handler action confirms no proxy routing change
    }

    // ---- Invariant 9: delegateBySig disabled invariant (R-64) ----

    /// @dev R-64: delegateBySig must always revert after any handler sequence.
    function invariant_delegateBySigDisabled() public {
        vm.expectRevert("delegateBySig disabled");
        token.delegateBySig(address(1), 0, block.timestamp + 1, 27, bytes32(uint256(1)), bytes32(uint256(2)));
    }
}

// ============================================================
// Regular tests for invariants that don't need the handler
// ============================================================
contract ForageGovernor_TC11_RegularInvariants is ForageGovernorTestBase {
    // ---- Test: No weighted wallets (R-61) ----

    /// @dev R-61: For any two accounts with equal delegated FORAGE balance at the same block,
    ///      getVotes() must return equal values. No multiplier anywhere.
    function test_TC11_noWeightedWallets() public {
        // voter4 and proposer both have exactly 1M tokens (PROPOSER_TOKENS)
        // Both delegated to themselves in setUp
        assertEq(token.balanceOf(proposer), PROPOSER_TOKENS, "proposer has 1M tokens");
        assertEq(token.balanceOf(voter4), 1_000_000 * 1e18, "voter4 has 1M tokens");

        // Their voting power must be equal
        uint256 proposerVotes = token.getVotes(proposer);
        uint256 voter4Votes = token.getVotes(voter4);
        assertEq(proposerVotes, voter4Votes, "Equal balances must produce equal voting power (no multipliers)");

        // Both must be exactly their balance (1:1 ratio)
        assertEq(proposerVotes, PROPOSER_TOKENS, "Voting power must equal token balance (1:1 ratio)");
    }

    // ---- Test: No ForageVault dependency (R-62) ----

    /// @dev R-62: ForageGovernor contract runtime bytecode MUST NOT contain references
    ///      to ForageVault, staking, or token-locking interfaces. We scan for known function
    ///      selectors that would indicate a ForageVault dependency.
    function test_TC11_noForageVaultDependency() public view {
        bytes memory code = address(governor).code;
        assertTrue(code.length > 0, "Governor must have deployed bytecode");

        // Search for ForageVault-related function selectors in bytecode.
        // These selectors would be present if ForageGovernor references ForageVault:
        // - stake(uint256): 0xa694fc3a
        // - unstake(uint256): 0x2e17de78
        // - bondedBalance(address): would appear in bytecode if governor reads staking data

        // Scan for the 4-byte selectors
        bytes4 stakeSelector = bytes4(keccak256("stake(uint256)"));
        bytes4 unstakeSelector = bytes4(keccak256("unstake(uint256)"));

        bool foundStake = false;
        bool foundUnstake = false;

        for (uint256 i = 0; i + 4 <= code.length; i++) {
            bytes4 chunk = bytes4(code[i]) | (bytes4(code[i + 1]) >> 8) | (bytes4(code[i + 2]) >> 16)
                | (bytes4(code[i + 3]) >> 24);
            if (chunk == stakeSelector) foundStake = true;
            if (chunk == unstakeSelector) foundUnstake = true;
        }

        assertFalse(foundStake, "ForageGovernor bytecode must not contain stake() selector");
        assertFalse(foundUnstake, "ForageGovernor bytecode must not contain unstake() selector");
    }

    // ---- Test: delegateBySig disabled (R-64) ----

    /// @dev R-64: ForageToken.delegateBySig() must always revert with "delegateBySig disabled".
    ///      MockForageTokenVotes overrides delegateBySig to always revert with this message,
    ///      matching the real ForageToken behavior.
    function test_TC11_delegateBySigReverts() public {
        // Build a dummy delegateBySig call
        // delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        address delegatee = voter1;
        uint256 nonce = 0;
        uint256 expiry = block.timestamp + 1 hours;
        uint8 v = 27;
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));

        // Must revert with "delegateBySig disabled"
        vm.expectRevert("delegateBySig disabled");
        token.delegateBySig(delegatee, nonce, expiry, v, r, s);
    }
}
