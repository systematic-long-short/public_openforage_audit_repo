# Openforage: public_openforage_audit_repo analysis report

- Repository: `systematic-long-short/public_openforage_audit_repo`
- Analysis date: 2026-06-12
- Vulnerabilities: 48
- Warnings: 7

## Summary

This analysis reviewed the Openforage: public_openforage_audit_repo smart contracts using Octane's automated analysis and included team feedback on findings.

The analysis identified a total of 55 issues (48 vulnerabilities, 7 warnings), including 5 high vulnerabilities.

## Vulnerabilities

### 1. [High] Relay-time anchored NAV freshness in RISKUSDVault/HLTradingBridge causes extended par redemptions post-loss

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge accepts custodian NAV observations up to 1 day old and does not forward observedAt to RISKUSDVault; the vault anchors freshness to the relay block.timestamp with a 2×attestationInterval staleness window. This can extend the effective age of accepted custodian state to ~1 day + 2×interval (≈3 days at defaults), keeping redemptions open after an off-chain loss and enabling arbitrage and distributional harm.

HLTradingBridge.postNAV enforces only that observedAt ≤ now + 1 day, stores observedAt internally, and calls RISKUSDVault.recordCustodianNAV without passing observedAt. RISKUSDVault then sets lastAttestationTimestamp = block.timestamp (relay time) and considers the NAV stale only after 2×attestationInterval seconds from that relay time. With default parameters (interval = 1 day), a custodian snapshot that was already nearly 1 day old when posted can keep the vault in a "fresh" state for about 2 more days. During this extended window, user-sensitive actions (notably 1:1 redemptions) remain open unless operators intervene (pause/manual attestation). If a real off-chain loss occurs after the last observedAt but before a new NAV is posted or the vault becomes stale, unprivileged users can redeem at par, extracting USDC and shifting losses to remaining holders when the loss is eventually recognized. The effect is bounded by vault USDC and the vault’s redemption caps (e.g., default 2% daily, 5% weekly) and any configured reserve ratio (default 0), but can still be materially large. The behavior stems from intentional design tradeoffs (bridge-side observedAt tolerance and vault-side relay-time anchoring) and does not require privileged malice.

#### Severity

**Impact Explanation:** [High] Allows direct, material loss of principal: USDC exits at par after an actual custodian loss, with arbitrage profit to attackers or early redeemers and corresponding losses shifted to remaining holders/protocol. Volume can be substantial within daily/weekly caps and vault liquidity.

**Likelihood Explanation:** [Medium] Requires an uncommon but realistic external loss event and operational timing within permitted windows (observedAt ≤ 1 day; staleness measured from relay time), plus the vault not being paused or manually updated immediately. These constraints are plausible and do not depend on privileged malice or user error.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Arbitrage redemption: After public news of a custodian loss that occurred post-observation, an attacker buys discounted RISKUSD on a DEX (e.g., $0.90) and redeems 1:1 at the vault during the extended freshness window anchored to the relay time, profiting the spread and pushing losses onto remaining holders.
#### Preconditions / Assumptions
- (a). A real custodian loss occurs after the most recent observedAt and before a fresh NAV is attested or the vault becomes stale
- (b). HLTradingBridge posts NAV with observedAt ≤ 1 day old (permitted policy)
- (c). RISKUSDVault attestationInterval is at a typical production value (e.g., 1 day)
- (d). Vault is not paused and no immediate manual attestation has overwritten NAV; reserve ratio is 0 or not binding
- (e). RISKUSD trades below par on a DEX due to public loss rumors/news
- (f). Attacker has sufficient capital to acquire discounted RISKUSD

### Scenario 2.
First-come exits by existing holders: Holders redeem at par before the vault becomes stale (based on relay time), escaping losses while later holders bear more of the eventual loss; the extended window increases total early exits.
#### Preconditions / Assumptions
- (a). A real custodian loss occurs after the most recent observedAt and before vault becomes stale or a fresh NAV is posted
- (b). HLTradingBridge posts within its allowed observedAt ≤ 1 day window
- (c). Vault is not paused; no immediate manual attestation has updated NAV; reserve ratio is 0 or not binding
- (d). Users holding RISKUSD act quickly to redeem during the extended freshness window

### Scenario 3.
Window alignment amplifies exits: The extra day of freshness (relay-time anchored) crosses into a new daily redemption window, and possibly a weekly reset, allowing additional capped redemptions at par that an observedAt-anchored freeze would have blocked.
#### Preconditions / Assumptions
- (a). All conditions from Scenario 1 or Scenario 2 apply
- (b). The extra freshness afforded by relay-time anchoring crosses into a new daily redemption window and possibly a weekly reset before the vault becomes stale

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 488 unchanged lines ...
         bool hadLossToResolve = _lossPending || _hasUnresolvedAttestedLoss() || _hasCurrentNAVShortfall();
         _lastAttestedNAV = nav;
+        // FIXME (OF-vault-observedAt): Introduce a new _lastObservedAt set via a new
+        // recordCustodianNAVObserved(..., observedAt) entrypoint, and gate staleness using
+        // observedAt (source time) instead of relay-time _lastAttestationTimestamp. Keep
+        // _lastAttestationTimestamp for delta accounting and event timestamps.
         _lastAttestationTimestamp = block.timestamp;
         _deployedSinceLastAttestation = 0;
 ... 927 unchanged lines ...

     function _custodianNAVUnavailableOrStale() internal view returns (bool) {
+        // FIXME (OF-vault-staleness): After wiring observedAt, change this to compare
+        // block.timestamp against (_lastObservedAt + 2 * _attestationIntervalSeconds)
+        // instead of using _lastAttestationTimestamp.
         if (_totalDeployed == 0) return false;
         if (_lastAttestationTimestamp == 0) return true;
 ... 362 unchanged lines ...
```

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 225 unchanged lines ...
         _requireKeeper();
         _requireNotBlocked(msg.sender);
+        // FIXME (OF-bridge-observedAt): For full mitigation, enforce observedAt <= block.timestamp and
+        // monotonicity versus _lastNAVObservedAt here, and call a new vault entrypoint that accepts observedAt
+        // (e.g., recordCustodianNAVObserved(vaultId, applied, lossNonce, observedAt)). This ensures vault
+        // staleness is anchored to source time rather than relay time.
         if (block.timestamp > observedAt + DAY_SECONDS) revert StaleNAV();
         if (_directionalFreeze && rawNav > _appliedNAV) revert DirectionFrozen();

         uint256 maxUp = bookValue + (bookValue * 1_000 / BPS_DENOMINATOR);
         uint256 applied = rawNav > maxUp ? maxUp : rawNav;
         _lastNAVBookValue = bookValue;
         _lastNAVRawValue = rawNav;
         _lastNAVObservedAt = observedAt;
         _appliedNAV = applied;
         if (_pendingDeployPrincipal != 0 && applied >= _deployedPrincipal) {
             _pendingDeployPrincipal = 0;
         }
+        // FIXME (OF-bridge-observedAt): Replace with vault.recordCustodianNAVObserved(vaultId, applied, 0, observedAt)
+        // once the vault exposes an observedAt-aware API.
         IRISKUSDVaultNAVPort(riskusdVault).recordCustodianNAV(vaultId, applied, 0);

 ... 448 unchanged lines ...
```

### 2. [High] Caller-only blocklist checks with persistent delegated voting power in ForageGovernor/ForageToken cause temporary governance proposal-slot DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Blocklist enforcement in governance only checks the active proposer/voter, while ERC20Votes-based delegated voting power persists even if the delegator is later blocklisted. An attacker can pre-delegate to an unblocked address and, after being blocklisted, still create proposals or saturate the governor’s active proposal slots via the delegate. Guardians can cancel/block after the fact, but initial impacts occur before intervention.

ForageGovernor enforces blocklisting only on the active caller during propose and vote casting. It then uses ERC20Votes snapshots (getVotes and getPastTotalSupply) to determine voting power and thresholds without discounting voting units sourced from later-blocklisted holders. ForageToken’s delegate requires both parties to be not blocked at delegation time, but it does not remove or invalidate the delegate’s checkpoints if the delegator is blocklisted later. As a result, a holder can delegate to a clean (unblocked) address before being blocklisted. That delegate can subsequently: (1) meet the proposal threshold to create proposals using the blocklisted holder’s delegated voting units; and (2) repeatedly call propose to fill the governor’s global active proposals cap, causing a temporary denial of proposal creation for others. There is no per-proposer cap for ordinary proposers (the stricter cap only applies to guardians with special propose permissions). Guardians can detect and cancel proposals or blocklist the delegate, but those mitigations occur after the initial creation/saturation. Therefore, the system permits a blocklisted-origin voting power to continue influencing governance via a clean delegate, enabling governance-policy bypass and a temporary proposal-slot DoS.

#### Severity

**Impact Explanation:** [Medium] Saturating active proposal slots is a significant but temporary availability loss of a core governance function (proposal creation). Enabling a blocklisted-origin holder to create proposals via a clean delegate is governance-process griefing and policy bypass without direct fund impact.

**Likelihood Explanation:** [High] A single unblocked delegate with threshold-level voting power can fill all active proposal slots in one block by repeatedly calling propose(). No special timing or trusted-operator failure is required for the initial DoS to occur; guardians’ mitigations act after the initial impact.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 2 (most severe): A large FORAGE holder delegates all voting power to an unblocked EOA B while unblocked. Later, the holder is blocklisted. B remains unblocked and, in a single block, repeatedly calls propose() to create proposals until the global active proposal cap is reached. Because ForageGovernor checks only the proposer’s blocklist status (B) and relies on ERC20Votes snapshots that still include the blocklisted holder’s delegated units, each proposal meets the threshold and is accepted. Other proposers are temporarily unable to create proposals until guardians cancel or block B.
#### Preconditions / Assumptions
- (a). Attacker controls enough FORAGE voting power to meet the proposal threshold at the snapshot timepoint.
- (b). Before being blocklisted, the attacker delegates to an unblocked delegate B.
- (c). The attacker is later blocklisted; the delegate B remains unblocked.
- (d). ForageGovernor’s global active proposal cap is configured (default nonzero).
- (e). There is no per-proposer cap for non-guardian proposers (only for guardians with special permissions).
- (f). Guardians have not yet intervened at the moment of proposal creation (cancellation/blocklisting happens after).

### Scenario 2.
Scenario 1: A large FORAGE holder delegates to an unblocked EOA B while unblocked. The holder is then blocklisted. B, still unblocked, calls propose(). ForageGovernor checks only B’s blocklist status and uses B’s past votes (including the delegator’s units) to meet the threshold. The proposal is accepted, allowing the blocklisted-origin voting power to initiate governance proposals via a clean delegate.
#### Preconditions / Assumptions
- (a). Attacker holds enough FORAGE voting power to meet the proposal threshold at the snapshot timepoint.
- (b). Before being blocklisted, the attacker delegates to an unblocked delegate B.
- (c). The attacker is later blocklisted; the delegate B remains unblocked at proposal time.

#### Proposed fix

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 48 unchanged lines ...
     error GuardianActiveProposalQuotaReached(address guardian, uint256 active, uint256 maximum);
     error TimelockSelfProposerGrant();
+    error PerProposerActiveProposalCap();

     // ── Custom events ────────────────────────────────────────────────────
 ... 166 unchanged lines ...
             }
         } else {
+            // General per-proposer active cap (non-guardians): prevents single-address slot saturation.
+            if (_activeProposalCountFor(proposerAddr) >= 1) revert PerProposerActiveProposalCap();
             uint256 proposerVotes = getVotes(proposerAddr, clock() - 1);
             uint256 threshold = proposalThreshold();
             if (threshold > 0 && proposerVotes < threshold) {
                 revert InsufficientVotingPower();
             }
+            // Additional current-votes check closes same-block snapshot window for threshold checks.
+            if (threshold > 0 && token().getVotes(proposerAddr) < threshold) revert InsufficientVotingPower();
         }

 ... 490 unchanged lines ...
```

#### Related findings

##### [Medium] Actor-only blocklist checks with persistent ERC20Votes delegation in ForageGovernor/ForageToken enable uncancelable governance entrenchment and temporary operational disruption

###### Description

ForageGovernor only blocklist-checks the acting proposer/voter while ERC20Votes delegation persists after a delegator is later blocklisted. Unblocked delegates can use voting power sourced from newly blocklisted holders to create/pass proposals. GuardianModule intentionally forbids guardian cancellation of certain governance-structure mutations (e.g., setGuardianModule, mass guardian removals), so such proposals cannot be canceled by guardians. Owners can mitigate by unpausing targets and decoupling guardian authority (2-day finalize delays on core contracts, or upgrades), reducing impact to governance degradation and temporary operational DoS rather than permanent protocol failure.

Delegated voting power is recorded via ERC20Votes checkpoints and is not removed when a delegator becomes blocklisted. ForageGovernor.propose and _castVote enforce the blocklist only on the acting address, not on the provenance of the delegated votes. Therefore, if a large holder delegated to a delegate prior to being blocklisted, the unblocked delegate retains that voting power for proposal threshold and voting snapshots. Separately, GuardianModule.guardianCancel explicitly blocks cancellation of governance-structure proposals (e.g., ForageGovernor.setGuardianModule, GuardianModule.setGuardianPermissions/removeGuardian where self-targeting applies). This combination allows an unblocked delegate to push entrenchment proposals that guardians cannot cancel. In practice, owners retain onlyOwner controls across core contracts to unpause and to rewire the ForageGovernor reference after a 2-day finalize delay (FinalizeDelayProfile) or to upgrade HLTradingBridge, so while governance can be degraded (veto power via a malicious module) and operations temporarily disrupted, owners can restore operations and sever malicious guardian authority within production delays. As a result, the impact is significant but not catastrophic under the stated trust and timing assumptions.

###### Severity

**Impact Explanation:** [Medium] No direct, unavoidable principal loss is enabled. While a malicious module can degrade governance and pause/throttle operations, owners can unpause and, within a 2-day finalize delay (or via upgrade for HLTradingBridge), decouple or replace guardian authority to restore operations. This constitutes significant but temporary availability loss and governance degradation rather than permanent core failure.

**Likelihood Explanation:** [Medium] Success requires notable, persisted voting power from pre-blocklisted delegations and favorable turnout dynamics. Diligent defenders can blocklist delegates and mobilize votes. Guardians cannot cancel certain entrenchment proposals by design, but proposal passage still depends on quorum/majority under production parameters.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An unblocked delegate D, holding votes delegated before the delegator was blocklisted, proposes ForageGovernor.setGuardianModule(attackerModule) and passes the vote by relying on persisted delegated voting power. GuardianModule.guardianCancel cannot cancel this proposal class. After timelock execution, the attacker-controlled module can pause/unpause and tighten caps on contracts that gate these actions by guardianModule and can veto governance by canceling proposals at any lifecycle stage. Owners can still unpause targets and, within 2 days, rewire affected contracts to a safe governor (or upgrade HLTradingBridge), restoring operations and cutting off the malicious module’s authority.
#### Preconditions / Assumptions
- (a). A large holder delegated votes to delegate D before the holder was blocklisted (both unblocked at delegation time).
- (b). The delegator becomes blocklisted later; D remains unblocked and retains the delegated voting power.
- (c). D’s voting power (including persisted delegation) is sufficient to meet proposal threshold and reach quorum/majority under realistic turnout; ForageGovernor requires forVotes ≥ quorum.
- (d). GuardianModule.guardianCancel is blocked for setGuardianModule proposals; timelock delay applies to execution.
- (e). Owners are trusted and can unpause core contracts and rewire ForageGovernor references after a 2-day finalize delay (FinalizeDelayProfile) or upgrade HLTradingBridge.
- (f). Defenders may attempt to blocklist D, but the proposal may already be created; community turnout is uncertain.

### Scenario 2.
An unblocked delegate D proposes a batch that removes or zeros permissions for all guardians via GuardianModule.setGuardianPermissions/removeGuardian. Because each guardian is self-targeted in the batch, guardianCancel reverts for every guardian, making the proposal uncancelable by guardians. If it passes, the protocol loses the guardian backstop for emergencies. Owners can continue operating core contracts via onlyOwner controls, but rapid guardian-driven defenses are gone until governance restores them.
#### Preconditions / Assumptions
- (a). Same delegation/blocklisting setup as Scenario 1; D remains unblocked with sufficient voting power.
- (b). Proposal targets GuardianModule.setGuardianPermissions/removeGuardian for all guardians, making any guardian’s guardianCancel revert due to self-targeting.
- (c). Timelock delay applies to execution; owners retain onlyOwner controls to operate core contracts.

### Scenario 3.
Multiple unblocked delegates D1..Dk, each retaining portions of a now-blocklisted whale’s delegated votes, rapidly open proposals to fill the ForageGovernor active proposal cap, temporarily blocking honest proposers. Guardians can cancel ordinary proposals to clear space, but the attacker can maintain pressure and interleave entrenchment-class items. This causes temporary governance availability loss and operational load until defenders clear the queue.
#### Preconditions / Assumptions
- (a). A large holder pre-distributed delegated votes across multiple delegates D1..Dk before being blocklisted.
- (b). D1..Dk remain unblocked and each can meet proposal threshold (global active proposal cap applies).
- (c). Guardians can cancel ordinary proposals; the attacker coordinates to refill slots quickly.
- (d). Community turnout and defender reaction times are uncertain.

###### Proposed fix

####### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 196 unchanged lines ...
         if (targets.length == 0) revert EmptyProposal();

-        // V7: guardian-proposed spam is cancelable by the guardian set. For ordinary
-        // governance proposals, keep the older protected-mutation cancellation guard.
-        if (!_isGuardianProposedProposal(proposalId)) {
+        // Guardians may cancel outsider proposals even if they target guardian structure.
+        // Keep self-targeting guard only for guardian-proposed proposals (anti-entrenchment).
+        if (_isGuardianProposedProposal(proposalId)) {
             _revertIfSelfTargetingGuardianMutation(msg.sender, targets, calldatas);
         }
 ... 855 unchanged lines ...
```

### 3. [High] Unbounded lazy-deletion heap pruning in atRISKUSD auto-renew tracking causes user funds freeze via OOG

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

atRISKUSD’s auto-renew-disabled tracking uses a min-heap of expiries with lazy deletion. Non-root stale expiries accumulate and are only removed when they become the root. When the last holder of the current minimum expiry untracks (e.g., exit/renew/deposit), an unbounded while-loop pops the entire stale prefix, can run out of gas, and revert, freezing the victim’s funds.

atRISKUSD tracks auto-renew-disabled accounts’ lockup expiries using: (a) a min-heap of expiry timestamps (_autoRenewDisabledExpiryHeap), and (b) a mapping of live counts per expiry (_autoRenewDisabledExpiryCounts). In _syncAutoRenewDisabledTracking, whenever a tracked account’s expiry changes, the old expiry’s count is decremented, the new expiry’s count is incremented, the new expiry is pushed onto the heap (duplicates allowed), and then _pruneAutoRenewDisabledExpiryHeap() is called. The prune function only pops stale roots (expiries with zero live count at the root) in a while loop until it finds a live root; stale non-root entries are left in the heap and accumulate over time. Because expiries are block.timestamp + lockupPeriod, batch processing (via StakingQueue) naturally creates many identical expiries, making large duplicate clusters realistic. An attacker can repeatedly extend their own lockup while another account remains the earliest-live tracked account (the root), causing many zero-count non-root expiries to accumulate. Later, when the last holder of the current minimum expiry untracks/changes expiry (e.g., selfRevert via StakingQueue.redeemForReversion, executeWithdrawal which burns then _sync’s, renewLockup, setAutoRenew(true) on an expired account, or deposit that extends lockup), _pruneAutoRenewDisabledExpiryHeap() must pop the current root and then all accumulated stale expiries that become the root in sequence. This unbounded while loop can exceed gas limits and revert. Because the transaction reverts, the victim remains expired and auto-renew-disabled; transfer restrictions (ExpiredAutoRenewDisabledLockup) prevent normal exits, and repeated attempts to exit/renew can face the same OOG condition. StakingQueue’s processExpiredLockups uses try/catch and will skip the failing user, leaving them stuck. The heap is only O(1)-cleared if no tracked accounts remain, which is unlikely in active tiers.

#### Severity

**Impact Explanation:** [High] User funds can be frozen for longer than a week with no user-side workaround: exit/renew operations revert due to OOG in unbounded prune, and operational keepers skip failed users, requiring admin/upgrade intervention to recover.

**Likelihood Explanation:** [Medium] Preconditions are realistic (nonzero lockups, multiple tracked users, batch-created duplicate expiries). The attacker must expend time and gas to build a backlog, but no rare external conditions or trusted role misuse are required. There is no clear profit motive, but effort alone does not reduce feasibility to low.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (funds frozen for last-holder-of-root): An attacker accumulates many zero-count non-root expiries by repeatedly extending their lockup over time while another user A remains the earliest-live tracked account. When A later tries to exit (selfRevert/executeWithdrawal) or to re-enable/renew lockup, A untracks and triggers prune; the unbounded popping of the stale prefix can OOG and revert, leaving A expired and unable to exit without admin intervention.
#### Preconditions / Assumptions
- (a). Tier has nonzero lockupPeriod
- (b). At least two auto-renew-disabled tracked accounts exist (the victim is earliest-live/root; attacker is another tracked account)
- (c). Attacker can get repeated small deposits processed over time via StakingQueue to extend their lockup and create many stale non-root expiries
- (d). Batch processing naturally creates duplicate expiries within a block
- (e). Gas limits make large prune bursts capable of OOG

### Scenario 2.
Scenario 3 (deposit/renewal DoS for earliest-live user): A user who is currently the earliest-live tracked account tries to deposit (which extends lockup) or renewLockup. Their action decrements the old root expiry’s count to zero and triggers prune; if a large stale prefix exists, prune can OOG and revert, blocking the deposit/renewal and potentially pushing the user toward becoming stuck at expiry later.
#### Preconditions / Assumptions
- (a). Tier has nonzero lockupPeriod
- (b). Victim is currently the earliest-live tracked account (root)
- (c). An attacker has previously accumulated a large backlog of stale non-root expiries
- (d). Victim attempts a deposit (lockup extension) or renewLockup which decrements the root expiry count to zero and triggers prune
- (e). Gas limits make large prune bursts capable of OOG

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 1112 unchanged lines ...

     function _pruneAutoRenewDisabledExpiryHeap() private {
-        while (_autoRenewDisabledExpiryHeap.length != 0) {
+        // Bound pruning work per call to prevent unbounded gas in hot paths.
+        uint256 cap = 32;
+        uint256 pops;
+        while (_autoRenewDisabledExpiryHeap.length != 0 && pops < cap) {
             uint256 root = _autoRenewDisabledExpiryHeap[0];
             if (_autoRenewDisabledExpiryCounts[root] != 0) {
                 _earliestAutoRenewDisabledExpiry = root;
                 return;
             }
             _popAutoRenewDisabledExpiryHeap();
+            unchecked {
+                ++pops;
+            }
         }
+        // If cap reached or heap empty without a live root, mark earliest as unknown (0).
         _earliestAutoRenewDisabledExpiry = 0;
     }
 ... 110 unchanged lines ...
```

### 4. [High] LossReporter wired to USDCTreasury lacks settlement functions in RISKUSDVault wiring causes system-wide freeze of withdrawals/deposits

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault’s loss settlement functions are restricted to the configured lossReporter, but the target wiring sets USDCTreasury as lossReporter and USDCTreasury has no callable path to execute burnForLoss/coverAndBurnForLoss/replenish. When a NAV shortfall, unresolved attested loss, or NAV staleness occurs, RISKUSDVault enters lossPendingActive(), which blocks public deposits and all redemptions (and atRISKUSD exits). Because the wired lossReporter cannot settle losses on-chain, the system remains frozen until multi-day custodian unwinds or delayed governance rewiring/upgrades.

RISKUSDVault gates its loss-settlement entrypoints (burnForLoss, coverAndBurnForLoss, replenish) to msg.sender == lossReporter. In the repository’s target deployment, USDCTreasury is set as lossReporter. However, USDCTreasury provides no functions that invoke these settlement methods and no generic call-forwarder. When HLTradingBridge posts a NAV that is below book (or a manual attestation establishes a loss nonce, or NAV becomes stale > 2×interval), RISKUSDVault’s lossPendingActive() becomes true. In this state, public deposits revert and all redemptions revert; atRISKUSD withdrawal and transition paths also revert due to a lossPending check. There is no on-chain way for the wired lossReporter (USDCTreasury) to settle the loss: it cannot call the vault’s settlement methods, and sending USDC directly to the vault does not change the adjusted NAV vs totalDeployed shortfall that drives the gate. finalizeAttestedLoss by the custodian validates nonces but does not cure a shortfall. Returning principal from the custodian reduces both book and adjusted NAV together, leaving the gap unchanged; only reducing book via burnForLoss or achieving NAV recovery clears the condition. With default return caps (e.g., 10% per day) and high deployment ratios, unwinding to zero can take longer than a week. Governance rewiring/upgrades are subject to production timelocks and FinalizeDelayProfile, adding days before a fix can be executed. Hence a realistic loss or prolonged attestation gap can freeze user withdrawals and public deposits system-wide for days or more.

#### Severity

**Impact Explanation:** [High] Core withdrawals (and most deposits) are unusable system-wide during lossPendingActive(). With default return caps and high deployment ratios, unwinding to zero can exceed a week; governance rewiring/upgrades are delayed by timelocks and finalize delays, so there is no immediate workaround. This matches high-impact criteria: core functionality unusable and funds effectively frozen for prolonged periods.

**Likelihood Explanation:** [Medium] The preconditions (realistic trading loss or attestation staleness > 2×interval) are uncommon but realistic operational states that do not require user/admin mistakes or malicious behavior.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (custodian loss → NAV shortfall → freeze): 1) A trading loss occurs; keeper posts NAV via HLTradingBridge, which clamps applied NAV to ≤ book+10%. 2) RISKUSDVault.recordCustodianNAV updates last NAV; since applied NAV < totalDeployed, lossPendingActive() becomes true. 3) RISKUSDVault.redeem() reverts for all users; public RISKUSDVault.deposit() reverts; atRISKUSD withdrawal and transition paths revert due to lossPending. 4) The only settlement functions are lossReporter-only, but the wired lossReporter (USDCTreasury) has no callable path to invoke them; sending USDC to the vault does not remove the NAV shortfall. 5) The system remains frozen until a slow principal unwind to zero (days) or governance rewires/upgrades after timelocks.
#### Preconditions / Assumptions
- (a). Target wiring sets USDCTreasury as RISKUSDVault.lossReporter; HLTradingBridge is custodian.
- (b). A realistic trading loss makes applied NAV < totalDeployed (keeper posts NAV; HLTradingBridge clamps applied NAV to ≤ book+10%).
- (c). Trusted operators are non-malicious; no attacker action required.

### Scenario 2.
Scenario 3 (NAV staleness > 2×interval → freeze): 1) Keeper fails to post NAV for > 2×attestationInterval while totalDeployed > 0. 2) RISKUSDVault treats NAV as stale and sets lossPendingActive() true. 3) RISKUSDVault redemptions and public deposits revert; atRISKUSD exits revert. 4) The freeze persists until a fresh attestation arrives or the custodian unwinds principal to zero over days; USDCTreasury still cannot invoke settlement methods to clear it on-chain.
#### Preconditions / Assumptions
- (a). Attestation interval configured (default ~1 day); totalDeployed > 0.
- (b). Keeper delays posting NAV for > 2×interval due to operational outage (not malicious).
- (c). Trusted operators are non-malicious; no attacker action required.

#### Proposed fix

##### USDCTreasury.sol

File: `openforage_smart_contracts/src/USDCTreasury.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/USDCTreasury.sol)

```diff
 // SPDX-License-Identifier: MIT
 pragma solidity ^0.8.20;

 import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
 import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
 import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
 import "@openzeppelin/contracts/utils/math/SignedMath.sol";
 import "./FinalizeDelayProfile.sol";

 interface IUSDCTreasuryBlocklist {
     function isBlocked(address account) external view returns (bool);
 }

+interface IRISKUSDVaultLoss { function coverAndBurnForLoss(uint256 vaultId, uint256 riskusdAmount, uint256 coverUsdcAmount) external; }
 /// @title USDCTreasury
 /// @notice Single protocol-USDC router for target accounting and returned-cash earmarks.
 ... 178 unchanged lines ...
     }

+    /// @notice Settlement wrapper: covers loss on RISKUSDVault using Treasury USDC.
+    function settleLossCover(uint256 vaultId, uint256 coverUsdcAmount) external onlyOwner nonReentrant {
+        if (coverUsdcAmount == 0) revert ZeroAmount();
+        _usdc.forceApprove(riskusdVault, coverUsdcAmount);
+        IRISKUSDVaultLoss(riskusdVault).coverAndBurnForLoss(vaultId, 0, coverUsdcAmount);
+        _usdc.forceApprove(riskusdVault, 0);
+    }
     function disburse(bytes32 earmark, address recipient, uint256 amount) external onlyOwner nonReentrant {
         _disburse(earmark, recipient, amount);
 ... 124 unchanged lines ...
```

### 5. [High] Single-snapshot ERC20Votes + guardian-cancel exclusions in ForageGovernor/GuardianModule cause governance capture and treasury drain via UUPS upgrades

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

ForageGovernor derives voting power from a single timestamp-based ERC20Votes snapshot at proposal voteStart, allowing concentrated, temporary voting power to pass proposals. GuardianModule explicitly blocks guardian cancellation for protected mutations (e.g., setGuardianModule, updateGovernor on the module, and per-guardian removals targeting the caller), creating non-cancelable paths to neutralize defenses. With the governance timelock as owner of UUPS treasuries, an attacker who assembles sufficient votes at snapshots can replace or brick guardians, then upgrade treasuries to malicious implementations to drain funds.

The governor uses OpenZeppelin GovernorVotes with ForageToken’s timestamp-based clock, so final vote weight is taken from a single voteStart snapshot via getPastVotes. Holding borrowed or delegated tokens across that snapshot second suffices to establish voting power; continued holding through the voting period is not required. ForageGovernor’s quorumForProposal uses getPastTotalSupply at the snapshot, so quorum is a percentage of total minted voting units, not just the delegated subset.

GuardianModule.guardianCancel() is intentionally blocked for several protected governance actions by _revertIfSelfTargetingGuardianMutation: (a) any proposal that calls ForageGovernor.setGuardianModule(address), (b) any proposal that calls GuardianModule.updateGovernor(address), proposeTimelock(address), upgradeToAndCall(address,bytes), or setPausableTarget(address,bool), and (c) proposals that call setGuardianPermissions/removeGuardian against the calling guardian (thereby blocking that guardian from canceling). This design creates non-cancelable governance paths for neutralizing the guardian defense.

The timelock enforces a minimum delay and limited guards but does not veto these operations. USDCTreasury and FORAGETreasury are UUPSUpgradeable with _authorizeUpgrade onlyOwner; in intended production wiring the governance timelock is the owner, so successful proposals can upgrade these treasuries. An attacker who can assemble enough voting power across snapshots can: (1) replace the GuardianModule (guardians cannot cancel setGuardianModule), or (2) brick guardians by mispointing module.governor, or (3) batch-remove all guardians if ≤100, and then (4) pass and execute upgrades on protocol treasuries to drain assets. This results in direct, material loss of funds and effective governance capture.

#### Severity

**Impact Explanation:** [High] Successful exploitation enables upgrading protocol treasuries to malicious implementations and directly draining principal funds (USDC and/or FORAGE), as well as neutralizing governance defenses. This is a direct, material loss of protocol funds and disruption of core financial flows.

**Likelihood Explanation:** [Medium] Exploitation requires assembling notable voting power at specific timestamp-based snapshots and repeating for subsequent proposals, which are significant but realistic constraints. Guardian cancellation exclusions ensure non-cancelable paths once sufficient votes are assembled; timelock delay slows but does not prevent execution.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: Replace GuardianModule, then upgrade USDCTreasury to malicious and drain USDC. The attacker self-delegates borrowed/assembled FORAGE to meet the proposal threshold at clock()-1 and later holds enough votes across the proposal voteStart second to pass ForageGovernor.setGuardianModule(maliciousModule). Guardian cancellation is categorically blocked for setGuardianModule, so after the timelock delay the module is replaced. The attacker then proposes and passes an upgradeTo/upgradeToAndCall on USDCTreasury (timelock is owner), installs a malicious implementation, and drains USDC.
#### Preconditions / Assumptions
- (a). Attacker can assemble sufficient FORAGE voting power at two timepoints: (a) clock()-1 to satisfy proposalThreshold for propose(), and (b) proposal voteStart to meet quorum and majority; timestamp-based ERC20Votes requires holding across the snapshot second.
- (b). Production wiring: governance timelock is ForageGovernor executor and owner of USDCTreasury (UUPSUpgradeable), allowing upgrades via successful proposals.
- (c). GuardianModule’s cancellation is blocked by design for ForageGovernor.setGuardianModule(address), so guardians cannot cancel this proposal.
- (d). Timelock delay exists but no veto blocks setGuardianModule or subsequent UUPS upgrades.
- (e). Attacker is not blocklisted; blocklist does not prevent timelock execution.

### Scenario 2.
Scenario 2: Brick guardians via GuardianModule.updateGovernor(bogusGovernor), then upgrade FORAGETreasury to malicious and drain FORAGE. The attacker assembles votes at the snapshots to pass updateGovernor on the module; guardianCancel is explicitly blocked for this target/selector, so after delay the internal governor pointer is mis-set. Guardian entrypoints revert due to _requireCurrentGuardianModule checks, effectively disabling guardian defense. The attacker then proposes and executes an upgrade of FORAGETreasury (owned by timelock) to a malicious implementation and drains FORAGE.
#### Preconditions / Assumptions
- (a). Attacker can assemble sufficient FORAGE voting power at clock()-1 and at proposal voteStart; timestamp-based ERC20Votes snapshot semantics apply.
- (b). GuardianModule.updateGovernor(address) is a protected mutation; guardianCancel is blocked by design for this selector/target.
- (c). After updateGovernor executes, GuardianModule’s _requireCurrentGuardianModule checks brick guardian actions, removing cancellation defense.
- (d). Production wiring: governance timelock is owner of FORAGETreasury (UUPSUpgradeable), so upgrades can be executed via governance.
- (e). Timelock delay exists but no veto blocks updateGovernor or subsequent UUPS upgrades.
- (f). Attacker is not blocklisted.

### Scenario 3.
Scenario 3: Batch-remove all guardians (≤100), then upgrade USDCTreasury to malicious and drain USDC. The attacker proposes removeGuardian for each guardian in a single batch (bounded by MAX_PROPOSAL_ACTIONS=100), assembles votes across snapshots to pass it, and each targeted guardian is blocked from canceling due to the self-targeting guard. After delay, all guardians are removed. The attacker then proposes and executes a UUPS upgrade on USDCTreasury to a malicious implementation and drains USDC.
#### Preconditions / Assumptions
- (a). Total guardian count is ≤100 to fit all removeGuardian calls within MAX_PROPOSAL_ACTIONS.
- (b). Attacker can assemble sufficient FORAGE voting power at clock()-1 and proposal voteStart; timestamp-based snapshots apply.
- (c). Each targeted guardian is blocked from canceling by self-targeting guard in GuardianModule; with all guardians targeted, none can cancel.
- (d). Production wiring: governance timelock is owner of USDCTreasury (UUPSUpgradeable), enabling upgrades via governance.
- (e). Timelock delay exists but no veto blocks removeGuardian or subsequent UUPS upgrades.
- (f). Attacker is not blocklisted.

#### Proposed fix

##### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 681 unchanged lines ...
     /// relay/timelock scheduling. Prevents governance entrenchment.
     function _revertIfSelfTargetingGuardianMutation(
+        // SECURITY: Consider permitting guardianCancel for protected wiring ops and moving enforcement
+        // to execute-time via guardian co-approval on protected calls (setGuardianModule, module
+        // updateGovernor/proposeTimelock/upgradeTo*/setPausableTarget).
         address guardian_,
         address[] memory targets,
 ... 373 unchanged lines ...
```

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 478 unchanged lines ...
         bytes32 descriptionHash
     ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
+        // SECURITY: Before any call, require guardianModule co-approval for protected operations
+        // (e.g., setGuardianModule; GuardianModule updateGovernor/proposeTimelock/upgradeTo*/setPausableTarget;
+        // UUPS upgrades on treasuries) by hashing (target,value,calldata) and checking approvals.
         address executor = _executor();
         // V28: prioritize unsafe delay-floor schedules before other timelock role guards.
 ... 235 unchanged lines ...
```

##### FORAGETreasury.sol

File: `openforage_smart_contracts/src/FORAGETreasury.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/FORAGETreasury.sol)

```diff
 ... 222 unchanged lines ...
     }

-    function _authorizeUpgrade(address) internal override onlyOwner {}
+    function _authorizeUpgrade(address) internal override onlyOwner {
+        // SECURITY: Require guardian module co-approval for this upgrade (e.g., isProtectedOpApproved(opHash)).
+    }
 }
```

### 6. [Medium] Fixed time-bucket mint/redemption caps in RISKUSDVault enable boundary-timing DoS of daily redemption for others

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault enforces daily and weekly mint/redemption limits using fixed time-bucket counters that reset at window boundaries without rolling history. An attacker can time actions around boundaries to concentrate usage, including consuming the entire daily redemption cap early in the day, temporarily blocking further redemptions for others until the next reset.

RISKUSDVault implements public mint and redemption throttles via fixed daily and weekly buckets. These reset usage counters at window boundaries and base caps on min-tracked start-of-window supply, but do not maintain a rolling history. As a result, a user can (a) mint at the end of one window and again immediately in the next, and (b) redeem at the start of a day to fully consume that day’s redemption headroom. While deposits remain 1:1 USDC and solvency is preserved, this design permits timing-based concentration that can significantly reduce short-horizon access for other users. The most consequential vector is early-day consumption of the entire daily redemption cap (default 2%), causing subsequent redemptions by others to revert with DailyRedemptionCapExceeded for the remainder of that day. Other effects include end/start-of-window mint spikes that enable queue capacity capture in StakingQueue and early-week onramp spikes due to 10M floors for small supplies. These are consistent with the fixed-bucket design but have fairness/availability impacts that differ from a true rolling window.

#### Severity

**Impact Explanation:** [Medium] Early-day consumption of the daily redemption cap can cause significant but temporary unavailability of a core operation (redemption) for other users for the rest of the day. Other effects are fairness/ordering advantages without principal loss.

**Likelihood Explanation:** [Medium] The attack requires notable capital and boundary timing, but these are realistic for large holders; no privileged roles or broken integrations are required.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Daily redemption cap exhaustion DoS: A large holder redeems shortly after the daily reset to consume the entire daily redemption cap (default 2%), causing subsequent redemption attempts by other users that day to revert due to DailyRedemptionCapExceeded, until the next daily reset.
#### Preconditions / Assumptions
- (a). Attacker holds sufficient RISKUSD (≈2% of daily base) to redeem the daily cap
- (b). RISKUSDVault not paused and no active lossPending
- (c). Vault has enough USDC liquidity and reserve ratio settings allow the redemption
- (d). Attacker times the transaction shortly after the daily reset

### Scenario 2.
Daily mint edge-doubling to seize StakingQueue capacity: An attacker mints near the end of a day and then again immediately after reset (≈20% + 20% with defaults), then floods StakingQueue (potentially using priority) to capture early processing capacity, delaying other users’ deposits from being processed.
#### Preconditions / Assumptions
- (a). Attacker controls sufficient USDC to reach per-block and daily mint caps
- (b). RISKUSDVault not paused and no active lossPending
- (c). Attacker submits one deposit before daily boundary and another after reset (in a new block)
- (d). StakingQueue active with available capacity (and optional priority lane) for the newly minted RISKUSD

### Scenario 3.
Genesis weekly floor boundary doubling: With tiny RISKUSD supply, computed daily/weekly caps floor to 10M. An attacker mints 10M USDC-equivalent just before week end and another 10M just after the week resets, producing a rapid ≈20M onramp across the boundary that can stress operational planning though still fully backed.
#### Preconditions / Assumptions
- (a). Early-phase deployment with tiny RISKUSD supply causing computed caps to floor at 10M
- (b). Attacker has large capital (~$20M USDC) and times deposits near the weekly boundary
- (c). RISKUSDVault not paused and no active lossPending

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 1508 unchanged lines ...

         uint256 cap = _dailyRedemptionWindowStartSupply * _dailyRedemptionCapBps / 10000;
-        if (_dailyRedemptionUsed + riskusdAmount > cap) revert DailyRedemptionCapExceeded();
+        // Linear time-weighted accrual: only allow redemptions up to the fraction accrued so far in the window.
+        uint256 elapsed2 = block.timestamp - _dailyRedemptionWindowStart;
+        if (elapsed2 > DAILY_WINDOW) elapsed2 = DAILY_WINDOW;
+        uint256 allowedSoFar = cap * elapsed2 / DAILY_WINDOW;
+        if (_dailyRedemptionUsed + riskusdAmount > allowedSoFar) revert DailyRedemptionCapExceeded();
     }

 ... 272 unchanged lines ...
```

### 7. [Medium] Total-supply-based quorum/threshold with enforced blocklist in ForageGovernor causes governance liveness degradation and proposal failures

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

ForageGovernor computes quorum and proposal threshold from total token supply while rejecting blocklisted addresses from proposing and voting, and only counting “for” votes toward quorum. Because blocklisting does not reduce total supply or enable new delegations from blocked holders, significant blocklisting can inflate effective requirements relative to the eligible voter base, making proposals harder to pass or causing time-sensitive proposals to fail.

ForageGovernor.quorum(), quorumForProposal(), and proposalThreshold() all use token().getPastTotalSupply(...) multiplied by BPS, so the basis includes all minted tokens regardless of eligibility. At the same time, propose() and _castVote() enforce a blocklist via token.blocklist(), reverting for blocklisted proposers and voters. ForageToken prevents new delegation by blocked accounts (delegate() reverts if caller or delegatee is blocked), and delegateBySig is disabled. Blocklisting does not burn tokens or reduce total supply, so the supply basis for quorum/threshold remains unchanged even when a holder is blocklisted. Additionally, ForageGovernor._quorumReached requires forVotes >= quorum (abstain votes do not count), further increasing the difficulty of meeting quorum if the eligible set shrinks. Consequences include governance proposals that become significantly harder to pass when non-delegated balances are blocklisted and a failure mode where a large delegate becomes blocklisted mid-vote, preventing those snapshotted votes from being cast and causing proposal failure. Mitigations exist (e.g., guardians can still propose, treasury/team voting, unblocking with finalize delay, and burning treasury-held supply to reduce future absolute quorum), but they do not salvage already-snapshotted proposals and do not eliminate the underlying mismatch between eligibility and the supply basis.

#### Severity

**Impact Explanation:** [Medium] Governance liveness suffers significantly: proposals become much harder to pass or fail during time-sensitive windows. This is a significant availability loss for governance but does not directly cause loss of principal funds or break core financial operations.

**Likelihood Explanation:** [Medium] While mass blocklisting of non-delegated holders is uncommon (low likelihood), mid-vote blocklisting of a concentrated delegate is an uncommon but realistic operational event (medium likelihood). Considering the valid scenarios together, the overall likelihood is assessed as medium.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Compliance-driven blocklisting of a large share of non-delegated holders: Many token holders who never delegated to unblocked delegates are blocklisted for compliance reasons. They cannot propose, vote, or newly delegate. Quorum and proposal threshold still use total supply. Since only “for” votes count to quorum, ordinary proposals repeatedly fail to reach quorum, degrading governance liveness until sufficient unblocked voting power mobilizes or parameters/supply are adjusted for future proposals.
#### Preconditions / Assumptions
- (a). Non-zero quorumBps and proposalThresholdBps configured in ForageGovernor
- (b). Significant token balances held by addresses that are later blocklisted and were not pre-delegated to unblocked delegates
- (c). ForageGovernor counts only forVotes toward quorum (abstain excluded)
- (d). Blocklisted accounts cannot newly delegate (ForageToken.delegate() reverts if caller or delegatee is blocked)
- (e). Treasury/team/other unblocked voters are insufficient to meet the unchanged absolute quorum for current proposals

### Scenario 2.
Mid-vote blocklisting of a mega-delegate: A large delegate address, to whom many holders had delegated before the snapshot, becomes blocklisted during an active, time-sensitive vote. Because _castVote() rejects blocklisted voters and the vote weight is snapshotted, the delegate cannot cast those votes, and delegators cannot salvage them for that proposal. The proposal fails to meet the for-vote quorum despite broad (but now immobilized) support.
#### Preconditions / Assumptions
- (a). Large concentration of delegated voting power to a single delegate address at the proposal’s snapshot
- (b). The mega-delegate becomes blocklisted during the voting window (e.g., compliance action)
- (c). Snapshot mechanics fix vote weight at the delegate address; delegators cannot reassign those snapshot votes for the current proposal
- (d). ForageGovernor rejects votes from blocklisted voter addresses

#### Proposed fix

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 624 unchanged lines ...
         returns (uint256)
     {
-        _requireNotBlocked(account);
+        // Allow blocked accounts to vote ONLY if they had non-zero voting power at the proposal snapshot.
+        // This preserves liveness for in-flight proposals when an account becomes blocklisted mid-vote.
+        address tokenAddress = address(token());
+        (bool ok, bytes memory data) = tokenAddress.staticcall(abi.encodeWithSignature("blocklist()"));
+        if (ok && data.length >= 32) {
+            address blocklist_ = abi.decode(data, (address));
+            if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) {
+                uint256 snap = proposalSnapshot(proposalId);
+                if (token().getPastVotes(account, snap) == 0) {
+                    revert BlockedAddress(account);
+                }
+            }
+        }
         // Let super handle state validation first, then check voting power
         uint256 weight = super._castVote(proposalId, account, support, reason, params);
 ... 88 unchanged lines ...
```

### 8. [Medium] Mempool race between cancel and permissionless processing in StakingQueue causes forced deposit/lockup and potential loss exposure

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

StakingQueue.cancelQueue can be front-run by anyone calling processQueue on the same tier. If processQueue marks the entry as processed first, the user’s cancel then reverts and their RISKUSD is deposited into atRISKUSD, extending lockup and subjecting them to cooldown/withdrawal caps. If timed before a known loss event, the user can be forced to absorb that loss.

StakingQueue allows permissionless settlement via processQueue(tier, maxEntries). A user’s only self-service escape from the queue is cancelQueue(queueId), which reverts if entry.processed is true. An attacker monitoring the mempool can front-run a victim’s cancelQueue by calling processQueue on the victim’s tier while capacity exists. _processLane scans ahead, skips dead/oversized/blocked entries, and deposits eligible entries via _depositQueuedRiskusd. Once processed is set, the victim’s cancel reverts (QueueEntryAlreadyProcessed). atRISKUSD.deposit extends the receiver’s lockup immediately and normal exit constraints (cooldown, weekly withdrawal caps) apply. In addition, if the attacker forces inclusion just before a normal loss absorption (absorbLoss by the trusted yieldSource), the victim’s principal can be reduced.

#### Severity

**Impact Explanation:** [High] In Scenario 2, forced inclusion before a normal loss event causes direct, material loss of principal funds for the victim. Scenarios 1 and 3 can significantly delay liquidity (lockup/cooldown/weekly caps), but the maximum impact across scenarios is direct principal loss.

**Likelihood Explanation:** [Low] Exploitation requires capacity windows, mempool front-running, and (for Scenario 2) timing before lossPending and before a normal absorbLoss. There is no clear profit incentive; the behavior is primarily griefing (attacker pays gas to harm the victim).

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (Forced lockup/cooldown): A victim with a live queue entry broadcasts cancelQueue(queueId). An attacker front-runs with processQueue(tier, very_large_maxEntries) while the vault/tier has capacity. _processLane deposits the victim’s RISKUSD into atRISKUSD and marks the entry processed. The victim’s cancel reverts. atRISKUSD.deposit extends lockup and enforces any configured cooldown and weekly withdrawal caps.
#### Preconditions / Assumptions
- (a). StakingQueue is initialized and unpaused; VaultRegistry.getVault(_vaultId).status == Active
- (b). The victim’s queue entry exists and is live: processed == false and cancelled == false
- (c). Combined and per-tier capacity are sufficient for the victim’s riskusdAmount
- (d). The attacker can observe mempool transactions and submit a front-running processQueue
- (e). atRISKUSD deposit path is available (not paused, no lossPending at deposit time); atRISKUSD.deposit extends lockup and applies configured cooldown/weekly caps

### Scenario 2.
Scenario 2 (Forced inclusion before loss): A victim tries to cancel just before an anticipated custodian NAV-related loss. An attacker front-runs with processQueue so the victim is deposited before lossPending is set. Shortly after, the trusted yieldSource calls absorbLoss as part of normal operations, reducing legitimate assets and the victim’s principal.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). LossPending is not yet set at deposit time; a normal loss absorption (absorbLoss) by the trusted yieldSource is expected soon after
- (c). The attacker can time the front-run so deposit occurs before the loss is executed

### Scenario 3.
Scenario 3 (Targeted cherry-pick deep in queue): A victim is not at the queue head and there are many dead/oversized entries ahead. The attacker first calls compactQueue(tier, priority/standard) to prune dead entries and reset heads, then front-runs cancelQueue with processQueue(tier, very_large_maxEntries). _processLane skips oversized/dead entries to reach and process the victim’s entry before the cancel executes.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1
- (b). The victim’s entry is not at the queue head; there are cancelled/processed/oversized entries ahead
- (c). The attacker can call compactQueue to prune dead entries and then processQueue with a large maxEntries to reach the victim

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 409 unchanged lines ...
         emit QueueCancelled(queueId, msg.sender, amount);
     }
-
-    function processQueue(uint8 tier, uint256 maxEntries) external whenNotPaused nonReentrant {
+    // Mitigation: restrict processing to trusted operators to prevent mempool race against user cancellations.
+    function processQueue(uint8 tier, uint256 maxEntries) external whenNotPaused nonReentrant onlyOwnerOrGovernor {
         if (tier >= 4) revert InvalidTier();
         if (maxEntries == 0) revert ZeroAmount();
 ... 1117 unchanged lines ...
```

### 9. [Medium] Missing failure isolation on 0-share ERC4626 mints in StakingQueue.processQueue causes tier deposit queue DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A dust queue entry that mints 0 shares in atRISKUSD causes _depositQueuedRiskusd to revert; since the entry is not marked processed/cancelled and the head is not advanced on revert, every subsequent processQueue call reverts on the same entry, blocking that tier’s queue until manual intervention.

In StakingQueue.processQueue, the loop over a tier’s lane calls _depositQueuedRiskusd for each live entry. _depositQueuedRiskusd approves and calls the tier’s atRISKUSD.deposit(assets, depositor), decodes the returned shares, and explicitly reverts if sharesMinted == 0. With standard ERC-4626 rounding-down semantics, when the atRISKUSD share price (assets per share) is > 1 and the deposit is a tiny “dust” amount (e.g., 1 unit at 6 decimals), convertToShares floors to 0. This makes atRISKUSD.deposit mint 0 shares and StakingQueue revert. Because the revert happens before the entry is marked processed/cancelled and before any head advancement (which only occurs after _processLane returns), the same failing entry remains at the head and causes every subsequent processQueue call to revert again. The result is a tier-level denial of service for deposit processing behind that entry until the depositor cancels, the owner admin-cancels, or the address is blocklisted (which allows skipping). This uses only normal ERC-4626 rounding and deployed logic; no external integrations or privileged malice are required.

#### Severity

**Impact Explanation:** [Medium] Deposit processing for affected tiers is significantly disrupted until manual intervention; this is a temporary but material availability loss of core functionality. There is no principal loss and clear operator workarounds exist, so it does not rise to high impact.

**Likelihood Explanation:** [Medium] Preconditions are realistic: price-per-share > 1 is common post-yield; obtaining a dust amount is trivial; and positioning at lane head with keepers reaching the standard lane is plausible though not guaranteed at every moment. No direct profit motive exists, and some timing/ordering constraints apply, so likelihood is not high.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Standard-lane tier DoS: An attacker queues a dust deposit (e.g., 1 unit of RISKUSD with 6 decimals) in the standard lane of tier T when atRISKUSD’s price-per-share > 1. When a keeper calls processQueue for that tier and reaches the standard lane (priority lane is empty or completed within budget), _depositQueuedRiskusd calls atRISKUSD.deposit, which mints 0 shares due to rounding. StakingQueue reverts, the entry is not advanced or mutated, and the same revert recurs on every subsequent processQueue call, blocking all later standard-lane entries for that tier until manual intervention.
#### Preconditions / Assumptions
- (a). The atRISKUSD price-per-share for the target tier is strictly greater than 1 (normal after any yield via accrueYield).
- (b). Attacker holds a minimal amount of RISKUSD (e.g., 1 unit at 6 decimals) to create a dust queue entry.
- (c). The attacker’s dust entry becomes the first active entry in the standard lane (timing/ordering relative to other entries and keeper cadence).
- (d). A keeper calls processQueue for that tier with available capacity and reaches the standard lane (priority lane empty or cleared within the call’s budget).

### Scenario 2.
Multi-tier persistent DoS: The attacker repeats the above tactic across several tiers and/or rotates addresses. As operators cancel or blocklist individual entries, the attacker places new dust entries at the head positions. This repeatedly stalls deposit processing across multiple tiers, increasing operational disruption despite available mitigations.
#### Preconditions / Assumptions
- (a). The atRISKUSD price-per-share is > 1 across multiple tiers over time (typical for yield-bearing tiers).
- (b). Attacker can repeatedly place dust entries at or near the head of standard lanes across tiers (timing and address rotation).
- (c). Keepers continue to call processQueue for affected tiers; operators mitigate individual entries via adminCancelQueue or blocklisting, after which the attacker reintroduces new dust entries.

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 476 unchanged lines ...
                 continue;
             }
+            // Skip entries that would mint zero shares (dust) to prevent permanent queue stall.
+            // Deterministically diagnosed via previewDeposit/_minimumDepositShares.
+            if (_minimumDepositShares(_tierVaults[tier], entry.riskusdAmount) == 0) {
+                unchecked { ++i; ++scanned; }
+                continue;
+            }

             _depositQueuedRiskusd(tier, entry.riskusdAmount, entry.depositor);
 ... 47 unchanged lines ...
             QueueEntry storage entry = _queueEntries[lane[newHead]];
             if (!entry.processed && !entry.cancelled && !_isBlocked(entry.depositor)) {
-                break;
+                if (_minimumDepositShares(_tierVaults[entry.tier], entry.riskusdAmount) > 0) {
+                    break;
+                }
             }
             unchecked {
 ... 1000 unchanged lines ...
```

### 10. [Medium] Netted mint caps and FCFS global redemption quotas in RISKUSDVault cause attacker-enforceable DoS on redemptions

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Global daily/weekly redemption caps in RISKUSDVault are first-come-first-served and can be cheaply exhausted by an attacker using deposit→redeem churn. Because redeem() nets and even same-block resets mint usage counters, per-block and daily/weekly mint caps do not constrain this churn. With flash loans, the attacker can block all redemptions for a day and, over 2–3 days, the rest of a week, causing system-wide temporary DoS of withdrawals.

RISKUSDVault enforces global first-come-first-served redemption quotas via _enforceWeeklyCap() and _enforceDailyRedemptionCap(), incrementing _weeklyRedemptionUsed and _dailyRedemptionUsed on redeem(). There is no per-account fairness. The deposit path mints RISKUSD 1:1 (subject to mint caps), and redeem burns it, returning USDC 1:1. Critically, redeem() calls _reduceMintActiveSupply(), which decreases _weeklyMintUsed, _dailyMintUsed, and, if in the same block, _mintUsedThisBlock. As a result, mint caps function as net-growth controls rather than gross-flow limiters, allowing repeated deposit→redeem loops—even within a single block—to churn arbitrary volume without being bounded by per-block/daily/weekly mint limits. The vault’s liquidity and reserve checks do not prevent the loop because the attacker’s own deposit provides the needed USDC and the reserve ratio impact cancels out. An attacker can therefore: (a) consume the entire daily redemption headroom early each day, blocking all later redemptions that day; and (b) accumulate weekly usage across the first 2–3 days to exhaust the weekly headroom, after which all redemptions revert for the remainder of the week. This yields a practical, repeatable, low-cost DoS against redemptions under normal operating conditions.

#### Severity

**Impact Explanation:** [High] Once weekly headroom is exhausted mid-week, the core withdrawal function (redeem) becomes completely unusable for all users for the remainder of the weekly window, matching the rule for high impact (core functionality unusable).

**Likelihood Explanation:** [Low] The attack primarily provides denial-of-service without guaranteed direct profit; it is griefing with costs (gas/fees, possibly flash-loan fees), fitting the low-likelihood rule for scenarios driven by irrational/unprofitable behavior.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Weekly lockout across 2–3 days: The attacker saturates the daily cap on days 1 and 2 (≈2% each) and then the remaining weekly headroom on day 3 (≈1%), causing all subsequent redemptions that week to revert with WeeklyRedemptionCapExceeded until the weekly window rolls over.
#### Preconditions / Assumptions
- (a). Vault and RISKUSD are unpaused
- (b). No loss pending in RISKUSDVault
- (c). Nonzero weekly and daily redemption headroom remains
- (d). Attacker is not blocklisted
- (e). Attacker can access flash loans or equivalent liquidity
- (f). Normal ERC20 semantics (USDC) per scope
- (g). Attacker can submit transactions normally; ordering advantages help but are not strictly required

### Scenario 2.
Day-long blockade: Shortly after the daily window starts, the attacker deposits D ≈ 2.04% of pre-deposit supply, then immediately redeems D, consuming the entire daily redemption cap computed off the first redemption’s snapshot; all later redemptions that day revert with DailyRedemptionCapExceeded.
#### Preconditions / Assumptions
- (a). Vault and RISKUSD are unpaused
- (b). No loss pending in RISKUSDVault
- (c). Nonzero daily redemption headroom at the start of the day
- (d). Attacker is not blocklisted
- (e). Attacker can access flash loans or equivalent liquidity
- (f). Normal ERC20 semantics (USDC) per scope
- (g). Attacker acts before other redeemers or front-runs the first redeem

### Scenario 3.
Targeted front-run griefing: The attacker front-runs a victim’s redeem() with a small deposit→redeem pair sized to consume the remaining daily/weekly headroom, causing the victim’s transaction to revert with the corresponding cap-exceeded error.
#### Preconditions / Assumptions
- (a). Vault and RISKUSD are unpaused
- (b). No loss pending in RISKUSDVault
- (c). Small remaining daily or weekly redemption headroom
- (d). Attacker is not blocklisted
- (e). Attacker can front-run via higher fee or private order flow

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 318 unchanged lines ...

     /// @notice OF-16-027: USDC is assumed to have no fee-on-transfer. Deposit mints RISKUSD
+    // FIX NOTE: To harden redemption liquidity against deposit→redeem churn, consider tracking
+    // "eligible" redemption liquidity that excludes same-window user deposits. Redemptions
+    // should be funded only from pre-window vault balance and custodian returns (Option C).
+    // This complements the intent queue or token-age gating approaches below.
     /// 1:1 based on the requested amount, not measured receipt. If USDC ever adds transfer fees,
     /// the 1:1 invariant would break. Monitor USDC for fee-on-transfer changes.
 ... 28 unchanged lines ...
     }

+    // FIX NOTE: Replace immediate, FCFS redemption with either:
+    // (A) a redemption-intent queue processed FIFO/pro-rata under daily/weekly caps; or
+    // (B) a token-age gating check requiring RISKUSD.redeemableBalance(msg.sender) >= riskusdAmount,
+    //     where redeemableBalance excludes newly minted (young) tokens over a rolling 24h window.
+    // Both approaches prevent cheap exhaustion of redemption headroom via deposit→redeem churn.
+    // Also consider liquidity-source gating to avoid using same-window deposits for payouts.
     function redeem(uint256 riskusdAmount) external whenNotPaused nonReentrant {
         if (riskusdAmount == 0) revert ZeroAmount();
 ... 1146 unchanged lines ...
             uint256 elapsed = (block.timestamp - _dailyRedemptionWindowStart) / DAILY_WINDOW;
             _dailyRedemptionWindowStart += elapsed * DAILY_WINDOW;
+            // FIX NOTE: Snapshot the daily baseline from the prior-day end-of-day supply (persisted at rollover),
+            // not from the first redemption of the day, to prevent an attacker from inflating the day's cap
+            // via a pre-snapshot deposit.
             _dailyRedemptionWindowStartSupply = _dailyRedemptionWindowStartSupply > cachedTotalSupply
                 ? _dailyRedemptionWindowStartSupply
 ... 95 unchanged lines ...
             _dailyMintUsed = riskusdAmount >= _dailyMintUsed ? 0 : _dailyMintUsed - riskusdAmount;
         }
+        // FIX NOTE: Do NOT reset same-block mint usage here. Resetting _mintUsedThisBlock enables per-block
+        // mint cap bypass via same-block deposit→redeem loops. Track/limit gross minted amounts per block instead.
+        // If needed, avoid netting daily/weekly mint usage as well to constrain gross churn.
         if (block.number == _mintUsedBlockNumber) {
             _mintUsedThisBlock = riskusdAmount >= _mintUsedThisBlock ? 0 : _mintUsedThisBlock - riskusdAmount;
 ... 182 unchanged lines ...
```

### 11. [Medium] Unbounded timelock scheduleBatch introspection and anti-entrenchment in ForageGovernor/GuardianModule cause uncancellable governance DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

ForageGovernor’s pre-execution guard loops unboundedly over nested timelock scheduleBatch payloads, enabling gas-exhaustion reverts while proposals remain Queued and counted as active. By embedding self-targeting GuardianModule mutations, an attacker can mechanically block guardian cancellation, filling active proposal slots and DoSing governance for up to ~30 days per wave.

Before executing a queued proposal, ForageGovernor._executeOperations runs a preflight guard _enforceTimelockOperation twice over each top-level action. When the target equals the executor (the Timelock) and the selector is scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256), the guard abi.decodes the nested arrays and iterates for (i; i < scheduledTargets.length; ++i) without any bound, recursing into nested schedule/scheduleBatch payloads. MAX_PROPOSAL_ACTIONS=100 caps only the number of top-level actions in propose() and does not constrain the size or depth of a single action’s calldata. As a result, a single top-level action that calls timelock.scheduleBatch with very large (or recursively nested) arrays can cause the guard to consume more gas than a block allows, reverting pre-execution.

Because the revert occurs in the guard, GovernorTimelockControlUpgradeable._executeOperations (which calls Timelock.executeBatch) is never reached. The timelock operation remains pending/ready, so GovernorTimelockControlUpgradeable.state() reports the proposal as Queued. ForageGovernor._usesActiveProposalSlot treats Queued proposals as active until eta + STALE_QUEUED_PROPOSAL_AGE (30 days), so each such proposal occupies an active slot.

GuardianModule.guardianCancel allows guardians to cancel proposals across states (Pending|Active|Succeeded|Queued), but for ordinary governance proposals it enforces an anti-entrenchment check via _revertIfSelfTargetingGuardianMutation: if the batch includes GuardianModule.setGuardianPermissions/removeGuardian that targets the caller, guardianCancel reverts. An attacker can include a self-targeting guardian-permissions mutation for each guardian in the same batch, causing every guardian’s cancellation attempt to revert. If no separate EOA with Timelock CANCELLER_ROLE cancels directly on the timelock (a role that may reasonably not exist per recommended setups), the proposals remain Queued until staleness, filling all active-proposal slots and preventing new proposals for up to ~30 days per wave.

This creates a governance DoS window. The unbounded scheduleBatch introspection guarantees deterministic pre-execution reverts and adds gas griefing, but the DoS is also achievable with any revert-inducing action combined with the anti-entrenchment technique.

#### Severity

**Impact Explanation:** [Medium] The attack causes a significant but temporary availability loss of governance by filling active proposal slots with Queued-but-unexecutable proposals for up to ~30 days per wave. Core user-facing contract functions continue to operate, and emergency guardian actions remain available, so this is not a complete protocol halt or direct fund loss.

**Likelihood Explanation:** [Medium] Exploitation requires notable voting power to pass and queue proposals, which is a significant but plausible constraint. No trusted-role malice or misconfiguration is required; the anti-entrenchment guard mechanically blocks guardian cancellation. The presence of an external canceller could mitigate, but its existence is not guaranteed by the design.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: Uncancellable queued-DoS via anti-entrenchment + unbounded scheduleBatch guard. The attacker drafts proposals with a single top-level action calling timelock.scheduleBatch containing very large nested arrays to trigger gas exhaustion in ForageGovernor._enforceTimelockOperation. The same proposal batch includes GuardianModule.setGuardianPermissions/removeGuardian targeting every guardian. After passing and queuing these proposals, any execution attempt reverts in the guard, leaving them Queued. guardianCancel reverts for each guardian due to self-targeting mutations, so proposals occupy active slots until they age out, DoSing governance proposal creation for up to ~30 days.
#### Preconditions / Assumptions
- (a). Attacker (or colluding voters) controls sufficient voting power to pass and queue proposals (meets threshold and quorum).
- (b). ForageGovernor uses Timelock as executor; default constants apply (MAX_PROPOSAL_ACTIONS=100, STALE_QUEUED_PROPOSAL_AGE=30 days).
- (c). Guardian set is small enough to enumerate in ≤100 top-level actions (typical).
- (d). No separate EOA/multisig with Timelock CANCELLER_ROLE actively cancels on the timelock.
- (e). Proposals include a top-level call to timelock.scheduleBatch with very large (or recursively nested) arrays to trigger the unbounded guard loop.
- (f). Proposals include GuardianModule.setGuardianPermissions/removeGuardian for every guardian (self-targeting each) to trigger the anti-entrenchment check and block guardianCancel.

### Scenario 2.
Scenario 2: Uncancellable queued-DoS via any revert-inducing action + anti-entrenchment. The attacker drafts proposals with a single top-level action that reliably reverts on execution (e.g., a call that fails by design), plus setGuardianPermissions/removeGuardian for each guardian. After passing and queuing, execution reverts inside the timelock batch, leaving proposals Queued. guardianCancel reverts due to anti-entrenchment, filling active slots and preventing new proposals for the staleness window.
#### Preconditions / Assumptions
- (a). Attacker (or colluding voters) controls sufficient voting power to pass and queue proposals.
- (b). ForageGovernor with default constants; Timelock as executor.
- (c). Guardian set is small enough to enumerate in ≤100 top-level actions.
- (d). No separate EOA/multisig with Timelock CANCELLER_ROLE actively cancels on the timelock.
- (e). Proposals contain at least one top-level revert-inducing action to ensure execution reverts.
- (f). Proposals include GuardianModule.setGuardianPermissions/removeGuardian for every guardian to block guardianCancel through anti-entrenchment.

### Scenario 3.
Scenario 3: Exponential recursion with nested scheduleBatch-of-scheduleBatch + anti-entrenchment. The attacker crafts proposals where the timelock.scheduleBatch payloads themselves contain nested scheduleBatch calls, creating broad/deep recursion. ForageGovernor._enforceTimelockOperation recursively traverses these without bounds and reverts due to gas before timelock execution. Including self-targeting guardian-permissions calls blocks guardianCancel. Proposals remain Queued and consume active slots for the staleness period.
#### Preconditions / Assumptions
- (a). Attacker (or colluding voters) controls sufficient voting power to pass and queue proposals.
- (b). ForageGovernor with Timelock as executor; default constants.
- (c). No separate EOA/multisig with Timelock CANCELLER_ROLE actively cancels on the timelock.
- (d). Proposals include nested timelock.scheduleBatch payloads (scheduleBatch calls inside scheduleBatch), creating deep recursion for the guard to traverse.
- (e). Proposals include GuardianModule.setGuardianPermissions/removeGuardian for every guardian to block guardianCancel via anti-entrenchment.

#### Proposed fix

##### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 198 unchanged lines ...
         // V7: guardian-proposed spam is cancelable by the guardian set. For ordinary
         // governance proposals, keep the older protected-mutation cancellation guard.
+        uint256 gLen=_guardianList.length; bool allTargeted=gLen!=0;
+        for(uint256 gi;gi<gLen;){address g=_guardianList[gi];bool seen;for(uint256 i;i<targets.length;){bytes4 sel=_selectorOf(calldatas[i]);if(targets[i]==address(this)&&(sel==GuardianModule.setGuardianPermissions.selector||sel==GuardianModule.removeGuardian.selector)){if(_firstAddressArgument(calldatas[i])==g){seen=true;break;}}unchecked{++i;}}if(!seen){allTargeted=false;break;}unchecked{++gi;}}
         if (!_isGuardianProposedProposal(proposalId)) {
-            _revertIfSelfTargetingGuardianMutation(msg.sender, targets, calldatas);
+            if (!allTargeted) { _revertIfSelfTargetingGuardianMutation(msg.sender, targets, calldatas); }
         }

 ... 854 unchanged lines ...
```

#### Related findings

##### [Low] Unbounded recursive timelock scheduleBatch guard in ForageGovernor causes per‑proposal execution DoS

###### Description

ForageGovernor’s pre-execution timelock guard recursively decodes and iterates over inner arrays of timelock.scheduleBatch() calls without an inner cap. A passed proposal can include one action that targets the timelock with a large or nested scheduleBatch payload, causing the guard to exceed gas/memory during execute() and permanently revert, making the proposal un-executable until canceled or stale.

In ForageGovernor, _executeOperations() calls _enforceTimelockOperation() twice per action when target == timelock, before delegating to OZ’s execution. If an action is a call to timelock.scheduleBatch, the guard: (1) copies the full calldata payload byte-by-byte via _operationPayload, (2) abi.decode’s unbounded address[]/bytes[] arrays, and (3) iterates and recurses for each inner scheduled call. While the outer batch size is capped by MAX_PROPOSAL_ACTIONS, there is no cap on the inner arrays embedded in scheduleBatch payloads. As a result, a proposal can pass with a single timelock.scheduleBatch action containing very large or nested arrays, making the preflight guard exceed gas/memory and revert on every execute() attempt. The proposal remains Queued (consuming a slot while fresh) until guardians cancel it or it becomes stale after 30 days. The issue produces a per-proposal liveness failure (temporary governance DoS for that proposal). Guardians can cancel stuck proposals, but this is an operational mitigation and does not remove the underlying unboundedness.

###### Severity

**Impact Explanation:** [Medium] Execution of the approved proposal is consistently reverted (significant but temporary DoS of a core governance function for that proposal). A workaround exists (submit a new proposal), so this is not a permanent freeze of funds or governance.

**Likelihood Explanation:** [Low] Exploitation requires passing a socially abnormal proposal (with large or nested scheduleBatch to the timelock), provides no direct profit (griefing), and trusted guardians can cancel stuck proposals; these factors reduce practical likelihood.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: A proposer crafts and passes a proposal with one action targeting the timelock using scheduleBatch with very large inner arrays (address[] and bytes[]). When execute() is called after eta, ForageGovernor’s guard copies and decodes the large payload and loops over all inner entries, exceeding gas/memory and reverting. The approved proposal becomes un-executable; it remains Queued until guardians cancel it or it turns stale.
#### Preconditions / Assumptions
- (a). The attacker can pass one governance proposal (quorum and majority).
- (b). The proposal includes a single action targeting the timelock (executor) with selector scheduleBatch.
- (c). The inner arrays (address[] targets, bytes[] payloads) are sufficiently large to make pre-execution guard decoding/iteration exceed gas or memory limits.
- (d). Guardians may later cancel; cancellation is not required for the liveness failure to occur.

### Scenario 2.
Scenario 3: A proposer crafts and passes a proposal whose single action is a nested scheduleBatch tree (moderate branching, multiple levels), each level again targeting the timelock with scheduleBatch. On execute(), the guard copies/decodes at each level and recurses over branches. Even with moderate sizes, the compounded preflight work exceeds available gas, causing permanent execute() failures for that proposal.
#### Preconditions / Assumptions
- (a). The attacker can pass one governance proposal (quorum and majority).
- (b). The proposal’s single action targets the timelock with a nested scheduleBatch structure (multiple levels, moderate branching).
- (c). The compounded pre-execution guard work from copying/decoding/recursing across levels is sufficient to exceed gas/memory during execute().
- (d). Guardians may later cancel; cancellation is not required for the liveness failure to occur.

###### Proposed fix

####### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 48 unchanged lines ...
     error GuardianActiveProposalQuotaReached(address guardian, uint256 active, uint256 maximum);
     error TimelockSelfProposerGrant();
+    error ForbiddenTimelockScheduling();

     // ── Custom events ────────────────────────────────────────────────────
 ... 147 unchanged lines ...
             revert TooManyProposalActions(targets.length, MAX_PROPOSAL_ACTIONS);
         }
+        {address exec=_executor(); for(uint256 i;i<targets.length;){bytes memory d=calldatas[i]; if(targets[i]==exec&&d.length>=4){bytes4 s=_operationSelector(d); if(s==_timelockScheduleSelector()||s==_timelockScheduleBatchSelector()) revert ForbiddenTimelockScheduling();} if(targets[i]==address(this)&&d.length>=4&&_operationSelector(d)==bytes4(keccak256("relay(address,uint256,bytes)"))){(address nt,,bytes memory nd)=abi.decode(d[4:],(address,uint256,bytes)); if(nt==exec&&nd.length>=4){bytes4 ns=_operationSelector(nd); if(ns==_timelockScheduleSelector()||ns==_timelockScheduleBatchSelector()) revert ForbiddenTimelockScheduling();}} unchecked{++i;}}}
         if (activeProposalCount() >= _maxActiveProposals) revert MaxActiveProposalsReached();

 ... 514 unchanged lines ...
```

### 12. [Medium] Missing depositor minOut/deadline in StakingQueue with permissionless processing enables forced settlement before loss gating, causing user principal loss via atRISKUSD absorbLoss

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

StakingQueue allows anyone to process queued deposits without a user-specified minOut/deadline, settling them at the then-current price. Because atRISKUSD only blocks deposits after on-chain loss gating flips, an attacker can process victims' entries immediately before a custodian loss attestation, forcing them into atRISKUSD and causing direct principal loss when absorbLoss executes.

The StakingQueue joinQueue records only depositor, amount, tier, and flags; it does not bind a user-provided minimum shares, maximum price, or expiry. processQueue is permissionless and calls _depositQueuedRiskusd, which computes minimumShares using previewDeposit at processing time and then calls the tier’s atRISKUSD.deposit. atRISKUSD blocks deposits only when _requireNoLossPending() detects on-chain loss signals (RISKUSDVault.lossPending, custodian tierShareActionsPaused, NAV stale/shortfall). Prior to those signals flipping on-chain, deposits are allowed. An unprivileged attacker can submit processQueue just before a custodian loss attestation (or in the same block with earlier inclusion), settling queued users into atRISKUSD. After the loss attestation, the authorized yieldSource reduces vault assets via absorbLoss, directly reducing the value of the victims’ newly minted shares (a principal loss). While users can cancel before processing, this is raceable; capacity must be available; and ordering on Arbitrum is not fully attacker-controlled, but windows are realistic enough to exploit opportunistically. No privileged-role malice or misconfiguration is required.

#### Severity

**Impact Explanation:** [High] Victims whose entries are force-settled just before loss gating flips suffer direct, material loss of principal when atRISKUSD.absorbLoss reduces vault assets and their newly minted shares' value.

**Likelihood Explanation:** [Low] Exploitation requires multiple timing-dependent preconditions: an imminent loss, deposits still allowed, sufficient capacity, presence of queued victims, and transaction inclusion before gating flips. Loss events are episodic; Arbitrum sequencing reduces ordering certainty; users may cancel; and trusted operators can proactively pause. These multiplicative constraints reduce overall likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Just-in-time processing before on-chain loss attestation: An attacker monitors for an imminent custodian loss attestation and calls processQueue to settle queued entries into atRISKUSD moments before lossPending flips. After attestation, absorbLoss executes and reduces the newly deposited users' share value, causing direct principal loss.
#### Preconditions / Assumptions
- (a). There are live StakingQueue entries (processed=false, cancelled=false) for a tier
- (b). Combined and per-tier capacity are available for the targeted entries
- (c). atRISKUSD deposits are currently allowed (lossPending=false; custodian tierShareActionsPaused=false; NAV not stale/shortfall)
- (d). A custodian loss is imminent but not yet reflected on-chain (attestation not yet finalized)
- (e). Attacker submits processQueue before the on-chain gating flips

### Scenario 2.
Same-block mempool snipe of loss attestation: The attacker observes a pending recordCustodianNAV(...) transaction indicating a loss and front-runs it with processQueue targeting tiers with capacity. Entries are settled before loss gating engages; subsequent absorbLoss reduces the victims' atRISKUSD assets.
#### Preconditions / Assumptions
- (a). There are live StakingQueue entries with capacity available in targeted tiers
- (b). A pending on-chain recordCustodianNAV(...) or equivalent loss-related transaction is visible in the mempool
- (c). atRISKUSD deposits are currently allowed (lossPending=false; custodian tierShareActionsPaused=false; NAV not stale/shortfall)
- (d). Attacker’s processQueue is included before the attestation transaction
- (e). Victims have not cancelled before processing

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 54 unchanged lines ...
         bool priority;
     }
+    // FIX-MITIGATION: Consider adding optional per-entry settlement constraints to QueueEntry:
+    // uint256 minSharesOut; uint256 deadline;

     struct TierDepositCap {
 ... 261 unchanged lines ...
     // -- State-changing functions --

+    // FIX-MITIGATION: Provide an overload joinQueue(amount, tier, minSharesOut, deadline) and store constraints;
+    // require deadline > block.timestamp when nonzero.
     function joinQueue(uint256 riskusdAmount, uint8 tier) external whenNotPaused nonReentrant {
         if (riskusdAmount == 0) revert ZeroAmount();
 ... 130 unchanged lines ...
             QueueEntry storage entry = _queueEntries[lane[i]];

+            // FIX-MITIGATION: If (entry.deadline != 0 && block.timestamp > entry.deadline) then mark expired and skip.
+            // Also pre-check previewShares; if (entry.minSharesOut != 0 && previewShares < entry.minSharesOut) then skip.
             if (entry.processed || entry.cancelled) {
                 unchecked {
 ... 71 unchanged lines ...
             if (!entry.processed && !entry.cancelled && !_isBlocked(entry.depositor)) {
                 break;
+            // FIX-MITIGATION: Also treat expired-deadline entries as inactive so head advances over them.
             }
             unchecked {
 ... 867 unchanged lines ...
         if (sharesMinted == 0) revert ZeroAmount();
         if (sharesMinted < minimumShares) revert DepositOutputBelowMinimum(sharesMinted, minimumShares);
+        // FIX-MITIGATION: Enforce depositor slippage: if (entry.minSharesOut != 0) require(sharesMinted >= entry.minSharesOut).
+        // Note: pass entryId or entry.minSharesOut into this function to enforce the constraint here.

         // OF-M10: reset allowance
 ... 129 unchanged lines ...
```

### 13. [Medium] Missing manual NAV normalizer in HLTradingBridge (custodian) causes unusable manual fallback and DoS of redemptions/deposits

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault’s manual custodian NAV fallback hard-requires the custodian to implement normalizeManualCustodianNAV(...). HLTradingBridge, the intended custodian, does not implement it, so manual attestations always revert. During custodian NAV staleness or unresolved loss, this prevents clearing the vault’s loss-pending state, blocking redemptions and public deposits until the custodian path recovers or delayed mitigations are executed.

RISKUSDVault.recordManualCustodianNAV(vaultId, nav, lossNonce) unconditionally calls _normalizeManualCustodianNAV(...), which performs a staticcall to the configured _custodian for IManualCustodianNAVNormalizer.normalizeManualCustodianNAV(uint256,uint256,uint256). If the call fails or returns short data, RISKUSDVault reverts ManualAttestationNormalizationFailed(custodian). HLTradingBridge is the only in-repo contract able to satisfy RISKUSDVault’s msg.sender == _custodian checks for deployCapital/returnCapital and recordCustodianNAV, so it must be set as the custodian. However, HLTradingBridge does not implement normalizeManualCustodianNAV and has no fallback, making the manual path mechanically unusable. While NAV is stale/unavailable (no attestation within 2×attestationIntervalSeconds) or there is an unresolved attested loss shortfall, _lossPendingActive() is true. In this state, redeem() reverts LossPending and public deposit() is blocked. Because manual attestation cannot succeed, the vault remains blocked until the custodian path recovers or owners apply slower mitigations (e.g., raise attestationIntervalSeconds to avoid staleness, have the lossReporter burn to match NAV for unresolved loss, or replace/upgrade keeper/custodian after finalize delays). The core defect is the custodian interface mismatch preventing the documented emergency/manual attestation path from functioning.

#### Severity

**Impact Explanation:** [Medium] Redemptions and public deposits (core protocol functionality) are significantly and temporarily unavailable when NAV is stale/unavailable or an attested loss is unresolved, and the documented emergency/manual path cannot restore availability due to a custodian interface mismatch. Privileged mitigations exist and can be applied quickly, so this does not meet the threshold for high impact (e.g., funds frozen > 1 week with no workaround).

**Likelihood Explanation:** [Medium] The scenarios require uncommon but realistic operational states outside attacker control: custodian/keeper downtime beyond 2× the attestation interval or custodian unavailability between attested loss and finalization, and governance role changes with finalize delays. These are plausible liveness conditions rather than rare/exceptional events or operator malice.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (NAV staleness DoS): HLTradingBridge posts NAV at time T0. The keeper then goes down and no postNAV occurs for > 2× attestationIntervalSeconds. RISKUSDVault marks NAV as stale, _lossPendingActive() becomes true, and redeem() and public deposit() revert. Governance attempts recordManualCustodianNAV, but it staticcalls HLTradingBridge.normalizeManualCustodianNAV(...) which does not exist, reverting ManualAttestationNormalizationFailed. Redemptions and public deposits remain blocked until the custodian path recovers or mitigations are applied.
#### Preconditions / Assumptions
- (a). RISKUSDVault.custodian is HLTradingBridge (required by msg.sender checks for deploy/return/NAV)
- (b). HLTradingBridge does not implement normalizeManualCustodianNAV and has no fallback
- (c). RISKUSDVault.attestationIntervalSeconds is finite (e.g., default 1 day)
- (d). HLTradingBridge keeper unavailable for > 2× attestation interval
- (e). Manual attestation reporter is configured and attempts to use recordManualCustodianNAV

### Scenario 2.
Scenario 2 (Unresolved attested loss DoS): HLTradingBridge posts an attested loss (lossNonce != 0, applied NAV < totalDeployed) and then becomes unavailable before calling finalizeAttestedLoss. With an open attested-loss nonce and shortfall, _lossPendingActive() is true, fully blocking redemptions and public deposits. The manual reporter calls recordManualCustodianNAV but it reverts due to the missing normalizer on HLTradingBridge, preventing clearing the state until HLTradingBridge returns or privileged mitigations are used.
#### Preconditions / Assumptions
- (a). RISKUSDVault.custodian is HLTradingBridge
- (b). HLTradingBridge does not implement normalizeManualCustodianNAV and has no fallback
- (c). HLTradingBridge successfully posts an attested loss (nonzero lossNonce, applied NAV < totalDeployed)
- (d). HLTradingBridge becomes unavailable before calling finalizeAttestedLoss
- (e). Manual attestation reporter attempts recordManualCustodianNAV

### Scenario 3.
Scenario 3 (Role replacement delay DoS): HLTradingBridge is custodian but becomes unable to attest NAV. Owner initiates keeper or custodian replacement, which has a 2-day finalize delay. During this delay, NAV remains stale and the vault is loss-pending. A manual attestation attempt reverts due to the missing normalizer, so redemptions and public deposits remain blocked until the new role is finalized and posts NAV (or owners apply other mitigations).
#### Preconditions / Assumptions
- (a). RISKUSDVault.custodian is HLTradingBridge
- (b). HLTradingBridge does not implement normalizeManualCustodianNAV and has no fallback
- (c). Custodian/keeper path is unavailable; NAV becomes stale
- (d). Owner initiates keeper or custodian replacement subject to a 2-day finalize delay
- (e). Manual attestation reporter attempts recordManualCustodianNAV during the delay

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 392 unchanged lines ...
     }

+    /// @notice Manual NAV normalizer for RISKUSDVault emergency fallback.
+    /// Mirrors postNAV policy: reject nonzero lossNonce, enforce directional freeze,
+    /// and clamp upward moves to +10% over custodian book value (deployed principal).
+    function normalizeManualCustodianNAV(uint256, uint256 nav, uint256 lossNonce)
+        external
+        view
+        returns (bool shouldRecord, uint256 normalizedNav)
+    {
+        if (lossNonce != 0 || (_directionalFreeze && nav > _appliedNAV)) return (false, 0);
+        uint256 bookValue = _deployedPrincipal; uint256 maxUp = bookValue + (bookValue * 1000 / BPS_DENOMINATOR); uint256 applied = nav > maxUp ? maxUp : nav; return (true, applied);
+    }
     function setBlocklist(address blocklist_) external onlyOwner {
         if (blocklist_ == address(0)) revert ZeroAddress();
 ... 293 unchanged lines ...
```

### 14. [Medium] Missing pre-attestation freeze in RISKUSDVault redemption path causes preferential par exits and loss socialization

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault only blocks redemptions after its on-chain loss state turns true (derived from lastAttestedNAV and related flags). Negative NAV exists off-chain before an on-chain attestation (recordCustodianNAV/recordManualCustodianNAV) lands, allowing ordinary holders to redeem at par until that transaction or a pause occurs. Unlike atRISKUSD, the base vault does not consult a custodian freeze hook. This creates a timing-based fairness gap where early redeemers exit at par and remaining holders absorb the loss via later burns. The window is bounded by redemption caps and can be closed by timely pause, but persists whenever there is latency between off-chain loss and on-chain recognition/pause.

In RISKUSDVault, redeem() is gated solely by _lossPendingActive(), which becomes true only after the vault’s on-chain state reflects loss (unresolved attested loss, stale/unavailable NAV, or NAV shortfall computed from lastAttestedNAV). Custodian NAV is updated via recordCustodianNAV/recordManualCustodianNAV, typically called from HLTradingBridge.postNAV. Until such an attestation is mined, _lossPendingActive() remains false and redeem() permits 1:1 USDC outflows, bounded by daily/weekly caps and any configured reserve ratio. By contrast, atRISKUSD consults a custodian directional-freeze hook; RISKUSDVault does not. On Arbitrum, attackers do not need mempool visibility; it suffices that a real off-chain loss occurs and operators have not yet paused or attested on-chain. Early redeemers can exit at par before recognition; later, when the attestation lands, redemptions are blocked and the loss is socialized via burnForLoss/finalizeAttestedLoss to remaining holders. Strong operational mitigations exist: pausing the RISKUSD token (which blocks user transferFrom during redeem) or pausing the vault can promptly close the window while preserving loss settlement (RISKUSD burn bypasses token pause). Nonetheless, any non-zero latency between off-chain loss and on-chain attestation/pause enables a bounded but real fairness gap.

#### Severity

**Impact Explanation:** [High] Early redeemers can exit at par while remaining holders absorb the loss through subsequent supply burns, constituting a direct, material loss of principal for a subset of users.

**Likelihood Explanation:** [Low] Exploitation requires a short timing window between an off-chain loss and on-chain attestation/pause without public mempool visibility on Arbitrum. Diligent operators can typically pause promptly; caps and buffers further bound the window, making successful exploitation less frequent.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: Off-chain loss occurs; users redeem before attestation/pause. Preconditions: the custodian’s actual NAV falls below total deployed; no new recordCustodianNAV/manual attestation has landed; RISKUSD and RISKUSDVault are not paused; vault has USDC buffer and daily/weekly caps are not yet exhausted. Steps: (1) A holder infers a drawdown from public signals. (2) They call RISKUSDVault.redeem up to available USDC and within caps. (3) Since _lossPendingActive() is still false, redemption executes at par. (4) Later, operators attest NAV and block further redemptions; loss is socialized via burn to remaining holders.
#### Preconditions / Assumptions
- (a). Off-chain custodian NAV < total deployed capital (real loss occurred)
- (b). No recordCustodianNAV/recordManualCustodianNAV has landed (lastAttestedNAV still healthy)
- (c). RISKUSD token not paused; RISKUSDVault not paused
- (d). Vault has sufficient USDC buffer and redemption caps are not yet exhausted
- (e). No reliance on public mempool visibility (Arbitrum environment)

### Scenario 2.
Scenario 2: Two-day cap exploitation across a daily reset before attestation lands. Preconditions: same as Scenario 1, plus attestation/pause does not occur before the daily window resets. Steps: (1) The attacker redeems near the end of day up to the daily cap. (2) After the daily window resets and before attestation/pause, they redeem again up to the new daily cap. (3) Once attestation or pause occurs, further redemptions are blocked and the loss is socialized to remaining holders.
#### Preconditions / Assumptions
- (a). All Scenario 1 preconditions
- (b). Attestation and/or pause is delayed past a daily window boundary
- (c). Sufficient USDC and new-day cap headroom remain after reset

### Scenario 3.
Scenario 3: Custodian directional freeze protects atRISKUSD, but base RISKUSD remains open. Preconditions: HLTradingBridge directional freeze is enabled (atRISKUSD actions blocked), RISKUSD and RISKUSDVault are not paused, off-chain loss exists, and no recordCustodianNAV has landed. Steps: (1) Base RISKUSD holders redeem via RISKUSDVault.redeem while _lossPendingActive() is still false. (2) atRISKUSD holders are blocked by the custodian freeze hook. (3) After attestation/pause, redemptions stop and the loss is socialized across remaining holders, including atRISKUSD depositors.
#### Preconditions / Assumptions
- (a). HLTradingBridge directional freeze is enabled (tierShareActionsPaused = true)
- (b). RISKUSD token not paused; RISKUSDVault not paused
- (c). Off-chain loss exists; no recordCustodianNAV has landed yet
- (d). atRISKUSD integrates the freeze hook; RISKUSDVault does not

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 325 unchanged lines ...
         // Exempt _lossReporter for protocol-controlled loss/yield accounting that must remain live.
         if (_lossPendingActive() && msg.sender != _lossReporter) revert LossPending();
+        if (msg.sender != _lossReporter) { address c = _custodian; if (c.code.length != 0) { (bool ok, bytes memory data) = c.staticcall(abi.encodeWithSignature("tierShareActionsPaused()")); if (ok && data.length >= 32 && abi.decode(data, (bool))) revert LossPending(); } }
         _requireNotBlocked(msg.sender);
         uint256 backingAssetsBefore = solvencyBackingAssets();
 ... 25 unchanged lines ...
         // OF-NEW-01 (12th audit): Block redemptions while loss is pending
         if (_lossPendingActive()) revert LossPending();
+        { address c = _custodian; if (c.code.length != 0) { (bool ok, bytes memory data) = c.staticcall(abi.encodeWithSignature("tierShareActionsPaused()")); if (ok && data.length >= 32 && abi.decode(data, (bool))) revert LossPending(); } }
         _requireNotBlocked(msg.sender);
         uint256 backingAssetsBefore = solvencyBackingAssets();
 ... 1427 unchanged lines ...
```

### 15. [Medium] Missing wallet-level blocklist wiring in FORAGETreasury partnership vesting causes continued governance control by blocklisted beneficiaries

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Partnership DelegatingVestingWallets created by FORAGETreasury are never wired to a blocklist and cannot be wired later, enabling a blocklisted beneficiary to continue directing the vesting wallet’s voting power by re-delegating to unblocked addresses. Piecemeal delegate blocks can be evaded by repeatedly changing delegates.

FORAGETreasury.distributePartnership creates a new DelegatingVestingWallet, funds it, precommits and sets the FORAGE token, but never calls the wallet’s setBlocklist. Only the treasury address is authorized to set/replace the wallet’s blocklist, and FORAGETreasury exposes no function to forward such calls later. As a result, each vesting wallet’s local _blocklist remains unset permanently. DelegatingVestingWallet’s sensitive operations (e.g., delegateVotingPower) call _requireNotBlocked using only the wallet’s own _blocklist, so with it unset these checks are no-ops. ForageToken.delegate enforces blocklist only on the caller (the vesting wallet) and the delegatee, not on the beneficiary; ForageGovernor enforces blocklist on the actual proposer/voter, not a vesting wallet’s beneficiary. Therefore, once a beneficiary is blocklisted at the protocol level, they can still re-delegate the vesting wallet’s votes to any unblocked address and continue influencing governance. If operations blocklist known delegates piecemeal but do not blocklist the vesting wallet itself, the beneficiary can repeatedly re-delegate to fresh addresses to maintain influence. This breaks enforcement of blocklist intent within governance control. Direct FORAGE releases to a blocked beneficiary remain prevented by token-level blocklist checks at transfer time, so the impact is specifically on governance influence, not direct fund theft.

#### Severity

**Impact Explanation:** [Medium] The issue undermines enforcement of blocklist intent within governance by allowing a blocklisted beneficiary to continue directing a vesting wallet’s voting power. This affects important non-core protocol functionality (governance influence) but does not directly steal funds or halt core protocol operations.

**Likelihood Explanation:** [Medium] Preconditions are plausible: partnership vesting wallets exist by design; beneficiaries can be blocklisted; wallets are not automatically blocklisted; and the beneficiary can select unblocked delegates. No admin malice or user mistakes are required, though some constraints exist (blocklisting event and absence of wallet-level blocklisting), placing this at medium likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: A beneficiary of a partnership DelegatingVestingWallet is later added to the protocol Blocklist. Because the vesting wallet’s local _blocklist was never wired and remains unset, the beneficiary calls delegateVotingPower to an unblocked EOA. DelegatingVestingWallet performs no effective blocklist checks, and ForageToken.delegate checks only the wallet (caller) and new delegatee, not the beneficiary. The delegation succeeds, allowing continued voting influence via the unblocked proxy.
#### Preconditions / Assumptions
- (a). A partnership DelegatingVestingWallet was created by FORAGETreasury.distributePartnership, funded, and setForageToken was called (delegation is available).
- (b). FORAGETreasury did not set the wallet’s local blocklist; it exposes no forwarding function; the wallet’s _blocklist remains unset.
- (c). The beneficiary address has been added to the protocol Blocklist; ForageToken.blocklist points to the Blocklist contract.
- (d). The vesting wallet contract address itself is not blocklisted at the token level (default unless ops add it).
- (e). The beneficiary controls an unblocked EOA to receive delegation.

### Scenario 2.
Scenario 2: Operations respond by blocklisting known delegate addresses but do not blocklist the vesting wallet. The beneficiary repeatedly calls delegateVotingPower to fresh, unblocked EOAs. Each redelegation succeeds for the same reasons (unset wallet _blocklist; token checks only caller and delegatee), enabling persistent governance influence despite piecemeal mitigations.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1.
- (b). Operations blocklist known delegate addresses but do not blocklist the vesting wallet address at the token level.

#### Proposed fix

##### FORAGETreasury.sol

File: `openforage_smart_contracts/src/FORAGETreasury.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/FORAGETreasury.sol)

```diff
 ... 153 unchanged lines ...
         wallet = address(new DelegatingVestingWallet(beneficiary, start, duration, cliff, address(this)));
         DelegatingVestingWallet(wallet).setInitialDelegatee(delegatee);
+        DelegatingVestingWallet(wallet).setBlocklist(blocklist);
         _forageToken.safeTransfer(wallet, amount);
         DelegatingVestingWallet(wallet).precommitForageToken(address(_forageToken));
 ... 69 unchanged lines ...
```

### 16. [Medium] Missing yield/loss synchronization path in atRISKUSD when yieldSource is USDCTreasury causes stale share prices and depositor yield underpayment

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

atRISKUSD is wired with yieldSource = USDCTreasury, but USDCTreasury (and HLTradingBridge) never call atRISKUSD.accrueYield() or absorbLoss() and never handle RISKUSD balances. As a result, atRISKUSD._legitimateAssets (and totalAssets) never reflect custodian PnL, leaving tier share prices stale. Profits are split to earmarks in USDCTreasury and can be sent to RISKUSDVault as USDC, but are never accrued to tiers; losses are handled centrally by RISKUSDVault without tier absorption. Weekly withdrawal caps that depend on totalAssets are also understated during profitable periods.

The repository’s default wiring sets each atRISKUSD vault’s yieldSource to USDCTreasury. atRISKUSD only changes its backing (_legitimateAssets) via user flows or via yieldSource-only calls to accrueYield()/absorbLoss(), which transfer RISKUSD in/out and update _legitimateAssets. USDCTreasury does not mint/hold RISKUSD and never calls these functions; HLTradingBridge also never interacts with atRISKUSD. Returned PnL USDC is held and split by USDCTreasury into earmarks (foundation/protocol/agent and a vault top-up earmark payable only to RISKUSDVault), which does not increase atRISKUSD’s totalAssets. Consequently, tier exchange rates do not reflect custodian PnL: profits are not accrued to atRISKUSD holders, and losses are not absorbed per tier. In profitable periods, atRISKUSD.totalAssets remains understated, tightening weekly withdrawal caps relative to economically warranted capacity. Loss gating still functions because atRISKUSD queries yieldSource.riskusdVault().lossPending(), but per-tier economics are not enforced.

#### Severity

**Impact Explanation:** [Medium] Direct, material loss of yield to atRISKUSD depositors and significant but temporary availability reduction due to understated withdrawal caps; no principal loss or long-term freeze.

**Likelihood Explanation:** [Medium] Requires profits or losses to occur and be returned/recorded under normal operations—plausible and expected for the strategy but not unconditional every period.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Profits recognized off-chain and returned on-chain via HLTradingBridge to USDCTreasury are split to earmarks, with depositor claims disbursed only as USDC to RISKUSDVault; no atRISKUSD.accrueYield() is called, so tier share prices never rise and depositors receive no on-chain yield.
#### Preconditions / Assumptions
- (a). atRISKUSD.yieldSource is USDCTreasury (repository default wiring)
- (b). HLTradingBridge reconciles and returns PnL USDC to USDCTreasury under normal operations
- (c). USDCTreasury never calls atRISKUSD.accrueYield() and does not handle RISKUSD
- (d). No other in-repo contract calls atRISKUSD.accrueYield()

### Scenario 2.
A custodian loss occurs and is processed centrally by RISKUSDVault (burnForLoss/finalizeAttestedLoss); atRISKUSD.absorbLoss() is never called, so per-tier loss absorption never happens and tier fairness is broken, even though loss gating prevents stale exits.
#### Preconditions / Assumptions
- (a). atRISKUSD.yieldSource is USDCTreasury (repository default wiring)
- (b). A custodian loss event occurs and is recorded in RISKUSDVault
- (c). RISKUSDVault processes loss centrally via burnForLoss/finalizeAttestedLoss
- (d). USDCTreasury never calls atRISKUSD.absorbLoss() and no other in-repo contract does

### Scenario 3.
Positive PnL accumulates without any atRISKUSD accrual; atRISKUSD.totalAssets remains at principal-only levels and is used as the base for weekly withdrawal caps, leading to tighter-than-warranted withdrawal throughput during profitable periods.
#### Preconditions / Assumptions
- (a). atRISKUSD.yieldSource is USDCTreasury (repository default wiring)
- (b). Positive PnL is realized and returned to USDCTreasury
- (c). No atRISKUSD.accrueYield() is called, so totalAssets exclude the PnL
- (d). Withdrawal caps derive from atRISKUSD.totalAssets

#### Proposed fix

##### USDCTreasury.sol

File: `openforage_smart_contracts/src/USDCTreasury.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/USDCTreasury.sol)

```diff
 // SPDX-License-Identifier: MIT
 pragma solidity ^0.8.20;

 import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
 import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
 import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
 import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
 import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
 import "@openzeppelin/contracts/utils/math/SignedMath.sol";
 import "./FinalizeDelayProfile.sol";

 interface IUSDCTreasuryBlocklist {
     function isBlocked(address account) external view returns (bool);
 }

 /// @title USDCTreasury
+/* FIXME (protocol): USDCTreasury is wired as atRISKUSD.yieldSource but does not call
+ * atRISKUSD.accrueYield()/absorbLoss(). Implement a settlement path (or a dedicated
+ * router) that mints/forwards RISKUSD to atRISKUSD per VaultRegistry yield splits,
+ * and absorbs losses per tier, forwarding received RISKUSD to RISKUSDVault burn. */
 /// @notice Single protocol-USDC router for target accounting and returned-cash earmarks.
 contract USDCTreasury is
 ... 154 unchanged lines ...
     }

+    // NOTE (protocol): This only earmarks returned PnL. Add a keeper-only settlement that deposits
+    // VAULT_TOP_UP USDC into RISKUSDVault to mint RISKUSD and calls atRISKUSD[i].accrueYield() per tier.
     function returnPnLUSDC(uint256 vaultId, uint256 amount) external nonReentrant {
         if (msg.sender != hlTradingBridge) revert UnauthorizedBridge();
 ... 143 unchanged lines ...
     }

+    /* Suggested additions (protocol):
+     * - function settleTierProfits(uint256 vaultId): deposit EARMARK_VAULT_TOP_UP USDC into RISKUSDVault,
+     *   then call atRISKUSD[i].accrueYield() per VaultRegistry.yieldSplitsBps (respect mint caps).
+     * - function settleTierLosses(uint256 vaultId): call atRISKUSD[i].absorbLoss() per splits and forward received RISKUSD to RISKUSDVault.burnForLoss(). */
     function _authorizeUpgrade(address) internal override onlyOwner {}
 }
```

### 17. [Medium] Monotonic daily snapshot in RISKUSDVault daily cap logic causes single-day exhaustion of weekly redemptions

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault’s daily redemption cap bases its limit on a snapshot that is set to max(previousSnapshot, currentSupply) at daily rollover and is never reduced. After supply contraction (e.g., loss burns or net redemptions), this stale high snapshot allows redemptions that are a larger fraction of the current supply than the daily BPS suggests. Because weekly cap enforcement runs first, total weekly outflow remains bounded, but the daily cap can be loose enough to consume the entire weekly allowance in a single day, denying redemptions to other users for the rest of the week.

The daily redemption logic in RISKUSDVault uses a rolling snapshot variable (_dailyRedemptionWindowStartSupply) to compute the cap: cap = snapshot * dailyRedemptionCapBps / 10000. On daily rollover, this snapshot is set to max(previousSnapshot, currentSupply) and is never reduced elsewhere. As a result, when total supply later contracts (due to burnForLoss or net redemptions), the daily cap remains tied to a stale, larger historical supply rather than the current supply. The weekly cap is enforced first and uses a protected snapshot (with min-tracking and adjustments on burnForLoss), so weekly totals cannot be exceeded. However, whenever the stale daily cap computed from the high watermark is greater than or equal to the weekly cap computed from the lower weekly snapshot, an early redeemer can consume most or all of the weekly allowance in a single day. This produces a time-based denial of redemption access for other users for the remainder of the weekly window. Additional checks like reserve ratio and vault USDC balance may constrain magnitudes; with default minReserveRatioBps = 0 and sufficient vault liquidity, the effect is straightforward. The behavior does not cause fund theft or invariant breaks; it weakens intended daily smoothing and enables one-day monopolization of that week’s redemption capacity.

#### Severity

**Impact Explanation:** [Medium] Redemptions—a core function—can be denied to other users for the remainder of the weekly window once a single actor consumes the weekly allowance early, constituting a significant but temporary DoS of core functionality.

**Likelihood Explanation:** [Medium] Exploitation requires realistic but non-default conditions (historically higher supply vs current lower), notable capital to consume the weekly cap, sufficient vault liquidity, and early timing; no trusted-role misuse or external integration failure is required.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: Single-day exhaustion of weekly allowance after supply contraction. Preconditions: past high supply (e.g., 200M RISKUSD), later reduced to ~40M after a resolved loss burn; weekly window just reset with weekly snapshot ≈ 40M (weekly cap ≈ 5% = 2M), while daily snapshot remains ≈ 200M (daily cap ≈ 2% = 4M). An attacker redeems 2M early in the day. Weekly check passes (<= 2M), daily check passes (<= 4M), transfer succeeds. Result: weekly allowance is consumed on Day 1; other holders revert with WeeklyRedemptionCapExceeded for the rest of the week.
#### Preconditions / Assumptions
- (a). A historically higher supply followed by contraction (e.g., burnForLoss or net redemptions) leaving the daily snapshot high while the weekly snapshot is low
- (b). Loss is fully resolved (lossPendingActive() is false) and the contract is not paused
- (c). Sufficient vault USDC liquidity; minReserveRatioBps is 0 or otherwise non-binding
- (d). Attacker holds enough RISKUSD to consume up to the weekly cap and acts early in the weekly/day window

### Scenario 2.
Scenario 2: Front-running to monopolize the weekly allowance on Day 1 via stale daily snapshot. Preconditions: current supply ~50M after prior contractions; daily snapshot persists high from history (~250M); weekly window reset with weekly snapshot ~50M (weekly cap ≈ 2.5M); daily cap ≈ 5M (2% of 250M) ≥ weekly cap. The attacker redeems 2.5M early Day 1. Weekly and daily checks both pass. Result: the entire weekly allowance is consumed on Day 1; later redeemers are blocked for the remainder of the week.
#### Preconditions / Assumptions
- (a). Daily snapshot remains elevated from a prior high-supply period while the weekly snapshot is low after reset
- (b). Redeem is enabled (not paused, no loss-pending blockage)
- (c). Sufficient vault USDC liquidity; minReserveRatioBps is 0 or otherwise non-binding
- (d). Attacker holds enough RISKUSD to consume the weekly cap and acts early in the weekly/day window

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 1284 unchanged lines ...
     function effectiveDailyRedemptionCap() public view returns (uint256) {
         uint256 effectiveSupply;
+        uint256 currentSupply = _riskusd.totalSupply();
         if (block.timestamp >= _dailyRedemptionWindowStart + DAILY_WINDOW) {
-            effectiveSupply = _dailyRedemptionWindowStartSupply > _riskusd.totalSupply()
-                ? _dailyRedemptionWindowStartSupply
-                : _riskusd.totalSupply();
+            effectiveSupply = currentSupply;
         } else if (_dailyRedemptionWindowStartSupply == 0) {
-            effectiveSupply = _riskusd.totalSupply();
+            effectiveSupply = currentSupply;
         } else {
-            effectiveSupply = _dailyRedemptionWindowStartSupply;
+            effectiveSupply = _dailyRedemptionWindowStartSupply > currentSupply
+                ? currentSupply
+                : _dailyRedemptionWindowStartSupply;
         }
         return effectiveSupply * _dailyRedemptionCapBps / 10000;
 ... 204 unchanged lines ...
             uint256 elapsed = (block.timestamp - _dailyRedemptionWindowStart) / DAILY_WINDOW;
             _dailyRedemptionWindowStart += elapsed * DAILY_WINDOW;
-            _dailyRedemptionWindowStartSupply = _dailyRedemptionWindowStartSupply > cachedTotalSupply
-                ? _dailyRedemptionWindowStartSupply
-                : cachedTotalSupply;
+            _dailyRedemptionWindowStartSupply = cachedTotalSupply;
         } else if (_dailyRedemptionWindowStartSupply == 0) {
             _dailyRedemptionWindowStartSupply = cachedTotalSupply;
         }

-        uint256 cap = _dailyRedemptionWindowStartSupply * _dailyRedemptionCapBps / 10000;
+        uint256 basis = _dailyRedemptionWindowStartSupply;
+        if (cachedTotalSupply < basis) {
+            basis = cachedTotalSupply;
+        }
+        uint256 cap = basis * _dailyRedemptionCapBps / 10000;
         if (_dailyRedemptionUsed + riskusdAmount > cap) revert DailyRedemptionCapExceeded();
     }
 ... 273 unchanged lines ...
```

### 18. [Medium] Oversized-entry skipping in StakingQueue._processLane under capacity scarcity causes later small deposits to bypass earlier large deposits, delaying victims' yield accrual

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When tier/combined capacity is scarce, StakingQueue._processLane skips earlier live entries that are larger than the remaining capacity and continues scanning, allowing later smaller entries to be processed first. Because head advancement does not move past a live, unblocked oversized entry, this behavior can repeat across calls, causing later users to leapfrog earlier larger deposits and delaying victims’ atRISKUSD minting (yield start).

StakingQueue.processQueue(tier, maxEntries) computes combined and per-tier available capacity, then calls _processLane with a scan budget (maxEntries). In _processLane, the loop scans from the lane head while processedCount < budget and scanned < budget. It continues past entries if they are processed/cancelled, blocked, or if entry.riskusdAmount exceeds the local remaining availCapacity or availTierCapacity. Entries that fit are deposited, reducing local capacity. Afterward, _advanceHead advances the head only over processed/cancelled/blocked entries and stops at the earliest live, unblocked entry—even if that entry was too large to fit. Since processQueue is permissionless and callers choose maxEntries, a caller can scan past oversized earlier entries and process later smaller ones. Under intermittent small capacity windows, this enables sustained leapfrogging: later small deposits are serviced first while earlier large deposits wait for a single window large enough to fit them. Impact is fairness/liveness harm: victims’ deposits remain unprocessed despite recurring small capacity, delaying their atRISKUSD minting and yield accrual. No principal is lost; victims can cancel and re-queue smaller chunks, but this places burden and cost on them. Operational controls (compactQueue, blocklist, pause) do not enforce FIFO or prevent the skip-on-oversize logic; the priority lane further indicates non-strict FIFO is accepted, but does not mitigate standard-lane leapfrogging.

#### Severity

**Impact Explanation:** [Medium] Victims suffer a direct, material loss of yield due to delayed atRISKUSD minting and a significant but temporary availability loss of processing for their deposits; no principal loss or permanent freeze occurs and a workaround (cancel/re-queue) exists.

**Likelihood Explanation:** [Medium] Exploitation relies on realistic but partially external conditions (capacity scarcity and intermittent windows) and a permissionless call with a chosen scan budget; there is rational incentive (earlier yield), but timing and capacity availability are not fully attacker-controlled.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (single earlier large entry starved by later small splits): A victim V enqueues an earlier standard-lane deposit of 100 RISKUSD in tier T. Available capacity windows are ~50. An attacker A appends several later 10 RISKUSD deposits and calls processQueue(T, large maxEntries). _processLane skips V’s oversized entry and processes A’s small entries that fit, reducing capacity. Head remains at V (live/unblocked). Repeated small windows allow A’s later deposits to be processed ahead of V, delaying V’s yield start until a single window ≥100 appears or V cancels and re-queues.
#### Preconditions / Assumptions
- (a). VaultRegistry vault is Active; StakingQueue is unpaused
- (b). Tier T has available capacity less than the first (victim) entry amount
- (c). Victim’s earlier standard-lane entry is live and unblocked
- (d). Attacker appends multiple smaller entries in the same lane and tier
- (e). processQueue is permissionless; attacker calls with a large maxEntries (scan budget)

### Scenario 2.
Scenario 3 (repeated capture of tiny capacity windows): Tier T’s cap is near-saturated; intermittent small headroom (e.g., 5–20) appears. Earlier large entries (80–150) are queued and live/unblocked; attacker has later entries sized 1–10. Whenever a small window opens, attacker calls processQueue(T, large maxEntries). _processLane skips earlier oversized entries and processes attacker’s small entries that fit, repeatedly consuming tiny windows. Earlier large entries are delayed from minting into atRISKUSD, postponing their yield accrual.
#### Preconditions / Assumptions
- (a). Tier T cap is near-saturated; intermittent small capacity windows appear (e.g., due to redemptions)
- (b). Earlier large entries in the same lane/tier are live and unblocked
- (c). Attacker has later small entries and monitors capacity windows
- (d). Attacker calls processQueue with large maxEntries whenever a window opens

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 460 unchanged lines ...
                 continue;
             }
-
+            // Enforce strict FIFO within lane: stop at first live, unblocked oversized entry.
             if (entry.riskusdAmount > availCapacity || entry.riskusdAmount > availTierCapacity) {
-                unchecked {
-                    ++i;
-                    ++scanned;
-                }
-                continue;
+                break;
             }
             if (_isBlocked(entry.depositor)) {
 ... 1061 unchanged lines ...
```

#### Related findings

##### [Medium] Head-of-line blocking in StakingQueue queue processing causes lane-level deposit processing DoS

###### Description

StakingQueue allows deposits larger than current combined or per-tier capacity to enter the queue. During processing, such entries are skipped but remain active, and the lane head does not advance over them. With per-call scan work capped by maxEntries, an attacker can maintain a head-of-line prefix of unprocessable entries so valid deposits behind are never reached, resulting in a sustained, lane-level DoS until privileged mitigation or user cancellation.

The StakingQueue join path accepts any riskusdAmount without checking combined or per-tier capacity. In processQueue, available combined and per-tier capacity are computed; _processLane scans entries up to a budget (derived from maxEntries), but for any entry where riskusdAmount exceeds either available capacity, the code simply continues (skips) without marking the entry processed or cancelled. The subsequent _advanceHead only skips processed, cancelled, or blocklisted entries, so active-but-unprocessable entries at the head keep the head in place. Since scanning is bounded per call, a head-of-line prefix longer than the scan budget prevents reaching valid entries behind it. Compaction cannot remove these entries because they remain active. This enables an attacker to: (a) jam a tier’s standard lane by inserting E+1 active entries larger than typical available capacity (or permanently above configured per-tier cap), (b) optionally jam the priority lane similarly if they can lock the minimal FORAGE per entry, and (c) sustain the jam cheaply by maintaining a prefix just longer than the keeper’s scan budget. Impact is denial of processing for affected depositors (no principal loss; users can cancel or switch lanes). Privileged mitigations exist (guardian blocklist allows head advancement on next processing, owner can adminCancelQueue), but absent timely intervention the queue can be starved. The highest-risk variant is a low-capital maintenance jam aligned to the keeper’s maxEntries, which is realistically exploitable.

###### Severity

**Impact Explanation:** [Medium] The behavior causes significant availability/DoS of a core subsystem (deposit processing) for affected lanes/tiers. There is no principal loss and users can cancel or use other lanes/tiers, so it is not a complete shutdown nor funds frozen without workaround.

**Likelihood Explanation:** [Medium] The highest-risk 'maintenance jam' variant is realistically achievable with modest capital by aligning a small head-of-line prefix to the keeper’s scan budget and typical availability. Privileged mitigations and operational variability lower persistence but do not preclude feasible exploitation.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Dual-lane jam of a tier: The attacker submits E+1 priority entries and E+1 standard entries at a target tier, each with riskusdAmount larger than per-tier cap or typical availability. In each processQueue(tier, E) call, both lanes scan E entries that are all unprocessable; heads do not advance; no valid entries behind are reached. All depositors in that tier are denied processing until privileged mitigation or user cancellation.
#### Preconditions / Assumptions
- (a). Keeper periodically calls processQueue with finite maxEntries E (bounded by gas).
- (b). The targeted tier has nonzero combined and per-tier availability at least intermittently (so processing does not always revert early).
- (c). Attacker holds sufficient RISKUSD to fund E+1 head-of-line entries in both lanes and sufficient FORAGE to meet the minimal per-entry lock to mark priority entries.
- (d). No immediate privileged mitigation (guardian blocklist or owner adminCancel) during the attack window.

### Scenario 2.
Standard-lane-only jam: The attacker submits E+1 standard-lane entries at a target tier, each larger than the per-tier cap or typical availability. Priority lane remains open. When processQueue runs, the standard lane scans E head entries that are unprocessable and remains stuck; valid standard-lane deposits behind are not processed.
#### Preconditions / Assumptions
- (a). Keeper periodically calls processQueue with finite maxEntries E.
- (b). The targeted tier has nonzero availability at least intermittently.
- (c). Attacker holds sufficient RISKUSD to fund E+1 head-of-line entries in the standard lane.
- (d). No immediate privileged mitigation during the attack window.

### Scenario 3.
Maintenance jam tuned to keeper budget: Observing keeper maxEntries E and typical availability, the attacker keeps E+1 head entries slightly larger than typical availability. Each processQueue scans E entries, finds them unprocessable, and does not advance the head. With modest capital and occasional top-ups to match E, the attacker sustains denial for that lane/tier.
#### Preconditions / Assumptions
- (a). Keeper uses a relatively stable or observable maxEntries E.
- (b). The targeted tier has intermittent small positive availability (typical bursts).
- (c). Attacker holds modest RISKUSD to keep about E+1 entries slightly above typical availability; can add a few entries if E increases.
- (d). No immediate privileged mitigation during the attack window.

###### Proposed fix

####### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 327 unchanged lines ...
             VaultConfig memory config = VaultRegistry(_vaultRegistry).getVault(_vaultId);
             if (config.status != VaultStatus.Active) revert VaultNotActive();
+            uint256 cap = config.capacityCap;
+            if (riskusdAmount > cap) revert TierDepositCapAboveVaultCapacity(riskusdAmount, cap);
+            if (riskusdAmount > _effectiveTierDepositCapForCap(tier, cap)) revert TierDepositCapExceeded(tier, riskusdAmount, _effectiveTierDepositCapForCap(tier, cap));
         }

 ... 94 unchanged lines ...
             _processLane(_tierPriorityQueue[tier], _tierPriorityHead[tier], tier, maxEntries, avail, tierAvail, true);
         // OF-M04: Cap head advancement to prevent DoS via dead entry accumulation
-        _tierPriorityHead[tier] = _advanceHead(_tierPriorityQueue[tier], _tierPriorityHead[tier], maxEntries);
+        _tierPriorityHead[tier] = _advanceHead(_tierPriorityQueue[tier], _tierPriorityHead[tier], maxEntries, _availableCapacityForCap(config.capacityCap), _availableTierDepositCapacityForCap(tier, config.capacityCap));

         avail = _availableCapacityForCap(config.capacityCap);
         tierAvail = _availableTierDepositCapacityForCap(tier, config.capacityCap);

         if (processed < maxEntries && avail > 0 && tierAvail > 0) {
             _processLane(
                 _tierStandardQueue[tier], _tierStandardHead[tier], tier, maxEntries - processed, avail, tierAvail, false
             );
-            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], maxEntries);
+            _tierStandardHead[tier] = _advanceHead(_tierStandardQueue[tier], _tierStandardHead[tier], maxEntries, _availableCapacityForCap(config.capacityCap), _availableTierDepositCapacityForCap(tier, config.capacityCap));
         }
     }
 ... 77 unchanged lines ...

     /// @dev OF-M04: Iteration cap prevents DoS via dead entry accumulation.
-    function _advanceHead(uint256[] storage lane, uint256 head, uint256 maxScan)
+    function _advanceHead(uint256[] storage lane, uint256 head, uint256 maxScan, uint256 availCapacity, uint256 availTierCapacity)
         internal
         view
         returns (uint256 newHead)
     {
         uint256 length = lane.length;
         newHead = head;
         uint256 scanned;
         while (newHead < length && scanned < maxScan) {
             QueueEntry storage entry = _queueEntries[lane[newHead]];
             if (!entry.processed && !entry.cancelled && !_isBlocked(entry.depositor)) {
-                break;
+                if (entry.riskusdAmount <= availCapacity && entry.riskusdAmount <= availTierCapacity) break;
             }
             unchecked {
 ... 1000 unchanged lines ...
```

### 19. [Low] Carryover of prior-week min supply in RISKUSDVault weekly cap rollover causes one-week redemption throttling

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault seeds the new week’s redemption cap from the prior week’s min-tracked totalSupply (lastActiveSupply) rather than the current supply at rollover. If supply recovered via deposits before the new week begins or after long inactivity, the next week’s aggregate redemption cap can be smaller than what current supply would suggest, temporarily tightening exits for all redeemers that week.

In RISKUSDVault._enforceWeeklyCap(), when a weekly window has expired, the contract resets counters and sets _windowStartSupply = (_lastActiveSupply > 0) ? _lastActiveSupply : current totalSupply, then resets _lastActiveSupply = current totalSupply. Within each active week, _lastActiveSupply is min-tracked only on redemptions and never raised by deposits. As a result, if redemptions drive a trough and subsequent deposits restore supply before rollover (or there is a long gap with no redemptions), the first redemption in the next active week seeds the cap from the prior trough rather than from current supply. This reduces that week’s aggregate redemption headroom compared with a pure current-supply basis. The effect is bounded to one subsequent active week because rollover also resets _lastActiveSupply to the current supply for future weeks. Daily caps are enforced independently and may bind first, but when the weekly cap is tighter, this rollover rule can cause on-chain reverts for some redeemers that week. The behavior is documented in-code (anti-inflation design), but it can still produce a transient, collective throttle.

#### Severity

**Impact Explanation:** [Low] The effect is a temporary, bounded reduction in weekly aggregate redemption headroom (typically small at defaults), potentially causing reverts for some redeemers that week but with no loss of principal or long-term freeze. Duration is at most one subsequent active week.

**Likelihood Explanation:** [Low] Realization requires multiple conditions outside the attacker’s full control: prior-week redemptions near cap, deposit recovery before rollover or long inactivity, and next-week demand near the cap. There is no direct profit motive (griefing-style), and default operations may not often saturate weekly caps.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 (defaults): In week N, users redeem near the weekly cap (5%), lowering lastActiveSupply below the earlier supply. Before the next week begins, deposits restore current totalSupply. In week N+1, the first redemption triggers rollover: _windowStartSupply is set to the prior week’s lastActiveSupply (the trough), so the weekly cap is computed on that lower basis (e.g., ~4.75% vs 5% of prior baseline). If aggregate redemptions approach the weekly cap, some redeemers revert that week.
#### Preconditions / Assumptions
- (a). Weekly window mechanics active (unpaused, no lossPending gating that prevents redemptions)
- (b). Default weeklyRedemptionCapBps ~ 5% and dailyRedemptionCapBps ~ 2%
- (c). Prior week redemptions lowered lastActiveSupply vs current supply (within cap limits)
- (d). Deposits restore supply before rollover
- (e). Next week’s aggregate redemption demand approaches/exceeds the reduced weekly cap

### Scenario 2.
Scenario 2 (temporary high-cap week): Governance (trusted, non-malicious) temporarily raises the weekly cap (e.g., to 20%). Late-week redemptions push lastActiveSupply down by ~20%. Deposits then restore supply before the next week. When the cap returns to 5% the following week, rollover seeds from the 20% trough, making that week’s cap ~4% of baseline instead of 5%. If weekly demand approaches the cap, some redeemers revert.
#### Preconditions / Assumptions
- (a). Governance temporarily raises weeklyRedemptionCapBps (legitimate operational change; trusted role, not malicious)
- (b). Heavy late-week redemptions reduce lastActiveSupply significantly (e.g., ~20%)
- (c). Deposits restore supply before rollover
- (d). Next week’s cap returns to normal (e.g., 5%)
- (e). Next week’s aggregate redemption demand approaches/exceeds the reduced weekly cap

### Scenario 3.
Scenario 3 (long inactivity): A past week’s redemptions (bounded by caps) or legitimate loss burns left a materially low lastActiveSupply. For several weeks, no one redeems while deposits increase supply. The next redemption after inactivity triggers rollover and seeds the weekly cap from the stale low watermark, temporarily tightening exits that week if demand meets the cap.
#### Preconditions / Assumptions
- (a). Historic lastActiveSupply is materially below current supply due to past redemptions (bounded by caps) or legitimate loss burns
- (b). Long period with no redemptions while deposits increase supply
- (c). The next active week’s aggregate redemption demand approaches/exceeds the reduced weekly cap

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 1264 unchanged lines ...
             effectiveSupply = _lastActiveSupply > 0 ? _lastActiveSupply : _riskusd.totalSupply();
         } else if (_windowStartSupply == 0) {
-            // No redemptions yet — use current supply
-            effectiveSupply = _riskusd.totalSupply();
+            // Window expired — mirror rollover clamp: max(lastActiveSupply/current, (_windowStartSupply - _weeklyRedemptionUsed))
+            uint256 candidate = _lastActiveSupply > 0 ? _lastActiveSupply : _riskusd.totalSupply();
+            uint256 netNoMintBasis =
+                _windowStartSupply > _weeklyRedemptionUsed ? (_windowStartSupply - _weeklyRedemptionUsed) : 0;
+            effectiveSupply = candidate < netNoMintBasis ? netNoMintBasis : candidate;
         } else {
             // Use only the window start supply — prevents cap inflation from mid-window deposits
 ... 201 unchanged lines ...
         // Lazy reset: if window has expired, reset used counter and advance window
         if (block.timestamp >= _weeklyRedemptionWindowStart + WEEKLY_WINDOW) {
+            uint256 netNoMintBasis =
+                _windowStartSupply > _weeklyRedemptionUsed ? (_windowStartSupply - _weeklyRedemptionUsed) : 0;
             _weeklyRedemptionUsed = 0;
             // OF-M02: Advance by elapsed periods (handles multi-week gaps)
             uint256 elapsed = (block.timestamp - _weeklyRedemptionWindowStart) / WEEKLY_WINDOW;
             _weeklyRedemptionWindowStart += elapsed * WEEKLY_WINDOW;
-            // OF-L21: Use last active-window supply to prevent cap inflation via temporary deposits
-            _windowStartSupply = _lastActiveSupply > 0 ? _lastActiveSupply : cachedTotalSupply;
+            // Clamp next basis to at least (prevStart - prevUsed) to avoid trough carryover while preventing pump inflation
+            uint256 candidate = _lastActiveSupply > 0 ? _lastActiveSupply : cachedTotalSupply;
+            _windowStartSupply = candidate < netNoMintBasis ? netNoMintBasis : candidate;
             // OF-007: Reset _lastActiveSupply for new window to prevent permanent cap ratchet-down
             _lastActiveSupply = cachedTotalSupply;
 ... 304 unchanged lines ...
```

#### Related findings

##### [Low] Pre-burn supply snapshot reuse in RISKUSDVault weekly cap rollover causes next-week redemption cap inflation

###### Description

RISKUSDVault seeds the next week’s weekly redemption cap from a pre-burn supply snapshot (_lastActiveSupply) taken during _enforceWeeklyCap() before user burns, and redeem() does not reduce this anchor post-burn. On weekly rollover, this can set the new window’s baseline above the true post-burn end-of-week supply, modestly increasing next week’s total allowed redemptions versus a strict post-burn baseline. The loss-burn path adjusts these anchors, but ordinary redemptions do not.

In redeem(), _enforceWeeklyCap() caches totalSupply before burning and min-tracks it into _lastActiveSupply to prevent cap inflation via mid-window deposits. When the weekly window rolls over, _windowStartSupply is set to _lastActiveSupply (if nonzero). Ordinary redemptions do not reduce _lastActiveSupply after the burn, so the next week’s cap may be computed from a pre-burn value that exceeds the true post-burn end-of-week supply. In contrast, _burnForLoss() explicitly reduces both _windowStartSupply (if within the current week) and _lastActiveSupply, ensuring loss events tighten current and subsequent caps. Impact: a small, bounded weakening of the weekly throttle (more next-week redemptions than a strict post-burn baseline would allow). With default parameters (5% weekly, 2% daily), the maximum extra headroom is bounded by weeklyBps × last-day redemption ≤ 0.05 × 0.02 × supply = 0.1% of supply. Daily caps, reserve ratio, vault liquidity, and NAV/loss gates further limit practical effects, and in stressed states redemptions can be blocked entirely. The harmed party is the protocol’s flow-control policy (not direct user funds).

###### Severity

**Impact Explanation:** [Low] The effect is a small, bounded weakening of the protocol’s weekly redemption throttle (policy/flow-control) without direct loss of funds, invariant breaks, or functional DoS. Under default parameters the maximum extra headroom is ~0.1% of supply, further limited by daily caps, reserve ratio, liquidity, and NAV/loss gates.

**Likelihood Explanation:** [Medium] Exploitation requires boundary timing (ideally being the last redeemer before rollover) and available daily headroom on the final day. These constraints are outside the attacker’s full control but are realistic and recurring; coordination can increase the chance without relying on rare or exceptional states.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single actor boundary redemption: Near the end of the weekly window, an actor redeems up to the remaining daily cap (e.g., 2% of 100M = 2M). _enforceWeeklyCap() snapshots pre-burn supply (100M) and min-tracks it into _lastActiveSupply; the burn reduces actual supply to 98M but _lastActiveSupply is not reduced. On the first redemption in the next week, rollover sets _windowStartSupply to 100M, so the weekly cap becomes 5% of 100M = 5M instead of 4.9M based on 98M. The extra 100k weekly headroom can be consumed early next week.
#### Preconditions / Assumptions
- (a). No active NAV/loss gate (_lossPendingActive() == false)
- (b). Sufficient USDC in the vault and reserve ratio (if set) remains satisfied
- (c). Weekly and daily caps configured at production-like values (e.g., 5% weekly, 2% daily)
- (d). Actor holds RISKUSD and can submit redeem() near the weekly boundary
- (e). Remaining daily redemption capacity exists on the final day

### Scenario 2.
Coordinated attempt to be last redeemer: Multiple accounts coordinate to maximize the chance that a chosen account performs the final redemption of the week within the daily cap. This locks in a higher pre-burn _lastActiveSupply for rollover, yielding the same small next-week headroom increase (weeklyBps × last-day redemption) for early consumption.
#### Preconditions / Assumptions
- (a). No active NAV/loss gate (_lossPendingActive() == false)
- (b). Sufficient USDC in the vault and reserve ratio (if set) remains satisfied
- (c). Weekly and daily caps configured at production-like values (e.g., 5% weekly, 2% daily)
- (d). Coordinated accounts to increase likelihood of being last redeemer before weekly rollover
- (e). Remaining daily redemption capacity exists on the final day

### Scenario 3.
Repeated weekly gaming: When conditions permit (sufficient liquidity, reserve ratio met, no NAV/loss gate), an actor repeats near-boundary redemptions across weeks. Each opportunity captures a small extra next-week headroom (bounded by ~0.1% of supply under defaults), realizable within daily caps. Effects are limited per week and do not compound materially.
#### Preconditions / Assumptions
- (a). No active NAV/loss gate (_lossPendingActive() == false) in the applicable weeks
- (b). Sufficient USDC in the vault and reserve ratio (if set) remains satisfied
- (c). Weekly and daily caps configured at production-like values (e.g., 5% weekly, 2% daily)
- (d). Ability to execute near-boundary redemptions in multiple weeks when feasible
- (e). Remaining daily redemption capacity exists on the final day in those weeks

###### Proposed fix

####### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 377 unchanged lines ...
         IERC20(address(_riskusd)).safeTransferFrom(msg.sender, address(this), riskusdAmount);
         _riskusd.burn(address(this), riskusdAmount);
+        if (_lastActiveSupply == riskusdSupplyBefore) {
+            _lastActiveSupply = riskusdSupplyBefore > riskusdAmount ? riskusdSupplyBefore - riskusdAmount : 0;
+        }
         _reduceMintActiveSupply(riskusdAmount);

 ... 1404 unchanged lines ...
```

### 20. [Low] Decoupled daily caps for intents and returns in HLTradingBridge cause temporary same-day forwarding DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge enforces daily caps separately for withdrawal intents and for actual USDC returns. Because requestWithdrawalIntent() charges an intent-side counter while returnPrincipalUSDC()/returnPnLUSDC() charge a distinct return-side counter, a same-day intent can be booked and its arrival reconciled, yet forwarding to the vault/treasury can still revert if the return bucket is already exhausted. Arrived funds remain queued on the bridge until the next daily reset, temporarily delaying redemptions that depend on near-term top-ups.

HLTradingBridge uses two independent throttles with the same BPS policy but distinct accounting: _enforceWithdrawalIntentCaps() tracks daily usage for booking requests (requestWithdrawalIntent), while _enforceReturnCaps() tracks daily usage for forwarding arrived funds (returnPrincipalUSDC and returnPnLUSDC). The two buckets do not synchronize or reserve return capacity at request time, and their day windows reset independently. As a result, operators can validly book an intent within the intent-side budget and later reconcile its arrival into _reconciledReturnLiquidity, but the same-day attempt to forward the arrived USDC can revert due to the return-side daily cap already being consumed (e.g., by earlier PnL or principal returns). Funds are safe and are queued on the bridge until caps reset, but vault top-ups can be delayed, temporarily impacting user redemptions that rely on near-term custodian returns. A related variant occurs when principal shrinks after intent booking, reducing the per-call cap below the intent amount and forcing multiple calls or partial next-day forwarding. The design imposes a deliberate two-stage throttle and a queue; the issue is a liveness/availability weakness from lack of reservation between stages, not a loss-of-funds bug.

#### Severity

**Impact Explanation:** [Medium] Temporary availability loss: arrived funds can be stranded on the bridge until the next daily reset, delaying vault/treasury top-ups and causing redemptions to fail when they depend on same-day custodian returns. No principal loss, no broken invariants, and no long-term freezes.

**Likelihood Explanation:** [Low] Requires non-trivial operational timing/sequencing (e.g., consuming the return bucket earlier in the day, window drift, or post-intent principal changes) and user redemption demand that needs immediate top-ups. Single-open-intent and daily resets further constrain incidence.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Same-day PnL return fully consumes the return-per-day cap; later that day, the executor books a valid withdrawal intent and the keeper reconciles its arrival, but forwarding via returnPrincipalUSDC reverts due to ReturnPerDayCapExceeded. The arrived USDC remains in the bridge’s reconciled buffer until the next daily reset, delaying vault top-up and any redemptions depending on it.
#### Preconditions / Assumptions
- (a). HLTradingBridge return caps configured (e.g., default 10% per-call and per-day in initialize).
- (b). Executor and keeper are operating normally (trusted roles), performing a same-day PnL return that consumes the return-per-day cap, then booking an additional principal withdrawal intent.
- (c). Off-chain withdrawal arrives and is reconciled the same day.
- (d). Vault liquidity for redemptions relies on the expected same-day top-up from the bridge.
- (e). No pause/directional freeze/blocklist conditions preventing the calls.

### Scenario 2.
Independent day-window anchors drift: a withdrawal intent is booked and reconciled shortly before the return window resets; return attempts revert until the return bucket’s window resets minutes/hours later, causing short-term forwarding delay despite funds having arrived at the bridge.
#### Preconditions / Assumptions
- (a). Intent-side and return-side daily windows are anchored and reset independently.
- (b). Executor books a withdrawal intent during a period when the return-side window has not yet reset.
- (c). Keeper reconciles arrival before the return window resets.
- (d). Users require forwarding before the upcoming reset for redemptions to succeed.
- (e). No pause/directional freeze/blocklist conditions preventing the calls.

### Scenario 3.
After booking a valid intent, principal is reduced (e.g., other returns), shrinking the per-call cap below the intent amount. A single-call completion reverts due to ReturnPerCallCapExceeded and must be split across multiple calls or, if the daily cap is tight, partially deferred to the next day.
#### Preconditions / Assumptions
- (a). A valid withdrawal intent is booked based on the then-current principal and caps.
- (b). Before completion, principal is reduced (e.g., by other returns), lowering the per-call cap below the intent amount.
- (c). Executor attempts a single-call forwarding that now exceeds the per-call cap; multi-call is possible but may be limited by remaining daily cap.
- (d). Users may rely on immediate full forwarding for same-day redemptions.
- (e). No pause/directional freeze/blocklist conditions preventing the calls.

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 98 unchanged lines ...
     uint256 internal _deployUsedDayStart;

+    // FIXME(reservation): Add reserved return-capacity counters to guarantee same-day completion for booked intents:
+    // uint256 internal _returnReservedThisDay; uint256 internal _returnReservedDayStart;
     uint16 internal _returnPerCallCapBps;
     uint16 internal _returnPerDayCapBps;
 ... 92 unchanged lines ...
         _returnPerDayCapBps = 1_000;
         _returnUsedDayStart = block.timestamp;
+        // FIXME(reservation): Initialize _returnReservedDayStart = block.timestamp; (new storage) in a reinitializer.
         _withdrawalIntentUsedDayStart = block.timestamp;
     }
 ... 107 unchanged lines ...
         }
         _enforceWithdrawalIntentCaps(amount);
+        // FIXME(reservation): Reserve same-day return capacity here: _reserveReturnCapacity(amount) after syncing return-day windows.

         intentId = keccak256(
 ... 316 unchanged lines ...

     function _enforceReturnCaps(uint256 amount) internal {
+        // FIXME(reservation): First consume reserved capacity (min(amount, _returnReservedThisDay)) after syncing return-day windows,
+        // then charge any remainder to _returnUsedThisDay; keep per-call cap unchanged.
         uint256 principalBase = _deployedPrincipal;
         uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
 ... 60 unchanged lines ...
```

### 21. [Low] Global per‑voter nonce for vote‑by‑signature in ForageGovernor (OZ GovernorUpgradeable) causes targeted gasless‑vote DoS via stale‑signature submission

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

ForageGovernor inherits OpenZeppelin Governor v5’s global per‑voter nonce for vote‑by‑signature. If an adversary holds an older, still‑valid signature from a voter for another Active proposal, they can submit it first to consume the voter’s current nonce, invalidating a newly produced signature for a different proposal. Near proposal deadlines, this can cause the victim to miss their intended vote. This is a per‑user, recoverable disruption (re‑signing with the next nonce), not a system‑wide failure.

ForageGovernor adopts OZ GovernorUpgradeable’s vote‑by‑signature flow, which uses a single global nonce per voter (NoncesUpgradeable). Each signature’s EIP‑712 digest includes proposalId, support, voter, and the voter’s current nonce. Validation consumes the nonce only if the signature is accepted; any revert rolls back the nonce increment. Votes can only be cast while the targeted proposal is Active, so expired signatures cannot burn nonce. Because the nonce is global across proposals, if a third party holds an older valid signature for a different proposal that is simultaneously Active, they can submit it first, consuming the nonce and making the voter’s freshly created signature for another proposal fail until re‑signed. ForageGovernor further allows zero‑weight Abstain votes (but not zero‑weight For/Against), enabling a ‘safe’ nonce consumption path that minimally affects tallies. The effect is a targeted, per‑voter DoS on gasless voting attempts, most impactful near deadlines where re‑signing may be infeasible. This stems from an intended design choice in OZ Governor v5 rather than a coding mistake.

#### Severity

**Impact Explanation:** [Low] The disruption affects only individual voters’ gasless vote submissions; no funds or core protocol state are compromised, and governance remains functional. The harm is a per‑user lost vote near deadlines, not a system‑level outage.

**Likelihood Explanation:** [Medium] Exploitation requires possession of an older valid signature and overlapping Active proposal windows, plus timing to submit before the victim can re‑sign. These constraints are uncommon but realistic in governance with gasless relayers.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: Cross‑proposal nonce burn near a critical deadline. Attacker submits an older valid signature for proposal A (still Active) just before proposal B’s deadline, consuming the victim’s current nonce and causing the victim’s new signature for B to fail, resulting in a missed vote on B.
#### Preconditions / Assumptions
- (a). Attacker possesses an older, unused, valid vote‑by‑signature from the victim for proposal A.
- (b). Proposal A is Active at the time of attacker submission.
- (c). Victim produces a new valid vote‑by‑signature for proposal B using the current nonce.
- (d). Proposal B is Active and near its voting deadline (insufficient time to re‑sign).
- (e). Victim is not blocklisted and has not already voted on proposal A.

### Scenario 2.
Scenario 2: Safe nonce burn via zero‑weight Abstain. Attacker holds a zero‑weight Abstain signature for proposal A (still Active) and submits it first to consume the nonce without meaningfully changing A’s tally, invalidating the victim’s new signature for proposal B near its deadline.
#### Preconditions / Assumptions
- (a). Attacker possesses an older, unused, valid zero‑weight Abstain signature from the victim for proposal A (victim had zero voting power at A’s snapshot).
- (b). Proposal A is Active at the time of attacker submission.
- (c). Victim produces a new valid vote‑by‑signature for proposal B using the current nonce.
- (d). Proposal B is Active and near its voting deadline (insufficient time to re‑sign).
- (e). Victim is not blocklisted and has not already voted on proposal A.

### Scenario 3.
Scenario 3: Multi‑staged nonce drain. A malicious relayer holds a stash of the victim’s pre‑signed ballots for multiple proposals A1..Ak (all Active). As the victim attempts to vote on proposal B, the attacker sequentially submits the old signatures to repeatedly consume successive nonces, blocking the victim until B’s deadline passes.
#### Preconditions / Assumptions
- (a). Victim previously pre‑signed multiple ballots off‑chain for proposals A1..Ak using successive nonces; attacker possesses these signatures.
- (b). Proposals A1..Ak are Active during the attack window.
- (c). Victim signs a new vote for proposal B using the current nonce.
- (d). Victim is not blocklisted and has not already voted on the A‑series proposals.

#### Proposed fix

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 24 unchanged lines ...
 /// upgrades preserve storage, so the domain separator remains valid across implementation
 /// changes. Cached domain separator is auto-rebuilt on chain ID change per EIP-712 spec.
+//
+// SECURITY-TODO (per-proposal keyed nonces for vote-by-signature):
+// To fully prevent cross-proposal nonce consumption DoS, implement per-proposal keyed nonces:
+// 1) Add: mapping(address => mapping(uint256 => uint256)) private _proposalVoteNonces;
+//    and a view getter proposalVoteNonce(address voter, uint256 proposalId).
+// 2) Override castVoteBySig(...) and castVoteWithReasonAndParamsBySig(...):
+//    build EIP-712 digests using expected = _proposalVoteNonces[voter][proposalId] (do not call _useNonce),
+//    validate via SignatureChecker, call _castVote, and ONLY on success increment _proposalVoteNonces[voter][proposalId].
 contract ForageGovernor is
     Initializable,
 ... 689 unchanged lines ...
```

### 22. [Low] Lack of deposit-to-accrual anchoring in StakingQueue/atRISKUSD causes pre-accrual minting and dilution of incumbent holders’ yield

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Because StakingQueue processes deposits at the tier’s current on-chain ERC-4626 price and atRISKUSD only updates totalAssets when deposits/withdrawals or accrueYield/absorbLoss occur, a depositor can be processed just before a positive accrueYield and then share in that accrual. There is no epoch/freshness anchor tying a queue entry to the price at join time, and processing is permissionless with capacity-based scanning, enabling timed pre-accrual mints that dilute existing holders’ per‑share uplift.

StakingQueue.processQueue is permissionless and processes two lanes (priority then standard). Within a lane, it scans forward and skips entries that are processed/cancelled/blocked or that do not fit current combined/tier capacities, and continues scanning (bounded by a caller-supplied budget). When it finds a fitting entry, it calls _depositQueuedRiskusd, which uses previewDeposit to derive a local minimumShares, then calls atRISKUSD.deposit to mint shares at the current on-chain price, reverting only on within-transaction under-mint (slippage) versus the preview.

atRISKUSD overrides totalAssets() to return _legitimateAssets (not raw balance). _legitimateAssets moves on deposits/withdrawals and when the authorized yieldSource calls accrueYield/absorbLoss. There is no timestamp/epoch carried from queue join to processing, so deposits are always priced at processing time. If a depositor’s entry is processed just before a positive accrueYield, they mint at the pre-accrual price and then share in the posted yield, diluting incumbent holders’ per-share uplift. Exit frictions (lockups/cooldowns/weekly caps) can slow realization but do not change the dilution at accrual time. Loss gating (lossPending/CustodianSettlementPending) blocks deposits around adverse events but does not prevent pre-accrual timing on positive updates.

This behavior is an intended ERC-4626-style design trade-off (asynchronous yield posting without epoch anchoring), not an authorization or invariant breach. The economic effect can be amplified by capacity-based scanning (skipping too-large earlier entries) and the priority lane, but the harm remains redistribution of subsequently posted yield rather than principal loss.

#### Severity

**Impact Explanation:** [Low] The impact is economic redistribution of subsequently posted yield (reduced per-share uplift for incumbents), not principal loss, invariant violation, or broken functionality. Deposits mint at the intended ERC-4626 on-chain price; no on-chain entitlement is breached. Conservatively classed as Low impact.

**Likelihood Explanation:** [Medium] The attacker must anticipate a near-term positive accrual and achieve processing before it, subject to lane FIFO, capacity, and scanning constraints. These are significant but plausible constraints and do not require trusted-role misuse or user mistakes, aligning with Medium likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Priority small entries under tight capacity: The attacker locks FORAGE to enter the priority lane with several small queue entries. With limited combined/tier capacity and larger earlier entries that don’t fit, they call processQueue with a large budget so scanning skips too-large entries and processes their small entries first at the pre-accrual price. When the authorized yieldSource later calls accrueYield, the attacker’s newly minted shares share in the uplift, diluting incumbents’ per-share gain.
#### Preconditions / Assumptions
- (a). No lossPending or custodian settlement pause for the tier (deposits allowed).
- (b). A positive accrueYield for the tier is anticipated soon (operator posts yield discretely).
- (c). Attacker’s entries can be placed in the priority lane (FORAGE lock) and are small enough to fit current combined/tier capacities while earlier larger entries do not.
- (d). processQueue can be called permissionlessly with a sufficiently large scan budget.

### Scenario 2.
Tier 0, cooldownPeriod == 0 (quick-in/out): For tier 0 (lockup enforced to zero by design) and a configured cooldown of zero, the attacker times their processing just before a positive accrueYield. After accrual posts, they can withdraw immediately, realizing the captured uplift. Even if cooldown > 0, the dilution happens at accrual time; zero-cooldown simply eases rapid harvesting.
#### Preconditions / Assumptions
- (a). Tier 0 lockup is 0 (by design) and cooldownPeriod is configured to 0.
- (b). No lossPending or custodian settlement pause for the tier.
- (c). A positive accrueYield is anticipated; attacker’s entry is processed pre-accrual.
- (d). Sufficient capacity exists to process the attacker’s entry before accrual.

### Scenario 3.
Deep scanning to skip too-large entries: In a congested lane with many large entries that don’t fit current capacity, the attacker splits deposits into many small entries. They call processQueue with a large scan budget so _processLane skips too-large earlier entries and processes the attacker’s small entries at the pre-accrual price. A subsequent accrueYield spreads across the enlarged supply, including the attacker’s new shares.
#### Preconditions / Assumptions
- (a). Lane backlog contains many entries too large for current combined/tier capacities.
- (b). Attacker splits deposits into small entries that fit capacity.
- (c). Attacker calls processQueue with a large scan budget to reach their entries.
- (d). A positive accrueYield is anticipated soon after processing; no loss gating is active.

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 319 unchanged lines ...
     // Yield/Loss Controls (yieldSource-only)
     // ============================================================
+    // FIX: Introduce settlementNonce/lastSettlementAt state and increment here to anchor post-settlement pricing.
     function accrueYield(uint256 riskusdAmount) external whenNotPaused nonReentrant {
         if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
 ... 21 unchanged lines ...

     /// @dev OF-L22: Loss reporting must work even when paused. Auth-gated by _yieldSource.
+    // FIX: Also increment settlementNonce/lastSettlementAt here after successful loss absorption.
     function absorbLoss(uint256 riskusdAmount) external nonReentrant {
         if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
 ... 886 unchanged lines ...
```

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 45 unchanged lines ...
     using SafeERC20 for IERC20;

+    // FIX: Add uint256 settleNonceAtJoin; captured from tier vault's settlementNonce at join time.
     struct QueueEntry {
         address depositor;
 ... 306 unchanged lines ...
             }
         }
+        // FIX: Read current settlementNonce from the selected tier vault and store in QueueEntry.settleNonceAtJoin.

         _queueEntries[queueId] = QueueEntry({
 ... 117 unchanged lines ...
                 continue;
             }
+            // FIX: Gate processing on tierVault.settlementNonce() > entry.settleNonceAtJoin; otherwise skip this entry.

             _depositQueuedRiskusd(tier, entry.riskusdAmount, entry.depositor);
 ... 1052 unchanged lines ...
```

### 23. [Low] Lazy weekly withdrawal-cap basis snapshot in atRISKUSD causes same-week exit/migration crowd-out

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

atRISKUSD freezes the weekly withdrawal cap basis lazily on the first cap-enforced action of a new window. An attacker can first process queued deposits via StakingQueue to raise totalAssets, then immediately perform a cap-enforced withdrawal/migration to freeze a higher basis and consume the enlarged weekly allowance, delaying other users’ exits/migrations within that week.

In atRISKUSD, _resetWeeklyWithdrawalWindowIfExpired() starts a new weekly window by setting _weeklyWithdrawalWindowStart = block.timestamp and clearing _weeklyWithdrawalWindowStartAssets to 0. The cap basis is not captured at this moment; instead, _enforceWeeklyWithdrawalCap() sets _weeklyWithdrawalWindowStartAssets lazily to totalAssets() on the first cap-enforced action of the new window. totalAssets() returns _legitimateAssets and increases only when atRISKUSD receives deposits via StakingQueue (in _deposit) or authorized yield via accrueYield (trusted role). Because StakingQueue.processQueue is permissionless, a user can process queued deposits into the tier to increase totalAssets before any cap-enforced action occurs, then immediately call a cap-enforced path (withdraw/redeem/executeWithdrawal or redeemForUpgrade/redeemForReversion). This freezes the higher basis and allows consuming the enlarged weekly allowance first. The effect does not steal funds but can crowd out other users’ same-week exits/migrations versus a plausible ordering where a small-withdrawal user freezes the base earlier at a lower value. The impact is a bounded, weekly timing/cap-consumption shift within the protocol’s intended weekly throttle. Conversions from RISKUSD to USDC remain separately throttled by RISKUSDVault and are unaffected.

#### Severity

**Impact Explanation:** [Low] The effect is a bounded, weekly timing/cap-consumption shift (minor griefing) within an intentional weekly throttle, without loss of principal, multi-week freeze, or broken invariants.

**Likelihood Explanation:** [Medium] Requires specific but realistic conditions: the start of a new weekly window before any cap-enforced call, presence of queued deposits and capacity, and front-running the first cap-enforced action. These occur plausibly and recur weekly.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Withdrawal crowd-out: At the start of a new weekly window (or before any cap-enforced call has occurred), an attacker calls StakingQueue.processQueue(tier, maxEntries) to deposit queued RISKUSD into the tier, raising totalAssets. The attacker then immediately performs a withdrawal path (e.g., withdraw or executeWithdrawal), causing _enforceWeeklyWithdrawalCap() to lazily set _weeklyWithdrawalWindowStartAssets = totalAssets() and consume the enlarged weekly allowance first. Other users with matured withdrawals are then unable to exit this week and must wait until the next window.
#### Preconditions / Assumptions
- (a). New weekly window for the tier has begun or no cap-enforced call has yet occurred (_weeklyWithdrawalWindowStartAssets == 0).
- (b). There is a backlog of queued deposits for the tier and available capacity so StakingQueue.processQueue can succeed.
- (c). No loss is pending; the tier is not paused; attacker and victims are not blocklisted.
- (d). Attacker has a matured withdrawal or eligible withdrawal path (e.g., cooldown satisfied, or Tier 0 with 0 cooldown).
- (e). Attacker can front-run the first cap-enforced call of the window to freeze the base after processing deposits.

### Scenario 2.
Tier migration crowd-out: At the start of a new source-tier weekly window (or before any cap-enforced call has occurred), an attacker processes queued deposits into the source tier to raise totalAssets. The attacker then triggers redeemForUpgrade via StakingQueue, which enforces the weekly cap in the source tier and lazily freezes the higher cap basis. The attacker consumes the enlarged migration allowance, pushing other users’ source-tier outflows/migrations to the next weekly window.
#### Preconditions / Assumptions
- (a). New weekly window for the source tier has begun or no cap-enforced call has yet occurred (_weeklyWithdrawalWindowStartAssets == 0).
- (b). There is a backlog of queued deposits for the source tier and available capacity so StakingQueue.processQueue can succeed.
- (c). No loss is pending; the tiers are not paused; attacker and victims are not blocklisted.
- (d). Attacker meets upgrade preconditions (no pending withdrawal; lockup/cooldown conditions satisfied).
- (e). Attacker can front-run the first source-tier cap-enforced call to freeze the base after processing deposits.

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 202 unchanged lines ...
         uint256 backingPerShareBefore = _backingPerShareRay();
         _extendLockup(receiver);
+        // Freeze new-week cap basis before inflows so deposits cannot inflate it.
+        _resetWeeklyWithdrawalWindowIfExpired();
+        if (_weeklyWithdrawalWindowStartAssets == 0) {
+            _weeklyWithdrawalWindowStartAssets = totalAssets();
+        }

         uint256 shares = super.deposit(assets, receiver);
         _assertBackingPerShareNotDecreased(backingPerShareBefore);
         return shares;
     }

     function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
         if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
         if (shares == 0) revert ZeroAmount();
         _requireNoLossPending(); // OF-14-002: Block mint during lossPending (same as deposit)
         _requireNoZeroAssetLegacySupply();
         _requireNotBlocked(msg.sender);
         _requireNotBlocked(receiver);
         uint256 backingPerShareBefore = _backingPerShareRay();
         _extendLockup(receiver);
+        // Freeze new-week cap basis before inflows so mints cannot inflate it.
+        _resetWeeklyWithdrawalWindowIfExpired();
+        if (_weeklyWithdrawalWindowStartAssets == 0) {
+            _weeklyWithdrawalWindowStartAssets = totalAssets();
+        }

         uint256 assets = super.mint(shares, receiver);
 ... 103 unchanged lines ...
         _requireNoZeroAssetLegacySupply();
         _requireNotBlocked(msg.sender);
+        // Freeze new-week cap basis before yield inflow so accrual cannot inflate it.
+        _resetWeeklyWithdrawalWindowIfExpired();
+        if (_weeklyWithdrawalWindowStartAssets == 0) {
+            _weeklyWithdrawalWindowStartAssets = totalAssets();
+        }

         uint256 supply = totalSupply();
 ... 906 unchanged lines ...
```

#### Related findings

##### [Low] Stale weekly withdrawal cap basis in atRISKUSD causes larger-than-intended post-loss outflows and delays for other users

###### Description

atRISKUSD’s weekly withdrawal cap uses a fixed window-start asset snapshot that is not reduced when losses are absorbed mid-window. After lossPending clears (within the same 7-day window), withdrawals are enforced against the stale, larger pre-loss basis, allowing early executors to withdraw a larger fraction of the now-smaller live asset pool than intended, consuming weekly room and delaying others until the next window.

In atRISKUSD, the weekly withdrawal cap is enforced by _enforceWeeklyWithdrawalCap(), which lazily snapshots _weeklyWithdrawalWindowStartAssets = totalAssets() the first time it is called in a 7-day window. This snapshot remains fixed for the entire window unless the window expires; it is not recalculated or reduced when a loss is absorbed. The absorbLoss() path decreases _legitimateAssets (which drives totalAssets()), but does not modify _weeklyWithdrawalWindowStartAssets or _weeklyWithdrawalUsed. While a loss is pending, withdraw/redeem/executeWithdrawal revert due to _requireNoLossPending(), but requestWithdrawal is not gated and can be submitted. If lossPending clears before the 7-day window ends, the stale snapshot still governs the cap, so withdrawals are allowed up to a cap based on the pre-loss asset base. This permits early executors to withdraw a larger percentage of the live asset pool than the configured BPS would imply post-loss, consuming weekly room and delaying other users’ executions to the next window. There is no theft or overpayment; the harm is fairness/throttle misalignment and bounded delay. Operators can mitigate by calling shrinkWeeklyWithdrawalCapBps before or at reopen, but this is optional and not guaranteed.

###### Severity

**Impact Explanation:** [Low] No theft or incorrect payouts occur; the effect is a throttle/fairness discrepancy that can delay other users’ withdrawals within the tier until the next weekly window. Delays are bounded to the remainder of the current week and can be mitigated operationally.

**Likelihood Explanation:** [Medium] Requires a plausible but non-attacker-controlled sequence: an earlier in-window enforcement to set the snapshot, a mid-window loss, resolution within 7 days, and timely execution by the attacker before any emergency cap tightening. These conditions are realistic for a risk-bearing product with daily attestations.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-tier stale-basis exit after mid-window loss (cooldown > 0): Early in the week a withdrawal seeds the snapshot at a high pre-loss asset level. A significant loss is absorbed mid-window, blocking execution while lossPending is true. If loss clears within the same 7-day window, the stale snapshot remains. An early executor calls executeWithdrawal, consuming up to the stale-based weekly cap (a larger percent of live assets than intended), leaving later users delayed until the next window.
#### Preconditions / Assumptions
- (a). A withdrawal enforcement occurred earlier in the 7-day window to set _weeklyWithdrawalWindowStartAssets at a higher pre-loss totalAssets
- (b). A significant mid-window loss was absorbed (absorbLoss reduced _legitimateAssets/totalAssets)
- (c). Loss clears before the 7-day window expires, so the snapshot does not reset by time
- (d). No emergency shrinkWeeklyWithdrawalCapBps executed before reopen
- (e). Attacker can execute early after reopen; cooldownPeriod > 0 so executeWithdrawal is the normal path

### Scenario 2.
Coordinated cross-tier exits: Attackers seed small pre-loss withdrawals in multiple atRISKUSD tiers to set high snapshots. A custodian loss reduces assets across tiers and is resolved within the same week. Upon reopen, attackers execute across tiers against stale bases, consuming each tier’s weekly room faster than a corrected basis would allow, delaying other depositors in each tier until the next window.
#### Preconditions / Assumptions
- (a). Multiple atRISKUSD tiers exist and each had at least one pre-loss enforcement this window (seeding high snapshots per tier)
- (b). A custodian loss affects all tiers and is resolved within the same 7-day window
- (c). No emergency shrinkWeeklyWithdrawalCapBps applied per tier before reopen
- (d). Attackers can execute quickly across tiers upon reopen

### Scenario 3.
First-to-exit via queuing during lossPending: A pre-loss enforcement sets a high snapshot. During lossPending (mid-window), the attacker submits requestWithdrawal (allowed), then monitors for loss clearance. As soon as loss clears (still within the same window), they execute immediately, consuming stale-basis room before others can act, delaying later users until the next window.
#### Preconditions / Assumptions
- (a). A pre-loss enforcement set a high snapshot for the current week
- (b). A mid-window loss set lossPending; requestWithdrawal remained callable
- (c). Attacker submitted requestWithdrawal during lossPending and monitored for clearance
- (d). Loss clears within the same 7-day window (no window rollover)
- (e). No emergency cap tightening before reopen; attacker executes immediately at reopen

###### Proposed fix

####### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 1188 unchanged lines ...
         }
         baseAssets = _weeklyWithdrawalWindowStartAssets;
-        if (baseAssets == 0) baseAssets = totalAssets();
+        uint256 current = totalAssets();
+        if (baseAssets == 0) {
+            baseAssets = current;
+        } else if (current < baseAssets) {
+            baseAssets = current;
+        }
         return (_weeklyWithdrawalUsed, baseAssets);
     }

     function _enforceWeeklyWithdrawalCap(uint256 assets) private {
         _resetWeeklyWithdrawalWindowIfExpired();
-        if (_weeklyWithdrawalWindowStartAssets == 0) {
-            _weeklyWithdrawalWindowStartAssets = totalAssets();
+        uint256 snap = _weeklyWithdrawalWindowStartAssets;
+        if (snap == 0) {
+            snap = totalAssets();
+            _weeklyWithdrawalWindowStartAssets = snap;
         }
-
+        uint256 current = totalAssets();
+        uint256 base = current < snap ? current : snap;
         uint256 used = _weeklyWithdrawalUsed;
-        uint256 cap = _weeklyWithdrawalWindowStartAssets * _effectiveWeeklyWithdrawalCapBps() / 10000;
+        uint256 cap = base * _effectiveWeeklyWithdrawalCapBps() / 10000;
         uint256 remaining = used >= cap ? 0 : cap - used;
         if (assets > remaining) revert WeeklyWithdrawalCapExceeded(assets, remaining);
 ... 30 unchanged lines ...
```

##### [Low] Weekly outflow cap applied to internal migrations in atRISKUSD causes time-bounded withdrawal DoS per tier

###### Description

atRISKUSD enforces its weekly withdrawal cap on both user exits and internal tier migrations (redeemForUpgrade/redeemForReversion). Because migrations consume the cap without any refund upon immediate redeposit via StakingQueue, an attacker can exhaust a tier’s weekly cap and cause subsequent withdrawals from that tier to revert until the weekly window resets.

The atRISKUSD tier vaults implement a weekly withdrawal cap that is enforced on all asset outflows from a tier, including migrations initiated by StakingQueue through redeemForUpgrade() and redeemForReversion(). These internal migrations transfer assets to StakingQueue (not to the end user) yet still consume the tier’s weekly cap via _enforceWeeklyWithdrawalCap. There is no mechanism to refund the cap when StakingQueue immediately redeposits the same assets into another tier. Two public/permissionless paths can be used to consume the cap: (1) processExpiredLockups() forces expired, auto-renew-disabled positions in a non-zero tier to redeemForReversion() and be redeposited to Tier 0, consuming the source tier’s cap without attacker capital; (2) upgradeTier() from Tier 0 to a higher tier calls redeemForUpgrade(), consuming Tier 0’s cap while immediately redepositing elsewhere. After the cap is exhausted, withdraw/redeem/executeWithdrawal from the targeted tier revert with WeeklyWithdrawalCapExceeded until the 7-day window resets. This is a significant but temporary denial-of-service on withdrawals for that tier. Exploitation depends on destination-tier capacity and, for the forced reversion path, the presence of expired, non-auto-renew positions. The behavior appears intentional (counting gross outflows), but it enables griefing that can delay other users’ exits.

###### Severity

**Impact Explanation:** [Medium] A significant but temporary denial-of-service of withdrawals for the targeted tier until the weekly window (≤7 days) resets.

**Likelihood Explanation:** [Low] Exploitation is primarily griefing with no direct profit; it depends on external constraints (destination-tier capacity, presence of expired non-auto-renew positions, timing). Capital and lockup acceptance are required for the Tier 0 upgrade path.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Permissionless cap exhaustion via processExpiredLockups: An attacker enumerates Tier N (N>0) depositors with expired lockups and auto-renew disabled. The attacker calls processExpiredLockups([...], tier=N). For each qualifying depositor, the queue calls redeemForReversion() on the source tier (consuming the weekly cap) and redeposits the assets into Tier 0. The try/catch in processExpiredLockups continues across failures, allowing the attacker to consume most or all of Tier N’s weekly cap without supplying capital. Subsequent user withdrawals from Tier N revert until the window resets.
#### Preconditions / Assumptions
- (a). Tier N (N>0) is active and has non-zero weekly cap remaining
- (b). A pool of Tier N depositors have lockups expired, auto-renew disabled, and no pending withdrawal
- (c). Tier 0 has sufficient deposit capacity to accept reversion deposits
- (d). StakingQueue and tier vaults are not paused

### Scenario 2.
Capital-based cap exhaustion from Tier 0 using upgradeTier: The attacker deposits RISKUSD into Tier 0 via joinQueue/processQueue to mint Tier 0 shares, then repeatedly calls upgradeTier(0, toTier, amount). Each call invokes redeemForUpgrade() on Tier 0, consuming its weekly cap and transferring assets to StakingQueue, which immediately deposits into the destination tier. After exhaustion, Tier 0 withdrawals by other users revert until reset. This requires attacker capital and acceptance of destination-tier lockups.
#### Preconditions / Assumptions
- (a). Tier 0 is active with zero lockup (by registry invariant/config)
- (b). Combined and Tier 0 capacity are sufficient for the attacker’s deposit
- (c). Destination tier has sufficient deposit capacity
- (d). Attacker supplies capital and accepts destination-tier lockups
- (e). Weekly cap has remaining headroom when the attacker acts

### Scenario 3.
Front-running pending-withdrawal users: The attacker monitors for users about to execute withdrawals in Tier M. Just before those executeWithdrawal calls, the attacker consumes most of the remaining weekly cap for Tier M using batch processExpiredLockups (forcing reversions) or their own migrations. As executeWithdrawal checks the cap at execution time, those user transactions revert with WeeklyWithdrawalCapExceeded until the window resets.
#### Preconditions / Assumptions
- (a). Targeted Tier M has non-zero weekly cap remaining
- (b). A sufficient number of expired, auto-renew-disabled positions exist (if using forced reversions path) and Tier 0 has capacity
- (c). Attacker can submit transactions before victims (timing/front-running)
- (d). StakingQueue and the relevant tiers are not paused

###### Proposed fix

####### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 515 unchanged lines ...
         assets = previewRedeem(shares);
         if (assets == 0) revert ZeroRedemptionOutput();
+        // FIX: Net migrations — record a migration debit here and require StakingQueue to refund after successful redeposit.
+        // FIX: Net migrations — record a migration debit here and require StakingQueue to refund after successful redeposit.
         _enforceWeeklyWithdrawalCap(assets);

 ... 686 unchanged lines ...
     }

+    // FIX: Expose a new external refundMigrationDebit(uint256) callable only by _stakingQueue
+    // that internally calls _refundWeeklyWithdrawalCap(windowStart, amount) to net internal migrations.
     function _refundWeeklyWithdrawalCap(uint256 windowStart, uint256 assets) private {
         if (assets == 0 || windowStart == 0 || _weeklyWithdrawalWindowStart != windowStart) return;
 ... 25 unchanged lines ...
```

####### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 597 unchanged lines ...
         _riskusd.forceApprove(destVault, 0);

+        // FIX: After successful deposit, call sourceVault.refundMigrationDebit(riskusdAmount) and revert on failure to keep migrations cap-neutral.
         _assertCombinedBackingPerShareNotDecreased(combinedBackingPerShareBefore);
         emit TierUpgraded(msg.sender, fromTier, toTier, atriskusdAmount, riskusdAmount, newAtriskusdAmount);
 ... 71 unchanged lines ...
             // OF-M10: reset allowance
             _riskusd.forceApprove(vault0Addr, 0);
+            // FIX: After successful Tier 0 deposit, call tierVaultAddr.refundMigrationDebit(riskusdAmount) and bubble failure per-depositor (try/catch continues).

             _assertCombinedAssetsNotDecreased(combinedAssetsBefore);
 ... 396 unchanged lines ...
             vault0Addr.call(abi.encodeWithSelector(_SEL_DEPOSIT, riskusdAmount, msg.sender));
         _riskusd.forceApprove(vault0Addr, 0);
+        // FIX: After successful Tier 0 deposit, call tierVaultAddr.refundMigrationDebit(riskusdAmount) and revert if it fails.

         if (!depositSuccess) {
 ... 456 unchanged lines ...
```

### 24. [Low] Reciprocal wiring precondition deadlock in RISKUSDVault/VaultRegistry causes extended downtime when replacing the vault address

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault and VaultRegistry enforce reciprocal wiring checks that create a circular dependency when attempting to replace the vault with a new address while keeping the existing registry. This blocks the documented two-step wiring flows and forces extra governance/upgrade steps, extending operational downtime during the swap.

RISKUSDVault.initializeV2, finalizeVaultRegistry, and acceptVaultRegistry each require that the target VaultRegistry already reports riskusdVault() == address(this) via _requireVaultRegistryMatchesThisVault. Conversely, VaultRegistry.finalizeRISKUSDVault requires the pending new vault already reports vaultRegistry() == address(this). When replacing the vault address while keeping the same registry, these symmetric prerequisites produce a deadlock: the new vault cannot point to the existing registry until the registry already points to it, and the registry refuses to point to the new vault until the new vault already points back. As a result, the intended two-step propose/finalize or accept paths cannot complete. If VaultRegistry.initializeV2 has not yet been used, it breaks the cycle by allowing the registry to set _riskusdVault first. Otherwise, governance must perform an additional registry upgrade (e.g., add a fresh reinitializer or a controlled finalize path) before completing the swap. These additional steps, combined with production finalize delays, extend downtime if operations are paused for the cutover. There is no theft or direct fund loss; the risk is operational availability and coordination cost. The behavior appears intentional as a safety tradeoff to prevent half-configured references, but it has real-world downtime impact in vault-address replacement scenarios.

#### Severity

**Impact Explanation:** [Medium] If governance pauses operations during the swap, deposits and redemptions are significantly but temporarily unavailable (DoS of core functionality). No direct loss of principal and no multi-week freeze.

**Likelihood Explanation:** [Low] Requires an uncommon but plausible need to replace the vault address (rather than in-place UUPS), prior consumption of VaultRegistry.initializeV2, and an operator decision to pause during the swap. Mitigations (registry upgrade) exist and are under trusted governance control.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 2 (most severe): Governance needs to replace RISKUSDVault with a new proxy address (e.g., a migration that cannot be performed via in-place UUPS). VaultRegistry.initializeV2 was already used historically. Governance pauses deposits/redemptions for the swap. Attempts to wire the new vault to the existing registry fail because the vault requires the registry to already point to it, and wiring the registry to the new vault fails because the registry requires the new vault to already point back. Governance must introduce an additional registry upgrade with a fresh reinitializer or a temporary relaxed finalize path, wait finalize/timelock delays, perform rewiring, then unpause. Users experience extended downtime for core operations during the swap.
#### Preconditions / Assumptions
- (a). A new RISKUSDVault proxy address is required (in-place UUPS upgrade not viable for this change).
- (b). VaultRegistry.initializeV2 has already been executed on the production registry and cannot be called again.
- (c). Governance chooses to pause deposits/redemptions during the swap window.
- (d). Governance/timelock and FinalizeDelayProfile apply (2 days on Arbitrum One), increasing elapsed time for the extra registry upgrade.
- (e). Trusted operators (governance/admin) act correctly and non-maliciously.

### Scenario 2.
Scenario 3: Governance targets a near-seamless cutover (no pause) but finds the same deadlock. Since VaultRegistry.initializeV2 is already consumed, they must schedule a registry upgrade to add a fresh reinitializer or temporary finalize variant, then perform the wiring and cut over. Users are not blocked from actions on the old vault during preparation, but the cutover is delayed and requires extra coordination and governance steps.
#### Preconditions / Assumptions
- (a). A new RISKUSDVault proxy address is required (in-place UUPS upgrade not viable for this change).
- (b). VaultRegistry.initializeV2 has already been executed on the production registry and cannot be called again.
- (c). Governance aims to minimize downtime by not pausing until final cutover.
- (d). A registry upgrade (fresh reinitializer or temporary relaxed finalize) is still required to break the cycle before cutover.
- (e). Trusted operators (governance/admin) act correctly and non-maliciously.

#### Proposed fix

##### VaultRegistry.sol

File: `openforage_smart_contracts/src/VaultRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/VaultRegistry.sol)

```diff
 ... 495 unchanged lines ...
         }
         if (block.timestamp > uint256(_pendingRISKUSDVaultTimestamp) + PROPOSAL_EXPIRY) revert ProposalExpired();
-        // OF-21-061: Verify new vault's vaultRegistry() points back to this registry
-        (bool ok, bytes memory data) = _pendingRISKUSDVault.staticcall(abi.encodeWithSignature("vaultRegistry()"));
-        if (!ok || data.length < 32) revert VaultRegistryMismatch();
-        if (abi.decode(data, (address)) != address(this)) revert VaultRegistryMismatch();
+        // Atomic mutual wiring: verify interface, set registry->vault, then require vault.acceptVaultRegistry() succeeds
         _requireRISKUSDVaultInterface(_pendingRISKUSDVault);

         address oldVault = _riskusdVault;
         _riskusdVault = _pendingRISKUSDVault;
+        (bool ok2,) = _riskusdVault.call(abi.encodeWithSignature("acceptVaultRegistry()"));
+        require(ok2);
         _pendingRISKUSDVault = address(0);
         _pendingRISKUSDVaultTimestamp = 0;
 ... 74 unchanged lines ...
```

### 25. [Low] Stale-price exit window in atRISKUSD exits before NAV/freeze causes loss-shifting to remaining holders

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Before a downwards NAV attestation or custodian freeze lands on-chain, atRISKUSD exits and tier transitions proceed at pre-loss prices. Early movers can redeem or transition and cash out within configured caps, shifting the imminent loss onto remaining holders.

atRISKUSD withdrawal and tier-transition paths are gated by a lossPending check sourced from RISKUSDVault and a custodian freeze flag. Until a lower NAV is posted or the custodian freeze is set, lossPending remains false and exits are honored using the current ERC4626 exchange rate based on atRISKUSD’s tracked legitimate assets. If a negative PnL event has already occurred off-chain, there is a short operational window where users with expired lockups (and, for some paths, cooldown disabled) can redeem at pre-loss prices. They may then redeem RISKUSD to USDC at the central vault, provided daily/weekly caps and reserve/liquidity constraints allow. This does not require admin malice or misconfiguration; it relies on finite attestation/freeze latency. The design includes mitigating controls—per-tier weekly caps, vault daily/weekly redemption caps, optional reserve constraints, and a custodian directional freeze—to bound impact and shorten the window. Cooldown-based withdrawals also intentionally remove stale-price optionality by paying the minimum of a snapshot and current value. Nevertheless, during the short window, early movers can extract value at the old price within caps, shifting losses to remaining holders when the NAV decrease or freeze later applies.

#### Severity

**Impact Explanation:** [Medium] The effect is a bounded redistribution of principal: early movers exit at pre-loss prices within configured caps, shifting loss to remaining holders. Protocol-level caps (per-tier weekly, vault daily/weekly) and reserve constraints significantly limit scope and prevent large-scale extraction.

**Likelihood Explanation:** [Low] Exploitation requires multiple constraints to align: a short pre-attestation/freeze window; attacker’s lockup expiry; specific tier configurations (e.g., cooldown==0, and for selfRevert, auto-renew disabled and tier 0 with lockup=0 and cooldown=0); plus available headroom in tier and vault caps and sufficient vault liquidity/reserve. Operators have fast freeze/NAV tools, further shortening the window.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 2 (Direct exit from cooldown==0 tier to USDC): An attacker with expired lockup in a tier configured with cooldown=0 redeems atRISK shares to RISKUSD at the pre-loss price while lossPending is still false, then immediately redeems RISKUSD for USDC at the central vault within daily/weekly caps and reserve/liquidity limits, all before the custodian posts a lower NAV or sets freeze.
#### Preconditions / Assumptions
- (a). An off-chain negative PnL event has occurred; on-chain lossPending remains false because no lower NAV has been posted and no custodian freeze is set yet.
- (b). Attacker’s lockup has expired in the source atRISKUSD tier.
- (c). The source atRISKUSD tier has cooldownPeriod == 0.
- (d). Per-tier weekly withdrawal cap has headroom for the attacker’s amount.
- (e). RISKUSDVault daily/weekly redemption caps have headroom; reserve ratio constraints (if set) and vault USDC liquidity allow redemption.
- (f). Attacker is not blocklisted; relevant contracts are not paused.

### Scenario 2.
Scenario 3 (SelfRevert to tier 0, then USDC exit if tier 0 has lockup=0 and cooldown=0): An attacker with expired lockup and auto-renew disabled calls selfRevert to move from a nonzero tier to tier 0 at the pre-loss price while lossPending is false, then immediately redeems from tier 0 to RISKUSD (cooldown=0, lockup=0) and redeems RISKUSD for USDC at the vault within daily/weekly caps, all before a NAV update or freeze.
#### Preconditions / Assumptions
- (a). An off-chain negative PnL event has occurred; on-chain lossPending remains false because no lower NAV has been posted and no custodian freeze is set yet.
- (b). Attacker’s lockup has expired in the source tier and auto-renew was disabled in advance.
- (c). Per-tier weekly withdrawal cap has headroom in the source tier.
- (d). Tier 0 is configured with lockupPeriod == 0 and cooldownPeriod == 0.
- (e). RISKUSDVault daily/weekly redemption caps have headroom; reserve ratio constraints (if set) and vault USDC liquidity allow redemption.
- (f). Attacker is not blocklisted; relevant contracts are not paused.

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 62 unchanged lines ...
     error ZeroRedemptionOutput();
     error ExpiredAutoRenewDisabledLockup();
+    error MinimumCooldownRequired();

     // ============================================================
 ... 119 unchanged lines ...
         _lockupPeriod = lockupPeriod_;
         _cooldownPeriod = cooldownPeriod_;
+        if (_cooldownPeriod == 0) revert MinimumCooldownRequired();
         _tierId = tierId_;
         _weeklyWithdrawalCapBps = DEFAULT_WEEKLY_WITHDRAWAL_CAP_BPS;
 ... 536 unchanged lines ...

     function setCooldownPeriod(uint256 newCooldownPeriod) external onlyOwner {
+        if (newCooldownPeriod == 0) revert MinimumCooldownRequired();
         uint256 old = _cooldownPeriod;
         _cooldownPeriod = newCooldownPeriod;
 ... 505 unchanged lines ...
```

### 26. [Low] Backing-per-share invariant with zero-supply residual in atRISKUSD causes tier deposit DoS (and Tier 0 reversion disruption)

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When a cooldown withdrawal leaves the atRISKUSD vault with totalSupply == 0 and residual totalAssets ≥ 1 RISKUSD, any subsequent deposit reverts due to the backing-per-share invariant, bricking StakingQueue processing for that tier and disrupting Tier 0 reversion flows until privileged intervention clears the residual.

Root cause: atRISKUSD enforces an invariant that backing-per-share must not decrease across deposits, computed as (totalAssets + 1) * (RAY * SHARE_SCALE) / (totalSupply + SHARE_SCALE) with SHARE_SCALE = 1e6. If totalSupply == 0 and totalAssets = A > 0 before a deposit, before = (A + 1) * RAY. After a first deposit of d > 0 assets (ERC-4626 mints d shares when supply == 0), after = (A + d + 1) * RAY * SHARE_SCALE / (d + SHARE_SCALE). The invariant after ≥ before reduces to d * (SHARE_SCALE − (A + 1)) ≥ 0, which fails for any d > 0 when A + 1 > SHARE_SCALE, i.e., when totalAssets ≥ 1,000,000 base units (1.0 RISKUSD). How this state arises: atRISKUSD’s cooldown withdrawal snapshots the withdrawer’s claim at request time, but on execution burns all locked shares and reduces _legitimateAssets only by the paid snapshot amount, leaving any post-request yield as residual in the vault. If this execution is done by the last/only holder, totalSupply becomes 0 while totalAssets retains the residual. Consequences: (1) Any subsequent deposit into that tier reverts on the invariant, so StakingQueue.processQueue for that tier reverts and the lane is bricked. (2) If Tier 0 is bricked, processExpiredLockups and selfRevert (which deposit into Tier 0) fail, disrupting reversion flows. (3) During wind-down, releaseTierVaults reverts if totalAssets != 0 for a zero-supply tier, obstructing cleanup. The DoS persists until a trusted privileged action (e.g., yieldSource.absorbLoss) reduces residual below 1 RISKUSD (or to zero).

#### Severity

**Impact Explanation:** [Medium] Tier-level deposit paths are bricked (significant availability/DoS of core functionality for that tier), and Tier 0 reversion flows are disrupted; no principal loss and alternatives exist (cancel queue or exit from current tier), so not high.

**Likelihood Explanation:** [Low] Attack requires becoming last holder and intentionally sacrificing post-request yield (griefing) with no direct profit; although feasible, the griefing criterion and specific-state preconditions reduce likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1 — Brick a tier’s deposits: (1) Attacker becomes the last/only holder in a target atRISKUSD tier. (2) Attacker calls requestWithdrawal for all shares (snapshot S taken). (3) Attacker waits for normal yield accrual so post-request residual Y ≥ 1 RISKUSD. (4) Attacker calls executeWithdrawal; vault pays S, burns all locked shares, leaves residual A = Y with totalSupply == 0. (5) Any subsequent deposit into the tier reverts on the invariant; StakingQueue.processQueue for that tier reverts and the lane is bricked until privileged absorbLoss clears residual.
#### Preconditions / Assumptions
- (a). Cooldown withdrawals enabled for the target atRISKUSD tier
- (b). Attacker can become or wait to become the last/only holder in the tier
- (c). Normal yield accrues after withdrawal request, producing residual ≥ 1 RISKUSD
- (d). No privileged absorbLoss clears residual before new deposits are attempted

### Scenario 2.
Scenario 2 — Break Tier 0 reversion flows: (1) Attacker becomes the last/only holder of Tier 0. (2) Attacker performs the same residual-creation flow to leave totalSupply == 0 and totalAssets ≥ 1 RISKUSD in Tier 0. (3) StakingQueue.processExpiredLockups and selfRevert that deposit into Tier 0 now revert on deposit, leaving affected users unable to revert into Tier 0; they must instead exit from their current tier via cooldown.
#### Preconditions / Assumptions
- (a). Cooldown withdrawals enabled for Tier 0
- (b). Attacker can become or wait to become the last/only holder of Tier 0
- (c). Normal yield accrues after withdrawal request, producing residual ≥ 1 RISKUSD
- (d). No privileged absorbLoss clears residual before reversion attempts

### Scenario 3.
Scenario 3 — Obstruct wind-down cleanup: (1) Using the same method, attacker leaves any tier with totalSupply == 0 and totalAssets > 0 (any positive amount). (2) During wind-down, VaultRegistry.releaseTierVaults reverts with ResidualTierVaultAssets for that tier, blocking address release until privileged absorbLoss clears residual.
#### Preconditions / Assumptions
- (a). Any atRISKUSD tier can reach totalSupply == 0 with residual totalAssets > 0
- (b). Governance initiates wind-down and attempts to release tier vault addresses
- (c). No privileged absorbLoss clears residual before releaseTierVaults is called

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 200 unchanged lines ...
         _requireNotBlocked(msg.sender);
         _requireNotBlocked(receiver);
-        uint256 backingPerShareBefore = _backingPerShareRay();
+        uint256 supplyBefore = totalSupply();
+        uint256 backingPerShareBefore = supplyBefore == 0 ? 0 : _backingPerShareRay();
         _extendLockup(receiver);

         uint256 shares = super.deposit(assets, receiver);
-        _assertBackingPerShareNotDecreased(backingPerShareBefore);
+        if (supplyBefore != 0) _assertBackingPerShareNotDecreased(backingPerShareBefore);
         return shares;
     }

     function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
         if (msg.sender != _stakingQueue) revert UnauthorizedStakingQueue();
         if (shares == 0) revert ZeroAmount();
         _requireNoLossPending(); // OF-14-002: Block mint during lossPending (same as deposit)
         _requireNoZeroAssetLegacySupply();
         _requireNotBlocked(msg.sender);
         _requireNotBlocked(receiver);
-        uint256 backingPerShareBefore = _backingPerShareRay();
+        uint256 supplyBefore = totalSupply();
+        uint256 backingPerShareBefore = supplyBefore == 0 ? 0 : _backingPerShareRay();
         _extendLockup(receiver);

         uint256 assets = super.mint(shares, receiver);
-        _assertBackingPerShareNotDecreased(backingPerShareBefore);
+        if (supplyBefore != 0) _assertBackingPerShareNotDecreased(backingPerShareBefore);
         return assets;
     }
 ... 1010 unchanged lines ...
```

#### Related findings

##### [Low] Cooldown withdrawal leftover yield in atRISKUSD when last holder causes stranded assets and deposit capacity DoS

###### Description

A user can become the last holder in an atRISKUSD tier, request a cooldown withdrawal, allow normal protocol yield to accrue during cooldown, then execute the withdrawal to leave the accrued excess in the vault with zero supply. These stranded assets inflate totalAssets (legitimateAssets) and reduce StakingQueue deposit capacity, causing a DoS for new depositors until privileged cleanup.

In atRISKUSD, requestWithdrawal snapshots the asset value of the shares at request time (pw.riskusdAmount). During executeWithdrawal, the vault pays min(currentValue, snapshot), where currentValue = convertToAssets(pw.atriskusdAmount) at execution. Any yield accrued during cooldown (currentValue > snapshot) is intentionally not paid; it remains in _legitimateAssets (totalAssets). The locked shares are then burned from address(this). If the withdrawing user is the last holder, burning their shares sets totalSupply() to 0 while the accrued excess remains in _legitimateAssets, creating unowned “stranded” assets. StakingQueue’s combinedStaked() sums each tier’s totalAssets (overridden to _legitimateAssets), so stranded assets directly reduce availableCapacity (combinedCapacity − combinedStaked), causing NoCapacityAvailable for new depositors in that tier (and potentially across tiers if the combined cap is reached). No privileged mistake is required: the attacker only relies on normal, operator-driven yield accrual during their cooldown window while they are the sole holder. Only the yieldSource can remove stranded balances via absorbLoss(), so availability is degraded until operators intervene. The attacker’s action is pure griefing (forgoes yield) and can be repeated across tiers to escalate the DoS.

###### Severity

**Impact Explanation:** [Medium] The outcome is a significant but temporary availability loss (DoS) for deposits due to reduced availableCapacity from stranded assets; no direct principal loss and operators can remediate via absorbLoss().

**Likelihood Explanation:** [Low] The exploit is pure griefing (no direct profit, attacker forgoes yield) and requires constrained conditions: becoming and remaining sole holder through lockup and cooldown while yield accrues, and avoiding intervening deposits; repetition across tiers further increases effort.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-tier DoS: The attacker deposits a small amount into a cooldown-enabled atRISKUSD tier to become the sole holder. After lockup expiry, they call requestWithdrawal for all shares. During cooldown, normal yield accrues, increasing currentValue above the snapshot. On executeWithdrawal, only the snapshot amount is paid, the last shares are burned (supply -> 0), and the accrued excess remains in legitimateAssets. StakingQueue sees higher combinedStaked, reducing availableCapacity and causing deposit processing to fail earlier for that tier.
#### Preconditions / Assumptions
- (a). Target tier has a nonzero cooldownPeriod
- (b). Attacker can become and remain the last holder through lockup and cooldown windows
- (c). Normal yield accrual occurs during the attacker’s cooldown window
- (d). No other depositor is processed before the attacker executes withdrawal
- (e). Attacker is not blocklisted and can use StakingQueue

### Scenario 2.
Registry-wide DoS: The attacker repeats the single-tier pattern across multiple cooldown-enabled tiers (and over time), stranding accrued excess in each tier. Combined stranded assets raise combinedStaked across the registry, shrinking availableCapacity and leading to NoCapacityAvailable for new deposits across tiers until privileged absorbLoss() cleanup.
#### Preconditions / Assumptions
- (a). Multiple cooldown-enabled tiers available to target
- (b). Attacker can sequentially become last holder in targeted tiers through lockup and cooldown
- (c). Normal yield accrual continues during each cooldown window
- (d). Attacker repeats the process across tiers/epochs
- (e). Attacker is not blocklisted and can use StakingQueue

###### Proposed fix

####### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 1363 unchanged lines ...

     function _readLegitimateAssets(address vaultAddr) internal view returns (uint256) {
+        // If a tier has zero supply, treat its staked assets as zero for capacity accounting.
+        // This prevents stranded balances (with no outstanding shares) from reducing available capacity.
+        (bool okSup, bytes memory supData) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_TOTAL_SUPPLY));
+        if (okSup && supData.length >= 32) {
+            if (abi.decode(supData, (uint256)) == 0) return 0;
+        }
         (bool success, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSelector(_SEL_LEGITIMATE_ASSETS));
         if (!success || data.length < 32) revert CapacityProbeFailed(vaultAddr);
 ... 165 unchanged lines ...
```

### 27. [Low] Entrenchment guard + atomic timelock batch and active-slot gating in ForageGovernor/GuardianModule causes governance proposal-creation DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

An attacker can craft governance proposals that both (a) cannot be canceled by guardians due to the GuardianModule entrenchment guard and (b) cannot be executed because a single deliberately failing action bricks OpenZeppelin’s TimelockController batch. These proposals remain in active states (Queued up to 30 days or Active during voting), saturating ForageGovernor’s active-proposal slots and preventing any new proposals.

ForageGovernor limits the number of concurrently “active” proposals; Pending, Active, Succeeded, and Queued (until stale after ~30 days) all count against this limit. Propose() reverts once the cap is reached. GuardianModule exposes guardianCancel(), which is allowed to cancel proposals beyond Pending, but it enforces an entrenchment guard: if the proposal’s calldatas include certain protected GuardianModule mutations (e.g., updateGovernor, proposeTimelock, setPausableTarget, upgradeToAndCall) or self-targeting setGuardianPermissions/removeGuardian for the caller, guardianCancel reverts. Separately, OpenZeppelin TimelockController executeBatch is atomic; any single failing action reverts the entire batch and leaves the operation not Done, so the Governor’s state remains Queued after queuing. An attacker who meets proposalThreshold can submit proposals that include: (1) at least one protected GuardianModule call that triggers the entrenchment guard for all guardians (or, alternatively, self-targeting calls for each guardian) and (2) a deliberately failing call (e.g., always-reverting GuardianModule function). If the attacker also meets quorum, they can pass and queue enough such proposals to saturate all active slots for up to 30 days, preventing any new proposals. Even without quorum, the attacker can keep slots filled during each voting period (e.g., ~5 days), since guardians cannot cancel Active proposals due to the entrenchment guard; by repeatedly resubmitting after defeat, they can maintain a rolling DoS. The effect is a significant, temporary impairment of governance proposal creation. Practical bounds/mitigations exist: queued proposals become stale after ~30 days; cleanupDefeated() frees slots post-defeat; queue() is permissionless (preventing indefinite Succeeded); operators could blocklist the attacker’s address at the token level, though that is an operational response rather than a design-level protection.

#### Severity

**Impact Explanation:** [Medium] This causes a significant but temporary availability loss of core governance proposal functionality (proposal creation blocked for up to ~30 days per wave or for the votingPeriod in rolling waves), without direct fund loss or permanent protocol brick.

**Likelihood Explanation:** [Low] The attack is griefing with no direct on-chain profit and requires notable capital (proposalThreshold, and quorum for 30-day variants) and deliberate construction. Defenders can also apply operational mitigations (e.g., blocklisting), and permissionless queue/cleanup bound persistence.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
30-day DoS by quorum-level attacker: The attacker meets proposalThreshold and quorum, submits 10 proposals each containing (a) a protected GuardianModule call (e.g., proposeTimelock) to trigger the entrenchment guard for any guardian attempting guardianCancel and (b) a deliberately failing action to brick Timelock execution. After passing and queuing, each proposal remains Queued and unexecutable; all 10 occupy active slots for up to ~30 days, preventing any new proposals.
#### Preconditions / Assumptions
- (a). Attacker holds proposalThreshold-level voting power and quorum-level voting power (e.g., sufficient For votes to pass proposals).
- (b). GuardianModule is configured and guardians exist (intended production setup).
- (c). ForageGovernor active-proposal cap is at default (e.g., 10) or similar, and Queued proposals remain active until ~30 days stale.
- (d). Timelock is wired in the standard pattern (Governor as proposer/canceller; no extra external cancellers).
- (e). Attacker can craft proposals ≤ MAX_PROPOSAL_ACTIONS with one protected GuardianModule call and one deliberately failing call.

### Scenario 2.
Rolling 5-day DoS by threshold-only attacker: The attacker meets proposalThreshold but not quorum, submits up to 10 proposals including protected GuardianModule calls that block guardianCancel. These proposals remain Active through the entire votingPeriod (e.g., ~5 days), filling all slots and preventing any new proposals during that time. When they become Defeated and are cleaned up, the attacker resubmits a new wave to repeat the DoS.
#### Preconditions / Assumptions
- (a). Attacker holds proposalThreshold-level voting power (but not quorum).
- (b). GuardianModule is configured and guardians exist.
- (c). ForageGovernor enforces active-proposal cap during voting; guardians cannot cancel Active proposals due to entrenchment guard.
- (d). Attacker can repeatedly resubmit waves after Defeated and cleanup.
- (e). Standard timelock wiring; no extra cancellers beyond the Governor.

### Scenario 3.
30-day DoS by per-guardian self-targeting mutations: If operators try to filter “broad” protected calls, the attacker instead includes, for each guardian, a self-targeting setGuardianPermissions/removeGuardian call (no-op values suffice) plus one deliberately failing action. With quorum-level votes, the attacker passes and queues 10 such proposals. Any guardian invoking guardianCancel will hit the self-targeting guard and revert, leaving all proposals Queued and unexecutable for up to ~30 days and blocking new proposals.
#### Preconditions / Assumptions
- (a). Attacker holds proposalThreshold-level and quorum-level voting power.
- (b). GuardianModule is configured and guardians exist, with total count ≤ MAX_PROPOSAL_ACTIONS budget when including self-targeting calls.
- (c). ForageGovernor active-proposal cap and Queued staleness window (~30 days) apply.
- (d). Standard timelock wiring; no extra cancellers beyond the Governor.
- (e). Attacker can enumerate guardians (public getter) and include per-guardian self-targeting calls plus one deliberately failing call in each proposal.

#### Proposed fix

##### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 184 unchanged lines ...
     /// @notice OF-001 (8th audit): Blocks guardian from cancelling proposals that would
     /// remove or modify their own guardian permissions (governance entrenchment prevention).
+    // NOTE (liveness): Consider adding a multi-guardian consensus cancellation override (propose/approve/finalize)
+    // that bypasses this entrenchment guard for malicious/unexecutable proposals, restoring liveness under spam
+    // while preserving anti-entrenchment for unilateral guardian actions.
     function guardianCancel(uint256 proposalId) external {
         _requireCurrentGuardianModule();
 ... 870 unchanged lines ...
```

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 695 unchanged lines ...
             return true;
         }
-        if (proposalState != ProposalState.Queued) return false;
-        uint256 eta = proposalEta(proposalId);
-        return eta == 0 || block.timestamp <= eta + STALE_QUEUED_PROPOSAL_AGE;
+        // Liveness: Do not count Queued proposals toward active slots to avoid long-duration slot lock while queued.
+        return false;
     }

     function _removeActiveProposal(uint256 proposalId) internal {
         // OF-035: Cache storage length to avoid redundant SLOAD per iteration
         uint256 len = _activeProposalIds.length;
         for (uint256 i = 0; i < len;) {
             if (_activeProposalIds[i] == proposalId) {
                 _activeProposalIds[i] = _activeProposalIds[len - 1];
                 _activeProposalIds.pop();
                 return;
             }
             unchecked {
                 ++i;
             }
         }
     }
 }
```

### 28. [Low] Unbounded nested timelock payload decoding in GuardianModule.guardianCancel causes temporary governance DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

GuardianModule.guardianCancel performs unbounded, attacker-controlled nested decoding/iteration of timelock schedule/scheduleBatch payloads for non-guardian proposals. A proposer who meets the proposal threshold can craft large nested arrays that make guardianCancel out-of-gas or economically infeasible, leaving proposals Active for the full voting period and saturating active proposal slots so new proposals revert.

For non-guardian-proposed proposals, GuardianModule.guardianCancel looks up stored proposal params via ForageGovernor.getProposalParams and runs _revertIfSelfTargetingGuardianMutation, which calls _isProtectedGuardianMutation for each action. When an action targets the timelock and uses schedule or scheduleBatch, the code decodes nestedTargets/values/calldatas using _tryDecodeSchedule[Batch]ForGuardianScan and iterates over all elements, recursing into further nested payloads. There is no protocol-level bound on nested array sizes inside a single action’s bytes payload beyond ABI sanity. ForageGovernor.propose caps only the number of top-level actions (MAX_PROPOSAL_ACTIONS = 100), not the size of their bytes payloads, and it stores calldatas in _proposalParams. Guardians are authorized to cancel via GuardianModule only (ForageGovernor.cancel validates the module or the original proposer while Pending). Because the deep scan happens before cancel is executed, a malicious proposer can submit proposals with very large or recursively nested scheduleBatch payloads that cause guardianCancel to run out of gas or become prohibitively expensive. Such proposals remain Active throughout the voting period, consuming active proposal slots, and subsequent legitimate propose() calls revert with MaxActiveProposalsReached. Emergency paths in GuardianModule are selector-whitelisted (pause/cap-tighten/freeze) and cannot bypass this logic. The net effect is a significant but temporary governance DoS, repeatable by re-submitting after expiry.

#### Severity

**Impact Explanation:** [Medium] Significant but temporary availability loss of core governance functionality by blocking new proposals during the voting period.

**Likelihood Explanation:** [Low] Attack requires meeting a nontrivial proposal threshold and bearing significant calldata/storage costs with no direct on-chain profit (griefing).

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Single-level heavy scheduleBatch: The attacker proposes a single action calling timelock.scheduleBatch with very large address[] and bytes[] (minimal 4-byte selectors per element), ensuring valid ABI offsets. GuardianModule.guardianCancel must allocate and iterate over all elements, running out of gas or becoming infeasible. Repeating for enough proposals fills all active slots, and propose() reverts for others for the entire voting period.
#### Preconditions / Assumptions
- (a). Attacker holds or controls enough FORAGE voting power to meet ForageGovernor.proposalThreshold().
- (b). Timelock address and scheduleBatch signature are correct and accepted as a top-level action.
- (c). Large but valid ABI-encoded arrays are included in the scheduleBatch payload.
- (d). Sufficient gas and calldata budget on L2 to submit proposals and store large calldatas.

### Scenario 2.
Two-level nested scheduleBatch-of-scheduleBatch: The attacker proposes one top-level scheduleBatch with K entries; each nestedCalldata is itself a valid scheduleBatch with M entries (moderate sizes, e.g., 64x64). guardianCancel’s scan becomes O(K*M) with layered allocations/recursion, making cancellation infeasible while proposals stay Active and block new proposals.
#### Preconditions / Assumptions
- (a). Attacker meets proposalThreshold().
- (b). Top-level scheduleBatch with K entries; each nestedCalldata is a valid scheduleBatch with M entries (valid ABI).
- (c). Sufficient gas/calldata budgets to submit the nested proposal.
- (d). Governance active proposal slots are not already saturated before attack.

### Scenario 3.
Many top-level actions with moderate nested arrays: The attacker uses up to MAX_PROPOSAL_ACTIONS = 100 top-level actions, each a scheduleBatch with moderate array sizes. guardianCancel must scan and decode all 100 payloads, cumulatively causing OOG/economic infeasibility and saturating active slots during the voting period.
#### Preconditions / Assumptions
- (a). Attacker meets proposalThreshold().
- (b). Proposal includes up to 100 top-level actions (MAX_PROPOSAL_ACTIONS), each a valid scheduleBatch with moderate array sizes.
- (c). Sufficient gas/calldata to submit and store the proposal.
- (d). Active proposal slots available to be filled at attack start.

#### Proposed fix

##### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 182 unchanged lines ...
     }

+    // NOTE: guardianCancel() performs deep nested decoding of timelock payloads.
+    // Proposal creation MUST enforce calldata size and nested complexity bounds
+    // (depth and total nested ops) to keep this scan bounded.
     /// @notice OF-001 (8th audit): Blocks guardian from cancelling proposals that would
     /// remove or modify their own guardian permissions (governance entrenchment prevention).
 ... 872 unchanged lines ...
```

##### ForageGovernor.sol

File: `openforage_smart_contracts/src/ForageGovernor.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageGovernor.sol)

```diff
 ... 201 unchanged lines ...
         if (activeProposalCount() >= _maxActiveProposals) revert MaxActiveProposalsReached();

+        // SAFETY: To bound GuardianModule.guardianCancel() cost, enforce per-action and total
+        // calldatas size caps, and validate nested timelock complexity (depth and total ops)
+        // at proposal creation. Recommend: cap calldatas[i].length and sum(calldatas[i].length),
+        // and call guardianModule.validateProposalComplexity(targets, calldatas) when set.
+
         // Guardian bypass: skip threshold check if caller has PERMISSION_CAN_PROPOSE in the module
         address proposerAddr = _msgSender();
 ... 512 unchanged lines ...
```

### 29. [Low] Permissionless lockup renewal at expiry in StakingQueue.processExpiredLockups/atRISKUSD.renewLockup causes temporary denial of withdrawals/upgrades

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

Any external caller can, at or just after a depositor’s lockup expiry, invoke StakingQueue.processExpiredLockups to renew the depositor’s lock (when autoRenew is enabled), which then makes immediate withdrawal or tier upgrade attempts revert with LockupNotExpired until the next expiry.

StakingQueue.processExpiredLockups is permissionless and whenNotPaused. For each depositor, it calls _processOneExpiredLockup, which queries the tier atRISKUSD vault for hasLockup, isExpired, autoRenew, hasPendingWithdrawal, and shares. If the depositor has an expired lockup, no pending withdrawal, and autoRenew is true, StakingQueue calls atRISKUSD.renewLockup(depositor). atRISKUSD.renewLockup requires msg.sender == _stakingQueue, the lock is expired, and autoRenew is enabled; it then sets the depositor’s lockExpiry to now + lockupPeriod. All withdrawal and tier upgrade entry points (e.g., requestWithdrawal, withdraw/redeem without cooldown, redeemForUpgrade) enforce that block.timestamp >= lockExpiry and otherwise revert with LockupNotExpired. Therefore, an attacker can proactively call processExpiredLockups at or just after expiry (or front-run a user’s post-expiry transaction) to force a renewal first, causing the user’s transaction to revert and delaying their exit/upgrade by a full lock period. There is no depositor-only grace window at expiry. This does not steal funds but imposes a temporary DoS on withdrawals/upgrades for the affected user. Users can mitigate by disabling autoRenew in advance; disabling after a forced renewal ensures the next expiry will auto-revert to tier 0 rather than auto-renew. Pausing does not selectively protect the depositor, and wrong-tier attempts are harmless. The attacker needs only on-chain knowledge of the user’s tier and expiry, which is readily discoverable.

#### Severity

**Impact Explanation:** [Medium] For affected users, withdrawals and tier upgrades are significantly but temporarily unavailable after a forced renewal, constituting a temporary DoS of core functionality. There is no loss of principal.

**Likelihood Explanation:** [Low] The attack is pure griefing with no direct profit and requires the attacker to spend gas to delay a specific user’s actions. Although operationally easy and relying on common states (autoRenew true and expiry reached), the rules classify such unprofitable griefing as low likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker front-runs a user’s immediate post-expiry requestWithdrawal: at expiry, attacker calls processExpiredLockups([user], userTier), which renews the lock since autoRenew is true. The user’s requestWithdrawal then reverts with LockupNotExpired and they must wait one full lockup period.
#### Preconditions / Assumptions
- (a). User holds a nonzero balance in an atRISKUSD tier vault (tier 1/2/3).
- (b). User’s lock has just reached expiry at attacker call time (block.timestamp >= lockExpiry[user]).
- (c). User’s autoRenew is enabled (default).
- (d). No pending withdrawal exists for the user.
- (e). Protocol is not paused.
- (f). Attacker can determine the user’s tier and expiry from on-chain data.

### Scenario 2.
Attacker preempts a user’s just-in-time disable-and-withdraw attempt: near/after expiry, before the user’s setAutoRenew(false) and requestWithdrawal land, attacker calls processExpiredLockups to renew the lock. The user’s subsequent disable succeeds but is too late; requestWithdrawal reverts until next expiry.
#### Preconditions / Assumptions
- (a). User holds a nonzero balance in an atRISKUSD tier vault (tier 1/2/3).
- (b). User’s lock is at or has just reached expiry.
- (c). User’s autoRenew is enabled at the moment of attacker call.
- (d). User plans to call setAutoRenew(false) and then requestWithdrawal in separate transactions near/after expiry.
- (e). No pending withdrawal exists at attacker call time.
- (f). Protocol is not paused.
- (g). Attacker proactively calls at/after expiry before the user’s transactions land.

### Scenario 3.
Attacker blocks a tier upgrade at expiry: at expiry, attacker calls processExpiredLockups([user], fromTier) to renew. The user’s upgrade flow (redeemForUpgrade) then reverts with LockupNotExpired and the user must wait another lockup period to upgrade.
#### Preconditions / Assumptions
- (a). User holds a nonzero balance in an atRISKUSD tier vault and intends to upgrade tiers at expiry.
- (b). User’s lock is at or has just reached expiry.
- (c). User’s autoRenew is enabled.
- (d). No pending withdrawal exists.
- (e). Protocol is not paused.
- (f). Attacker can identify the correct tier to target.

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 604 unchanged lines ...
     /// Callers should limit array size to avoid out-of-gas. Off-chain keepers split large
     /// batches into multiple transactions as needed.
+    /// SECURITY NOTE: Permissionless renewal enables third-party forced renewals at expiry.
+    /// To fully mitigate, gate the renewal path to an authorized keeper OR depositor-only,
+    /// while keeping the reversion (autoRenew=false) path permissionless for liveness.
+    /// Consider: (1) a keeper-only variant for renewals, (2) a public variant that only
+    /// processes reversions, and (3) a depositor-facing renewMyLockup(tier) helper.
     function processExpiredLockups(address[] calldata depositors, uint8 tier) external whenNotPaused nonReentrant {
         if (depositors.length == 0) revert ZeroAmount();
 ... 31 unchanged lines ...
         if (!hasLockup || !isExpired || hasPendingWithdrawal) return;

+        // SECURITY NOTE: The auto-renew branch below should not be callable permissionlessly.
+        // Gate renewals to an authorized keeper or depositor-only; keep the reversion branch
+        // (autoRenew == false) permissionless to preserve exit liveness.
         if (autoRenew) {
             (bool success, bytes memory data) = tierVaultAddr.call(abi.encodeWithSelector(_SEL_RENEW_LOCKUP, depositor));
 ... 889 unchanged lines ...
```

### 30. [Low] Dynamic-balance window cap basis in USDCTreasury FOUNDATION/AGENT_PAY enforcement causes path-dependent reverts of intended daily disbursements

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

USDCTreasury enforces daily caps for FOUNDATION and AGENT_PAY against the current earmark balance while the per-day used amount accumulates, making the effective allowance shrink after each payout and depend on call order. This can prevent completing otherwise policy-compliant (e.g., 10% of day-start) disbursements and cause batch payroll reverts, creating an operational DoS for trusted operators. No funds are lost; failures are atomic and mitigations exist.

In USDCTreasury.sol, _disburse() enforces daily caps for FOUNDATION and AGENT_PAY via _enforceEarmarkWindowCap(earmark, amount, earmarkBalance[earmark], capBps). _enforceEarmarkWindowCap resets the window if expired, then computes cap = basis * capBps / 10_000 and checks _earmarkWindowUsed[earmark] + amount <= cap before incrementing _earmarkWindowUsed. Because the basis is the current earmarkBalance[earmark], which is reduced after each successful _disburse (earmarkBalance[earmark] -= amount), while _earmarkWindowUsed accumulates for the entire day, the computed cap effectively shrinks after every disbursement. For AGENT_PAY, there is also a per-payment cap paymentCap = earmarkBalance[earmark] * AGENT_PAY_CAP_BPS / 10_000 that further tightens after any prior payment. As a result, splitting a nominal 10% daily payout into multiple transfers can cause later transfers to revert with PurposeCapExceeded, and disburseAgentPayBatch() can fail mid-loop (atomically reverting the entire batch) even when the total batch is within 10% of the day-start earmark. This is an operational liveness issue affecting owner-only disbursement flows; there is no attacker path, and no funds are lost or stuck. Workarounds include a single aggregator payment up to the cap, ordering larger payments first, splitting across days, or increasing earmark balances intra-day (e.g., via returnPnLUSDC).

#### Severity

**Impact Explanation:** [Low] Operational DoS/revert of owner-only disbursement flows due to path-dependent daily cap enforcement; no funds lost or stuck, no core user functionality broken, and straightforward workarounds exist (aggregator, ordering, splitting, or intra-day inflows).

**Likelihood Explanation:** [Low] Requires the trusted operator to structure transfers in ways that conflict with the dynamic-basis cap (e.g., many splits or ordering a small payment before a large one). Competent operators can mitigate by simple procedures; no attacker action is involved.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
AGENT_PAY payroll batch within 10% of day-start reverts atomically mid-loop: Start-of-day AGENT_PAY earmark is 1,000,000 USDC and AGENT_PAY_CAP_BPS=10%. Owner calls disburseAgentPayBatch to pay 100 recipients of 1,000 USDC each (total 100,000 = 10%). As the loop progresses, the basis (current balance) shrinks while _earmarkWindowUsed grows; around the 92nd iteration used+amount exceeds cap=basis*10%, causing PurposeCapExceeded and reverting the entire batch.
#### Preconditions / Assumptions
- (a). Owner-only call to disburseAgentPayBatch; recipients not blocked; MAX_AGENT_PAY_BATCH limit respected
- (b). Same-day window (no reset during the transaction)
- (c). AGENT_PAY_CAP_BPS = 1,000 (10%)
- (d). Start-of-day earmarkBalance[EARMARK_AGENT_PAY] = 1,000,000 USDC; _earmarkWindowUsed[EARMARK_AGENT_PAY] = 0
- (e). No intra-day inflows during the batch

### Scenario 2.
FOUNDATION split across two same-day transfers totaling 10% of day-start fails: Start-of-day FOUNDATION earmark is 1,000,000 USDC and FOUNDATION_DAILY_CAP_BPS=10%. Owner first calls disburseFoundation(50,000) (used=50,000; balance=950,000). Later same day, a second disburseFoundation(50,000) reverts because cap = 950,000*10% = 95,000 and used+amount = 100,000 > 95,000.
#### Preconditions / Assumptions
- (a). Owner-only calls to disburseFoundation; FoundationPrimary/Backup not blocked
- (b). Same-day window (no reset between the two transfers)
- (c). FOUNDATION_DAILY_CAP_BPS = 1,000 (10%)
- (d). Start-of-day earmarkBalance[EARMARK_FOUNDATION] = 1,000,000 USDC; _earmarkWindowUsed[EARMARK_FOUNDATION] = 0
- (e). No intra-day inflows between the two disbursements

### Scenario 3.
AGENT_PAY per-payment cap shrinks after a small earlier payout, blocking a planned large transfer: Start-of-day AGENT_PAY earmark is 1,000,000 USDC. After an early 1,000 USDC payment, paymentCap becomes 999,000*10% = 99,900. A later single intended 100,000 USDC payment to an aggregator reverts immediately on the per-payment cap check (100,000 > 99,900), even before the daily cap check.
#### Preconditions / Assumptions
- (a). Owner-only disburse calls; recipient not blocked
- (b). Same-day window
- (c). AGENT_PAY_CAP_BPS = 1,000 (10%)
- (d). Start-of-day earmarkBalance[EARMARK_AGENT_PAY] = 1,000,000 USDC; initial small disbursement executed earlier the same day
- (e). No intra-day inflows before attempting the large transfer

#### Proposed fix

##### USDCTreasury.sol

File: `openforage_smart_contracts/src/USDCTreasury.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/USDCTreasury.sol)

```diff
 ... 270 unchanged lines ...
         if (earmarkBalance[earmark] < amount) revert InsufficientEarmark();
         if (earmark == EARMARK_FOUNDATION) {
-            _enforceEarmarkWindowCap(earmark, amount, earmarkBalance[earmark], FOUNDATION_DAILY_CAP_BPS);
+            _enforceEarmarkWindowCap(earmark, amount, FOUNDATION_DAILY_CAP_BPS);
             if (recipient != foundationPrimary && recipient != foundationBackup) revert DestinationNotAllowed();
         } else if (earmark == EARMARK_PROTOCOL_RETAINED) {
             _enforceFixedWindowCap(earmark, amount, PROTOCOL_RETAINED_DAILY_CAP);
             if (recipient != protocolPrimary && recipient != protocolBackup) revert DestinationNotAllowed();
         } else if (earmark == EARMARK_VAULT_TOP_UP) {
             if (recipient != riskusdVault) revert DestinationNotAllowed();
         } else if (earmark == EARMARK_AGENT_PAY) {
-            _enforceEarmarkWindowCap(earmark, amount, earmarkBalance[earmark], AGENT_PAY_CAP_BPS);
-            uint256 paymentCap = earmarkBalance[earmark] * AGENT_PAY_CAP_BPS / 10_000;
+            _enforceEarmarkWindowCap(earmark, amount, AGENT_PAY_CAP_BPS);
+            uint256 paymentCap = (earmarkBalance[earmark] + _earmarkWindowUsed[earmark] - amount) * AGENT_PAY_CAP_BPS / 10_000;
             if (amount > paymentCap) revert PurposeCapExceeded();
         } else {
             revert DestinationNotAllowed();
         }
         earmarkBalance[earmark] -= amount;
         _usdc.safeTransfer(recipient, amount);
         emit EarmarkDisbursed(earmark, recipient, amount);
     }

-    function _enforceEarmarkWindowCap(bytes32 earmark, uint256 amount, uint256 basis, uint16 capBps) internal {
+    function _enforceEarmarkWindowCap(bytes32 earmark, uint256 amount, uint16 capBps) internal {
         _resetEarmarkWindowIfExpired(earmark);
-        uint256 cap = basis * capBps / 10_000;
+        uint256 cap = (earmarkBalance[earmark] + _earmarkWindowUsed[earmark]) * capBps / 10_000;
         if (_earmarkWindowUsed[earmark] + amount > cap) revert PurposeCapExceeded();
         _earmarkWindowUsed[earmark] += amount;
 ... 28 unchanged lines ...
```

### 31. [Low] Missing L2 sequencer-uptime/grace checks in StakingQueue oracle pricing causes underpriced priority access and queue fairness distortion

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

StakingQueue uses a Chainlink-style oracle price on Arbitrum without sequencer-uptime or post-recovery grace checks. Immediately after sequencer recovery, a price that appears fresh under updatedAt/staleness can be unsafe, letting attackers buy priority lane access too cheaply and overtake standard-lane users, causing unfair delays.

In ORACLE mode, StakingQueue’s _tryActiveForagePriceUsd() accepts a Chainlink-style price if it passes answeredInRound/updatedAt and staleness checks, but it does not perform the recommended Arbitrum L2 sequencer-uptime or post-recovery grace checks. joinQueue() uses this price to calculate the FORAGE amount to lock for priority: forageToLock = ceilDiv(riskusdAmount * 1e18, price * priorityMultiplier). Immediately after an Arbitrum sequencer outage, the feed can appear fresh yet be within an unsafe post-recovery window. If the price is stale-high, priority becomes underpriced, enabling attackers to cheaply mark their entries as priority and be processed before standard-lane entries. This distorts queue fairness and can delay standard-lane users, especially under tier deposit caps. There is no direct loss of principal or broken core functionality; harm is in processing order and waiting time.

#### Severity

**Impact Explanation:** [Low] No direct loss of principal or broken core functionality occurs; the impact is unfair queue ordering and user delays (potential minor yield opportunity loss), which fits a low-impact classification.

**Likelihood Explanation:** [Medium] Exploitation requires an uncommon but realistic Arbitrum sequencer outage and immediate post-recovery timing, plus operational conditions (ORACLE mode with priority enabled). These are notable constraints but plausible over the protocol’s lifetime.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Cheap priority front-running after sequencer recovery: An attacker joins the queue during the unsafe post-recovery window when the FORAGE/USD price is stale-high but passes updatedAt/staleness checks. The attacker locks a small amount of FORAGE to obtain priority and is processed before earlier standard-lane users, delaying their processing.
#### Preconditions / Assumptions
- (a). Deployment on Arbitrum One mainnet
- (b). StakingQueue configured in ORACLE price mode with a Chainlink-style AggregatorV3-compatible feed
- (c). priorityMultiplier > 0 and StakingQueue authorized as a ForageToken locker
- (d). Arbitrum sequencer has just recovered; latestRoundData passes updatedAt/answeredInRound and staleness but is within the unsafe post-recovery window with a stale-high (or mispriced) value
- (e). Sufficient capacity exists in the target tier and keeper operations proceed normally
- (f). Attacker has enough FORAGE and RISKUSD to meet the minimum lock threshold (>= 0.001 FORAGE) and desired stake size

### Scenario 2.
Capacity capture under deposit caps: With tight per-tier deposit caps, the attacker submits multiple priority entries cheaply (due to stale-high price) and consumes most or all available tier capacity for the current window, pushing standard-lane users’ processing further out.
#### Preconditions / Assumptions
- (a). Deployment on Arbitrum One mainnet
- (b). StakingQueue configured in ORACLE price mode with a Chainlink-style AggregatorV3-compatible feed
- (c). priorityMultiplier > 0 and StakingQueue authorized as a ForageToken locker
- (d). Arbitrum sequencer has just recovered; latestRoundData passes updatedAt/answeredInRound and staleness but is within the unsafe post-recovery window with a stale-high (or mispriced) value
- (e). Meaningful per-tier deposit caps are active and remaining capacity is scarce
- (f). Keeper operations proceed normally and process the priority lane first

### Scenario 3.
Last-moment priority injection: Right before the keeper’s processQueue(), the attacker submits a priority entry during the unsafe post-recovery window and is processed immediately ahead of a large standard-lane backlog, increasing victim wait times.
#### Preconditions / Assumptions
- (a). Deployment on Arbitrum One mainnet
- (b). StakingQueue configured in ORACLE price mode with a Chainlink-style AggregatorV3-compatible feed
- (c). priorityMultiplier > 0 and StakingQueue authorized as a ForageToken locker
- (d). Arbitrum sequencer has just recovered; latestRoundData passes updatedAt/answeredInRound and staleness but is within the unsafe post-recovery window with a stale-high (or mispriced) value
- (e). No or few existing priority entries; standard-lane backlog exists
- (f). Keeper’s processQueue() is imminent and attacker can submit a transaction just before it

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 340 unchanged lines ...
             uint256 mult = _priorityMultiplier;
             if (mult > 0) {
+                // SECURITY: On Arbitrum, gate oracle usage on L2 sequencer uptime + grace; see _tryActiveForagePriceUsd().
                 (bool priceReady, uint256 price,) = _tryActiveForagePriceUsd();
                 if (priceReady && price > 0) {
 ... 973 unchanged lines ...
         revert InvalidOraclePrice();
     }
+    // SECURITY TODO (Arbitrum L2):
+    // - Integrate Chainlink L2 Sequencer Uptime feed and enforce a post-recovery grace period
+    //   before accepting ORACLE prices.
+    // - When sequencer is down or within grace, treat price as not ready so joinQueue() skips priority.
+    // - Keeps existing staleness/answeredInRound checks; only add sequencer gating in ORACLE mode.

     function _tryActiveForagePriceUsd() internal view returns (bool success, uint256 price, bytes4 reason) {
 ... 211 unchanged lines ...
```

### 32. [Low] Missing Tier 0 cap checks in StakingQueue reversion paths allow Tier 0 to exceed per-tier cap, blocking fair queue access

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

StakingQueue’s selfRevert and batched _processOneExpiredLockup redeem expired higher-tier positions and deposit directly into Tier 0 without enforcing Tier 0’s per-tier cap (or combined cap), while normal queue and upgrade paths enforce caps. This lets Tier 0 grow past its configured cap via reversion, undermining governance’s per-tier exposure policy and keeping Tier 0 queue deposits blocked.

In StakingQueue, processQueue and upgradeTier enforce both combined capacity and per-tier deposit caps prior to depositing. However, the expired-lockup reversion flows—selfRevert and the keeper-driven _processOneExpiredLockup—redeem from a higher-tier atRISKUSD vault and immediately deposit the RISKUSD into Tier 0 without checking Tier 0’s deposit cap or the combined capacity. The Tier 0 atRISKUSD.deposit only verifies the caller (StakingQueue) and safety gates (pause, loss, blocklist) and does not enforce tier caps. As a result, when Tier 0 is already at cap and new queue deposits are blocked, a user can still move funds into Tier 0 via reversion, causing Tier 0 to exceed its configured cap. This undermines governance’s per-tier exposure accounting and blocks fair access for Tier 0 queue entrants. While the source tier’s weekly withdrawal cap throttles the pace of such reversions, and loss/settlement/pause/blocklist gates can temporarily block them, these mitigations do not prevent the policy bypass when conditions are normal. Combined capacity is preserved (assets shift tiers), so the harm is policy/fairness rather than fund loss.

#### Severity

**Impact Explanation:** [Low] No principal funds are lost and combined capacity is preserved; the impact is a policy/fairness issue where Tier 0 grows beyond its configured per-tier cap, prolonging blockage of normal Tier 0 queue deposits and undermining governance’s per-tier exposure limits.

**Likelihood Explanation:** [Medium] Exploitation is time-gated (lockup expiry), rate-limited (weekly withdrawal cap on the source tier), and requires Tier 0 to be at/over cap, but these are plausible operational conditions. No privileged actions or rare states are required.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: An attacker with expired, auto-renew-disabled Tier 1 shares calls StakingQueue.selfRevert(1). The flow redeems from Tier 1 (subject to its weekly withdrawal cap) and deposits into Tier 0 without Tier 0 capacity checks. Tier 0 staked grows beyond its cap while normal Tier 0 queue deposits remain blocked.
#### Preconditions / Assumptions
- (a). Attacker previously deposited into a higher tier through normal queue processing
- (b). Attacker set auto-renew to false on the higher-tier atRISKUSD vault
- (c). Higher-tier lockup has expired
- (d). Tier 0 is at or above its configured per-tier cap
- (e). No lossPending or custodian settlement pending on the yield source
- (f). StakingQueue and atRISKUSD vaults are not paused
- (g). Attacker is not blocklisted
- (h). Source tier’s weekly withdrawal cap not fully exhausted for the redemption amount

### Scenario 2.
Scenario 2: The attacker holds expired, auto-renew-disabled positions across multiple higher tiers (1/2/3) and sequentially self-reverts each. Weekly withdrawal caps apply per-tier, enabling a larger aggregate weekly inflow into Tier 0 without Tier 0 cap checks, accelerating Tier 0 growth past the cap and keeping the Tier 0 queue closed longer.
#### Preconditions / Assumptions
- (a). Attacker holds expired, auto-renew-disabled positions across multiple higher tiers (1/2/3)
- (b). Tier 0 is at or above its configured per-tier cap
- (c). No lossPending or custodian settlement pending on the yield source
- (d). StakingQueue and atRISKUSD vaults are not paused
- (e). Attacker is not blocklisted
- (f). Each source tier’s weekly withdrawal cap allows the planned redemptions within the time windows

### Scenario 3.
Scenario 3: Governance shrinks Tier 0 per-tier cap to 0 intending to freeze inflows. The attacker with expired, auto-renew-disabled higher-tier shares calls selfRevert(tier). Redemption (rate-limited by source-tier weekly cap) deposits into Tier 0 despite the 0 cap, contradicting governance intent while normal queue deposits remain blocked.
#### Preconditions / Assumptions
- (a). Governance has shrunk Tier 0 per-tier cap to 0
- (b). Attacker holds expired, auto-renew-disabled higher-tier shares
- (c). No lossPending or custodian settlement pending on the yield source
- (d). StakingQueue and atRISKUSD vaults are not paused
- (e). Attacker is not blocklisted
- (f). Source tier’s weekly withdrawal cap allows the redemption amount

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 658 unchanged lines ...
             if (riskusdAmount == 0) revert ZeroAmount();

+            if (_vaultId != 0) {
+                if (riskusdAmount > _availableCapacity()) revert NoCapacityAvailable();
+                uint256 tier0Avail = _availableTierDepositCapacity(0);
+                if (riskusdAmount > tier0Avail) revert TierDepositCapExceeded(0, riskusdAmount, tier0Avail);
+            }
             // OF-M10: use forceApprove instead of bare approve
             _riskusd.forceApprove(vault0Addr, riskusdAmount);
 ... 405 unchanged lines ...
         if (riskusdAmount == 0) revert ZeroAmount();

+        if (_vaultId != 0) {
+            if (riskusdAmount > _availableCapacity()) revert NoCapacityAvailable();
+            uint256 tier0Avail = _availableTierDepositCapacity(0);
+            if (riskusdAmount > tier0Avail) revert TierDepositCapExceeded(0, riskusdAmount, tier0Avail);
+        }
         // Try deposit into tier 0; if it fails, revert to keep the source lockup retryable.
         _riskusd.forceApprove(vault0Addr, riskusdAmount);
 ... 461 unchanged lines ...
```

### 33. [Low] Pre-filter scan limit in RISKUSDVault deployment buffer causes deployCapital() DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault’s deployment buffer sums active tier assets by scanning only the first 64 registry vault IDs before filtering for Active status. Because VaultRegistry.getAllVaults() is append-only and oldest-first, newer Active vaults beyond index 63 can be omitted, undercounting assets and causing _enforceDeploymentBuffer() to compute an artificially low maxTotalDeployment that reverts deployCapital().

In RISKUSDVault._activeRegisteredTierAssets(), the contract fetches all vault IDs from VaultRegistry.getAllVaults() and applies a hard limit of 64 entries (DEPLOYMENT_BUFFER_SCAN_LIMIT) before filtering those entries by VaultStatus.Active and summing their tierVaults’ totalAssets(). VaultRegistry.getAllVaults() returns an append-only, oldest-first list, so when the registry contains more than 64 historical vaults and many of the earliest 64 are Paused/WindingDown or have negligible assets, newer Active vaults beyond index 63 are ignored. RISKUSDVault._enforceDeploymentBuffer() then uses the undercounted activeTierAssets to compute maxTotalDeployment = activeTierAssets * (10000 - deploymentBufferBps) / 10000. If _totalDeployed + additionalDeployment exceeds this (now artificially small) cap, deployCapital() reverts with DeploymentBufferExceeded(). This creates a liveness/availability failure for custodian capital deployment even when substantial Active tier assets actually exist in later-registered vaults. Deposits/redemptions and solvency do not break, and returnCapital() remains functional. Governance can immediately mitigate by setting deploymentBufferBps to 0, but the underlying logic remains a valid cause of deployCapital() DoS under the described state evolution.

#### Severity

**Impact Explanation:** [Medium] The bug causes a significant but temporary availability loss of an important operator function (deployCapital), impairing protocol operations and potentially yield, but does not cause principal loss, break deposits/redemptions, or violate core invariants.

**Likelihood Explanation:** [Low] It requires multiple uncommon preconditions: more than 64 historical vaults and a particular distribution where early entries are mostly inactive/low-assets while later ones are active/high-assets. Trusted governance can also promptly disable the buffer, reducing persistence.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Complete block of new deployments: The registry has >64 vaults; the first 64 are largely Paused/WindingDown or hold negligible assets while newer vaults (beyond index 63) are Active with substantial assets. The custodian calls deployCapital(). _activeRegisteredTierAssets() scans only the first 64 and sums ≈0, leading _enforceDeploymentBuffer() to compute maxTotalDeployment ≈ 0, and deployCapital() reverts with DeploymentBufferExceeded().
#### Preconditions / Assumptions
- (a). >64 vaults registered in VaultRegistry; getAllVaults() returns IDs oldest-first (append-only).
- (b). Many of the first 64 vaults are Paused/WindingDown or have negligible totalAssets; newer vaults beyond index 63 are Active with substantial assets.
- (c). RISKUSDVault._deploymentBufferBps > 0 and _vaultRegistry is properly set.
- (d). No loss is pending; deployment ratio and vault balance checks pass; custodian calls deployCapital().

### Scenario 2.
Severe undercount and false low cap: There are 100 vaults. The first 64 include limited Active assets (~10M), while later Active vaults (65–100) hold ~200M. With deploymentBufferBps at 5% and _totalDeployed at 9.4M, a deployCapital(5M) call uses only the first-64 sum (~10M) to compute a 9.5M cap and reverts since 9.4M + 5M > 9.5M, despite abundant Active assets beyond the scan window.
#### Preconditions / Assumptions
- (a). 100+ vaults registered; the first 64 have limited Active assets (~10M), later Active vaults hold ~200M.
- (b). RISKUSDVault._deploymentBufferBps = 500 (5%), _totalDeployed = 9.4M; custodian attempts deployCapital(5M).
- (c). No loss pending; vault balance and ratio checks pass; _vaultRegistry set.

### Scenario 3.
Time-sensitive redeploy blocked: After returning capital for reserves, the custodian attempts to quickly redeploy. With >64 historical vaults and the early 64 mostly inactive/low-assets, _activeRegisteredTierAssets() again undercounts. The resulting low maxTotalDeployment triggers DeploymentBufferExceeded(), preventing timely redeployment and causing missed allocation windows.
#### Preconditions / Assumptions
- (a). >64 vaults registered with early 64 largely inactive/low-assets; later Active vaults hold substantial assets.
- (b). Custodian recently called returnCapital() and now needs to redeploy quickly.
- (c). RISKUSDVault._deploymentBufferBps > 0; no loss pending; other deployCapital() checks pass.

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 1622 unchanged lines ...
     function _activeRegisteredTierAssets() internal view returns (uint256 assets) {
         uint256[] memory vaultIds = _vaultRegistry.getAllVaults();
-        uint256 limit = vaultIds.length < DEPLOYMENT_BUFFER_SCAN_LIMIT ? vaultIds.length : DEPLOYMENT_BUFFER_SCAN_LIMIT;
-        for (uint256 i; i < limit;) {
+        for (uint256 i; i < vaultIds.length;) {
             try _vaultRegistry.getVault(vaultIds[i]) returns (VaultConfig memory vc) {
                 if (vc.status == VaultStatus.Active) {
 ... 157 unchanged lines ...
```

### 34. [Low] Ratcheting daily caps from live principal basis in HLTradingBridge causes same-day operational DoS of returns/intents

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge computes per-call and per-day caps as BPS of the current _deployedPrincipal while daily usage counters accumulate. After a principal return reduces _deployedPrincipal, the remaining same-day allowance shrinks mid-window, causing subsequent same-day returns or withdrawal intents to revert even if the combined total would fit within a BPS of the day’s opening principal.

In HLTradingBridge, _enforceReturnCaps() and _enforceWithdrawalIntentCaps() compute per-call/day caps using the current _deployedPrincipal each time they run, while _returnUsedThisDay and _withdrawalIntentUsedThisDay accumulate for the day. When returnPrincipalUSDC() succeeds, it reduces _deployedPrincipal. Later same-day returns or intents are checked against this smaller principal base, but the used counters remain unchanged. This ‘ratchets down’ the remaining allowance mid-day and can make otherwise policy-compliant operations (relative to the opening-of-day principal) revert with ReturnPerDayCapExceeded or WithdrawalIntentAmountExceeded. CustodianRegistry uses a different formula (dayBasis = deployed + used, with rounded-up BPS), which keeps the effective day basis stable across intraday returns; HLTradingBridge is stricter and can temporarily block operations until the day window resets. There is no unprivileged attack path; the effect is a same-day operational throttle that can delay capital movement and dependent processes.

#### Severity

**Impact Explanation:** [Low] The effect is a partial, same-day throughput throttle: only the excess beyond the recomputed per-day/per-call caps is rejected. Core user-facing operations (deposits/redemptions) and protocol invariants remain intact, caps reset daily, and operations can be rescheduled or reordered. This does not constitute a significant DoS of core functionality.

**Likelihood Explanation:** [Medium] While avoidable via simple mitigations (PnL-first, intents-before-principal, batching one call per day), staggered off-chain arrivals and natural intraday sequencing make these scenarios plausible during normal operations without operator negligence.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Principal-first then PnL return the same day: Starting with 1,000,000e6 deployed and 10% caps, executor returns 60,000e6 principal (OK, used=60,000e6). Now _deployedPrincipal is 940,000e6. A same-day returnPnLUSDC(40,000e6) recomputes the per-day cap from 940,000e6 (94,000e6) and sees remaining=34,000e6, so it reverts ReturnPerDayCapExceeded(40,000e6, 34,000e6).
#### Preconditions / Assumptions
- (a). HLTradingBridge not paused; executor authorized; blocklist checks pass.
- (b). Start-of-day _returnUsedThisDay = 0 and within the same 1-day window.
- (c). _deployedPrincipal = 1,000,000e6; returnPerCallCapBps = returnPerDayCapBps = 1000 (10%) or similar values.
- (d). Sufficient reconciled return liquidity and USDC balance for both calls.
- (e). Operator performs a same-day principal return first (e.g., 60,000e6) followed by a PnL return (e.g., 40,000e6).

### Scenario 2.
Intent requested after a same-day principal return: With 1,000,000e6 deployed and 10% caps, executor first returns 50,000e6 principal (shrinking _deployedPrincipal to 950,000e6). Later the same day, requestWithdrawalIntent(100,000e6, …) fails because per-call cap is recomputed from 950,000e6 (95,000e6), reverting WithdrawalIntentAmountExceeded.
#### Preconditions / Assumptions
- (a). HLTradingBridge not paused; executor authorized; blocklist checks pass.
- (b). Start-of-day _withdrawalIntentUsedThisDay = 0 and within the same 1-day window.
- (c). _deployedPrincipal at day start = 1,000,000e6; returnPerCallCapBps = returnPerDayCapBps = 1000 (10%).
- (d). A same-day principal return (e.g., 50,000e6) has already reduced _deployedPrincipal (to 950,000e6).
- (e). Intent parameters valid: recipient == address(this), sourceAccount == hyperliquidSourceAccount, chainSelector == withdrawalChainSelector; no open intent.

### Scenario 3.
Two-chunk principal return plan: With 1,000,000e6 deployed and 10% caps, executor returns 60,000e6 principal (OK), reducing _deployedPrincipal to 940,000e6 and used=60,000e6. A second same-day returnPrincipalUSDC(40,000e6) recomputes day cap to 94,000e6 with remaining=34,000e6 and reverts ReturnPerDayCapExceeded.
#### Preconditions / Assumptions
- (a). HLTradingBridge not paused; executor authorized; blocklist checks pass.
- (b). Start-of-day _returnUsedThisDay = 0 and within the same 1-day window.
- (c). _deployedPrincipal = 1,000,000e6; returnPerCallCapBps = returnPerDayCapBps = 1000 (10%).
- (d). Two off-chain arrival batches are reconciled intraday; sufficient reconciled liquidity for both 60,000e6 and 40,000e6 principal returns.
- (e). Operator processes the first principal return chunk (60,000e6) and then attempts the second (40,000e6) in the same day.

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 633 unchanged lines ...
             _returnUsedThisDay = 0;
         }
-        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
+        uint256 dayBasis = principalBase + _returnUsedThisDay;
+        uint256 perDayCap = dayBasis * _returnPerDayCapBps / BPS_DENOMINATOR;
         uint256 remainingDay = perDayCap > _returnUsedThisDay ? perDayCap - _returnUsedThisDay : 0;
         if (amount > remainingDay) revert ReturnPerDayCapExceeded(amount, remainingDay);
         _returnUsedThisDay += amount;
     }

     function _enforceWithdrawalIntentCaps(uint256 amount) internal {
         uint256 principalBase = _deployedPrincipal;
-        uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
+        if (block.timestamp >= _returnUsedDayStart + DAY_SECONDS) {
+            _returnUsedDayStart = block.timestamp;
+            _returnUsedThisDay = 0;
+        }
+        uint256 dayBasis = principalBase + _returnUsedThisDay;
+        uint256 perCallCap = dayBasis * _returnPerCallCapBps / BPS_DENOMINATOR;
         if (amount > perCallCap) revert WithdrawalIntentAmountExceeded(amount, perCallCap);

         if (block.timestamp >= _withdrawalIntentUsedDayStart + DAY_SECONDS) {
             _withdrawalIntentUsedDayStart = block.timestamp;
             _withdrawalIntentUsedThisDay = 0;
         }
-        uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
+        uint256 perDayCap = dayBasis * _returnPerDayCapBps / BPS_DENOMINATOR;
         uint256 remainingDay = perDayCap > _withdrawalIntentUsedThisDay ? perDayCap - _withdrawalIntentUsedThisDay : 0;
         if (amount > remainingDay) revert WithdrawalIntentAmountExceeded(amount, remainingDay);
 ... 36 unchanged lines ...
```

#### Related findings

##### [Low] Cap basis tied to zero principal in HLTradingBridge causes PnL return and withdrawal-intent freeze

###### Description

HLTradingBridge enforces per-call and per-day caps for both returnPnLUSDC and requestWithdrawalIntent strictly as BPS of _deployedPrincipal. After principal is fully returned to zero, these caps become zero, causing returnPnLUSDC and requestWithdrawalIntent to revert. Already-reconciled PnL cannot be forwarded to USDCTreasury, and new off-chain PnL withdrawals cannot be initiated. returnPrincipalUSDC cannot be used as a fallback because RISKUSDVault rejects returns above its tracked deployed principal. This creates a liveness failure for PnL forwarding until privileged remediation (e.g., small redeploy/unfreeze/upgrade).

In HLTradingBridge, both _enforceReturnCaps and _enforceWithdrawalIntentCaps compute per-call and per-day limits as _deployedPrincipal * bps / 10,000. returnPnLUSDC() invokes _enforceReturnCaps() before forwarding reconciled liquidity to USDCTreasury; requestWithdrawalIntent() invokes _enforceWithdrawalIntentCaps() before opening a new off-chain withdrawal. When returnPrincipalUSDC() reduces _deployedPrincipal to zero, the cap basis becomes zero and any positive amount causes reverts (ReturnPerCallCapExceeded / WithdrawalIntentAmountExceeded). Meanwhile, reconcileWithdrawalArrival() can still increase _reconciledReturnLiquidity, but those funds can only be moved out via returnPnLUSDC (now capped at zero) or returnPrincipalUSDC (which cannot be used for PnL, and RISKUSDVault.returnCapital reverts if amount exceeds its own _totalDeployed when principal at the vault is zero). As a result, already-arrived PnL can be stranded on the bridge and new PnL withdrawals cannot be initiated after principal is fully unwound. This is a design-level liveness defect; no external attacker is required. It is recoverable by trusted owner actions (e.g., temporarily re-enabling a positive principal cap basis or upgrading), but can delay distributions to depositors, foundation, and agents until such actions are taken.

###### Severity

**Impact Explanation:** [Medium] This causes significant but temporary availability loss of an important non-core function: forwarding PnL to USDCTreasury and downstream distributions (depositors, foundation, agents). Principal safety and core vault operations remain intact, but payouts are materially delayed until privileged remediation.

**Likelihood Explanation:** [Low] The freeze requires specific operational states and choices by trusted operators (e.g., fully unwinding principal before forwarding all PnL, not keeping a minimal principal anchor, or not promptly redeploying a small principal to re-enable caps). Under competent operations, these conditions are avoidable or quickly remediated.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Reconciled PnL stranded after principal reaches zero: Executor previously created a PnL withdrawal intent and keeper reconciled the arrival, increasing _reconciledReturnLiquidity. Subsequent principal returns reduce _deployedPrincipal to 0. A later call to returnPnLUSDC(amount) reverts because per-call/per-day caps are computed from a zero principal base, blocking forwarding of already-arrived PnL to USDCTreasury.
#### Preconditions / Assumptions
- (a). HLTradingBridge returnPerCallCapBps/returnPerDayCapBps configured (defaults nonzero).
- (b). An earlier withdrawal intent for PnL was created within caps while principal > 0.
- (c). Keeper reconciled arrival increasing _reconciledReturnLiquidity.
- (d). Executor used returnPrincipalUSDC to reduce _deployedPrincipal to 0 before forwarding PnL.

### Scenario 2.
Late venue credits after full unwind: Principal is fully returned (bridge _deployedPrincipal == 0). Later, exchange rebates/funding arrive and are reconciled via reconcileWithdrawalArrival on an existing intent, increasing _reconciledReturnLiquidity. Attempting to forward via returnPnLUSDC reverts due to zero cap basis, freezing these funds on the bridge until privileged remediation.
#### Preconditions / Assumptions
- (a). HLTradingBridge _deployedPrincipal == 0 after legitimate principal returns.
- (b). Existing withdrawal intent enables later reconcileWithdrawalArrival to increase _reconciledReturnLiquidity.
- (c). Executor subsequently calls returnPnLUSDC(amount) > 0.

### Scenario 3.
New PnL post-unwind cannot initiate withdrawal: After _deployedPrincipal == 0, additional PnL becomes available off-chain. Executor attempts requestWithdrawalIntent(amount, this, sourceAccount, chainSelector) but it reverts because per-call/per-day caps are 0 when principal is 0. Without a new intent, no arrivals can be reconciled or forwarded, blocking the normal PnL drain path.
#### Preconditions / Assumptions
- (a). HLTradingBridge _deployedPrincipal == 0.
- (b). New PnL becomes available off-chain (e.g., late rebates/funding).
- (c). Executor attempts requestWithdrawalIntent for a positive amount.

###### Proposed fix

####### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 626 unchanged lines ...
     function _enforceReturnCaps(uint256 amount) internal {
         uint256 principalBase = _deployedPrincipal;
+        // Allow PnL-only unwind when no principal is deployed: skip caps, still limited by reconciled liquidity.
+        if (principalBase == 0) return;
         uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
         if (amount > perCallCap) revert ReturnPerCallCapExceeded(amount, perCallCap);

         if (block.timestamp >= _returnUsedDayStart + DAY_SECONDS) {
             _returnUsedDayStart = block.timestamp;
             _returnUsedThisDay = 0;
         }
         uint256 perDayCap = principalBase * _returnPerDayCapBps / BPS_DENOMINATOR;
         uint256 remainingDay = perDayCap > _returnUsedThisDay ? perDayCap - _returnUsedThisDay : 0;
         if (amount > remainingDay) revert ReturnPerDayCapExceeded(amount, remainingDay);
         _returnUsedThisDay += amount;
     }

     function _enforceWithdrawalIntentCaps(uint256 amount) internal {
         uint256 principalBase = _deployedPrincipal;
+        // When no principal is deployed, permit PnL-only intent creation without return caps; arrival is still verified.
+        if (principalBase == 0) return;
         uint256 perCallCap = principalBase * _returnPerCallCapBps / BPS_DENOMINATOR;
         if (amount > perCallCap) revert WithdrawalIntentAmountExceeded(amount, perCallCap);
 ... 44 unchanged lines ...
```

### 35. [Low] Rigid one-intent reconciliation state machine in HLTradingBridge causes stuck withdrawal intents and stranded USDC

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge enforces a single open withdrawal intent and exact, delta-from-checkpoint reconciliation to convert arrivals into usable (reconciled) liquidity. There is no cancel/partial/manual recovery path. When off-chain arrivals do not align with the intent size and no further inflow occurs, the open intent can remain stuck and/or portions of USDC can remain unreconciled and unusable by return flows.

HLTradingBridge maintains a strict withdrawal-intent process: only one intent can be open at a time; reconcileWithdrawalArrival requires arrivedAmount to equal the intent amount and that the net increase in unreconciled balance since the intent’s checkpoint meets or exceeds that amount. Only successful reconciliation increases _reconciledReturnLiquidity, which gates returnPrincipalUSDC/returnPnLUSDC. There is no cancel/expiry/partial-reconcile/manual-credit path. In realistic external conditions (e.g., partial/unsplittable exchange withdrawals, venue outages, shutdown), these constraints can cause: (a) an open intent to remain unreconcilable when net arrivals fall short and no further inflow occurs, blocking new intents and additional reconciled liquidity; or (b) surplus USDC remaining unreconciled and unusable when arrivals exceed the intent or caps and no further inflow will happen. While operational workarounds exist (e.g., external top-ups, splitting withdrawals, adjusting caps, or upgrading), the code lacks an on-chain recovery branch, leading to liveness and funds-access friction under such conditions.

#### Severity

**Impact Explanation:** [Medium] Significant availability/liveness loss within the HLTradingBridge subsystem: open intents can remain unreconcilable, blocking new intents and additional reconciled liquidity, and portions of USDC can be stranded/unusable by return flows. Not classified as high because operational workarounds (external top-ups, splitting arrivals, adjusting caps, upgrades) exist.

**Likelihood Explanation:** [Low] Requires uncommon external constraints (partial/unsplittable arrivals, outages) to persist without operator remediation. Competent operators can mitigate by sizing intents after confirmed arrivals, splitting withdrawals, adjusting caps, or performing external top-ups.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Shortfall with no further inflow: An intent for amount A is opened. Only B < A arrives on-chain and no additional inflow occurs (e.g., venue outage or exhaustion). Reconciliation fails the delta check indefinitely, leaving the open intent pending, blocking new intents and preventing any increase in reconciled liquidity needed for return flows.
#### Preconditions / Assumptions
- (a). Executor/keeper are trusted and operate HLTradingBridge per design
- (b). An intent for A is opened and checkpoint C0 recorded
- (c). Only B < A arrives on-chain (partial withdrawal/venue constraint)
- (d). No further inflow or external top-up occurs in the relevant timeframe

### Scenario 2.
Single large arrival exceeds caps: With per-call/day caps active, an intent is opened for A = cap. The off-chain venue delivers a single on-chain arrival S > cap that cannot be split. Reconciliation credits only A and clears the intent, leaving r = S − A as unreconciled. A subsequent intent snapshots a checkpoint that includes r; with no further inflow, r cannot satisfy the delta requirement and remains stranded/unusable.
#### Preconditions / Assumptions
- (a). Per-call/day return caps are active (e.g., ~10% of deployed principal)
- (b). A single off-chain arrival S > cap is delivered and cannot be split
- (c). An intent is sized to A = cap to satisfy caps
- (d). No further inflow occurs after the large arrival; owner does not or cannot promptly adjust caps before/at arrival

### Scenario 3.
Final-cycle overshoot at wind-down: During shutdown, an intent for A is opened but the venue delivers A + e (e > 0) due to minimum increments/rounding. Reconciliation credits A, leaving e unreconciled. With no further inflow planned, e cannot satisfy a new intent’s delta requirement and remains stranded on the bridge.
#### Preconditions / Assumptions
- (a). Protocol is winding down HL exposure (no further inflow planned)
- (b). Final off-chain arrival exceeds the intended amount by e > 0 due to rounding/minimum increments
- (c). Reconciliation is executed for exactly the intent amount A (as required by code)

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 336 unchanged lines ...
         uint256 currentBalance = IERC20(usdc).balanceOf(address(this));
         uint256 unreconciledBalance = _unreconciledBalance(currentBalance);
-        if (unreconciledBalance < intent.balanceCheckpoint + arrivedAmount) revert ArrivalAmountMismatch();
+        // Allow reconciliation against total unreconciled balance to avoid deadlocks on mismatches
+        if (unreconciledBalance < arrivedAmount) revert ArrivalAmountMismatch();

         _reconciledReturnLiquidity += arrivedAmount;
         intent.consumed = true;
         _openWithdrawalIntentId = bytes32(0);
         emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
     }

+    // Allows owner or guardian to clear a stuck open intent when no further inflow is expected.
+    function cancelOpenWithdrawalIntent() external {
+        _requireGuardianModuleOrOwner();
+        bytes32 id = _openWithdrawalIntentId;
+        if (id == bytes32(0)) revert RequestMismatch();
+        WithdrawalIntent storage intent = _withdrawalIntents[id];
+        if (!intent.exists || intent.consumed) revert RequestMismatch();
+        intent.consumed = true;
+        _openWithdrawalIntentId = bytes32(0);
+    }
+
     function setDirectionalFreeze(bool frozen) external {
         _requireGuardianModuleOrOwner();
 ... 341 unchanged lines ...
```

### 36. [Low] Storage layout insertion in atRISKUSD upgrade causes loss of expired opt‑out lockup enforcement on first transfer

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

After an upgrade that inserts _legitimateAssets before previously live tracking fields, the per‑account auto‑renew‑disabled tracking storage is orphaned. Until each account is re‑tracked, atRISKUSD no longer reverts transfers from depositors with autoRenew disabled and expired lockups, allowing a one‑time transfer to third parties and bypassing intended post‑expiry restrictions.

The atRISKUSD contract added a new state variable (_legitimateAssets) and seeds it via initializeV2(). Because it is declared before several later fields, upgrading a live proxy where those later fields already existed shifts their storage slots. The code only seeds _legitimateAssets and clears pending setter state; it does not migrate the per‑account tracking used to enforce Expired Auto‑Renew Disabled Lockup behavior (_autoRenewDisabledTracked, _autoRenewDisabledTrackedExpiry, counters, and min‑heap). After upgrade, these mappings/heaps are effectively empty in the new layout. The transfer gate in _update() checks _hasExpiredAutoRenewDisabledAccount(from) before syncing tracking and therefore allows the first post‑upgrade transfer from such accounts to any third party, rather than reverting with ExpiredAutoRenewDisabledLockup. Only after that transfer does _syncAutoRenewDisabledTracking run and re‑establish enforcement for subsequent actions. This creates a real but non‑fund‑loss policy/semantics enforcement gap on post‑expiry share mobility. It does not rely on operator mistakes, cannot be fully mitigated in a single upgrade transaction, and does not affect solvency or core deposit/withdraw flows.

#### Severity

**Impact Explanation:** [Low] This is a policy/logic enforcement gap that allows a one‑time transfer by accounts with autoRenew disabled and expired lockups. It does not cause principal loss, does not break solvency/accounting, and does not disable core deposit/withdraw flows.

**Likelihood Explanation:** [Medium] Requires a realistic live upgrade over proxies that previously used the tracking fields and the presence of users with autoRenew disabled and expired lockups. No admin/operator mistake is required; a user’s first post‑upgrade transfer will bypass the check by design before re‑tracking occurs.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A live atRISKUSD proxy is upgraded to a version that declares _legitimateAssets before the existing auto‑renew‑disabled tracking fields. The owner calls initializeV2() (as required for totalAssets()) but no migration exists for the tracking data. Some users previously set autoRenew disabled and now have expired lockups. Such a user performs a transfer of atRISKUSD shares to a third‑party address. Because the tracking mappings/heap are empty in the new storage slot, _hasExpiredAutoRenewDisabledAccount(from) returns false and the revert ExpiredAutoRenewDisabledLockup does not trigger, allowing this first post‑upgrade transfer. After the transfer, _syncAutoRenewDisabledTracking re‑tracks the account, restoring enforcement for subsequent actions, but the one‑time bypass has already occurred.
#### Preconditions / Assumptions
- (a). The proxy was previously running a version where auto‑renew‑disabled tracking fields existed after the point where _legitimateAssets is now declared.
- (b). A UUPS upgrade to the current layout was performed and initializeV2() was called to seed _legitimateAssets.
- (c). There exist depositors who had autoRenew disabled and whose lockups are expired at or shortly after upgrade time.
- (d). No explicit migration exists to rebuild the per‑account tracking structures immediately after upgrade.
- (e). Affected users perform a transfer before any other state change re‑tracks their account.

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 923 unchanged lines ...
                     revert LockupNotExpired(_lockExpiry[from]);
                 }
-                if (to != address(this) && _hasExpiredAutoRenewDisabledAccount(from)) {
+                if (to != address(this) && _shouldBlockExpiredAutoRenewTransfer(from)) {
                     revert ExpiredAutoRenewDisabledLockup();
                 }
 ... 148 unchanged lines ...
     }

+    function _shouldBlockExpiredAutoRenewTransfer(address account) private view returns (bool) {
+        if (_lockupPeriod == 0) return false;
+        if (!_autoRenewDisabled[account]) return false;
+        uint256 expiry = _lockExpiry[account];
+        if (expiry == 0 || block.timestamp < expiry) return false;
+        return _autoRenewDisabledEffectiveBalance(account) > 0;
+    }
     function _hasExpiredAutoRenewDisabledAccount(address account) private view returns (bool) {
         uint256 expiry = _autoRenewDisabledTrackedExpiry[account];
 ... 154 unchanged lines ...
```

### 37. [Low] Zero-address tier vault auto-sync in StakingQueue during WindingDown causes DoS of selfRevert/keeper/upgrade flows

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

During WindingDown, VaultRegistry can zero released tier vault slots. StakingQueue’s auto-sync copies these zeros into its cache and then unconditionally aggregates across all four tier addresses, calling totalAssets/totalSupply on address(0). This reverts and blocks selfRevert, processExpiredLockups, and upgradeTier. Users can still exit via atRISKUSD withdrawals, so impact is limited to a liveness/operability DoS of queue-managed flows.

VaultRegistry.releaseTierVaults(vaultId) sets specific tierVaults[i] = address(0) for tiers that are fully empty while the vault is WindingDown. StakingQueue._syncTierVaultsFromRegistry() then overwrites its cached _tierVaults[] with these registry values without validating nonzero addresses. StakingQueue’s selfRevert, processExpiredLockups, and upgradeTier all call _syncTierVaultsFromRegistry() and then compute aggregate invariants via _combinedTotalAssets() or _combinedBackingPerShareRay(), which loop across all four cached addresses and call totalAssets()/totalSupply() through a high-level interface. When any cached entry is address(0) (no code), the call returns empty returndata and ABI decoding reverts, causing these functions to fail systematically after any tier is released. In processExpiredLockups, each per-depositor attempt reverts in the invariant pre-check and is caught, emitting a failure event without processing the lockup. In selfRevert and upgradeTier, the transactions revert outright. Owner-only syncTierVaults() explicitly rejects zero addresses, highlighting an inconsistency with the auto-sync path. Funds are not lost because users can still exit directly via atRISKUSD withdrawals; therefore, the issue is a liveness DoS of queue-managed reversion/upgrade and keeper batch processing during WindingDown.

#### Severity

**Impact Explanation:** [Low] Denial of specific non-core, queue-managed flows (selfRevert, keeper batch processing, tier upgrades) during WindingDown; core exits remain available via atRISKUSD withdrawals; no principal loss.

**Likelihood Explanation:** [Low] Requires a specific lifecycle phase (WindingDown) plus a deliberate, legitimate governance action (releasing empty tiers) and users/operators attempting affected queue flows during that window; operators can coordinate to mitigate.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Self-revert blocked: A depositor with an expired lockup in a live tier calls StakingQueue.selfRevert after another tier was released to address(0). Auto-sync caches the zero, _combinedTotalAssets() calls totalAssets() on address(0), reverts, and the user cannot self-revert to tier 0. They must instead use atRISKUSD withdrawals.
#### Preconditions / Assumptions
- (a). Vault is WindingDown (VaultRegistry.startWindDown executed)
- (b). At least one tier fully emptied and released via VaultRegistry.releaseTierVaults, so registry returns address(0) for that tier
- (c). StakingQueue has a valid _vaultId and is not paused
- (d). User has an expired lockup in a live tier, no pending withdrawal, and is not blocklisted
- (e). No loss is pending (so atRISKUSD redeem paths would be allowed if reached)

### Scenario 2.
Keeper batch reversion blocked: An operator calls StakingQueue.processExpiredLockups for depositors in a live tier after any other tier has been released to address(0). Auto-sync caches the zero, and for each depositor the invariant pre-check _combinedTotalAssets() reverts on address(0); the outer try/catch emits ExpiredLockupProcessingFailed for each, and no lockups are processed.
#### Preconditions / Assumptions
- (a). Vault is WindingDown
- (b). At least one tier fully emptied and released via VaultRegistry.releaseTierVaults, producing address(0) in tierVaults
- (c). StakingQueue is not paused; keeper/operator invokes processExpiredLockups on a live tier
- (d). Affected depositors have expired lockups and are not blocklisted
- (e). Whether or not a loss is pending is immaterial here because the revert happens before calling redeem

### Scenario 3.
Tier upgrades blocked: A user attempts StakingQueue.upgradeTier(fromTier,toTier) during WindingDown after any tier has been released to address(0). Auto-sync caches the zero, _combinedBackingPerShareRay() calls totalAssets()/totalSupply() on address(0) and reverts, preventing the upgrade.
#### Preconditions / Assumptions
- (a). Vault is WindingDown
- (b). At least one tier fully emptied and released via VaultRegistry.releaseTierVaults, producing address(0) in tierVaults
- (c). fromTier and toTier are still live (non-zero) atRISKUSD vaults
- (d). StakingQueue is not paused; user is not blocklisted and holds shares in fromTier
- (e). No loss is pending

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 1415 unchanged lines ...
         uint256 totalShares;
         for (uint256 i; i < 4;) {
-            IAtRiskBackingView backingView = IAtRiskBackingView(_tierVaults[i]);
-            totalBackingAssets += backingView.totalAssets() + 1;
-            totalShares += backingView.totalSupply() + AT_RISK_SHARE_SCALE;
+            if (_tierVaults[i].code.length != 0) {
+                IAtRiskBackingView backingView = IAtRiskBackingView(_tierVaults[i]);
+                totalBackingAssets += backingView.totalAssets() + 1;
+                totalShares += backingView.totalSupply() + AT_RISK_SHARE_SCALE;
+            }
             unchecked {
                 ++i;
             }
         }
+        if (totalShares == 0) return 0;
         return Math.mulDiv(totalBackingAssets, RAY * AT_RISK_SHARE_SCALE, totalShares);
     }

     function _assertCombinedBackingPerShareNotDecreased(uint256 beforeRay) internal view {
         if (_combinedTotalSupply() == 0) return;
         uint256 afterRay = _combinedBackingPerShareRay();
         if (afterRay < beforeRay) revert CombinedBackingPerShareDecreased(beforeRay, afterRay);
     }

     function _assertCombinedAssetsNotDecreased(uint256 beforeAssets) internal view {
         uint256 afterAssets = _combinedTotalAssets();
         if (afterAssets < beforeAssets) revert CombinedBackingAssetsDecreased(beforeAssets, afterAssets);
     }

     function _combinedTotalAssets() internal view returns (uint256 totalAssets) {
         for (uint256 i; i < 4;) {
-            totalAssets += IAtRiskBackingView(_tierVaults[i]).totalAssets();
+            if (_tierVaults[i].code.length != 0) {
+                totalAssets += IAtRiskBackingView(_tierVaults[i]).totalAssets();
+            }
             unchecked {
                 ++i;
             }
         }
     }

     function _combinedTotalSupply() internal view returns (uint256 totalShares) {
         for (uint256 i; i < 4;) {
-            totalShares += IAtRiskBackingView(_tierVaults[i]).totalSupply();
+            if (_tierVaults[i].code.length != 0) {
+                totalShares += IAtRiskBackingView(_tierVaults[i]).totalSupply();
+            }
             unchecked {
                 ++i;
 ... 80 unchanged lines ...
```

### 38. [Low] Zero-asset legacy supply guard in atRISKUSD with StakingQueue processing causes tier deposit queue liveness failure

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When an atRISKUSD tier reaches totalAssets()==0 while totalSupply()>0 (after a full loss), atRISKUSD.deposit() reverts by design. StakingQueue continues to admit entries and attempts to process them, but each processQueue() call reverts on deposit, preventing head advancement and blocking that tier’s queue until users or admin cancel entries.

In atRISKUSD, totalAssets() is backed by _legitimateAssets only. After a full loss is absorbed via absorbLoss(), a tier can be left in a state where totalAssets()==0 while totalSupply()>0. The vault intentionally prevents new inflows in this state by reverting deposit()/mint() with ZeroAssetLegacySupply. StakingQueue admits entries via joinQueue() without capacity checks and uses legitimateAssets (via legitimateAssets()) to compute capacity only during processing. When processQueue() runs, it calls _depositQueuedRiskusd(), which low-level calls vault.deposit(). In the zero-asset legacy supply state, deposit() reverts, bubbling up and reverting processQueue() before the queue head is advanced. As a result, any non-cancelled, non-blocklisted entry will repeatedly cause reverts for that tier, and later entries remain unprocessed. Funds for affected users are not lost: they are escrowed by StakingQueue and can be retrieved by cancelQueue(); admins can also refund via adminCancelQueue(). The condition is tier-scoped (other tiers remain unaffected) and operational mitigations exist (e.g., keepers stop processing that tier, guardians/governance shrink the tier’s deposit cap to 0, or admins unwind entries).

#### Severity

**Impact Explanation:** [Medium] Significant but contained availability loss: the deposit path for one tier is effectively DoS’ed; queued funds are escrowed but recoverable via cancel/adminCancel; other tiers and withdrawals remain functional.

**Likelihood Explanation:** [Low] Requires an exceptional but plausible precondition (full loss causing totalAssets()==0 while totalSupply()>0). Repeated revert behavior also depends on operational choices (keepers attempting to process the broken tier).

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Tier-wide queue liveness failure after full loss: A tier suffers a full loss such that atRISKUSD.totalAssets()==0 while totalSupply()>0. Users join the tier’s queue; keepers call processQueue(). Each deposit attempt reverts with ZeroAssetLegacySupply, so processQueue() reverts and head advancement never occurs. All queued entries for that tier remain unprocessed until users/admin cancel.
#### Preconditions / Assumptions
- (a). The specific atRISKUSD tier is in zero-asset legacy supply: totalAssets()==0 and totalSupply()>0 (e.g., following a full loss via absorbLoss())
- (b). The tier’s deposit cap is not shrunk to 0 (so processing is attempted)
- (c). A keeper or operator calls processQueue(tier, ...)

### Scenario 2.
Gas griefing of keepers on a broken tier: While the tier is in zero-asset legacy supply, an attacker or any user spams joinQueue() for that tier. If naïve keepers continue to call processQueue(tier,...), each call reverts on the first live entry due to deposit() reverting, wasting keeper gas and accumulating unprocessable entries. Users must cancel to recover funds.
#### Preconditions / Assumptions
- (a). Same broken-tier state: totalAssets()==0 and totalSupply()>0
- (b). Users (including an attacker) can join the queue for the broken tier
- (c). Naïve keepers continue attempting processQueue(tier, ...)

### Scenario 3.
Priority FORAGE remains locked until cancel: A user joins the broken tier with priority (locking FORAGE). Because processing never succeeds (deposit() reverts), the per-entry FORAGE unlock on success never runs. The user’s FORAGE remains locked until they cancel the queue entry (or admin refunds), after which unlock is attempted or can be retried.
#### Preconditions / Assumptions
- (a). Same broken-tier state: totalAssets()==0 and totalSupply()>0
- (b). Priority lane is enabled and priced; the user opts into priority in joinQueue()
- (c). No successful processing occurs (deposit() continues to revert)

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 329 unchanged lines ...
         }

+        // FIX-MITIGATION: Reject admissions into a tier whose atRISKUSD vault is in
+        // zero-asset legacy supply (totalSupply()>0 && totalAssets()==0) by checking
+        // IAtRiskBackingView(totalSupply/totalAssets) and reverting with a clear error.
+
         _riskusd.safeTransferFrom(msg.sender, address(this), riskusdAmount);

 ... 84 unchanged lines ...
         if (config.status != VaultStatus.Active) revert VaultNotActive();

+        // FIX-MITIGATION: If the target tier's vault is in zero-asset legacy supply,
+        // short-circuit here with a clear error (e.g., TierDepositHalted) to avoid
+        // attempting deposit() and blocking head advancement on repeated reverts.
+
         uint256 avail = _availableCapacityForCap(config.capacityCap);
         if (avail == 0) revert NoCapacityAvailable();
 ... 964 unchanged lines ...
         uint256 minimumShares = _minimumDepositShares(tierVaultAddr, riskusdAmount);

+        // FIX-MITIGATION: Defensive guard — pre-check zero-asset legacy supply and
+        // revert with a clear, tier-specific error before the low-level deposit() call.
+
         // OF-M10: use forceApprove instead of bare approve
         _riskusd.forceApprove(tierVaultAddr, riskusdAmount);
 ... 73 unchanged lines ...
         uint256 tierCap = _effectiveTierDepositCapForCap(tier, vaultCap);
         uint256 staked = _tierStaked(tier);
+        // FIX-MITIGATION: Treat tiers in zero-asset legacy supply as having 0 available capacity
+        // so views and processing logic avoid attempting new deposits and signal halt status.
+        // (Detect via IAtRiskBackingView.totalSupply/totalAssets.)
         if (staked >= tierCap) return 0;
         return tierCap - staked;
 ... 66 unchanged lines ...
```

#### Related findings

##### [Low] Zero-asset legacy supply state in atRISKUSD after full loss causes tier-level DoS

###### Description

atRISKUSD tracks totalAssets via internal _legitimateAssets; a full loss absorbed by the authorized yieldSource can set _legitimateAssets to zero without burning shares. With totalSupply > 0 and totalAssets == 0, deposit/mint/accrueYield revert, and all redemption/migration paths return 0 and revert. Donations don’t restore accounting. No on-chain recovery path exists without an upgrade.

In atRISKUSD, totalAssets() is overridden to return _legitimateAssets. The yieldSource-only absorbLoss() can reduce _legitimateAssets to zero without reducing totalSupply. Once totalSupply() != 0 and totalAssets() == 0: (1) deposit(), mint(), and accrueYield() all revert via _requireNoZeroAssetLegacySupply(); (2) convertToAssets() returns 0 under OZ ERC-4626 math with virtual shares, causing redeem(), executeWithdrawal(), redeemForUpgrade(), and redeemForReversion() to revert with ZeroRedemptionOutput; (3) direct RISKUSD donations are ignored by totalAssets() accounting and cannot re-seed _legitimateAssets. The emergency loss-pending override and weekly withdrawal cap logic do not help. This yields a permanent, on-chain unusable state for the affected tier unless a governance upgrade adds a recovery mechanism. The impact is component-level availability loss (no additional principal is lost by the bug itself), and likelihood is low because it requires a genuine 100% loss event.

###### Severity

**Impact Explanation:** [Medium] Severe availability loss of a core component (tier) where deposits/mints/yield accrual and all exits/migrations are blocked on-chain; scope is tier-level and does not add new principal loss beyond the already realized 100% loss.

**Likelihood Explanation:** [Low] Requires the rare/exceptional precondition of a genuine 100% loss event and, for some scenarios, additional timing (e.g., pending cooldown), without relying on user/admin mistakes or broken integrations.

###### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A genuine 100% loss is recorded by the authorized yieldSource via absorbLoss(), zeroing _legitimateAssets while totalSupply > 0. All redemption and migration paths revert due to zero outputs, and deposit/mint/accrueYield are blocked by the zero-asset legacy guard. The tier becomes bricked on-chain.
#### Preconditions / Assumptions
- (a). The atRISKUSD tier has nonzero totalSupply due to prior deposits
- (b). The tier initially has _legitimateAssets > 0
- (c). The authorized yieldSource calls absorbLoss with an amount >= _legitimateAssets to reflect a genuine 100% economic loss
- (d). No immediate governance upgrade/recovery function is deployed

### Scenario 2.
A user who previously requested a cooldown withdrawal cannot execute it after a full loss: convertToAssets for their locked shares becomes 0, causing executeWithdrawal() to revert with ZeroRedemptionOutput, leaving shares non-redeemable.
#### Preconditions / Assumptions
- (a). User has an active pending cooldown withdrawal with shares locked in the vault contract
- (b). Before cooldown execution, a genuine 100% loss is absorbed, setting _legitimateAssets (totalAssets) to 0 while totalSupply > 0
- (c). No immediate governance upgrade/recovery function is deployed

### Scenario 3.
Operators attempt to recapitalize the tier by donating RISKUSD or calling accrueYield/deposit/mint. Donations do not affect totalAssets() (which follows _legitimateAssets), and accrueYield/deposit/mint revert due to the zero-asset legacy guard. The tier remains unusable until a governance upgrade adds a recovery path.
#### Preconditions / Assumptions
- (a). The tier is in the state totalAssets() == 0 and totalSupply() > 0 after a prior absorbLoss
- (b). Operators attempt to donate RISKUSD or use accrueYield/deposit/mint to recapitalize
- (c). No governance upgrade/recovery function is deployed yet

###### Proposed fix

####### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 322 unchanged lines ...
         if (msg.sender != _yieldSource) revert UnauthorizedYieldSource();
         if (riskusdAmount == 0) revert ZeroAmount();
-        _requireNoZeroAssetLegacySupply();
         _requireNotBlocked(msg.sender);

 ... 907 unchanged lines ...
```

### 39. [Informational] Blocklist gating of unlock paths in StakingQueue/ForageToken causes stranded FORAGE locks for blocked depositors

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When a depositor is blocklisted, the FORAGE unlock cleanup for priority-lane entries cannot proceed: StakingQueue.retryForageUnlock requires the depositor not be blocked, and ForageToken.unlock/emergencyUnlock also refuse blocked accounts. The result is that a blocked user’s FORAGE lock remains stranded until unblocked, while RISKUSD side effects (deposit or admin cancel) complete normally.

Priority-lane queue entries in StakingQueue lock a depositor’s FORAGE via ForageToken.lock. On processing or admin cancellation, StakingQueue attempts ForageToken.unlock; if it fails, it emits ForageUnlockFailed and keeps the per-entry lock amount for later retry. The retry path StakingQueue.retryForageUnlock enforces that the original depositor is not blocklisted. Separately, ForageToken.unlock and owner-only emergencyUnlock also enforce that the account is not blocklisted. Therefore, while a depositor remains blocklisted, there is no on-chain path to clear the FORAGE lock; it remains stranded until the account is unblocked, at which point anyone can call retryForageUnlock (or the owner can use emergencyUnlock if the locker is deauthorized). StakingQueue.processQueue skips currently blocked depositors, so blocklisting alone will not create a newly processed entry; however, a previously processed entry whose unlock failed for a different reason can become unrecoverable while the user is blocked. The effect is confined to the blocked user’s FORAGE lock cleanup (no principal loss, protocol funds unaffected) and aligns with a strict, intended blocklist freeze policy.

#### Severity

**Impact Explanation:** [Low] No principal loss or protocol-wide risk; the effect is a temporary unavailability of FORAGE unlock cleanup for the blocked user only. Recovery is possible after unblocking; RISKUSD processing/cancel proceeds as intended. Incremental harm beyond the intended blocklist freeze is minimal.

**Likelihood Explanation:** [Low] All scenarios rely on trusted operator actions (guardian blocklisting, owner admin-cancel and/or prior locker state changes) and specific state sequences; there is no unprivileged exploit path.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Admin-cancel after blocklisting: A user joined priority lane (FORAGE locked). The guardian blocklists the user. The owner admin-cancels the queue entry, returning RISKUSD to a non-blocked recipient. The subsequent FORAGE unlock fails due to the blocklist; retryForageUnlock also reverts while blocked; emergencyUnlock also refuses blocked accounts. The FORAGE remains locked until the user is unblocked.
#### Preconditions / Assumptions
- (a). StakingQueue is authorized as a ForageToken locker when the user joined the priority lane
- (b). User has a priority-lane queue entry with FORAGE locked
- (c). Guardian blocklists the user (trusted operator action)
- (d). Owner calls adminCancelQueue during the block period

### Scenario 2.
Queued entry under blocklist: A user with a queued (possibly priority) entry is blocklisted. processQueue skips the user; the user cannot self-cancel (cancelQueue requires not blocked). Only adminCancelQueue can return the RISKUSD. If priority, the FORAGE unlock attempt fails while blocked and remains stranded until unblocked.
#### Preconditions / Assumptions
- (a). User has a queued entry (priority or standard) held by StakingQueue
- (b). Guardian blocklists the user (trusted operator action)
- (c). No self-cancel possible due to blocklist; only owner can adminCancelQueue

### Scenario 3.
Processed entry with prior unlock failure then blocklist: A priority entry was processed (RISKUSD deposited) but the unlock failed for a non-blocklist reason (e.g., transient locker deauthorization). Later, the guardian blocklists the user. retryForageUnlock now reverts due to the blocklist, and emergencyUnlock also refuses blocked accounts. The FORAGE remains locked until unblocked.
#### Preconditions / Assumptions
- (a). User had a priority entry that was processed (RISKUSD deposited)
- (b). The initial FORAGE unlock failed for a non-blocklist reason (e.g., transient locker deauthorization)
- (c). Guardian later blocklists the user (trusted operator action)

#### Proposed fix

##### ForageToken.sol

File: `openforage_smart_contracts/src/ForageToken.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageToken.sol)

```diff
 ... 275 unchanged lines ...
         if (account == address(0)) revert ZeroAddress();
         if (amount == 0) revert ZeroAmount();
-        _requireNotBlocked(account);

         uint256 lockerBal = _lockerBalances[account][msg.sender];
 ... 52 unchanged lines ...
         if (account == address(0)) revert ZeroAddress();
         if (locker == address(0)) revert ZeroAddress();
-        _requireNotBlocked(account);
         if (_authorizedLockers[locker]) revert LockerStillAuthorized();
         uint256 lockerBal = _lockerBalances[account][locker];
 ... 95 unchanged lines ...
```

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 1103 unchanged lines ...
             }
         }
-        _requireNotBlocked(entry.depositor);

         (bool unlockSuccess,) = _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
 ... 424 unchanged lines ...
```

### 40. [Informational] Deterministic, nonce-less rotation IDs and non-reset executed flag in GuardianModule cause single-use rotations and block reusing the same accelerated tuple

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

GuardianModule keys rotations by a deterministic, nonce-less operationId per (path, slot, current, successor) and never clears executed for that key. After a path-specific tuple is executed once, attempts to repeat the same tuple on that same path always revert. For guardian seat changes, only accelerated execution actually transfers permissions, so reusing the same accelerated tuple later is blocked, creating operational rigidity.

GuardianModule computes operationId as keccak256("accelerated"|"routine", slot, current, successor) without any nonce/epoch, making each (path, slot, current, successor) a single unique key for all time. For accelerated rotations, proposeAcceleratedRotation only initializes state if the key does not already exist; re-proposing an existing key does not reset readyAt or executed. For routine rotations, proposeRoutineRotation overwrites some fields but does not clear executed. Both executeAcceleratedRotation and finalizeRoutineRotation revert if executed is already true. Consequently, once a given tuple (for a given path) has executed, it is permanently ineligible for re-execution. For the guardian seat specifically, only accelerated execution calls _replaceGuardianSeat to transfer permissions; routine finalize does not change the guardian seat, so reusing accelerated A→B later is blocked and routine A→B cannot substitute for a seat change. The net effect is an operational limitation rather than a funds-impacting bug: the protocol cannot repeat the same accelerated rotation to the same successor address; operators must either use a new successor address (fresh opId) via timelock or upgrade the module.

#### Severity

**Impact Explanation:** [Low] No direct fund loss or user-facing core-functionality break. The impact is an operational limitation: inability to re-execute the same path-specific rotation tuple (notably accelerated guardian-seat A→B) without changing the successor address or upgrading. Emergency tools (pause/emergency-exec) remain available, and a governance workaround exists (pre-commit a new successor).

**Likelihood Explanation:** [Low] Multiple conditions must align: a prior accelerated A→B, a later return to A, and a fresh emergency that specifically requires reusing the exact same B address immediately instead of using pause/emergency-exec or a pre-committed alternate successor (B2). Well-run operations can mitigate by pre-committing backups or using governance to set a new successor, reducing frequency.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Emergency guardian-seat A→B accelerated re-rotation blocked: After an earlier accelerated A→B executed successfully and the seat later returned to A, a new emergency requires accelerated A→B to the same B address. Re-proposing returns the same operationId with executed=true, and executeAcceleratedRotation reverts, preventing re-rotation. Routine A→B cannot substitute because it does not transfer guardian permissions.
#### Preconditions / Assumptions
- (a). GuardianModule deployed with guardians and permissions set
- (b). preCommittedSuccessor[SLOT_GUARDIAN_SEAT][A] = B and reciprocal entries exist
- (c). An accelerated A→B was executed historically (executed=true for that operationId)
- (d). The seat later returned to A by some valid rotation
- (e). A new emergency requires moving the seat from A back to the exact same B address immediately

### Scenario 2.
Misleading accelerated readiness on re-proposal: After an earlier accelerated A→B executed, operators re-propose the same tuple and observe non-zero readyAt/ready flags but execution still reverts because executed=true permanently blocks reuse, causing UX confusion and operational delay.
#### Preconditions / Assumptions
- (a). An accelerated A→B was executed historically (executed=true for that operationId)
- (b). Operators re-propose the same accelerated A→B operationId expecting readiness to suffice for execution

#### Proposed fix

##### GuardianModule.sol

File: `openforage_smart_contracts/src/GuardianModule.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/GuardianModule.sol)

```diff
 ... 117 unchanged lines ...
     mapping(bytes32 => mapping(address => bool)) internal _rotationApprovals;
     mapping(bytes32 => uint256) internal _rotationApprovalCount;
+    // NOTE(OF-FIX): To enable repeat rotations per (path,slot,current,successor), introduce per-tuple
+    // nonces and "open" operation tracking, and include the nonce in operationId. On propose:
+    // - return the open op if present; else increment nonce, create a fresh opId, and mark it open.
+    // On execute/finalize: mark executed and clear the corresponding open opId pointer.
+    // This avoids reusing stale executed state and leaking approvals/readiness across attempts.

     /// @dev Reserved storage gap for future upgrades.
 ... 216 unchanged lines ...
         }
     }
+    // NOTE(OF-FIX): Update to use/open per-tuple nonce-based opId (see comment above).

     function proposeAcceleratedRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
 ... 32 unchanged lines ...
         return _rotations[operationId].readyAt;
     }
+    // NOTE(OF-FIX): After success, clear open opId for (slot,current,successor).

     function executeAcceleratedRotation(bytes32 operationId) external {
         Rotation storage rotation = _rotations[operationId];
         if (rotation.readyAt == 0 || block.timestamp < rotation.readyAt || rotation.executed) {
             revert RotationNotReady();
         }
         rotation.executed = true;
         activeSlotHolder[rotation.slot] = rotation.successor;
         if (rotation.slot == SLOT_GUARDIAN_SEAT) {
             _replaceGuardianSeat(rotation.current, rotation.successor);
         }
     }
+    // NOTE(OF-FIX): Same nonce/open-op semantics for routine; refreshing proposedAt for open op.

     function proposeRoutineRotation(bytes32 slot, address current, address successor) external returns (bytes32) {
         if (msg.sender != governor) revert Unauthorized();
         if (preCommittedSuccessor[slot][current] != successor) revert SuccessorNotPreCommitted();
         bytes32 operationId = keccak256(abi.encode("routine", slot, current, successor));
         Rotation storage rotation = _rotations[operationId];
         rotation.slot = slot;
         rotation.current = current;
         rotation.successor = successor;
         rotation.proposedAt = block.timestamp;
         rotation.exists = true;
         return operationId;
     }
+    // NOTE(OF-FIX): After success, clear open routine opId for (slot,current,successor).

     function finalizeRoutineRotation(bytes32 operationId) external {
 ... 656 unchanged lines ...
```

### 41. [Informational] Exact-amount-only reconciliation in HLTradingBridge causes surplus USDC to be stranded

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge reconciles only the exact requested withdrawal amount and exposes no sweep/manual-reconcile path, so any surplus USDC that arrives (beyond the intent amount) becomes unreconciled and unspendable by the bridge until a governance upgrade.

HLTradingBridge tracks spendable funds via _reconciledReturnLiquidity and computes unreconciledBalance as current token balance minus this reconciled bucket. On reconcileWithdrawalArrival, the contract requires arrivedAmount == intent.amount and only credits exactly that amount to _reconciledReturnLiquidity. Spending via returnPrincipalUSDC/returnPnLUSDC is strictly limited to _reconciledReturnLiquidity, not raw balance. If the off-chain platform sends more than the requested amount in a single transfer, the extra remains as unreconciledBalance and cannot be moved by any on-chain function in HLTradingBridge. Future withdrawal intents cannot absorb this old surplus because each new intent snapshots a balanceCheckpoint that already includes the surplus; reconciliation requires new post-checkpoint arrivals. There is no sweep or manual-reconcile function to recover this balance; only a UUPS upgrade adding such functionality can recover it. Core operations continue to function, and there is no theft, but the surplus portion is stranded until governance action.

#### Severity

**Impact Explanation:** [Low] The surplus is stranded but recoverable via a governance UUPS upgrade; no theft occurs and core protocol functionality remains intact.

**Likelihood Explanation:** [Low] Requires the integration to send more than the exact intent amount in a single transfer, which is an uncommon deviation from the expected exact-amount-per-intent workflow and outside attacker control.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Protocol-owned surplus stranded: An open withdrawal intent exists for amount A. The off-chain platform pays A + R (R > 0) to HLTradingBridge in a single transfer (e.g., bundling principal plus rebate/PnL). The keeper reconciles with arrivedAmount = A (must equal the intent). Only A is credited to _reconciledReturnLiquidity; R remains unreconciled and cannot be returned to the vault/treasury or redeployed by any on-chain function. The surplus R stays stuck until a governance UUPS upgrade introduces a sweep/manual-reconcile.
#### Preconditions / Assumptions
- (a). HLTradingBridge is deployed and configured with valid roles and USDC token.
- (b). A withdrawal intent for amount A has been created and is currently open.
- (c). The off-chain platform sends a single inbound payment totaling A + R (R > 0) to the bridge for that intent.
- (d). The keeper reconciles using arrivedAmount = A (exact-match requirement).
- (e). USDC exhibits standard ERC20 behavior (no fees/rebasing/hooks) per scope assumptions.

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 343 unchanged lines ...
         emit WithdrawalArrivalReconciled(intentId, arrivedAmount);
     }
+    function reconcileSurplus(uint256 amount) external nonReentrant { _requireKeeper(); if (amount==0) revert ZeroAmount(); _requireNotBlocked(msg.sender); uint256 u=_unreconciledBalance(IERC20(usdc).balanceOf(address(this))); bytes32 id=_openWithdrawalIntentId; if (id!=bytes32(0)) { WithdrawalIntent storage w=_withdrawalIntents[id]; uint256 mr=w.balanceCheckpoint+w.amount; if (u<mr) revert ArrivalAmountMismatch(); u-=mr; } if (amount>u) revert ArrivalAmountMismatch(); _reconciledReturnLiquidity+=amount; }

     function setDirectionalFreeze(bool frozen) external {
 ... 342 unchanged lines ...
```

### 42. [Informational] No per-entry FORAGE lock backfill in StakingQueue V3 upgrade causes temporary user FORAGE to remain locked until cleanup

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When upgrading to StakingQueue V3, legacy priority queue entries have no per-entry FORAGE lock amounts recorded. Processing or canceling such entries skips auto-unlock, leaving the user’s FORAGE locked in ForageToken until their total priority exposure reaches zero and retryForageUnlock() is called. This is recoverable via a single permissionless call and/or by canceling outstanding priority entries.

StakingQueue V3 introduces per-entry FORAGE lock tracking via _forageLockedPerEntry but reinitializeV3() is a no-op, so legacy pre‑V3 entries have zero recorded lock amounts. In joinQueue(), new V3 entries record the per-entry lock; however, cancelQueue() and the priority-lane path in processQueue() only attempt unlock if _forageLockedPerEntry[queueId] > 0. As a result, legacy priority entries processed or canceled post-upgrade do not auto-unlock, leaving FORAGE locked under StakingQueue in ForageToken. The contract provides a designed, permissionless recovery path: retryForageUnlock(queueId). If the per-entry amount is zero, it requires the depositor’s _priorityRiskusdQueued to be zero (no remaining priority exposure), then looks up the true locker balance via ForageToken.lockerBalance and unlocks that amount to the depositor. Users can accelerate recovery by canceling outstanding priority entries to reach zero exposure, and a keeper can automate the final retry call. No theft or protocol DoS occurs; the impact is temporary unavailability of FORAGE until cleanup.

#### Severity

**Impact Explanation:** [Low] The effect is temporary unavailability of a user’s FORAGE due to migration semantics, with a clear, permissionless workaround (retryForageUnlock after priority exposure is zero) and the option to cancel outstanding entries to reach zero; no core protocol DoS or loss of principal occurs.

**Likelihood Explanation:** [Low] Requires a specific upgrade-time state (legacy priority entries with real locks) and can be mitigated operationally (draining queues, keeper automation). Depositors control the gating by cancelling outstanding priority entries.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A depositor has a pre‑V3 priority entry (with real FORAGE locked) at the time of upgrade. After the upgrade, the entry is processed or canceled. Because _forageLockedPerEntry[queueId] == 0 for this legacy entry, StakingQueue skips calling ForageToken.unlock(). The depositor’s FORAGE remains locked until all of their priority exposure is zero and someone calls retryForageUnlock(queueId), which then reads ForageToken.lockerBalance and unlocks the full residual amount to the depositor.
#### Preconditions / Assumptions
- (a). StakingQueue is upgraded to V3 while at least one legacy pre‑V3 priority entry exists for the depositor.
- (b). The legacy priority entry had FORAGE locked via ForageToken.lock with StakingQueue authorized as the locker.
- (c). _forageLockedPerEntry is zero for legacy entries by design (reinitializeV3 is a no-op).
- (d). _priorityRiskusdQueued was tracked pre‑V3 and remains consistent so V3 process/cancel arithmetic does not underflow.

### Scenario 2.
A depositor has a pre‑V3 priority entry at upgrade and continues submitting new priority entries post‑upgrade. The legacy entry is processed/canceled without auto-unlock, but _priorityRiskusdQueued remains > 0 due to ongoing usage. retryForageUnlock(queueId) reverts until the depositor finally clears/cancels all priority entries; then a single retryForageUnlock call unlocks the residual FORAGE.
#### Preconditions / Assumptions
- (a). All preconditions of Scenario 1.
- (b). Post‑upgrade, the depositor continues to create or maintain new priority entries such that _priorityRiskusdQueued remains > 0 for an extended period.

### 43. [Informational] Unsynchronized rolling daily cap windows in HLTradingBridge and CustodianRegistry cause temporary operator-level reverts of returns/deployments

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge and CustodianRegistry independently enforce rolling 1-day per-call and per-day caps for principal returns and deployments, but their day-start anchors are initialized at different times and reset independently. This can create an offset window where the bridge passes its cap check while the registry still treats the prior day as active, causing legitimate operator actions to revert until the registry's window rolls.

Both HLTradingBridge and CustodianRegistry maintain their own rolling daily cap windows for principal returns and deployments. In HLTradingBridge.initialize(), _returnUsedDayStart and _deployUsedDayStart are set to block.timestamp. In CustodianRegistry.finalizeCustodianConfig(), state.returnUsedDayStart and state.deployUsedDayStart are set to block.timestamp (if zero) at a later time. Each contract then resets its day window on the first action after expiry using block.timestamp >= start + 1 day. As a result, the two windows can become offset. In HLTradingBridge.returnPrincipalUSDC(), the bridge first enforces _enforceReturnCaps(), then calls CustodianRegistry.recordReturn() (or recordEmergencyReturn() when paused), which re-enforces caps via _enforceReturnCaps() on the registry side. If the bridge window has reset but the registry’s has not, the registry reverts (e.g., CustodianReturnPerDayCapExceeded), rolling back the entire transaction. An analogous pattern exists for deployments via deployToHyperLiquid() and CustodianRegistry.recordDeployment(). Rounding differences (bridge uses truncation; registry uses ceil in _bpsCap) do not remove the timing-offset issue. The effect is temporary operational friction for the trusted executor; no user funds are lost and no partial state is applied due to full revert semantics. The registry is the canonical policy gate, so these reverts reflect intended conservative, defense-in-depth enforcement rather than broken invariants.

#### Severity

**Impact Explanation:** [Low] This results in temporary operational unavailability for returns/deployments initiated by a trusted executor, with no user fund loss, no broken invariants, and full revert semantics. It does not halt user-facing core functions beyond the intended registry policy caps.

**Likelihood Explanation:** [Low] Reverts require specific timing (offset window) and near-cap usage on the registry side, and occur only when the trusted operator chooses to execute during that window. Operators can schedule around the registry’s canonical window or pre-check capacity.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Principal return dead zone: After HLTradingBridge’s daily return window resets (based on its earlier initialize time) but before CustodianRegistry’s daily return window resets (based on later finalizeCustodianConfig time), the executor calls returnPrincipalUSDC(amount). The bridge’s _enforceReturnCaps() passes, but CustodianRegistry.recordReturn() reverts on per-day cap since its window hasn’t reset, causing the entire transaction to revert until the registry window rolls.
#### Preconditions / Assumptions
- (a). HLTradingBridge.initialize() occurred at time T0; CustodianRegistry.finalizeCustodianConfig() for the custodian occurred later at time T1 > T0, creating an offset between daily windows.
- (b). The registry’s daily return usage is already near its per-day cap for the still-active day.
- (c). Sufficient reconciled return liquidity is available on the bridge for the attempted return.
- (d). The executor attempts returnPrincipalUSDC during the offset interval (after T0+1d but before T1+1d).
- (e). Executor and keeper roles are correctly set and trusted (as per scope).

### Scenario 2.
Deployment dead zone: After HLTradingBridge’s daily deploy window resets but before CustodianRegistry’s deploy window resets, the executor calls deployToHyperLiquid(amount). Bridge-side _enforceDeployCaps() passes, but CustodianRegistry.recordDeployment() reverts on per-day cap, blocking deployment until the registry window rolls.
#### Preconditions / Assumptions
- (a). HLTradingBridge._deployUsedDayStart and CustodianRegistry.state.deployUsedDayStart were anchored at different times (T0 and T1).
- (b). The registry’s per-day deploy usage is already near its per-day cap for the still-active day.
- (c). The executor attempts deployToHyperLiquid during the offset interval (after T0+1d but before T1+1d).
- (d). Executor role is correctly set and trusted (as per scope).

### Scenario 3.
Emergency principal return while registry paused: With registry paused, HLTradingBridge.returnPrincipalUSDC(amount) routes to CustodianRegistry.recordEmergencyReturn(). If the bridge’s daily return window has reset but the registry’s has not (and usage is near cap), the registry’s _enforceReturnCaps() still reverts, blocking the emergency return until the registry window rolls.
#### Preconditions / Assumptions
- (a). CustodianRegistry is paused; HLTradingBridge will call recordEmergencyReturn().
- (b). Bridge and registry daily return windows are offset (T0 initialize vs T1 finalize).
- (c). Registry’s per-day return usage is near cap for the still-active day.
- (d). The executor attempts returnPrincipalUSDC during the offset interval (after T0+1d but before T1+1d).
- (e). Executor and keeper roles are correctly set and trusted (as per scope).

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 203 unchanged lines ...
         _requireNotBlocked(msg.sender);
         _requireNotBlocked(coldAccount);
+        // SECURITY-TODO: Roll registry deploy window before local caps to avoid bridge/registry drift (call rollDeployWindow()).
         _enforceDeployCaps(usdcE6);
         _recordCustodianDeployment(usdcE6);
 ... 41 unchanged lines ...
         _requireNotBlocked(address(this));
         _requireNotBlocked(riskusdVault);
+        // SECURITY-TODO: Roll registry return window before local caps to avoid drift; align per-call/day rounding with Registry (ceil).
         _enforceReturnCaps(amount);

 ... 25 unchanged lines ...
         _requireNotBlocked(address(this));
         _requireNotBlocked(usdcTreasury);
+        // SECURITY-TODO: Roll registry return window before local caps to avoid drift; align rounding with Registry (ceil).
         _enforceReturnCaps(amount);

 ... 23 unchanged lines ...
             revert WithdrawalIntentChainMismatch(chainSelector, withdrawalChainSelector);
         }
+        // SECURITY-TODO: Roll registry return window before local intent caps to keep budgets aligned with canonical Registry window.
         _enforceWithdrawalIntentCaps(amount);

 ... 316 unchanged lines ...
     }

+    // SECURITY-TODO: Align per-call/day cap rounding with CustodianRegistry (ceil) and ensure window alignment via rollReturnWindow().
     function _enforceReturnCaps(uint256 amount) internal {
         uint256 principalBase = _deployedPrincipal;
 ... 61 unchanged lines ...
```

##### CustodianRegistry.sol

File: `openforage_smart_contracts/src/CustodianRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/CustodianRegistry.sol)

```diff
 ... 628 unchanged lines ...
     }

+    // SECURITY-TODO: Add role-gated rollReturnWindow/rollDeployWindow() so bridges can realign day windows before enforcing local caps.
     function _enforceReturnCaps(bytes32 id, CustodianState storage state, uint256 amount) internal {
         uint256 callCap = _bpsCap(state.deployed, state.returnPerCallBps);
 ... 38 unchanged lines ...
```

### 44. [Informational] O(n) compaction in StakingQueue.compactQueue causes gas grief and minor processing delays

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

The compactQueue function in StakingQueue performs O(n) compaction over the entire lane, which can become very gas-expensive or revert when lanes are large. Attackers can inflate lane size via repeated join/cancel actions, leading to wasted gas for compactors and requiring multiple bounded processQueue calls to advance the head over dead prefixes. Core processing remains permissionless and bounded; no funds are at risk.

In StakingQueue, compactQueue(tier, priority) iterates over the selected lane from head to end twice (counting active entries and then compacting them forward) and pops trailing slots, resetting the head to 0. This is an O(n) operation over the lane length and is permissionless maintenance with no token transfers. On very large lanes, compactQueue can exceed gas limits and revert, wasting the caller’s gas. Meanwhile, processQueue(tier, maxEntries) is engineered to avoid unbounded iteration: _processLane caps both processedCount and scanned by budget (maxEntries), and _advanceHead skips processed/cancelled/blocked entries with its own scan cap (also maxEntries). Therefore, queue processing remains available and bounded regardless of lane size. An attacker can inflate lane size cheaply by repeatedly calling joinQueue (appending an entry) and immediately cancelQueue (recovering their RISKUSD), leaving many cancelled (dead) entries. Alternatively, they can spam active entries. This makes compactQueue impractical or costly and increases the number of processQueue calls required to advance the head over a large dead prefix. Impact is limited to wasted gas for compactQueue callers and minor, recoverable delays for depositors behind a dead prefix until enough bounded processQueue calls advance the head, or depositors cancel to retrieve funds. No funds are lost or frozen, and core functionality remains permissionless and usable.

#### Severity

**Impact Explanation:** [Low] No funds are lost or frozen; compactQueue is optional maintenance. The primary impact is wasted gas for compactQueue callers and minor, recoverable delays for depositors until bounded processQueue calls advance the head or users cancel to exit.

**Likelihood Explanation:** [Low] Exploitation requires repeated, unprofitable spam (griefing) to inflate lanes, involving many transactions over time with no clear attacker profit; effects are bounded and recoverable.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Join+cancel spam inflates a lane with many cancelled entries, causing compactQueue to revert or become uneconomical; advancing past the dead prefix then requires multiple bounded processQueue calls, delaying deposits behind it until someone spends the gas to progress the head.
#### Preconditions / Assumptions
- (a). Vault/tier is active and StakingQueue is unpaused
- (b). Attacker has a small positive amount of RISKUSD
- (c). Attacker repeatedly calls joinQueue then cancelQueue to create many cancelled entries
- (d). A third party attempts compactQueue or relies on processQueue to advance head

### Scenario 2.
Attacker (or organic load) leaves many entries active; compactQueue must rewrite most entries and pops few, becoming very gas-heavy with little size reduction, wasting gas for the caller while processQueue continues to function normally.
#### Preconditions / Assumptions
- (a). Vault/tier is active and StakingQueue is unpaused
- (b). Lane contains many active (not processed/cancelled) entries, attacker-driven or organic
- (c). A third party attempts compactQueue expecting size reduction

### Scenario 3.
An operator’s cron periodically calls compactQueue; the attacker times repeated lane bloat so compactQueue attempts frequently revert or are too costly, wasting operator gas. Processing still proceeds via processQueue, but head advancement over large prefixes requires multiple bounded calls.
#### Preconditions / Assumptions
- (a). An operator/keeper runs a cron that periodically calls compactQueue
- (b). Attacker can inflate lane size through repeated join/cancel spam and time it with cron runs
- (c). StakingQueue remains operational; processQueue is available

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 102 unchanged lines ...
     error DepositOutputBelowMinimum(uint256 sharesMinted, uint256 minimumShares);
     error InvalidForagePriceScale(uint256 price);
+    error CompactionDisabled();

     // -- Precomputed function selectors --
 ... 851 unchanged lines ...
     /// Anyone can call to prevent priority lane DoS via systematic join+cancel.
     function compactQueue(uint8 tier, bool priority) external {
+        revert CompactionDisabled();
         if (tier >= 4) revert InvalidTier();

 ... 571 unchanged lines ...
```

### 45. [Informational] Residual-asset revert in VaultRegistry.releaseTierVaults causes governance housekeeping DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

If any tier vault has zero share supply but non‑zero assets, VaultRegistry._tierVaultIsReleasable() reverts, which aborts releaseTierVaults() and prevents releasing even clean tier addresses. A normal last‑withdrawer can create this residual state due to atRISKUSD’s cooldown snapshot semantics combined with yield accrual.

VaultRegistry.releaseTierVaults(vaultId) iterates tier vault addresses and calls _tierVaultIsReleasable() for each. The helper checks totalSupply() and totalAssets(); if totalSupply()==0 but totalAssets()>0 it reverts with ResidualTierVaultAssets. Because releaseTierVaults does not catch this, the entire call aborts and no tier addresses are released in that transaction. In atRISKUSD, executeWithdrawal during cooldown pays out min(currentValue, snapshotRiskusdAmount) and decreases _legitimateAssets only by the transfer amount. If yield accrues between request and execution, a last‑withdrawer can burn all shares (totalSupply becomes 0) while leaving the excess yield in _legitimateAssets (totalAssets>0). This legitimate state (no misconfiguration or privileged malice) triggers the ResidualTierVaultAssets revert, causing a governance-facing denial of service on this housekeeping function. No funds are at risk and normal user operations are unaffected; operators can remediate by sweeping residual assets (e.g., yieldSource.absorbLoss) before retrying.

#### Severity

**Impact Explanation:** [Low] This is a governance-only housekeeping DoS with a straightforward operator workaround (sweep residual assets). No user funds or core user operations are affected.

**Likelihood Explanation:** [Low] Requires WindingDown state, last-holder condition, and timing against a yield accrual during cooldown; attacker has no direct profit, making it a griefing scenario with uncommon preconditions.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
A user becomes the last holder in a tier during WindingDown, requests a full cooldown withdrawal, waits for a normal yield accrual during cooldown, then executes withdrawal. Due to atRISKUSD’s snapshot payout, all shares are burned but some assets remain (_legitimateAssets>0). VaultRegistry.releaseTierVaults then reverts with ResidualTierVaultAssets for that tier, aborting the entire call and preventing release of even the clean tier addresses in the same transaction.
#### Preconditions / Assumptions
- (a). The vault has transitioned to WindingDown (required by releaseTierVaults).
- (b). Tier vault is an atRISKUSD instance with a non-zero cooldownPeriod configured.
- (c). StakingQueue blocks new deposits into WindingDown vaults (so supply can wind down).
- (d). The attacker can become the last remaining holder in the targeted tier.
- (e). A normal yield accrual occurs between withdrawal request and execution (yieldSource remains active and accrues during the cooldown window).
- (f). Weekly withdrawal caps/time windows may stretch timing but do not prevent the sequence.

#### Proposed fix

##### VaultRegistry.sol

File: `openforage_smart_contracts/src/VaultRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/VaultRegistry.sol)

```diff
 ... 555 unchanged lines ...
         }
         try ITierVaultAccountingQuery(tierVault).totalAssets() returns (uint256 assets) {
-            if (assets != 0) revert ResidualTierVaultAssets(tierVault, assets);
-        } catch (bytes memory reason) {
-            if (reason.length != 0) {
-                assembly {
-                    revert(add(reason, 32), mload(reason))
-                }
-            }
+            if (assets != 0) return false;
+        } catch (bytes memory) {
             return false;
         }
         return true;
     }

     // ── Ownership ──
     function renounceOwnership() public pure override {
         revert RenounceOwnershipDisabled();
     }

     // ── UUPS ──
     function _authorizeUpgrade(address) internal override onlyOwner {
         // OF-15-004: Clear pending RISKUSDVault proposal on upgrade to prevent stale proposals
         _pendingRISKUSDVault = address(0);
         _pendingRISKUSDVaultTimestamp = 0;
     }
 }
```

### 46. [Informational] First-come-first-served per-block mint cap in RISKUSDVault causes ordering-dependent deposit reverts within a block

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

RISKUSDVault enforces a global per-block mint cap via a shared counter. Any earlier deposit in the same block reduces remaining capacity, so later near-cap deposits may revert solely due to transaction ordering. This results in transient UX/availability friction without funds loss.

In RISKUSDVault.deposit, public deposits (everyone except the lossReporter) are throttled by a global per-block mint cap enforced first via _enforcePerBlockMintCap before any token transfers. The cap is computed each call as min(totalSupply * perBlockMintCapBps / 10000, perBlockMintCapMax), and a single shared counter _mintUsedThisBlock is incremented for successful deposits within the current block. If a later depositor’s requested amount exceeds the remaining per-block capacity (cap - _mintUsedThisBlock), the call reverts with PerBlockMintCapExceeded. Because the counter is global and first-come-first-served, any earlier depositor in the same block can reduce remaining capacity and cause near-cap deposits to fail purely due to ordering. Effects are transient—users can retry next block or size down using the revert’s ‘remaining’ hint. No funds or core invariants are at risk; this is an intentional throttle design that can be leveraged for minor, intrablock DoS-style griefing.

#### Severity

**Impact Explanation:** [Informational] Effects are transient UX/availability friction: ordering-dependent reverts for near-cap deposits within a single block, easily addressed by retrying or reducing size. No funds or invariants are at risk.

**Likelihood Explanation:** [Low] Exploitation is griefing-driven with no direct profit. It requires timing (pre-seeding or landing earlier) and, for full-block denial, notable capital with impractical sustained repetition due to redemption constraints.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Scenario 1: A small pre-seed deposit causes a whale’s near-cap deposit to revert. An attacker sends a tiny deposit (e.g., 1 USDC) slightly before a whale’s transaction in the same block. The shared per-block counter increments by 1, reducing remaining capacity. The whale’s attempt to deposit exactly the per-block cap now exceeds the remaining and reverts (PerBlockMintCapExceeded). The attacker later redeems the tiny amount, incurring only gas and a minimal capital float.
#### Preconditions / Assumptions
- (a). Vault is not paused and no loss-pending state blocks deposits (normal operation).
- (b). Per-block mint cap parameters are nonzero (defaults apply).
- (c). Attacker is not on the Blocklist.
- (d). Sequencer ordering on Arbitrum allows attacker to land earlier or pre-seed the block.
- (e). Victim attempts a deposit near the per-block remaining capacity.
- (f). Attacker has a tiny amount of USDC to pre-seed and can later redeem.

### Scenario 2.
Scenario 2: Continuous small pre-seeding degrades near-cap deposits. An attacker repeatedly pre-seeds blocks with tiny deposits so remaining capacity is always slightly below the nominal cap. Any user attempting to deposit near the cap intermittently reverts and must retry or reduce size. The attacker periodically redeems prior pre-seeds; impact remains repeated minor UX friction for near-cap depositors.
#### Preconditions / Assumptions
- (a). Vault is not paused and no loss-pending state blocks deposits (normal operation).
- (b). Per-block mint cap parameters are nonzero (defaults apply).
- (c). Attacker is not on the Blocklist.
- (d). Attacker can routinely land a small deposit early in many blocks (pre-seeding).
- (e). Victims occasionally attempt near-cap deposits.
- (f). Attacker can periodically redeem small pre-seed amounts.

### Scenario 3.
Scenario 3: One-off full-block saturation denies all deposits for that block. An attacker with notable capital deposits up to the entire per-block capacity at the start of a target block, driving remaining capacity to zero. All subsequent deposits in that block revert. Users can retry in the next block; sustaining this across many blocks is impractical due to capital and redemption constraints.
#### Preconditions / Assumptions
- (a). Vault is not paused and no loss-pending state blocks deposits (normal operation).
- (b). Per-block mint cap parameters are nonzero (defaults apply).
- (c). Attacker is not on the Blocklist.
- (d). Attacker has notable capital (up to the per-block cap) to consume full capacity in one block.
- (e). Victims attempt to deposit in the same block and face zero remaining capacity.
- (f). Attacker is willing to unwind the position over time subject to redemption/liq constraints.

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 317 unchanged lines ...
     // --- Deposit / Redeem ---

+    // MITIGATION NOTE:
+    // To eliminate ordering-dependent reverts for near-cap deposits while preserving throttles,
+    // add a new depositUpTo(uint256 maxUsdc) that computes allowed fill as
+    // min(per-block, daily, weekly remaining, maxUsdc) and mints that amount instead of reverting.
+    // Keep this deposit(uint256) strict for backwards compatibility; expose view helpers to pre-size.
+
     /// @notice OF-16-027: USDC is assumed to have no fee-on-transfer. Deposit mints RISKUSD
     /// 1:1 based on the requested amount, not measured receipt. If USDC ever adds transfer fees,
 ... 1190 unchanged lines ...
     }

+    // MITIGATION NOTE:
+    // Refactor this routine into (a) view: perBlockMintRemaining() with block rollover semantics,
+    // and (b) stateful: _consumePerBlockMint(amount). depositUpTo should min() across all caps, then consume.
+
     function _enforcePerBlockMintCap(uint256 riskusdAmount) internal {
         if (block.number != _mintUsedBlockNumber) {
 ... 270 unchanged lines ...
```

### 47. [Informational] Stale NAV baseline and zero-NAV prohibition in CustodianRegistry recordNAV/_enforceNAVDeltaCap cause registry NAV updates to revert or remain stale

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

CustodianRegistry updates deployed exposure on deployments/returns but does not adjust lastNAV; recordNAV enforces a delta cap against the stale lastNAV and forbids nav==0. After allowed returns or full exit, honest NAV posts can revert, leaving registry NAV stale. No in-scope contract consumes this value, so impact is operational/observability only.

In CustodianRegistry, recordDeployment/recordReturn (via _applyReturnAccounting) update state.deployed and the global _totalDeployed but do not touch state.lastNAV. recordNAV requires nav != 0 and calls _enforceNAVDeltaCap, which compares the new nav to the previous state.lastNAV using a fixed-percentage cap (navDeltaCapBps). _validateConfig forbids navDeltaCapBps == 0, so the cap cannot be disabled. The provided lighterReadyFixture config sets navDeltaCapBps = 1000 (±10%) while allowing returnPerCallBps = 2500 (25%) and returnPerDayBps = 5000 (50%), creating a mismatch where otherwise-permitted returns can push the honest NAV change beyond the cap and make recordNAV revert. Additionally, recordNAV(0) reverts (ZeroAmount), preventing a clean baseline reset after a full exit.

In this repository’s wiring, HLTradingBridge uses CustodianRegistry only to record deployments/returns and posts NAV directly to RISKUSDVault via recordCustodianNAV; no in-scope contract reads CustodianRegistry.lastNAV. Therefore, failed registry NAV updates cause stale registry-level NAV but do not affect on-chain solvency or fund flows. The issue is a real liveness/observability defect limited to the registry’s NAV fields.

#### Severity

**Impact Explanation:** [Informational] The effect is limited to read-only registry NAV fields (lastNAV/lastNAVTimestamp) remaining stale or hard to update; no in-scope contract relies on these values for critical logic, and HLTradingBridge posts NAV directly to RISKUSDVault.

**Likelihood Explanation:** [Low] Scenarios depend on trusted operator actions: enabling a reachable NAV_ATTESTER, having a prior lastNAV, performing allowed returns that exceed the delta cap, and attempting to post NAV to the registry (distinct from the HL bridge’s posting to RISKUSDVault). These are plausible but operator-driven.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
After a 25% allowed principal return (per returnPerCallBps), the honest next registry NAV post reflecting a 25% drop reverts because navDeltaCapBps is set to ±10%; CustodianRegistry.lastNAV/lastNAVTimestamp remain stale while deployed has decreased.
#### Preconditions / Assumptions
- (a). Custodian configured with navDeltaCapBps tighter than allowed return caps (e.g., ±10% vs 25–50%)
- (b). A prior registry lastNAV has been posted (lastNAV > 0)
- (c). Governance has assigned a reachable ROLE_NAV_ATTESTER (intended two-step role flow)
- (d). Executor performs an allowed return exceeding the NAV delta cap threshold
- (e). Operator attempts to post the honest new NAV to CustodianRegistry via recordNAV

### Scenario 2.
Following a full exit that drives state.deployed to 0 via allowed returns, attempting to reset registry NAV to 0 reverts (ZeroAmount), and posting a small positive NAV likely also reverts due to exceeding the delta cap from the previous large lastNAV; registry NAV cannot be cleanly reset.
#### Preconditions / Assumptions
- (a). A prior registry lastNAV has been posted (lastNAV > 0)
- (b). Governance has assigned a reachable ROLE_NAV_ATTESTER
- (c). Executor fully exits position so state.deployed == 0 via allowed returns
- (d). Operator attempts recordNAV with nav == 0 or a small positive value

### Scenario 3.
Multiple successive allowed returns (e.g., 25% of deployed twice) compound a larger drop than the ±10% delta cap permits; an honest single-step registry NAV post reverts unless operators manually step NAV in several small increments, leaving registry NAV stale meanwhile.
#### Preconditions / Assumptions
- (a). Custodian configured with navDeltaCapBps tighter than cumulative allowed returns
- (b). A prior registry lastNAV has been posted (lastNAV > 0)
- (c). Governance has assigned a reachable ROLE_NAV_ATTESTER
- (d). Executor performs multiple successive allowed returns exceeding ±navDeltaCapBps in aggregate
- (e). Operator attempts to post the honest single-step new NAV to CustodianRegistry

#### Proposed fix

##### CustodianRegistry.sol

File: `openforage_smart_contracts/src/CustodianRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/CustodianRegistry.sol)

```diff
 ... 81 unchanged lines ...
         uint256 returnUsedThisDay;
         uint256 returnUsedDayStart;
+        uint256 lastDeployedAtNAV;
     }

 ... 276 unchanged lines ...
         CustodianState storage state = _requireCustodian(id);
         if (state.paused) revert CustodianPaused(id);
-        if (nav == 0) revert ZeroAmount();
-        _enforceNAVDeltaCap(id, state, nav);
+        if (nav == 0) {
+            if (state.deployed != 0) revert ZeroAmount();
+        } else {
+            bool flowsSinceLast = (state.lastDeployedAtNAV != state.deployed);
+            if (!flowsSinceLast) {
+                _enforceNAVDeltaCap(id, state, nav);
+            }
+        }
         state.lastNAV = nav;
         state.lastNAVTimestamp = block.timestamp;
+        state.lastDeployedAtNAV = state.deployed;
         emit CustodianNAVRecorded(id, nav, block.timestamp);
     }
 ... 301 unchanged lines ...
```

### 48. [Informational] Static guardianModule binding in HLTradingBridge causes loss of guardian emergency controls after module rotation

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

HLTradingBridge stores a fixed guardianModule address at initialization and never updates or resolves it dynamically. After governance rotates the GuardianModule, guardian-originated emergency actions on the bridge revert because the new module is not recognized and the old module self-disables. Only the owner/timelock can act, creating an operational delay rather than fund loss.

HLTradingBridge authorizes its emergency controls (pause, directional freeze, freeze attestations, and cap tightenings) by checking msg.sender against a guardianModule address set once during initialize(). There is no setter or dynamic governor-based resolution. Elsewhere in the system, the GuardianModule enforces that only the current module (as per ForageGovernor.guardianModule()) can forward emergency calls; once rotated, the old module self-disables its outward emergency functions. Consequently, after a legitimate GuardianModule rotation, HLTradingBridge rejects calls from the new module while the old module cannot call at all. The owner/timelock can still perform the same actions, but typically with a governance delay. Other protocol contracts (e.g., RISKUSD and RISKUSDVault) resolve the guardian dynamically, indicating the intended design supports rotation; the bridge’s static binding is inconsistent with that pattern. The result is an operational unavailability of guardian emergency controls on HLTradingBridge until the owner/timelock intervenes or the bridge is upgraded/rewired.

#### Severity

**Impact Explanation:** [Low] This is an authorization/logic mismatch affecting a privileged, emergency-only path. No direct user fund loss or invariant break occurs, and an owner/timelock fallback exists. Moreover, alternative mitigations (e.g., pausing RISKUSDVault or tightening vault caps) remain available to guardians.

**Likelihood Explanation:** [Low] Multiple preconditions must coincide: a guardian-module rotation, a subsequent emergency specifically requiring HLTradingBridge-local action during the mismatch window, and no coordinated bridge upgrade. Guardians can often mitigate at the vault level, further reducing the chance that bridge-local controls are immediately required.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
After ForageGovernor rotates the GuardianModule (GM1 → GM2), guardians attempt to pause HLTradingBridge via GM2. HLTradingBridge rejects GM2 (stored GM1 mismatch) and GM1 self-disables because it is no longer current. Only the owner/timelock can pause, introducing delay.
#### Preconditions / Assumptions
- (a). HLTradingBridge stored guardianModule = GM1 during initialization and provides no rotation setter or dynamic resolution.
- (b). Governance rotates ForageGovernor.guardianModule to GM2 via the intended governance flow.
- (c). HLTradingBridge owner is a production timelock with a non-trivial delay (not an instant multisig).
- (d). Guardians operate through the GuardianModule for bridge emergency controls (design intent).
- (e). No coordinated HLTradingBridge upgrade or local guardian-module update is executed alongside the rotation.

### Scenario 2.
Following GuardianModule rotation, guardians attempt to tighten HLTradingBridge deploy/return caps via GM2’s emergency execution. HLTradingBridge rejects GM2 due to the stored GM1, while GM1 cannot relay. Cap changes require owner/timelock actions, delaying response.
#### Preconditions / Assumptions
- (a). HLTradingBridge stored guardianModule = GM1 during initialization and provides no rotation setter or dynamic resolution.
- (b). Governance rotates ForageGovernor.guardianModule to GM2 via the intended governance flow.
- (c). HLTradingBridge owner is a production timelock with a non-trivial delay (not an instant multisig).
- (d). Guardians operate through the GuardianModule for bridge emergency controls (design intent).
- (e). No coordinated HLTradingBridge upgrade or local guardian-module update is executed alongside the rotation.

### Scenario 3.
After GuardianModule rotation, guardians try to set directional freeze or freeze attestations on HLTradingBridge. Calls via GM2 are rejected; GM1 cannot forward. Only owner/timelock can execute these actions, causing an operational delay.
#### Preconditions / Assumptions
- (a). HLTradingBridge stored guardianModule = GM1 during initialization and provides no rotation setter or dynamic resolution.
- (b). Governance rotates ForageGovernor.guardianModule to GM2 via the intended governance flow.
- (c). HLTradingBridge owner is a production timelock with a non-trivial delay (not an instant multisig).
- (d). Guardians operate through the GuardianModule for bridge emergency controls (design intent).
- (e). No coordinated HLTradingBridge upgrade or local guardian-module update is executed alongside the rotation.

#### Proposed fix

##### HLTradingBridge.sol

File: `openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol)

```diff
 ... 346 unchanged lines ...
     function setDirectionalFreeze(bool frozen) external {
         _requireGuardianModuleOrOwner();
-        if (msg.sender == guardianModule && !frozen) revert GuardianCannotLoosen();
+        if (msg.sender != owner() && !frozen) revert GuardianCannotLoosen();
         _setDirectionalFreeze(frozen);
     }

     function freezeAttestations() external {
         _requireGuardianModuleOrOwner();
         _setDirectionalFreeze(true);
     }

     function pause() external {
-        if (msg.sender != guardianModule && msg.sender != owner()) revert UnauthorizedPause();
+        _requireGuardianModuleOrOwner();
         _pause();
     }
 ... 106 unchanged lines ...

     function _requireGuardianModuleOrOwner() internal view {
-        if (msg.sender != guardianModule && msg.sender != owner()) revert UnauthorizedPause();
+        if (msg.sender == owner()) return;
+        (bool ok, bytes memory d) = riskusdVault.staticcall(abi.encodeWithSignature("forageGovernor()"));
+        if (ok && d.length >= 32) {
+            address gov = abi.decode(d, (address));
+            (ok, d) = gov.staticcall(abi.encodeWithSignature("guardianModule()"));
+            if (ok && d.length >= 32 && abi.decode(d, (address)) == msg.sender) return;
+        }
+        revert UnauthorizedPause();
     }

 ... 217 unchanged lines ...
```

## Warnings

### 1. [Medium] One-shot oracle-priced priority in StakingQueue.joinQueue without revalidation enables capacity preemption

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

StakingQueue assigns a permanent priority flag to queue entries based on a single spot FORAGE/USD price read. By manipulating the oracle price and calibrating the deposit so the required FORAGE lock equals the 0.001 FORAGE minimum, an attacker can obtain priority at negligible lock cost. Priority is not revalidated at processing, allowing the attacker to be processed ahead of standard-lane users and preempt limited capacity.

StakingQueue.joinQueue() determines priority using a single spot FORAGE/USD price via _tryActiveForagePriceUsd() and the formula forageToLock = ceil((riskusdAmount * 1e18) / (price * multiplier)). If the computed lock is below 0.001 FORAGE (1e15), the contract refuses priority; otherwise it attempts ForageToken.lock(account, forageToLock) and marks the QueueEntry as priority = true. There is no TWAP/deviation bound on the read and no revalidation later: processQueue() always serves the priority lane first and never re-checks price or lock sufficiency. An attacker who can manipulate the oracle can choose a fresh price P and deposit D so that D/(P*multiplier) ≈ 0.001 FORAGE, meeting the minimum lock and obtaining a permanent priority flag at negligible lock cost. The attacker can then immediately call processQueue to be processed ahead of standard-lane users, preempting limited tier/combined capacity. This causes significant, temporary availability degradation (delays and missed windows) for standard-lane users, without direct principal loss. Preconditions include ORACLE price mode enabled, priorityMultiplier > 0, StakingQueue authorized as a ForageToken locker, capacity available, and the attacker able to publish a fresh, positive manipulated oracle price within contract bounds and staleness limits.

#### Severity

**Impact Explanation:** [Medium] Priority entries are processed ahead of standard-lane users, enabling capacity preemption and causing significant but temporary availability degradation (delays/missed windows) for deposits. No direct principal loss or permanent freeze.

**Likelihood Explanation:** [Low] Exploitation requires the oracle integration to produce a manipulated/compromised fresh price within contract bounds. This integration-break precondition classifies as low likelihood under the rules, despite being considered an in-scope vector.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Calibrated large deposit at minimal lock: The attacker selects a large RISKUSD deposit D and manipulates the oracle to a fresh price P such that D/(P*multiplier) ≈ 0.001 FORAGE. They call joinQueue to get priority = true with a ~0.001 FORAGE lock, then immediately call processQueue to be processed before standard-lane users, consuming available capacity first.
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode
- (b). priorityMultiplier > 0
- (c). StakingQueue is authorized as a ForageToken locker so lock() succeeds
- (d). Attacker can manipulate/publish a fresh positive oracle price within contract sanity checks and max staleness
- (e). Normalized oracle price ≤ MAX (1,000,000 USD with 6 decimals)
- (f). Targeted tier and combined capacities are available
- (g). Attacker holds the chosen deposit D in RISKUSD and at least 0.001 FORAGE unlocked
- (h). Attacker can promptly call processQueue after joining

### Scenario 2.
Ephemeral manipulated spike then immediate processing: The attacker briefly pushes the oracle price to a level that makes their chosen deposit meet the 0.001 FORAGE lock threshold, calls joinQueue to obtain priority, and immediately invokes processQueue. Even if the oracle normalizes shortly after, the stored priority flag is not revalidated, so the attacker is still processed first.
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode
- (b). priorityMultiplier > 0
- (c). StakingQueue is authorized as a ForageToken locker so lock() succeeds
- (d). Attacker can briefly manipulate/publish a fresh positive oracle price within contract sanity checks and max staleness
- (e). Normalized oracle price ≤ MAX (1,000,000 USD with 6 decimals)
- (f). Targeted tier and combined capacities are available
- (g). Attacker holds the chosen deposit D in RISKUSD and at least 0.001 FORAGE unlocked
- (h). Attacker can promptly call processQueue during or immediately after the fresh-price window

### Scenario 3.
Multi-tier capacity drain with calibrated entries: The attacker sets a manipulated price and submits multiple priority entries across tiers (each calibrated so D_i/(P*multiplier) ≥ 0.001 FORAGE and near the minimum), then calls processQueue on those tiers to drain combined/per-tier capacity ahead of standard-lane users across the targeted tiers.
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode
- (b). priorityMultiplier > 0
- (c). StakingQueue is authorized as a ForageToken locker so lock() succeeds
- (d). Attacker can manipulate/publish a fresh positive oracle price within contract sanity checks and max staleness
- (e). Normalized oracle price ≤ MAX (1,000,000 USD with 6 decimals)
- (f). Multiple targeted tiers and combined capacities are available consistent with per-tier caps
- (g). Attacker holds the total chosen deposits ΣD_i in RISKUSD and sufficient FORAGE (≥ number_of_entries * 0.001)
- (h). Attacker can call processQueue for each targeted tier

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 343 unchanged lines ...
                 if (priceReady && price > 0) {
                     uint256 forageToLock = Math.ceilDiv(riskusdAmount * 1e18, price * mult);
+                    // SECURITY-TODO: Record priorityAssignedAt = block.timestamp (or reuse entryTimestamp)
+                    // and enforce a configurable minPriorityAge before priority processing.
+                    // SECURITY-TODO: Priority granted here must be revalidated at processing time
+                    // against a robust price (TWAP/deviation-bounded). If insufficient, demote and unlock.
                     // OF-L10-M02: Skip priority if computed lock amount is trivially small (< 0.001 FORAGE)
                     // OF-16-012: Skip if _forage has no code (EOA/self-destructed) — prevents false priority
 ... 129 unchanged lines ...
                 continue;
             }
+            // SECURITY-TODO: If isPriorityLane, re-check that _forageLockedPerEntry[qId] >=
+            // ceilDiv(entry.riskusdAmount * 1e18, robustPrice * _priorityMultiplier).
+            // If not, demote entry to the standard lane, attempt to unlock its FORAGE (best-effort), and continue.
+            // Implement robust price (_robustPriorityPriceUsd) with TWAP/deviation bounds and consider minPriorityAge.

             _depositQueuedRiskusd(tier, entry.riskusdAmount, entry.depositor);

             entry.processed = true;
             if (isPriorityLane) {
                 _priorityRiskusdQueued[entry.depositor] -= entry.riskusdAmount;
                 uint256 qId = lane[i];
                 uint256 forageToUnlock = _forageLockedPerEntry[qId];
                 if (forageToUnlock > 0) {
                     // OF-007 (11th audit): Only zero entry on success to allow retry
                     (bool unlockSuccess,) =
+                        // SECURITY-TODO: Also attempt unlock when demoting a priority entry (not only after processing).
                         _forage.call(abi.encodeWithSelector(_SEL_UNLOCK, entry.depositor, forageToUnlock));
                     if (unlockSuccess) {
 ... 1041 unchanged lines ...
```

### 2. [Medium] Overflow in oracle price normalization (decimals < 6) in StakingQueue ORACLE mode causes deposit DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When StakingQueue uses an AggregatorV3 oracle with <6 decimals, a very large positive oracle answer can overflow during normalization outside the try/catch, hard-reverting _tryActiveForagePriceUsd(). Because joinQueue() calls this when _priorityMultiplier > 0, deposits revert (DoS). effectiveForagePriceUsd() and priorityCapFor() views also revert.

In StakingQueue._tryActiveForagePriceUsd(), the contract calls oracle.latestRoundData() inside a try/catch and then normalizes the returned answer by casting it to uint256 and calling _normalizeOraclePrice(). If the configured oracle has decimals < 6, normalization multiplies by 10^(6 - decimals). Solidity 0.8.x arithmetic reverts on overflow, and this multiplication occurs after the try/catch, so any overflow hard-reverts the entire function rather than being caught and mapped to InvalidOraclePrice. joinQueue() calls _tryActiveForagePriceUsd() whenever _priorityMultiplier > 0 to compute FORAGE locking for the priority lane; thus, an overflow makes joinQueue revert, causing a complete DoS of user deposits while the bad oracle round persists. effectiveForagePriceUsd() and priorityCapFor() also revert under the same condition. The code allows oracle decimals < 6 (only rejects > 18), so this configuration is permitted. Preconditions for exploitation: ORACLE mode active, _priorityMultiplier > 0 (for the deposit path), a <6-decimal oracle, and a manipulated/malfunctioning oracle answer that is large enough to overflow and still passes basic latestRoundData checks (answer > 0, fresh updatedAt, answeredInRound >= roundId, within staleness).

#### Severity

**Impact Explanation:** [High] Deposits via StakingQueue are the only allowed user deposit path into atRISKUSD; when overflow is triggered, joinQueue() reverts for all users, making core deposit functionality completely unusable while the bad oracle round persists.

**Likelihood Explanation:** [Low] Exploitation requires an external integration (oracle) to behave incorrectly or be compromised and also rely on a less common but permitted configuration (decimals < 6) while ORACLE mode is active (and _priorityMultiplier > 0 for deposit DoS).

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
An attacker compromises the AggregatorV3 oracle used by StakingQueue in ORACLE mode and, with a configured <6-decimal feed and _priorityMultiplier > 0, publishes a very large positive answer that passes basic feed checks. _normalizeOraclePrice() overflows during scaling, causing joinQueue() to revert for all users, fully blocking deposits until operators mitigate.
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode (finalized).
- (b). _priorityMultiplier > 0.
- (c). Configured AggregatorV3-compatible oracle has decimals < 6.
- (d). Oracle publishes a very large positive answer that passes latestRoundData basic checks (answer > 0, answeredInRound >= roundId, updatedAt fresh and within _oraclePriceMaxStaleness).

### Scenario 2.
Due to an oracle implementation bug (not malicious), a <6-decimal AggregatorV3 oracle intermittently returns an abnormally large positive value with fresh metadata. In ORACLE mode with _priorityMultiplier > 0, normalization overflows and joinQueue() reverts, temporarily blocking deposits during the bad round(s).
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode (finalized).
- (b). _priorityMultiplier > 0.
- (c). Configured AggregatorV3-compatible oracle has decimals < 6.
- (d). Oracle malfunctions and returns an abnormally large positive answer that still passes basic latestRoundData checks (fresh and valid metadata).

### Scenario 3.
With ORACLE mode active and a <6-decimal oracle returning an extremely large positive answer, calls to effectiveForagePriceUsd() and priorityCapFor() overflow during normalization and revert, breaking off-chain price reads and priority capacity queries even if _priorityMultiplier == 0.
#### Preconditions / Assumptions
- (a). StakingQueue is in ORACLE price mode (finalized).
- (b). Configured AggregatorV3-compatible oracle has decimals < 6.
- (c). Oracle returns a very large positive answer that passes basic latestRoundData checks (fresh and valid metadata).
- (d). _priorityMultiplier value is irrelevant for this view-only path.

#### Proposed fix

##### StakingQueue.sol

File: `openforage_smart_contracts/src/StakingQueue.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/StakingQueue.sol)

```diff
 ... 1351 unchanged lines ...
         if (decimals_ == 6) return price;
         if (decimals_ > 6) return price / (10 ** (decimals_ - 6));
-        return price * (10 ** (6 - decimals_));
+        uint256 scale = 10 ** (6 - decimals_);
+        if (price > type(uint256).max / scale) return 0;
+        return price * scale;
     }

 ... 176 unchanged lines ...
```

### 3. [Low] Storage layout shift in RISKUSD UUPS upgrade can disable or brick blocklist enforcement

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

A new EnumerableSet field was inserted immediately before _blocklist in a live RISKUSD UUPS proxy, risking a storage slot shift for _blocklist on upgrade. If the prior implementation already had _blocklist, the upgrade can either zero it (disabling checks) or point it to a non-contract (bricking token operations) until the owner resets it.

RISKUSD (a UUPS proxy) introduced new state variables, including EnumerableSet.AddressSet _exemptAddressSet, declared immediately before address _blocklist. In UUPS, upgrading to this implementation preserves storage but does not automatically migrate or validate affected fields. If the previously deployed implementation already had _blocklist, adding a two-slot EnumerableSet before it shifts its storage slot. As a result, post-upgrade _blocklist can read as address(0) (from a zero-initialized gap) or as a stale non-contract address. With _blocklist == address(0), all _requireNotBlocked checks short-circuit, silently disabling blocklist enforcement and allowing previously blocked EOAs to transfer/approve/transferFrom. If _blocklist points to a non-contract EOA, calls to IBlocklist.isBlocked revert due to empty returndata decoding, bricking all token operations (transfer, approve with nonzero value, mint, burn) and downstream uses (e.g., StakingQueue flows) until the owner calls setBlocklist() to correct the pointer. The new implementation’s _authorizeUpgrade does not auto-migrate blocklist on the upgrade into it (UUPS nuance). While owners can mitigate this by using upgradeToAndCall to setBlocklist atomically, the implementation remains upgrade-unsafe if prior layout included _blocklist and the atomic migration is not performed.

#### Severity

**Impact Explanation:** [Medium] The DoS scenario makes core token functionality (transfers, approvals with nonzero value, minter mint/burn) temporarily unusable across the protocol until the owner resets the blocklist address. This is a significant but temporary availability loss of core functionality, mapping to Medium impact under the rules.

**Likelihood Explanation:** [Low] The scenarios require specific preconditions: the prior implementation must have had _blocklist, and the upgrade must be performed without an atomic migration call (upgradeToAndCall). The DoS variant further requires the new slot to hold a non-contract address, a rarer state. Under trusted, diligent admin assumptions, these conditions are considered low likelihood.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Silent blocklist disablement: After upgrading RISKUSD to the new implementation, _blocklist reads from a zeroed gap slot and becomes address(0). All _requireNotBlocked checks become no-ops, allowing previously blocked addresses to transfer/approve/transferFrom RISKUSD until the owner calls setBlocklist to restore the correct contract.
#### Preconditions / Assumptions
- (a). The prior deployed RISKUSD implementation already had address _blocklist declared in storage
- (b). Owner performs a UUPS upgrade to the new implementation that inserts EnumerableSet.AddressSet immediately before _blocklist
- (c). The new _blocklist slot maps to a zero-initialized gap slot (reads as address(0))
- (d). Owner does not atomically reset _blocklist during the upgrade (e.g., no upgradeToAndCall)

### Scenario 2.
Global RISKUSD DoS: After upgrading RISKUSD to the new implementation, _blocklist points to a non-contract (e.g., an EOA). Any call to IBlocklist.isBlocked reverts due to empty returndata decoding, bricking transfers, nonzero approvals, and minter mint/burn. Downstream protocol functions that move RISKUSD also fail. The owner must call setBlocklist to restore functionality.
#### Preconditions / Assumptions
- (a). The prior deployed RISKUSD implementation already had address _blocklist declared in storage
- (b). Owner performs a UUPS upgrade to the new implementation that inserts EnumerableSet.AddressSet immediately before _blocklist
- (c). The new _blocklist slot maps to a stale nonzero non-contract address (e.g., an EOA)
- (d). Owner does not atomically reset _blocklist during the upgrade (e.g., no upgradeToAndCall)

#### Proposed fix

##### RISKUSD.sol

File: `openforage_smart_contracts/src/RISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSD.sol)

```diff
 ... 68 unchanged lines ...
     /// Uses 2 storage slots (length + mapping) from the gap.
     using EnumerableSet for EnumerableSet.AddressSet;
+    address internal _blocklist;
     EnumerableSet.AddressSet private _exemptAddressSet;
-    address internal _blocklist;

     /// @dev Reserved storage gap for future upgrades (47 - 2 pending ForageGovernor - 2 exempt set - 1 blocklist = 42)
 ... 240 unchanged lines ...
```

### 4. [Low] Sender-only pause check in RISKUSD during token pause causes user-to-protocol transfers to revert

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When RISKUSD is paused, only transfers whose sender is transfer-exempt bypass the pause. Because the recipient is ignored, user→protocol transfers revert even if protocol contracts are exempt. This temporarily blocks redemptions via RISKUSDVault (which pulls RISKUSD from the user) and staking via StakingQueue.joinQueue() while the token is paused.

RISKUSD enforces pause semantics by checking only the sender (from) side for transfer-exemption. If the token is paused and the sender is not exempt, the transfer reverts. Protocol contracts (e.g., RISKUSDVault, StakingQueue) being exempt does not help inbound user→protocol transfers because the user is the sender in those flows. As a result, while RISKUSD is paused: (1) RISKUSDVault.redeem() fails at the step where it pulls RISKUSD from the user before burning and returning USDC; (2) StakingQueue.joinQueue() fails when it pulls RISKUSD from the user. Outbound protocol→user transfers (where the protocol contract is the sender) can still work if the protocol is exempt. This behavior appears to be an intentional design choice to prevent pause circumvention through exempt contracts, but it creates a temporary availability loss for user redemptions and staking during a token pause.

#### Severity

**Impact Explanation:** [Medium] Blocking redemptions and staking while the token is paused is a significant but temporary availability loss of important protocol functionality.

**Likelihood Explanation:** [Low] The scenarios depend on a privileged operator pausing RISKUSD and leaving the vault/queue unpaused; no attacker path or incentive is involved.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
RISKUSDVault.redeem() reverts while only RISKUSD is paused: the vault is unpaused and liquid, a user calls redeem, the vault attempts to safeTransferFrom(user→vault) the RISKUSD, but the token-level pause blocks the user (non-exempt) as sender; the transfer reverts and the user cannot redeem USDC until the token is unpaused.
#### Preconditions / Assumptions
- (a). RISKUSD token is paused by a trusted operator (owner/governor/guardian)
- (b). RISKUSDVault is unpaused
- (c). User holds sufficient RISKUSD and is not transfer-exempt
- (d). RISKUSDVault is transfer-exempt
- (e). RISKUSDVault has sufficient USDC liquidity to fulfill redemptions

### Scenario 2.
StakingQueue.joinQueue() reverts while only RISKUSD is paused: the queue is unpaused, a user calls joinQueue, the queue attempts to safeTransferFrom(user→queue) the RISKUSD, but the token-level pause blocks the user (non-exempt) as sender; the transfer reverts and the user cannot enter the staking queue until the token is unpaused.
#### Preconditions / Assumptions
- (a). RISKUSD token is paused by a trusted operator (owner/governor/guardian)
- (b). StakingQueue is unpaused
- (c). User holds RISKUSD and is not transfer-exempt
- (d). StakingQueue is transfer-exempt

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 374 unchanged lines ...
         _dailyRedemptionUsed += riskusdAmount;

-        // Pull RISKUSD from redeemer and burn
-        IERC20(address(_riskusd)).safeTransferFrom(msg.sender, address(this), riskusdAmount);
-        _riskusd.burn(address(this), riskusdAmount);
+        // Burn RISKUSD directly from redeemer (minter-only; bypasses token pause)
+        _riskusd.burn(msg.sender, riskusdAmount);
         _reduceMintActiveSupply(riskusdAmount);

 ... 1404 unchanged lines ...
```

### 5. [Low] Unbounded dynamic array return in VaultRegistry.getAllVaults causes large-scale gas blowups and operational DoS

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

VaultRegistry.getAllVaults returns the entire storage-backed _allVaultIds array. When the registry grows very large, any on-chain call that relies on this view (notably RISKUSDVault’s deployCapital via _enforceDeploymentBuffer and RISKUSDVault’s registry-wiring interface check) must pay O(n) gas for ABI-encoding, which can revert due to gas limits. This blocks custodian deployments and may block admin rewiring, creating an operational liveness risk without affecting user funds.

Root cause: VaultRegistry.getAllVaults returns a dynamic storage array by value, forcing a full array copy and ABI encoding that scales linearly with the number of registered vaults. At large scale, this becomes prohibitively expensive and can revert. Impacted paths: (1) RISKUSDVault._enforceDeploymentBuffer, called during deployCapital (custodian-only), fetches all vault IDs and then scans up to 64, but the expensive part (full array return) already occurred in VaultRegistry. (2) RISKUSDVault’s registry wiring guards (_requireVaultRegistryInterface) perform a staticcall to getAllVaults to validate the target’s interface; this also forces full-array encoding and can revert if the target registry is very large. Effects: Capital deployment can be temporarily blocked until governance mitigates (e.g., setting deploymentBufferBps=0), and admin rewiring to a new registry can fail if the target is already large. Deposits/redemptions and user funds remain unaffected. This is a scalability/design limitation that manifests only at extreme registry sizes and is admin-managed.

#### Severity

**Impact Explanation:** [Medium] Blocks an important non-core operational function (custodian capital deployment) and can block admin rewiring; user deposits/redemptions and funds are unaffected. This fits 'breaks important non-core functionality' rather than principal loss.

**Likelihood Explanation:** [Low] Requires an exceptionally large registry (admin-managed scale) and, for some scenarios, governance actions; these are rare/exceptional preconditions and not under unprivileged attacker control.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Custodian deploys revert due to large getAllVaults encoding: The privileged executor calls HLTradingBridge.deployToHyperLiquid, which forwards to RISKUSDVault.deployCapital. _enforceDeploymentBuffer calls VaultRegistry.getAllVaults, forcing full-array encoding. With a very large _allVaultIds, the call reverts from gas exhaustion, preventing capital deployment until governance mitigates.
#### Preconditions / Assumptions
- (a). VaultRegistry._allVaultIds is very large (admin has added many vaults over time, each with four globally unique tier vault addresses).
- (b). RISKUSDVault.deploymentBufferBps > 0.
- (c). HLTradingBridge is correctly wired and a privileged executor attempts a deployment.

### Scenario 2.
Governance rewiring to a large new VaultRegistry fails during interface check: Owner calls finalize/accept registry on RISKUSDVault. The wiring guard staticcalls newRegistry.getAllVaults to validate the interface. The target must encode the entire array; at very large size, the call becomes too expensive and reverts, blocking this maintenance operation.
#### Preconditions / Assumptions
- (a). A target VaultRegistry (to be wired) already contains a very large _allVaultIds.
- (b). Owner/governance initiates finalizeVaultRegistry or acceptVaultRegistry on RISKUSDVault.

### Scenario 3.
Short-term deploy liveness degradation while timelock elapses: With a very large registry and nonzero deploymentBufferBps, deployCapital reverts as above. Governance proposes setDeploymentBufferBps(0) to bypass the expensive path, but production finalize delay postpones execution, leaving deploys blocked until the timelock completes.
#### Preconditions / Assumptions
- (a). VaultRegistry._allVaultIds is very large.
- (b). RISKUSDVault.deploymentBufferBps > 0.
- (c). Production governance finalize delay (timelock) in effect.
- (d). Privileged executor attempts deployments before the mitigation executes.

#### Proposed fix

##### RISKUSDVault.sol

File: `openforage_smart_contracts/src/RISKUSDVault.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/RISKUSDVault.sol)

```diff
 ... 694 unchanged lines ...
         if (vaultRegistry_.code.length == 0) revert InvalidVaultRegistryInterface(vaultRegistry_);
         (bool ok, bytes memory data) =
-            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistry.getAllVaults.selector));
-        if (!ok || data.length < 64) revert InvalidVaultRegistryInterface(vaultRegistry_);
+            vaultRegistry_.staticcall(abi.encodeWithSelector(IVaultRegistry.vaultCount.selector));
+        if (!ok || data.length < 32) revert InvalidVaultRegistryInterface(vaultRegistry_);
     }

 ... 921 unchanged lines ...

     function _activeRegisteredTierAssets() internal view returns (uint256 assets) {
-        uint256[] memory vaultIds = _vaultRegistry.getAllVaults();
-        uint256 limit = vaultIds.length < DEPLOYMENT_BUFFER_SCAN_LIMIT ? vaultIds.length : DEPLOYMENT_BUFFER_SCAN_LIMIT;
+        uint256 count = _vaultRegistry.vaultCount();
+        uint256 limit = count < DEPLOYMENT_BUFFER_SCAN_LIMIT ? count : DEPLOYMENT_BUFFER_SCAN_LIMIT;
         for (uint256 i; i < limit;) {
-            try _vaultRegistry.getVault(vaultIds[i]) returns (VaultConfig memory vc) {
+            try _vaultRegistry.getVault(_vaultRegistry.vaultIdAt(i)) returns (VaultConfig memory vc) {
                 if (vc.status == VaultStatus.Active) {
                     for (uint256 j; j < 4;) {
 ... 156 unchanged lines ...
```

##### IVaultRegistry.sol

File: `openforage_smart_contracts/src/interfaces/IVaultRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/interfaces/IVaultRegistry.sol)

```diff
 ... 30 unchanged lines ...
     function getVault(uint256 vaultId) external view returns (VaultConfig memory);
     function getAllVaults() external view returns (uint256[] memory);
+    function vaultCount() external view returns (uint256);
+    function vaultIdAt(uint256 index) external view returns (uint256);
     /// @dev OF-16-002: Notify VaultRegistry that a loss has been resolved for cooldown tracking.
     function notifyLossResolved() external;
 }
```

##### VaultRegistry.sol

File: `openforage_smart_contracts/src/VaultRegistry.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/VaultRegistry.sol)

```diff
 ... 443 unchanged lines ...
         return _allVaultIds.length;
     }
+    function vaultIdAt(uint256 index) external view returns (uint256) {
+        return _allVaultIds[index];
+    }

     function getVaultByAbbreviation(string calldata abbreviation_) external view returns (uint256) {
 ... 134 unchanged lines ...
```

### 6. [Low] Emergency override validation reuses failing reachability checks in atRISKUSD when yield source is unreachable causes tier-wide liveness freeze

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

When the atRISKUSD yield source becomes EVM-level unreachable, the contract’s emergency override setter repeats the same external checks that fail-close normal operations, preventing activation of the bypass and freezing all share actions until a delayed governance rotation completes.

atRISKUSD gates all core share actions (deposit, mint, withdraw, redeem, execute/cancel withdrawals, tier migrations) behind _requireNoLossPending(). That function fail-closes by staticcalling yieldSource.riskusdVault() and then vault.lossPending(); if either call fails/short, it reverts. The owner-facing emergency bypass setEmergencyLossPendingOverride(true)—documented as intended for an unreachable yield source—re-executes the same staticcalls before setting the flag, reverting on the same failures (EmergencyOverrideValidationFailed or CustodianSettlementHookFailed). Therefore, when the yield source is EVM-level unreachable, both user operations and the emergency bypass are blocked. Users may still request withdrawals (no lossPending gate) and unintentionally lock their shares, but cannot execute or cancel due to the same gate. Recovery requires rotating the yield source through a finalize-delayed governance action (2 days on Arbitrum), making the outage a temporary but complete DoS of the affected atRISKUSD tier.

#### Severity

**Impact Explanation:** [Medium] A significant but temporary DoS of all core user flows for the affected atRISKUSD tier; funds are not lost but access is delayed until governance rotation completes.

**Likelihood Explanation:** [Low] Requires a dependent integration (the yield source contract) to become EVM-level unreachable, a rare/exceptional but plausible outage; no attacker-controlled path.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Yield source unreachable freezes tier and bypass cannot be enabled: 1) atRISKUSD has a configured yield source; 2) the yield source becomes EVM-level unreachable (no code/bricked proxy/fatal upgrade), so staticcall to riskusdVault() fails/short; 3) any user share action reverts in _requireNoLossPending() at the yieldSource.riskusdVault() check; 4) the owner calls setEmergencyLossPendingOverride(true), which repeats the same staticcall and reverts, so the bypass cannot be enabled; 5) only recovery is to rotate the yield source via governance after FINALIZE_DELAY (~2 days), during which the tier’s deposit/mint/withdraw/redeem/execute/cancel/tier-migration operations remain frozen.
#### Preconditions / Assumptions
- (a). atRISKUSD is deployed with a configured yield source
- (b). The yield source becomes EVM-level unreachable (no code/bricked proxy/ABI mismatch or similar outage)
- (c). Owner attempts to enable setEmergencyLossPendingOverride(true)
- (d). Governance rotation of the yield source is subject to a ~2-day FINALIZE_DELAY on Arbitrum

#### Proposed fix

##### atRISKUSD.sol

File: `openforage_smart_contracts/src/atRISKUSD.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/atRISKUSD.sol)

```diff
 ... 986 unchanged lines ...
             // OF-18-004: Block override activation during active loss
             (bool ok, bytes memory data) = _yieldSource.staticcall(abi.encodeWithSignature("riskusdVault()"));
-            if (!ok || data.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
-            address vault = abi.decode(data, (address));
+            address vault;
+            if (ok && data.length >= 32) {
+                vault = abi.decode(data, (address));
+            } else {
+                (ok, data) = _stakingQueue.staticcall(abi.encodeWithSignature("vaultRegistry()"));
+                if (!ok || data.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
+                (ok, data) = abi.decode(data, (address)).staticcall(abi.encodeWithSignature("riskusdVault()"));
+                if (!ok || data.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
+                vault = abi.decode(data, (address));
+            }
             (bool ok2, bytes memory data2) = vault.staticcall(abi.encodeWithSignature("lossPending()"));
             if (!ok2 || data2.length < 32) revert EmergencyOverrideValidationFailed(_yieldSource);
 ... 242 unchanged lines ...
```

### 7. [Informational] Non-zero-to-non-zero approve restriction in ForageToken.approve causes integration transaction reverts

#### Status

Review status: Unresolved
Remediation status: Unremediated
Remediation note: Created by pipeline analysis

#### Description

ForageToken’s approve() reverts when changing a non-zero allowance to another non-zero value. Integrations that attempt single-call allowance updates (non-zero to non-zero) will see transactions revert. Users must use zero-first approve, increase/decreaseAllowance, SafeERC20.forceApprove, or Permit/Permit2 to proceed.

ForageToken.approve(spender, value) enforces a zero-first policy: if the current allowance for (owner, spender) is non-zero and the new value is also non-zero, the call reverts with AllowanceChangeRequiresZero. This deviates from simple overwrite semantics some integrations assume. As a result, any integration that tries to refresh or increase a non-zero FORAGE allowance in a single approve call will fail. Alternatives remain: two-step approve(0) then approve(new), increaseAllowance/decreaseAllowance (inherited from OZ and not overridden), SafeERC20.forceApprove (auto zero-then-set), or Permit/Permit2 patterns. TransferFrom and token transfers still enforce blocklist checks at spend time, preventing any spending bypass. Core protocol flows in the in-scope contracts do not rely on FORAGE allowance overwrites, so the impact is limited to third-party integrations experiencing reverted transactions.

#### Severity

**Impact Explanation:** [Low] No direct loss of funds or state; the impact is transaction reverts (availability/UX friction) for integrations relying on single-call non-zero-to-non-zero approve updates. Workarounds exist and core protocol functionality is unaffected.

**Likelihood Explanation:** [Low] Failures require specific integration behavior: attempting to overwrite a non-zero allowance in a single approve call instead of using zero-first, increase/decreaseAllowance, forceApprove, or Permit/Permit2. Many modern integrations avoid this pattern.

#### Exploitation

## Exploitation Scenarios:

### Scenario 1.
DEX swap revert: A user with an existing non-zero FORAGE allowance to a router initiates a larger swap; the router/front-end attempts approve(spender, newNonZero) to raise allowance in one call; approve() reverts due to non-zero-to-non-zero change, causing the swap transaction to fail.
#### Preconditions / Assumptions
- (a). User already has a non-zero FORAGE allowance to the router (spender).
- (b). The integration attempts a single-call non-zero-to-non-zero approve overwrite (no zero-first, no increase/decreaseAllowance, no forceApprove, no Permit/Permit2).
- (c). Neither the user nor the spender is blocklisted.
- (d). approve() is called by the token owner address.

### Scenario 2.
Farm/strategy deposit revert: A user with a prior non-zero FORAGE allowance to a strategy starts a larger deposit; the strategy or its UI refreshes allowance via a single approve(spender, newNonZero); approve() reverts, and the deposit transaction fails.
#### Preconditions / Assumptions
- (a). User already has a non-zero FORAGE allowance to the farm/strategy (spender).
- (b). The deposit flow refreshes allowance via a single-call non-zero-to-non-zero approve overwrite.
- (c). Neither the user nor the spender is blocklisted.
- (d). approve() is called by the token owner address.

### Scenario 3.
Owner-executed multicall revert: A smart wallet (e.g., Safe) batch includes approve(spender, newNonZero) followed by an operation requiring allowance; the approve step reverts due to non-zero-to-non-zero change, causing the entire batch to revert.
#### Preconditions / Assumptions
- (a). A smart wallet (owner address) executes a multicall where the first step is approve(spender, newNonZero) while an existing non-zero allowance is present.
- (b). The batch assumes overwrite semantics (no zero-first or increase/decreaseAllowance or forceApprove).
- (c). Neither the user nor the spender is blocklisted.
- (d). approve() is invoked by the token owner address.

#### Proposed fix

##### ForageToken.sol

File: `openforage_smart_contracts/src/ForageToken.sol`

[Source](https://github.com/systematic-long-short/public_openforage_audit_repo/blob/bcd1bd86f6bdf9a3df50607aed83625111a3570a/openforage_smart_contracts/src/ForageToken.sol)

```diff
 ... 238 unchanged lines ...
         uint256 currentAllowance = allowance(owner_, spender);
         if (currentAllowance != 0 && value != 0) {
-            revert AllowanceChangeRequiresZero(spender, currentAllowance, value);
+            // Atomic zero-then-set to support single-call overwrite and mitigate approval race
+            super.approve(spender, 0);
+            return super.approve(spender, value);
         }
         return super.approve(spender, value);
 ... 189 unchanged lines ...
```
