# Cantina Findings Assessment — 2026-06-17 External Audit

Source basis: current `openforage_smart_contracts/src/` plus retained audit-document evidence for documentation-scope OPEN-97. Skeptic disposition is recorded in each row to keep false-positive pressure visible.

### OPEN-80
Severity: High
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/FORAGETreasury.sol:141 creates partnership vesting wallets and wires the blocklist at openforage_smart_contracts/src/FORAGETreasury.sol:156.
Affected journey: T-7 partnership FORAGE distribution.
Pre-launch use case: partner receives a vesting wallet that cannot bypass the live blocklist.
Deciding experiment: partnership Foundry binding verifies a blocked beneficiary cannot release.
Recurrence: partnership-blocklist cluster.
Support rationale: current distribution checks beneficiary/delegatee and gives the wallet the same blocklist before funding.
Skeptic disposition: support as valid; reject only claims that require a second wallet/blocklist authority.

### OPEN-84
Severity: High
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/DelegatingVestingWallet.sol:82 accepts one blocklist and openforage_smart_contracts/src/DelegatingVestingWallet.sol:151 gates release.
Affected journey: V-1 vested FORAGE release.
Pre-launch use case: a legitimate beneficiary releases after the cliff unless currently blocked.
Deciding experiment: partnership-blocklist repro plus journey fulfilment D/T/V matrix.
Recurrence: partnership-blocklist cluster.
Support rationale: release checks beneficiary and wallet blocklist state before transfer.
Skeptic disposition: support as valid historical class; current source closes the live path.

### OPEN-94
Severity: High
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/DelegatingVestingWallet.sol:167 gates delegation updates through the vesting wallet blocklist.
Affected journey: V-2 vesting FORAGE still votes.
Pre-launch use case: unblocked beneficiary can delegate; blocked beneficiary cannot use vesting voting power.
Deciding experiment: partnership wallet blocklist test and journey binding checker.
Recurrence: partnership-blocklist cluster.
Support rationale: delegation checks beneficiary, wallet, and new delegatee before calling token delegation.
Skeptic disposition: support as valid; no new code change beyond current source needed.

### OPEN-79
Severity: High
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:141 appends nonce storage after existing custom bridge state, openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:242 mints a loss nonce, and openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:246 posts it to the vault.
Affected journey: K-1 keeper posts NAV and K loss settlement.
Pre-launch use case: a real custodian loss becomes nonce-bound before settlement.
Deciding experiment: ExternalAudit20260617Repros loss NAV test.
Recurrence: loss-settlement cluster.
Support rationale: zero-loss-nonce bridge posts were live before this phase; the phase-7 diff makes the bridge pass a nonce for negative NAV.
Skeptic disposition: support as live true positive; note the repro contains a stale zero-vault assertion that conflicts with nonce-bound vault design.

### OPEN-91
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/FORAGETreasury.sol:152 rejects blocked partnership beneficiaries and delegates.
Affected journey: T-7 partnership FORAGE distribution.
Pre-launch use case: owner can distribute to legitimate partners without granting blocked addresses a route.
Deciding experiment: partnership-blocklist Foundry binding.
Recurrence: partnership-blocklist cluster.
Support rationale: current source checks both authority targets before creating the vesting wallet.
Skeptic disposition: support as valid and currently closed.

### OPEN-90
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:298 removes guardians and openforage_smart_contracts/src/CustodianRegistry.sol:302 proposes custodian role changes through delayed governance.
Affected journey: E-10 guardian administration and K-11 custodian registry operations.
Pre-launch use case: governance can revoke a compromised guardian/executor without instant hostile replacement.
Deciding experiment: guardian/executor revocation overlap review.
Recurrence: guardian/executor revocation cluster.
Support rationale: role mutation is explicit, permissioned, and delayed where custodian authority is involved.
Skeptic disposition: support as resolved by current role lifecycle.

### OPEN-73
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/DelegatingVestingWallet.sol:279 enforces the inherited blocklist on beneficiary and wallet-sensitive paths.
Affected journey: V-1 and V-2 vesting journeys.
Pre-launch use case: vesting remains useful for honest beneficiaries and blocked recipients cannot extract.
Deciding experiment: partnership-blocklist repro.
Recurrence: partnership-blocklist cluster.
Support rationale: the wallet carries its own blocklist pointer and validates target health before accepting it.
Skeptic disposition: support as valid historical class; no extra fix beyond current source.

### OPEN-83
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:336 stores pre-committed successors and openforage_smart_contracts/src/GuardianModule.sol:342 requires them for accelerated rotation.
Affected journey: E-6 and E-7 accelerated rotation.
Pre-launch use case: guardians can accelerate only to a pre-committed successor.
Deciding experiment: accelerated-rotation overlap review.
Recurrence: accelerated rotation cluster.
Support rationale: the successor registry prevents arbitrary guardian-selected rotation targets.
Skeptic disposition: support as fixed; reject claims that demand direct guardian custody repointing.

### OPEN-97
Severity: Informational
Verdict: valid-documentation-scope
Current-source trace: this public snapshot omits the provenance-bearing raw portal exports and the broad internal defence-in-depth memo; no Solidity source change is required for this documentation-scope finding.
Affected journey: X-2 public auditability.
Pre-launch use case: auditors can trace why findings are accepted, fixed, or rejected before launch.
Deciding experiment: external-audit docs pytest and Foundry provenance marker.
Recurrence: documentation provenance cluster.
Support rationale: this is evidence/documentation scope, not a Solidity change.
Skeptic disposition: support as documentation-valid; do not create contract churn for it.

### OPEN-101
Severity: High
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/CustodianRegistry.sol:302 proposes executor role membership and openforage_smart_contracts/src/CustodianRegistry.sol:318 finalizes it after delay.
Affected journey: K-10 bridge executor/keeper and K-11 registry operations.
Pre-launch use case: governance can revoke or rotate custodian executors without breaking active registry reads.
Deciding experiment: guardian/executor revocation overlap review.
Recurrence: guardian/executor revocation cluster.
Support rationale: delayed role finalization prevents silent immediate executor replacement.
Skeptic disposition: support as current-source fixed.

### OPEN-75
Severity: High
Verdict: valid-live-true-positive-fixed-in-phase7
Current-source trace: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:226 records keeper NAV and openforage_smart_contracts/src/RISKUSDVault.sol:453 receives nonce-bearing custody NAV.
Affected journey: K-1 and D-14 incident fairness.
Pre-launch use case: loss-pending exits remain blocked by the vault when NAV is below deployed principal.
Deciding experiment: bridge NAV loss nonce repro.
Recurrence: loss-settlement cluster.
Support rationale: current bridge path now supplies a nonce instead of posting a zero-loss frame.
Skeptic disposition: support as live true positive.

### OPEN-98
Severity: High
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/Blocklist.sol:148 exposes snapshot-time blocklist history and openforage_smart_contracts/src/ForageToken.sol:531 computes past votes from historical delegate-source checkpoints plus that history.
Affected journey: G-1 and G-2 FORAGE voting/delegation.
Pre-launch use case: governance snapshots remain stable after later blocklist changes.
Deciding experiment: historical-blocklist Foundry repro plus phase-9 blocked-at-snapshot expiry repro.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: previous live blocklist reads could erase clean historical snapshots or re-include blocked snapshots after expiry; current source binds both votes and blocked status to the queried snapshot.
Skeptic disposition: support as live true positive.

### OPEN-102
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:715 detects protected guardian mutations, including nested paths.
Affected journey: E-5 proposal cancellation and E-10 guardian administration.
Pre-launch use case: a guardian cannot cancel or route a mutation that protects itself from revocation.
Deciding experiment: guardian/executor revocation overlap review.
Recurrence: guardian/executor revocation cluster.
Support rationale: nested protected mutation detection preserves revocation authority.
Skeptic disposition: support as fixed by current source.

### OPEN-74
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:264 separates incompatible guardian permissions and openforage_smart_contracts/src/GuardianModule.sol:298 removes guardians.
Affected journey: E-10 guardian administration.
Pre-launch use case: governance can manage guardians without entrenching a single compromised seat.
Deciding experiment: guardian/executor revocation overlap review.
Recurrence: guardian/executor revocation cluster.
Support rationale: current source prevents permission combinations that would weaken revocation.
Skeptic disposition: support as current-source fixed.

### OPEN-82
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/RISKUSD.sol:129 uses delayed minter setup and openforage_smart_contracts/src/RISKUSD.sol:177 scopes pause authority.
Affected journey: O-2 admin role handoff.
Pre-launch use case: deployment can hand off minter/governor without leaving an instant or unpauseable authority gap.
Deciding experiment: deployment/admin role overlap review.
Recurrence: deployment wiring cluster.
Support rationale: two-stage setup and scoped pause keep the launch path usable and auditable.
Skeptic disposition: support as fixed; no live repro remained.

### OPEN-89
Severity: Medium
Verdict: valid-live-true-positive-fixed-through-phase9
Current-source trace: openforage_smart_contracts/src/ForageToken.sol:540 iterates historical delegate sources, openforage_smart_contracts/src/ForageToken.sol:547 filters snapshot-blocked sources, and openforage_smart_contracts/src/ForageToken.sol:549 caps at checkpoint votes.
Affected journey: G-5 governance voting.
Pre-launch use case: vote snapshots remain deterministic when a delegate source is later blocked or later unblocked after being blocked at the snapshot.
Deciding experiment: historical-blocklist Foundry repro plus phase-9 blocked-at-snapshot expiry repro.
Recurrence: blocklist-vote re-inclusion cluster.
Support rationale: source iteration is historical and source exclusion now uses snapshot-time blocklist history instead of query-time blocklist state.
Skeptic disposition: support as live true positive.

### OPEN-69
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/GuardianModule.sol:380 executes accelerated rotation only after the quorum-derived ready time.
Affected journey: E-6 accelerated custody rotation.
Pre-launch use case: emergency rotation is faster than a timelock but still bounded and pre-committed.
Deciding experiment: accelerated-rotation overlap review.
Recurrence: accelerated rotation cluster.
Support rationale: ready-time and successor checks prevent instant arbitrary rotation.
Skeptic disposition: support as current-source fixed.

### OPEN-81
Severity: Medium
Verdict: valid-fixed-current-source
Current-source trace: openforage_smart_contracts/src/ForageToken.sol:321 documents deauthorizing locker risk and openforage_smart_contracts/src/ForageToken.sol:374 provides batch unlock.
Affected journey: D-3 priority lane FORAGE lock/unlock.
Pre-launch use case: locked FORAGE can be released or batch-cleared before locker authority changes.
Deciding experiment: FORAGE lock lifecycle source review.
Recurrence: FORAGE unlock / deployment wiring cluster.
Support rationale: current source preserves user recovery instead of stranding locks silently.
Skeptic disposition: support as fixed; no phase-7 Solidity change required.
