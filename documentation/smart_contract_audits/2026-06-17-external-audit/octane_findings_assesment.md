# Octane Findings Assessment — 2026-06-17 External Audit

Source basis: current `openforage_smart_contracts/src/`. Skeptic disposition is explicit so acknowledged findings do not become false-positive-driven changes.

### OCTANE-01
Severity: High
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/Blocklist.sol:148 exposes snapshot-time blocklist history and openforage_smart_contracts/src/ForageToken.sol:531 uses it with historical delegate-source checkpoints for past-vote snapshots.
Affected journey: G-1/G-2 FORAGE governance voting.
Pre-launch use case: old voting snapshots remain stable after later blocklist updates.
Deciding experiment: `test_liveCandidatePastVotesUseHistoricalBlocklistState` and `test_liveCandidatePastVotesDiscountSourceBlockedAtSnapshotAfterExpiry`.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: current-source fix binds historical vote calculation to snapshot-time vote checkpoints and snapshot-time blocklist status while preserving live vote filtering.
Skeptic disposition: support; this was live before phase 7.

### OCTANE-02
Severity: Medium
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/StakingQueue.sol:388 keeps currently unreachable depositor minimums out of the priority lane, openforage_smart_contracts/src/StakingQueue.sol:482 pre-advances the standard head inside the caller's bounded budget, and openforage_smart_contracts/src/StakingQueue.sol:606 excludes currently unreachable depositor minimum shares from live head status.
Affected journey: D-2 staking into chosen tier.
Pre-launch use case: a healthy depositor behind a toxic entry can still be processed.
Deciding experiment: `test_liveCandidateExtremeMinimumSharesCannotPinStandardQueueLane`, `test_liveCandidateExtremeMinimumSharesCannotConsumeSingleEntryBudget`, and `test_liveCandidatePriorityMinimumSharesCannotPinStandardLane`.
Recurrence: StakingQueue denial-of-service cluster.
Support rationale: current-source fix preserves the toxic entry and processes later healthy entries without letting an unreachable minimum-share head consume the only processing slot or enter priority.
Skeptic disposition: support as live true positive.

### OCTANE-03
Severity: Medium
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/StakingQueue.sol:1519 compares depositor minimum shares against the current preview, and openforage_smart_contracts/src/StakingQueue.sol:606 applies that reachability decision to head advancement.
Affected journey: D-12 large depositor enters through queue.
Pre-launch use case: legacy or extreme depositor bounds do not pin the queue.
Deciding experiment: same standard-lane DoS repro as OCTANE-02.
Recurrence: StakingQueue denial-of-service cluster.
Support rationale: the helper makes the liveness decision deterministic from current vault preview data.
Skeptic disposition: support as variant of the live DoS.

### OCTANE-04
Severity: Medium
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/StakingQueue.sol:461 processes priority then standard lanes with bounded scan, openforage_smart_contracts/src/StakingQueue.sol:546 skips impossible minimum-share entries in either lane, and openforage_smart_contracts/src/StakingQueue.sol:606 skips impossible heads.
Affected journey: D-2 queue processing.
Pre-launch use case: queue processing remains useful even with one toxic queued entry.
Deciding experiment: standard- and priority-lane DoS repros.
Recurrence: StakingQueue denial-of-service cluster.
Support rationale: neither lane reverts as a whole because of one impossible min-share.
Skeptic disposition: support as variant, not a separate code path.

### OCTANE-05
Severity: High
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141 appends nonce storage after existing custom bridge state, openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242 creates a loss nonce, and openforage_smart_contracts/src/RISKUSDVault.sol:453 records nonce-bearing custodian NAV.
Affected journey: K-1 keeper NAV and D-14 incident fairness.
Pre-launch use case: a real loss NAV enters the vault's nonce-bound settlement path.
Deciding experiment: bridge NAV loss repro.
Recurrence: loss-settlement cluster.
Support rationale: the bridge no longer posts every NAV with lossNonce zero.
Skeptic disposition: support; the repro still contains a stale zero-vault-id assertion to be escalated.

### OCTANE-06
Severity: Medium
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:599 lets nonce-bound manual NAV bypass the stale keeper baseline while preserving directional freeze.
Affected journey: K-1 manual NAV rescue.
Pre-launch use case: manual reporter can record a loss attestation after the keeper baseline has gone stale.
Deciding experiment: `test_liveCandidateManualNAVRescueWorksAfterKeeperBaselineStales`.
Recurrence: loss-settlement cluster.
Support rationale: nonce-bound manual attestations remain useful for emergency rescue and still feed `RISKUSDVault`.
Skeptic disposition: support as live true positive.

### OCTANE-07
Severity: Medium
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/ForageToken.sol:540 iterates historical delegate sources and openforage_smart_contracts/src/ForageToken.sol:547 filters them against snapshot-time blocklist history.
Affected journey: G-5 voting.
Pre-launch use case: delegate source iteration cannot retroactively erase a clean snapshot.
Deciding experiment: historical-blocklist Foundry repro plus phase-9 blocked-at-snapshot expiry repro.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: iteration is over historical source checkpoints and subtracts only sources blocked at the queried snapshot.
Skeptic disposition: support as a delegate-source variant of OCTANE-01.

### OCTANE-08
Severity: Medium
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/ForageToken.sol:543 reads source votes at the requested timepoint.
Affected journey: G-1/G-2 governance delegation.
Pre-launch use case: old delegated votes are sourced from the historical timepoint.
Deciding experiment: historical-blocklist Foundry repro plus phase-9 blocked-at-snapshot expiry repro.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: current source binds source votes and source blocklist status to `timepoint` instead of current blocklist state.
Skeptic disposition: support as a confirmed variant.

### OCTANE-09
Severity: Medium
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/StakingQueue.sol:546 and openforage_smart_contracts/src/StakingQueue.sol:1519 cover the dead-entry/min-share DoS.
Affected journey: D-2 and D-12 queue liveness.
Pre-launch use case: a toxic standard entry stays unprocessed but does not stop later healthy entries.
Deciding experiment: standard-lane DoS repro.
Recurrence: StakingQueue denial-of-service cluster.
Support rationale: skip-not-revert behavior preserves depositor bounds and lane liveness.
Skeptic disposition: support as same-root DoS cluster.

### OCTANE-10
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:298 removes guardians and openforage_smart_contracts/src/CustodianRegistry.sol:318 finalizes custodian roles after delay.
Affected journey: E-10 guardian administration and K-10 executor/keeper wiring.
Pre-launch use case: compromised authorities can be revoked without breaking honest operations.
Deciding experiment: guardian/executor revocation source review.
Recurrence: guardian/executor revocation cluster.
Support rationale: current source carries explicit removal/finalization paths.
Skeptic disposition: acknowledge as current-source fixed; no phase-7 code change.

### OCTANE-11
Severity: Medium
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/ForageToken.sol:549 caps tracked historical votes at the ERC20Votes checkpoint total.
Affected journey: G-5 voting.
Pre-launch use case: delegate-source iteration cannot inflate or zero a historical snapshot after a later blocklist change.
Deciding experiment: historical-blocklist Foundry repro plus phase-9 blocked-at-snapshot expiry repro.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: the cap preserves checkpoint authority after snapshot-time blocked-source subtraction.
Skeptic disposition: support as delegate-source variant.
