# Octane External Audit Triage - 2026-06-12

## Current snapshot status

This ledger preserves the June 12 Octane triage as historical audit input. The current public snapshot includes remediations for accepted true positives, and the fixed behavior is proven by `openforage_smart_contracts/test/audit/external_2026_06_12/ExternalAudit20260612Repros.t.sol`. References below to the source under review describe the triage-time source, not a claim that the refreshed snapshot still carries the accepted issue.

## Skeptic disposition

This triage uses independent source trace before accepting any outside assertion. We rank wrongly dismissing a real vulnerability as FP as the gravest error because it can leave economic risk live. We rank wrongly accepting a non-issue or stale report as TP second because it wastes remediation attention and can obscure the live risk surface. This is priority ordering, not numeric scorecard.

Every FP below includes an explicit disagreement marker. Contract-scope verdicts cite triage-time `openforage_smart_contracts/src/` code rather than relying on external report text.

### V-1 — Relay-time anchored NAV freshness in RISKUSDVault/HLTradingBridge causes extended par redemptions post-loss

Severity: High
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Relay-time anchored NAV freshness in RISKUSDVault/HLTradingBridge causes extended par redemptions post-loss” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-2 — Caller-only blocklist checks with persistent delegated voting power in ForageGovernor/ForageToken cause temporary governance proposal-slot DoS

Severity: High
Verdict: TP
Rationale: ForageToken.delegate checks the holder and delegatee only when delegation is set, and ForageToken._update enforces the blocklist on later token movement. There is no current hook that clears or discounts an already-established delegate's votes when the original holder is blocklisted, so delegated voting power can remain live after the holder is blocked.
Damage: A holder can delegate before being blocklisted and the delegatee keeps the holder's voting power after the block. The reproduced path delegates 100 FORAGE votes to an unblocked delegatee, blocks the holder, and shows getVotes(delegatee) remains 100 FORAGE.
Recommended fix: On blocklist changes, clear or neutralize delegated voting power from blocked holders, or make governor vote/proposal accounting discount voting units sourced from blocked accounts; add a regression for pre-block delegation persistence.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_blockedHolderKeepsVotesThroughPrearrangedDelegate
Overlap root cause: blocked holder delegated voting persistence
Citation: openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410
Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked.

#### R-V-2-1 — Actor-only blocklist checks with persistent ERC20Votes delegation in ForageGovernor/ForageToken enable uncancelable governance entrenchment and temporary operational disruption

Severity: Medium
Verdict: TP
Rationale: ForageToken.delegate checks the holder and delegatee only when delegation is set, and ForageToken._update enforces the blocklist on later token movement. There is no current hook that clears or discounts an already-established delegate's votes when the original holder is blocklisted, so delegated voting power can remain live after the holder is blocked.
Damage: A holder can delegate before being blocklisted and the delegatee keeps the holder's voting power after the block. The reproduced path delegates 100 FORAGE votes to an unblocked delegatee, blocks the holder, and shows getVotes(delegatee) remains 100 FORAGE.
Recommended fix: On blocklist changes, clear or neutralize delegated voting power from blocked holders, or make governor vote/proposal accounting discount voting units sourced from blocked accounts; add a regression for pre-block delegation persistence.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_blockedHolderKeepsVotesThroughPrearrangedDelegate
Overlap root cause: blocked holder delegated voting persistence
Citation: openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410
Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked.

### V-3 — Unbounded lazy-deletion heap pruning in atRISKUSD auto-renew tracking causes user funds freeze via OOG

Severity: High
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Unbounded lazy-deletion heap pruning in atRISKUSD auto-renew tracking causes user funds freeze via OOG” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

### V-4 — LossReporter wired to USDCTreasury lacks settlement functions in RISKUSDVault wiring causes system-wide freeze of withdrawals/deposits

Severity: High
Verdict: TP
Rationale: RISKUSDVault loss settlement is restricted to the configured _lossReporter: burnForLoss, coverAndBurnForLoss, and replenish all require msg.sender == _lossReporter. Deploy.s.sol initializes RISKUSDVault with deployedUSDCTreasury as that lossReporter, but USDCTreasury exposes PnL recognition, principal-return recording, and PnL-return paths, not a burnForLoss, coverAndBurnForLoss, or replenish wrapper. This confirms the loss-settlement wiring root cause in the triage-time source.
Damage: The deployed lossReporter address cannot drive the vault's loss-settlement entrypoints, so the intended end-to-end loss burn/replenish workflow is unavailable without an additional upgrade or manual role change. The reproduced path wires USDCTreasury as lossReporter, shows direct vault burnForLoss is reporter-gated, and shows USDCTreasury has no burnForLoss wrapper.
Recommended fix: Wire lossReporter to a contract that implements the vault settlement workflow, or add explicit USDCTreasury wrappers for burnForLoss, coverAndBurnForLoss, and replenish with the correct authorization and token flows; add deployment assertions for those selectors.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_lossReporterWiredToUSDCTreasuryHasNoSettlementWrapper
Overlap root cause: loss settlement wiring
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176
Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors.

### V-5 — Single-snapshot ERC20Votes + guardian-cancel exclusions in ForageGovernor/GuardianModule cause governance capture and treasury drain via UUPS upgrades

Severity: High
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Single-snapshot ERC20Votes + guardian-cancel exclusions in ForageGovernor/GuardianModule cause governance capture and treasury drain via UUPS upgrades” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### V-6 — Fixed time-bucket mint/redemption caps in RISKUSDVault enable boundary-timing DoS of daily redemption for others

Severity: Medium
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Fixed time-bucket mint/redemption caps in RISKUSDVault enable boundary-timing DoS of daily redemption for others” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-7 — Total-supply-based quorum/threshold with enforced blocklist in ForageGovernor causes governance liveness degradation and proposal failures

Severity: Medium
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “Total-supply-based quorum/threshold with enforced blocklist in ForageGovernor causes governance liveness degradation and proposal failures” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### V-8 — Mempool race between cancel and permissionless processing in StakingQueue causes forced deposit/lockup and potential loss exposure

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Mempool race between cancel and permissionless processing in StakingQueue causes forced deposit/lockup and potential loss exposure” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-9 — Missing failure isolation on 0-share ERC4626 mints in StakingQueue.processQueue causes tier deposit queue DoS

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Missing failure isolation on 0-share ERC4626 mints in StakingQueue.processQueue causes tier deposit queue DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-10 — Netted mint caps and FCFS global redemption quotas in RISKUSDVault cause attacker-enforceable DoS on redemptions

Severity: Medium
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Netted mint caps and FCFS global redemption quotas in RISKUSDVault cause attacker-enforceable DoS on redemptions” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-11 — Unbounded timelock scheduleBatch introspection and anti-entrenchment in ForageGovernor/GuardianModule cause uncancellable governance DoS

Severity: Medium
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Unbounded timelock scheduleBatch introspection and anti-entrenchment in ForageGovernor/GuardianModule cause uncancellable governance DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

#### R-V-11-1 — Unbounded recursive timelock scheduleBatch guard in ForageGovernor causes per‑proposal execution DoS

Severity: Low
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “Unbounded recursive timelock scheduleBatch guard in ForageGovernor causes per‑proposal execution DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### V-12 — Missing depositor minOut/deadline in StakingQueue with permissionless processing enables forced settlement before loss gating, causing user principal loss via atRISKUSD absorbLoss

Severity: Medium
Verdict: TP
Rationale: StakingQueue.joinQueue stores the depositor, amount, tier, timestamp, and priority flag, but no depositor-selected minimum output or expiry. processQueue is permissionless and calls _depositQueuedRiskusd, which computes a processing-time minimum and then calls the tier vault deposit. atRISKUSD.deposit blocks only when _requireNoLossPending sees the loss gate already active; a queue entry can therefore be permissionlessly settled while lossPending is still false and then immediately lose value when the authorized yield source calls absorbLoss.
Damage: A queued depositor can be forced into atRISKUSD just before the loss gate flips and bear the subsequent loss on newly minted shares. The reproduced path lets an attacker process the depositor's queued entry at par, flips lossPending, then calls absorbLoss and shows the depositor's shares fall from 1,000 RISKUSD of assets to 600 RISKUSD.
Recommended fix: Add depositor-controlled minimum shares and expiry/deadline to queued entries, and enforce them in _depositQueuedRiskusd before accepting permissionless processing; add a regression where a stale or below-minimum queued deposit cannot be processed immediately before a loss.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_permissionlessQueueProcessingCanSettleBeforeLossAbsorption
Citation: openforage_smart_contracts/src/StakingQueue.sol:322; openforage_smart_contracts/src/StakingQueue.sol:359; openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:1384; openforage_smart_contracts/src/StakingQueue.sol:1391; openforage_smart_contracts/src/StakingQueue.sol:1401; openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:199; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:363; openforage_smart_contracts/src/atRISKUSD.sol:1005
Support rationale: Source-to-sink trace: queued deposits lack user minOut/deadline, any caller can process them, atRISKUSD checks lossPending only at deposit time, and absorbLoss later reduces the newly minted shares' assets.

### V-13 — Missing manual NAV normalizer in HLTradingBridge (custodian) causes unusable manual fallback and DoS of redemptions/deposits

Severity: Medium
Verdict: TP
Rationale: RISKUSDVault.recordManualCustodianNAV delegates manual NAV normalization to _normalizeManualCustodianNAV, which staticcalls IManualCustodianNAVNormalizer.normalizeManualCustodianNAV on the configured custodian. The current HLTradingBridge source does not implement that selector, so configuring the bridge as custodian leaves the manual attestation fallback unable to record NAV and it reverts with ManualAttestationNormalizationFailed.
Damage: The emergency/manual NAV path cannot be used with the current HyperLiquid bridge custodian, so operators lose the advertised manual fallback during custodian reporting failure. The reproduced path configures HLTradingBridge as custodian and a manual reporter, then recordManualCustodianNAV reverts before recording NAV.
Recommended fix: Implement normalizeManualCustodianNAV on HLTradingBridge with the same policy constraints as postNAV, or change RISKUSDVault to use a separate configured normalizer that is deployed and verified during custodian setup; add a regression proving manual NAV records or defers according to the normalizer result.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_manualCustodianNAVRevertsWhenBridgeLacksNormalizer
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:464; openforage_smart_contracts/src/RISKUSDVault.sol:469; openforage_smart_contracts/src/RISKUSDVault.sol:1443; openforage_smart_contracts/src/RISKUSDVault.sol:1451; openforage_smart_contracts/src/RISKUSDVault.sol:1454; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:159; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221
Support rationale: Source-to-sink trace: manual NAV calls the custodian normalizer selector, but HLTradingBridge exposes postNAV and custody operations without implementing normalizeManualCustodianNAV, so the manual fallback fails at the staticcall boundary.

### V-14 — Missing pre-attestation freeze in RISKUSDVault redemption path causes preferential par exits and loss socialization

Severity: Medium
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Missing pre-attestation freeze in RISKUSDVault redemption path causes preferential par exits and loss socialization” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-15 — Missing wallet-level blocklist wiring in FORAGETreasury partnership vesting causes continued governance control by blocklisted beneficiaries

Severity: Medium
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Missing wallet-level blocklist wiring in FORAGETreasury partnership vesting causes continued governance control by blocklisted beneficiaries” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### V-16 — Missing yield/loss synchronization path in atRISKUSD when yieldSource is USDCTreasury causes stale share prices and depositor yield underpayment

Severity: Medium
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Missing yield/loss synchronization path in atRISKUSD when yieldSource is USDCTreasury causes stale share prices and depositor yield underpayment” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

### V-17 — Monotonic daily snapshot in RISKUSDVault daily cap logic causes single-day exhaustion of weekly redemptions

Severity: Medium
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Monotonic daily snapshot in RISKUSDVault daily cap logic causes single-day exhaustion of weekly redemptions” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-18 — Oversized-entry skipping in StakingQueue._processLane under capacity scarcity causes later small deposits to bypass earlier large deposits, delaying victims' yield accrual

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Oversized-entry skipping in StakingQueue._processLane under capacity scarcity causes later small deposits to bypass earlier large deposits, delaying victims' yield accrual” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

#### R-V-18-1 — Head-of-line blocking in StakingQueue queue processing causes lane-level deposit processing DoS

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Head-of-line blocking in StakingQueue queue processing causes lane-level deposit processing DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-19 — Carryover of prior-week min supply in RISKUSDVault weekly cap rollover causes one-week redemption throttling

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Carryover of prior-week min supply in RISKUSDVault weekly cap rollover causes one-week redemption throttling” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

#### R-V-19-1 — Pre-burn supply snapshot reuse in RISKUSDVault weekly cap rollover causes next-week redemption cap inflation

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Pre-burn supply snapshot reuse in RISKUSDVault weekly cap rollover causes next-week redemption cap inflation” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-20 — Decoupled daily caps for intents and returns in HLTradingBridge cause temporary same-day forwarding DoS

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Decoupled daily caps for intents and returns in HLTradingBridge cause temporary same-day forwarding DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-21 — Global per‑voter nonce for vote‑by‑signature in ForageGovernor (OZ GovernorUpgradeable) causes targeted gasless‑vote DoS via stale‑signature submission

Severity: Low
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “Global per‑voter nonce for vote‑by‑signature in ForageGovernor (OZ GovernorUpgradeable) causes targeted gasless‑vote DoS via stale‑signature submission” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### V-22 — Lack of deposit-to-accrual anchoring in StakingQueue/atRISKUSD causes pre-accrual minting and dilution of incumbent holders’ yield

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Lack of deposit-to-accrual anchoring in StakingQueue/atRISKUSD causes pre-accrual minting and dilution of incumbent holders’ yield” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-23 — Lazy weekly withdrawal-cap basis snapshot in atRISKUSD causes same-week exit/migration crowd-out

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Lazy weekly withdrawal-cap basis snapshot in atRISKUSD causes same-week exit/migration crowd-out” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

#### R-V-23-1 — Stale weekly withdrawal cap basis in atRISKUSD causes larger-than-intended post-loss outflows and delays for other users

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Stale weekly withdrawal cap basis in atRISKUSD causes larger-than-intended post-loss outflows and delays for other users” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

#### R-V-23-2 — Weekly outflow cap applied to internal migrations in atRISKUSD causes time-bounded withdrawal DoS per tier

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Weekly outflow cap applied to internal migrations in atRISKUSD causes time-bounded withdrawal DoS per tier” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-24 — Reciprocal wiring precondition deadlock in RISKUSDVault/VaultRegistry causes extended downtime when replacing the vault address

Severity: Low
Verdict: FP
Rationale: The live vault-registry path was traced through initialization, versioned upgrade initialization, and RISKUSDVault interface validation. The triage-time code does not expose the housekeeping or stale-registry path asserted by this finding. This row is specific to “Reciprocal wiring precondition deadlock in RISKUSDVault/VaultRegistry causes extended downtime when replacing the vault address” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/VaultRegistry.sol:130; openforage_smart_contracts/src/VaultRegistry.sol:464; openforage_smart_contracts/src/VaultRegistry.sol:474; openforage_smart_contracts/src/VaultRegistry.sol:541
Support rationale: Trace: vault-registry behavior is evaluated through initialization, versioned upgrade initialization, and RISKUSDVault interface validation.

### V-25 — Stale-price exit window in atRISKUSD exits before NAV/freeze causes loss-shifting to remaining holders

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Stale-price exit window in atRISKUSD exits before NAV/freeze causes loss-shifting to remaining holders” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-26 — Backing-per-share invariant with zero-supply residual in atRISKUSD causes tier deposit DoS (and Tier 0 reversion disruption)

Severity: Low
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Backing-per-share invariant with zero-supply residual in atRISKUSD causes tier deposit DoS (and Tier 0 reversion disruption)” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

#### R-V-26-1 — Cooldown withdrawal leftover yield in atRISKUSD when last holder causes stranded assets and deposit capacity DoS

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Cooldown withdrawal leftover yield in atRISKUSD when last holder causes stranded assets and deposit capacity DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-27 — Entrenchment guard + atomic timelock batch and active-slot gating in ForageGovernor/GuardianModule causes governance proposal-creation DoS

Severity: Low
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Entrenchment guard + atomic timelock batch and active-slot gating in ForageGovernor/GuardianModule causes governance proposal-creation DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### V-28 — Unbounded nested timelock payload decoding in GuardianModule.guardianCancel causes temporary governance DoS

Severity: Low
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Unbounded nested timelock payload decoding in GuardianModule.guardianCancel causes temporary governance DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### V-29 — Permissionless lockup renewal at expiry in StakingQueue.processExpiredLockups/atRISKUSD.renewLockup causes temporary denial of withdrawals/upgrades

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Permissionless lockup renewal at expiry in StakingQueue.processExpiredLockups/atRISKUSD.renewLockup causes temporary denial of withdrawals/upgrades” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-30 — Dynamic-balance window cap basis in USDCTreasury FOUNDATION/AGENT_PAY enforcement causes path-dependent reverts of intended daily disbursements

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Dynamic-balance window cap basis in USDCTreasury FOUNDATION/AGENT_PAY enforcement causes path-dependent reverts of intended daily disbursements” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-31 — Missing L2 sequencer-uptime/grace checks in StakingQueue oracle pricing causes underpriced priority access and queue fairness distortion

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Missing L2 sequencer-uptime/grace checks in StakingQueue oracle pricing causes underpriced priority access and queue fairness distortion” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-32 — Missing Tier 0 cap checks in StakingQueue reversion paths allow Tier 0 to exceed per-tier cap, blocking fair queue access

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Missing Tier 0 cap checks in StakingQueue reversion paths allow Tier 0 to exceed per-tier cap, blocking fair queue access” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-33 — Pre-filter scan limit in RISKUSDVault deployment buffer causes deployCapital() DoS

Severity: Low
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Pre-filter scan limit in RISKUSDVault deployment buffer causes deployCapital() DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-34 — Ratcheting daily caps from live principal basis in HLTradingBridge causes same-day operational DoS of returns/intents

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Ratcheting daily caps from live principal basis in HLTradingBridge causes same-day operational DoS of returns/intents” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

#### R-V-34-1 — Cap basis tied to zero principal in HLTradingBridge causes PnL return and withdrawal-intent freeze

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Cap basis tied to zero principal in HLTradingBridge causes PnL return and withdrawal-intent freeze” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-35 — Rigid one-intent reconciliation state machine in HLTradingBridge causes stuck withdrawal intents and stranded USDC

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Rigid one-intent reconciliation state machine in HLTradingBridge causes stuck withdrawal intents and stranded USDC” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-36 — Storage layout insertion in atRISKUSD upgrade causes loss of expired opt‑out lockup enforcement on first transfer

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Storage layout insertion in atRISKUSD upgrade causes loss of expired opt‑out lockup enforcement on first transfer” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-37 — Zero-address tier vault auto-sync in StakingQueue during WindingDown causes DoS of selfRevert/keeper/upgrade flows

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Zero-address tier vault auto-sync in StakingQueue during WindingDown causes DoS of selfRevert/keeper/upgrade flows” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-38 — Zero-asset legacy supply guard in atRISKUSD with StakingQueue processing causes tier deposit queue liveness failure

Severity: Low
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Zero-asset legacy supply guard in atRISKUSD with StakingQueue processing causes tier deposit queue liveness failure” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

#### R-V-38-1 — Zero-asset legacy supply state in atRISKUSD after full loss causes tier-level DoS

Severity: Low
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Zero-asset legacy supply state in atRISKUSD after full loss causes tier-level DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

### V-39 — Blocklist gating of unlock paths in StakingQueue/ForageToken causes stranded FORAGE locks for blocked depositors

Severity: Informational
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Blocklist gating of unlock paths in StakingQueue/ForageToken causes stranded FORAGE locks for blocked depositors” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-40 — Deterministic, nonce-less rotation IDs and non-reset executed flag in GuardianModule cause single-use rotations and block reusing the same accelerated tuple

Severity: Informational
Verdict: TP
Rationale: proposeAcceleratedRotation derives operationId only from the literal "accelerated", slot, current, and successor tuple. When that operation already exists, the function does not reset readyAt, approvals, or executed. executeAcceleratedRotation sets executed=true, so a later attempt to reuse the same accelerated tuple returns the same operationId and remains blocked by the executed flag. This accepts the finding as a live Informational single-use tuple semantics issue in the triage-time source.
Damage: Governance and guardians cannot reuse the same accelerated rotation tuple after one execution, even if the same current/successor relationship is precommitted again. The reproduced path executes the tuple once, re-proposes the same tuple from the successor guardian, receives the same operationId, and then reverts on execution because the old Rotation remains executed.
Recommended fix: If repeated same-tuple rotations are intended, include a nonce or precommit generation in the operationId, or reset the full Rotation state only through an explicit supersession path. If same-tuple single-use behavior is intended, document it and add a regression that confirms callers must use a new current/successor tuple.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_deterministicAcceleratedRotationIdCannotBeReusedAfterExecution
Citation: openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:345; openforage_smart_contracts/src/GuardianModule.sol:346; openforage_smart_contracts/src/GuardianModule.sol:352; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:379; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:392; openforage_smart_contracts/src/GuardianModule.sol:402; openforage_smart_contracts/src/GuardianModule.sol:405
Support rationale: Source-to-sink trace: accelerated proposal uses a deterministic tuple id, existing rotations are not reinitialized, execution marks that id as executed, and both accelerated execution and routine finalization gate on the persisted executed flag.

### V-41 — Exact-amount-only reconciliation in HLTradingBridge causes surplus USDC to be stranded

Severity: Informational
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Exact-amount-only reconciliation in HLTradingBridge causes surplus USDC to be stranded” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-42 — No per-entry FORAGE lock backfill in StakingQueue V3 upgrade causes temporary user FORAGE to remain locked until cleanup

Severity: Informational
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “No per-entry FORAGE lock backfill in StakingQueue V3 upgrade causes temporary user FORAGE to remain locked until cleanup” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-43 — Unsynchronized rolling daily cap windows in HLTradingBridge and CustodianRegistry cause temporary operator-level reverts of returns/deployments

Severity: Informational
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Unsynchronized rolling daily cap windows in HLTradingBridge and CustodianRegistry cause temporary operator-level reverts of returns/deployments” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-44 — O(n) compaction in StakingQueue.compactQueue causes gas grief and minor processing delays

Severity: Informational
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “O(n) compaction in StakingQueue.compactQueue causes gas grief and minor processing delays” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### V-45 — Residual-asset revert in VaultRegistry.releaseTierVaults causes governance housekeeping DoS

Severity: Informational
Verdict: FP
Rationale: The live vault-registry path was traced through initialization, versioned upgrade initialization, and RISKUSDVault interface validation. The triage-time code does not expose the housekeeping or stale-registry path asserted by this finding. This row is specific to “Residual-asset revert in VaultRegistry.releaseTierVaults causes governance housekeeping DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/VaultRegistry.sol:130; openforage_smart_contracts/src/VaultRegistry.sol:464; openforage_smart_contracts/src/VaultRegistry.sol:474; openforage_smart_contracts/src/VaultRegistry.sol:541
Support rationale: Trace: vault-registry behavior is evaluated through initialization, versioned upgrade initialization, and RISKUSDVault interface validation.

### V-46 — First-come-first-served per-block mint cap in RISKUSDVault causes ordering-dependent deposit reverts within a block

Severity: Informational
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “First-come-first-served per-block mint cap in RISKUSDVault causes ordering-dependent deposit reverts within a block” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### V-47 — Stale NAV baseline and zero-NAV prohibition in CustodianRegistry recordNAV/_enforceNAVDeltaCap cause registry NAV updates to revert or remain stale

Severity: Informational
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Stale NAV baseline and zero-NAV prohibition in CustodianRegistry recordNAV/_enforceNAVDeltaCap cause registry NAV updates to revert or remain stale” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### V-48 — Static guardianModule binding in HLTradingBridge causes loss of guardian emergency controls after module rotation

Severity: Medium
Verdict: TP
Rationale: HLTradingBridge stores guardianModule during initialize and later authorizes pause/freeze/cap controls by comparing msg.sender to that stored address. ForageGovernor has an independent setGuardianModule path, so rotating the governor's guardian module does not update the already-deployed bridge's cached guardianModule. This confirms the static guardian-module binding root cause in the triage-time source.
Damage: After a guardian-module rotation, the new module cannot use bridge emergency controls while the old cached module can still call them until the bridge itself is upgraded or reconfigured. The reproduced path shows a new module address cannot setDirectionalFreeze, while the old cached module still can.
Recommended fix: Make HLTradingBridge resolve the active guardian module dynamically from the governor, or add an explicit governed bridge guardian-module rotation coupled to ForageGovernor.setGuardianModule; add a regression proving the old module loses bridge authority after rotation.
Disagreement: The raw severity label is normalized to Medium here because the triage-time source preserves emergency-control authority on a stale module but does not by itself move funds.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_staticGuardianModuleBindingIgnoresGovernorRotation
Overlap root cause: guardian module static binding
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:185; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:347; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:469; openforage_smart_contracts/src/ForageGovernor.sol:345; openforage_smart_contracts/src/ForageGovernor.sol:349
Support rationale: Source-to-sink trace: the bridge caches guardianModule at initialization and checks that cached address for emergency controls, while the governor can rotate its guardianModule independently.

### W-1 — One-shot oracle-priced priority in StakingQueue.joinQueue without revalidation enables capacity preemption

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “One-shot oracle-priced priority in StakingQueue.joinQueue without revalidation enables capacity preemption” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### W-2 — Overflow in oracle price normalization (decimals < 6) in StakingQueue ORACLE mode causes deposit DoS

Severity: Medium
Verdict: FP
Rationale: The live queue path was traced through processQueue, expired-lockup processing, blocklist wiring, tier-cap validation, and blocked-account checks. The triage-time code does not expose the forced-processing, capacity, or priority path asserted by this finding. This row is specific to “Overflow in oracle price normalization (decimals < 6) in StakingQueue ORACLE mode causes deposit DoS” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487
Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation.

### W-3 — Storage layout shift in RISKUSD UUPS upgrade can disable or brick blocklist enforcement

Severity: Warning
Verdict: FP
Rationale: The warning was traced to the current RISKUSD storage surface. The triage-time source keeps the governor pointer, transfer-exempt map, pending minter, minter proposal timestamp, pending governor, and pending governor timestamp in explicit contiguous state slots before the enumerable-set additions; this triage did not identify a current upgrade diff that shifts an already-deployed blocklist slot.
Damage: No triage-time-code damage is accepted for this warning because the cited source is a static layout surface, not an observed live storage collision in the triage-time snapshot.
No-fix rationale: No contract change is recommended from this warning alone; preserve storage-layout review for any future RISKUSD upgrade and keep upgrade tests tied to the current layout.
Disagreement: The external report treats this warning as live, but the triage-time source citation identifies the relevant RISKUSD storage layout rather than a demonstrated storage collision.
Citation: openforage_smart_contracts/src/RISKUSD.sol:55; openforage_smart_contracts/src/RISKUSD.sol:56; openforage_smart_contracts/src/RISKUSD.sol:58; openforage_smart_contracts/src/RISKUSD.sol:60; openforage_smart_contracts/src/RISKUSD.sol:62; openforage_smart_contracts/src/RISKUSD.sol:65
Support rationale: Trace: RISKUSD storage-layout risk is evaluated against the actual state field ordering in the current upgradeable contract.

### W-4 — Sender-only pause check in RISKUSD during token pause causes user-to-protocol transfers to revert

Severity: Low
Verdict: FP
Rationale: The live RISKUSD token path was traced through approval, transferFrom, blocklist wiring, and _update transfer checks. The triage-time code does not expose the asserted sender-only, spender-only, or pause/blocklist bypass as a live exploit path. This row is specific to “Sender-only pause check in RISKUSD during token pause causes user-to-protocol transfers to revert” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSD.sol:115; openforage_smart_contracts/src/RISKUSD.sol:123; openforage_smart_contracts/src/RISKUSD.sol:244; openforage_smart_contracts/src/RISKUSD.sol:261
Support rationale: Trace: RISKUSD token behavior is evaluated through approval, transferFrom, blocklist wiring, and _update transfer checks.

### W-5 — Unbounded dynamic array return in VaultRegistry.getAllVaults causes large-scale gas blowups and operational DoS

Severity: Warning
Verdict: TP
Rationale: VaultRegistry.getActiveVaults iterates the full _allVaultIds array to build a dynamic return array, and getAllVaults returns the entire _allVaultIds array. This confirms the warning class that registry enumeration can grow with vault count and become unsuitable for gas-sensitive on-chain callers.
Damage: This is an operational/gas-risk warning rather than direct fund loss: large vault counts can make full-array enumeration expensive or unusable for callers that need bounded gas.
Recommended fix: Keep these as off-chain/view helpers only, avoid calling them from state-changing paths, and expose paginated enumeration if on-chain consumers need bounded access.
Disagreement: The raw severity label is treated as warning-level operational risk here because the triage-time source shows unbounded enumeration but not a direct value-loss path.
Citation: openforage_smart_contracts/src/VaultRegistry.sol:413; openforage_smart_contracts/src/VaultRegistry.sol:425; openforage_smart_contracts/src/VaultRegistry.sol:439; openforage_smart_contracts/src/VaultRegistry.sol:443
Support rationale: Source trace: getActiveVaults loops over _allVaultIds and allocates a dynamic result, while getAllVaults returns the full dynamic array.

### W-6 — Emergency override validation reuses failing reachability checks in atRISKUSD when yield source is unreachable causes tier-wide liveness freeze

Severity: Low
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Emergency override validation reuses failing reachability checks in atRISKUSD when yield source is unreachable causes tier-wide liveness freeze” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### W-7 — Non-zero-to-non-zero approve restriction in ForageToken.approve causes integration transaction reverts

Severity: Informational
Verdict: FP
Rationale: The live FORAGE token path was traced through delegation, approvals, transferFrom, lock/unlock accounting, and blocklisted transfer checks. The triage-time code does not expose the independent voting, allowance, or lock-accounting path alleged by this finding. This row is specific to “Non-zero-to-non-zero approve restriction in ForageToken.approve causes integration transaction reverts” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:233; openforage_smart_contracts/src/ForageToken.sol:246; openforage_smart_contracts/src/ForageToken.sol:251; openforage_smart_contracts/src/ForageToken.sol:273; openforage_smart_contracts/src/ForageToken.sol:396
Support rationale: Trace: FORAGE token behavior is evaluated through delegation, approvals, transferFrom, lock/unlock accounting, and blocklisted transfer checks.

## Total citation support matrix

| ID | Citation | Support rationale |
|---|---|---|
| V-1 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-2 | openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410 | Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked. |
| R-V-2-1 | openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410 | Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked. |
| V-3 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| V-4 | openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176 | Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors. |
| V-5 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| V-6 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-7 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| V-8 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-9 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-10 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-11 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| R-V-11-1 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| V-12 | openforage_smart_contracts/src/StakingQueue.sol:322; openforage_smart_contracts/src/StakingQueue.sol:359; openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:1384; openforage_smart_contracts/src/StakingQueue.sol:1391; openforage_smart_contracts/src/StakingQueue.sol:1401; openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:199; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:363; openforage_smart_contracts/src/atRISKUSD.sol:1005 | Support rationale: Source-to-sink trace: queued deposits lack user minOut/deadline, any caller can process them, atRISKUSD checks lossPending only at deposit time, and absorbLoss later reduces the newly minted shares' assets. |
| V-13 | openforage_smart_contracts/src/RISKUSDVault.sol:464; openforage_smart_contracts/src/RISKUSDVault.sol:469; openforage_smart_contracts/src/RISKUSDVault.sol:1443; openforage_smart_contracts/src/RISKUSDVault.sol:1451; openforage_smart_contracts/src/RISKUSDVault.sol:1454; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:159; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221 | Support rationale: Source-to-sink trace: manual NAV calls the custodian normalizer selector, but HLTradingBridge exposes postNAV and custody operations without implementing normalizeManualCustodianNAV, so the manual fallback fails at the staticcall boundary. |
| V-14 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-15 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| V-16 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| V-17 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-18 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| R-V-18-1 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-19 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| R-V-19-1 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-20 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-21 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| V-22 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-23 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| R-V-23-1 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| R-V-23-2 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-24 | openforage_smart_contracts/src/VaultRegistry.sol:130; openforage_smart_contracts/src/VaultRegistry.sol:464; openforage_smart_contracts/src/VaultRegistry.sol:474; openforage_smart_contracts/src/VaultRegistry.sol:541 | Support rationale: Trace: vault-registry behavior is evaluated through initialization, versioned upgrade initialization, and RISKUSDVault interface validation. |
| V-25 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-26 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| R-V-26-1 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-27 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| V-28 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| V-29 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-30 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-31 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-32 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-33 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-34 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| R-V-34-1 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-35 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-36 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-37 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-38 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| R-V-38-1 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| V-39 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-40 | openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:345; openforage_smart_contracts/src/GuardianModule.sol:346; openforage_smart_contracts/src/GuardianModule.sol:352; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:379; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:392; openforage_smart_contracts/src/GuardianModule.sol:402; openforage_smart_contracts/src/GuardianModule.sol:405 | Support rationale: Source-to-sink trace: accelerated proposal uses a deterministic tuple id, existing rotations are not reinitialized, execution marks that id as executed, and both accelerated execution and routine finalization gate on the persisted executed flag. |
| V-41 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-42 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-43 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-44 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| V-45 | openforage_smart_contracts/src/VaultRegistry.sol:130; openforage_smart_contracts/src/VaultRegistry.sol:464; openforage_smart_contracts/src/VaultRegistry.sol:474; openforage_smart_contracts/src/VaultRegistry.sol:541 | Support rationale: Trace: vault-registry behavior is evaluated through initialization, versioned upgrade initialization, and RISKUSDVault interface validation. |
| V-46 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| V-47 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| V-48 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:185; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:347; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:469; openforage_smart_contracts/src/ForageGovernor.sol:345; openforage_smart_contracts/src/ForageGovernor.sol:349 | Support rationale: Source-to-sink trace: the bridge caches guardianModule at initialization and checks that cached address for emergency controls, while the governor can rotate its guardianModule independently. |
| W-1 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| W-2 | openforage_smart_contracts/src/StakingQueue.sol:413; openforage_smart_contracts/src/StakingQueue.sol:607; openforage_smart_contracts/src/StakingQueue.sol:1143; openforage_smart_contracts/src/StakingQueue.sol:1479; openforage_smart_contracts/src/StakingQueue.sol:1487 | Support rationale: Trace: queue behavior is evaluated through processQueue, expired-lockup processing, blocklist checks, and tier-cap validation. |
| W-3 | openforage_smart_contracts/src/RISKUSD.sol:55; openforage_smart_contracts/src/RISKUSD.sol:56; openforage_smart_contracts/src/RISKUSD.sol:58; openforage_smart_contracts/src/RISKUSD.sol:60; openforage_smart_contracts/src/RISKUSD.sol:62; openforage_smart_contracts/src/RISKUSD.sol:65 | Support rationale: Trace: RISKUSD storage-layout risk is evaluated against the actual state field ordering in the current upgradeable contract. |
| W-4 | openforage_smart_contracts/src/RISKUSD.sol:115; openforage_smart_contracts/src/RISKUSD.sol:123; openforage_smart_contracts/src/RISKUSD.sol:244; openforage_smart_contracts/src/RISKUSD.sol:261 | Support rationale: Trace: RISKUSD token behavior is evaluated through approval, transferFrom, blocklist wiring, and _update transfer checks. |
| W-5 | openforage_smart_contracts/src/VaultRegistry.sol:413; openforage_smart_contracts/src/VaultRegistry.sol:425; openforage_smart_contracts/src/VaultRegistry.sol:439; openforage_smart_contracts/src/VaultRegistry.sol:443 | Support rationale: Source trace: getActiveVaults loops over _allVaultIds and allocates a dynamic result, while getAllVaults returns the full dynamic array. |
| W-6 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| W-7 | openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:233; openforage_smart_contracts/src/ForageToken.sol:246; openforage_smart_contracts/src/ForageToken.sol:251; openforage_smart_contracts/src/ForageToken.sol:273; openforage_smart_contracts/src/ForageToken.sol:396 | Support rationale: Trace: FORAGE token behavior is evaluated through delegation, approvals, transferFrom, lock/unlock accounting, and blocklisted transfer checks. |
