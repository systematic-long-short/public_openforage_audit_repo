# Cantina External Audit Triage - 2026-06-12

## Current snapshot status

This ledger preserves the June 12 Cantina triage as historical audit input. The current public snapshot includes remediations for accepted true positives, and the fixed behavior is proven by `openforage_smart_contracts/test/audit/external_2026_06_12/ExternalAudit20260612Repros.t.sol`. References below to the source under review describe the triage-time source, not a claim that the refreshed snapshot still carries the accepted issue.

## Skeptic disposition

This triage uses independent source trace before accepting any outside assertion. We rank wrongly dismissing a real vulnerability as FP as the gravest error because it can leave economic risk live. We rank wrongly accepting a non-issue or stale report as TP second because it wastes remediation attention and can obscure the live risk surface. This is priority ordering, not numeric scorecard.

Every FP below includes an explicit disagreement marker. Contract-scope verdicts cite triage-time `openforage_smart_contracts/src/` code rather than relying on external report text; the one documentation-scope verdict, `OPEN-97`, cites retained audit-document evidence instead.

### OPEN-69 — A ready accelerated guardian-seat rotation still installs the old successor after timelock retargets the precommitted successor

Severity: Medium
Verdict: TP
Rationale: GuardianModule.setPreCommittedSuccessor lets the timelock overwrite the live precommitted successor for a guardian-seat slot, but proposeAcceleratedRotation snapshots the successor into a Rotation only once and executeAcceleratedRotation later executes that stored successor without rechecking the current preCommittedSuccessor mapping. This confirms the stale accelerated guardian-seat successor issue in the triage-time source.
Damage: After four guardians approve an accelerated rotation, the timelock can retarget the precommit to a different successor, yet the already-ready operation still installs the old successor and transfers the current guardian's permissions to that stale address. The reproduced path leaves preCommittedSuccessor pointing at the replacement while activeSlotHolder and guardianPermissions move to the revoked successor.
Recommended fix: Re-read preCommittedSuccessor during executeAcceleratedRotation, or cancel/invalidate outstanding accelerated rotations when the timelock retargets a successor; add a regression proving a retargeted precommit prevents execution of the stale operation.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_acceleratedRotationExecutesRevokedSuccessorWithoutLiveRecheck
Citation: openforage_smart_contracts/src/GuardianModule.sol:332; openforage_smart_contracts/src/GuardianModule.sol:335; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:383; openforage_smart_contracts/src/GuardianModule.sol:466; openforage_smart_contracts/src/GuardianModule.sol:471; openforage_smart_contracts/src/GuardianModule.sol:472; openforage_smart_contracts/src/GuardianModule.sol:473
Support rationale: Source-to-sink trace: timelock precommit overwrite changes the live mapping, but accelerated proposal snapshots the old successor, execution trusts the stored Rotation, and guardian-seat replacement transfers permissions to that stale successor.

### OPEN-70 — Tier loss socialization is not atomically coupled to RISKUSDVault settlement

Severity: Informational
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Tier loss socialization is not atomically coupled to RISKUSDVault settlement” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### OPEN-71 — Registry bridge cutover can strand reconciled return liquidity on the retired HyperLiquid bridge

Severity: Medium
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Registry bridge cutover can strand reconciled return liquidity on the retired HyperLiquid bridge” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### OPEN-72 — NAV posted after arrival reconciliation but before principal settlement double-subtracts the same returned cash

Severity: Medium
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “NAV posted after arrival reconciliation but before principal settlement double-subtracts the same returned cash” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### OPEN-73 — Treasury-created partnership wallets cannot be retrofitted or repaired with a blocklist after deployment

Severity: Medium
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Treasury-created partnership wallets cannot be retrofitted or repaired with a blocklist after deployment” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### OPEN-74 — Registry executor rotation never revokes the live HyperLiquid executor

Severity: Medium
Verdict: TP
Rationale: HLTradingBridge.initialize caches the launch executor in _custodianExecutor, and deployToHyperLiquid reaches _requireExecutor, which checks only that cached address. CustodianRegistry.setCustodianRole and _setCoreRoles mutate a separate ROLE_EXECUTOR map, so revoking the executor in the registry does not change the bridge's live executor check. This confirms “Registry executor rotation never revokes the live HyperLiquid executor” as the cached-executor divergence in the triage-time source.
Damage: An executor removed from CustodianRegistry can still move vault USDC through the bridge executor path until the bridge itself is upgraded or otherwise reconfigured. The reproduced path revokes ROLE_EXECUTOR in the registry and then uses the same address to deploy USDC to the cold account.
Recommended fix: Make bridge executor authorization consult CustodianRegistry ROLE_EXECUTOR at the point of use, or add an owner/governance-controlled bridge executor rotation that is atomically coupled to registry role changes; add a regression proving a revoked registry executor cannot call deploy/return paths.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_revokedRegistryExecutorStillControlsBridgeCachedExecutor
Overlap root cause: HyperLiquid cached executor authority
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586
Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor.

### OPEN-75 — Deploy script wires USDCTreasury as an unusable RISKUSDVault lossReporter

Severity: High
Verdict: TP
Rationale: RISKUSDVault loss settlement is restricted to the configured _lossReporter: burnForLoss, coverAndBurnForLoss, and replenish all require msg.sender == _lossReporter. Deploy.s.sol initializes RISKUSDVault with deployedUSDCTreasury as that lossReporter, but USDCTreasury exposes PnL recognition, principal-return recording, and PnL-return paths, not a burnForLoss, coverAndBurnForLoss, or replenish wrapper. This confirms the loss-settlement wiring root cause in the triage-time source.
Damage: The deployed lossReporter address cannot drive the vault's loss-settlement entrypoints, so the intended end-to-end loss burn/replenish workflow is unavailable without an additional upgrade or manual role change. The reproduced path wires USDCTreasury as lossReporter, shows direct vault burnForLoss is reporter-gated, and shows USDCTreasury has no burnForLoss wrapper.
Recommended fix: Wire lossReporter to a contract that implements the vault settlement workflow, or add explicit USDCTreasury wrappers for burnForLoss, coverAndBurnForLoss, and replenish with the correct authorization and token flows; add deployment assertions for those selectors.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_lossReporterWiredToUSDCTreasuryHasNoSettlementWrapper
Overlap root cause: loss settlement wiring
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176
Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors.

### OPEN-76 — HLTradingBridge cannot execute the vault's nonce-bound loss workflow in production

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “HLTradingBridge cannot execute the vault's nonce-bound loss workflow in production” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### OPEN-77 — Direct timelock execution lets the timelock grant itself PROPOSER_ROLE

Severity: Low
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “Direct timelock execution lets the timelock grant itself PROPOSER_ROLE” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### OPEN-78 — Real bridge losses are globally unbound, so one vault shortfall freezes every vault and burns can be booked against any vaultId

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Real bridge losses are globally unbound, so one vault shortfall freezes every vault and burns can be booked against any vaultId” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### OPEN-79 — Deployed bridge/treasury wiring leaves no reachable end-to-end loss-settlement path

Severity: High
Verdict: TP
Rationale: RISKUSDVault loss settlement is restricted to the configured _lossReporter: burnForLoss, coverAndBurnForLoss, and replenish all require msg.sender == _lossReporter. Deploy.s.sol initializes RISKUSDVault with deployedUSDCTreasury as that lossReporter, but USDCTreasury exposes PnL recognition, principal-return recording, and PnL-return paths, not a burnForLoss, coverAndBurnForLoss, or replenish wrapper. This confirms the loss-settlement wiring root cause in the triage-time source.
Damage: The deployed lossReporter address cannot drive the vault's loss-settlement entrypoints, so the intended end-to-end loss burn/replenish workflow is unavailable without an additional upgrade or manual role change. The reproduced path wires USDCTreasury as lossReporter, shows direct vault burnForLoss is reporter-gated, and shows USDCTreasury has no burnForLoss wrapper.
Recommended fix: Wire lossReporter to a contract that implements the vault settlement workflow, or add explicit USDCTreasury wrappers for burnForLoss, coverAndBurnForLoss, and replenish with the correct authorization and token flows; add deployment assertions for those selectors.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_lossReporterWiredToUSDCTreasuryHasNoSettlementWrapper
Overlap root cause: loss settlement wiring
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176
Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors.

### OPEN-80 — Partnership vesting wallets are shipped without any live blocklist path, so blocked beneficiaries can re-route up to 40M FORAGE votes after screening

Severity: High
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Partnership vesting wallets are shipped without any live blocklist path, so blocked beneficiaries can re-route up to 40M FORAGE votes after screening” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### OPEN-81 — retryForageUnlock can spend a stale entry's lock budget to unlock later priority entries

Severity: Medium
Verdict: TP
Rationale: StakingQueue.joinQueue records a priority entry's per-entry FORAGE lock, and processQueue can leave that per-entry amount nonzero when the queue's call to ForageToken.unlock fails. retryForageUnlock later accepts any processed/cancelled entry and applies that stale per-entry amount to the depositor's current aggregate queue locker balance. If the old token-side lock was cleared while the stale queue record remains, a newer priority entry's live FORAGE lock can be consumed while the newer entry still stays priority=true with a nonzero per-entry lock record.
Damage: A depositor can retain priority-lane treatment for a later queue entry after the live FORAGE backing for that entry has been unlocked by retrying a stale processed entry. The reproduced path processes an old priority entry during queue deauthorization, clears the stale token lock by emergency unlock, creates a fresh priority entry, then calls retryForageUnlock on the old ID and drains the fresh token-side lock.
Recommended fix: Bind retryForageUnlock to the specific entry's still-live token-side lock, or mark the queue entry's lock state as unrecoverable once an owner emergency unlock clears the aggregate locker balance; add a regression that a stale queue ID cannot reduce a newer priority entry's locker balance.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_retryForageUnlockSpendsStaleEntryAgainstNewPriorityLock
Citation: openforage_smart_contracts/src/StakingQueue.sol:352; openforage_smart_contracts/src/StakingQueue.sol:484; openforage_smart_contracts/src/StakingQueue.sol:486; openforage_smart_contracts/src/StakingQueue.sol:1090; openforage_smart_contracts/src/StakingQueue.sol:1094; openforage_smart_contracts/src/StakingQueue.sol:1108; openforage_smart_contracts/src/ForageToken.sol:332
Support rationale: Source-to-sink trace: joinQueue records the per-entry FORAGE lock, processQueue can leave the stale amount retryable after unlock failure, emergencyUnlock clears the aggregate token lock, and retryForageUnlock then spends the depositor's current queue locker balance for the stale ID.

### OPEN-82 — Genesis wiring never connects `RISKUSD`, `RISKUSDVault`, `StakingQueue`, or `atRISKUSD` to the governor/guardian pause graph

Severity: Medium
Verdict: TP
Rationale: The pause fast path on RISKUSD, RISKUSDVault, StakingQueue, and atRISKUSD depends on each target resolving a nonzero forageGovernor and then checking that governor's guardianModule. With forageGovernor unset, _isGuardianModule returns false, so a GuardianModule call into pause is rejected even though the deployment flow can register these contracts as pausable targets. This confirms the genesis pause-graph wiring issue against the triage-time source.
Damage: Guardian emergency pause cannot reach the affected core contracts until the governor pointer is set and finalized on each target. In the reproduced triage-time-code path, a guardian-module-like caller cannot pause RISKUSD, RISKUSDVault, StakingQueue, or atRISKUSD while forageGovernor remains address(0); only the owner/timelock path remains.
Recommended fix: Set and finalize forageGovernor on every governor-dependent pause target before registering or relying on guardian pause protection, and add deployment assertions that each protected target reports the deployed governor before handoff.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_unwiredGovernorBlocksGuardianPauseFastPath
Citation: openforage_smart_contracts/src/RISKUSD.sol:178; openforage_smart_contracts/src/RISKUSD.sol:193; openforage_smart_contracts/src/RISKUSD.sol:204; openforage_smart_contracts/src/RISKUSDVault.sol:1002; openforage_smart_contracts/src/RISKUSDVault.sol:1035; openforage_smart_contracts/src/StakingQueue.sol:1118; openforage_smart_contracts/src/StakingQueue.sol:1150; openforage_smart_contracts/src/atRISKUSD.sol:696; openforage_smart_contracts/src/atRISKUSD.sol:746; openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:180
Support rationale: Source-to-sink trace: GuardianModule.guardianPause calls target.pause, and the target pause functions accept the guardian module only through a nonzero finalized forageGovernor; when that pointer is unset, the guardian fast path is unreachable.

### OPEN-83 — Accelerated guardian-seat rotations stay executable after successor revocation

Severity: Medium
Verdict: TP
Rationale: GuardianModule checks preCommittedSuccessor only when proposeAcceleratedRotation is called. Once that operation exists and receives enough approvals, executeAcceleratedRotation uses the stored Rotation successor and never verifies that the successor is still the live precommit for the slot/current pair. This confirms that accelerated guardian-seat rotations stay executable after successor revocation or replacement.
Damage: A successor that timelock governance has replaced can still be installed as the active guardian-seat holder after the accelerated approval floor elapses. The reproduced path transfers guardian permissions to the revoked successor while the live precommit maps the old guardian to a different replacement.
Recommended fix: Revalidate the stored successor against preCommittedSuccessor immediately before marking the rotation executed, and clear or supersede pending accelerated rotations when setPreCommittedSuccessor retargets the same slot/current pair.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_acceleratedRotationExecutesRevokedSuccessorWithoutLiveRecheck
Citation: openforage_smart_contracts/src/GuardianModule.sol:332; openforage_smart_contracts/src/GuardianModule.sol:335; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:383; openforage_smart_contracts/src/GuardianModule.sol:466; openforage_smart_contracts/src/GuardianModule.sol:471; openforage_smart_contracts/src/GuardianModule.sol:472; openforage_smart_contracts/src/GuardianModule.sol:473
Support rationale: Source-to-sink trace: successor revocation updates preCommittedSuccessor, but the ready accelerated Rotation keeps the old successor and executeAcceleratedRotation installs it without a live mapping check.

### OPEN-84 — Partnership vesting wallets never wire a blocklist, allowing blocked beneficiaries to recover unvested governance power through unblocked mules

Severity: High
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Partnership vesting wallets never wire a blocklist, allowing blocked beneficiaries to recover unvested governance power through unblocked mules” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### OPEN-85 — Live zero-nonce loss burns never notify VaultRegistry, so the real bridge path skips the same-block loss-resolution cooldown

Severity: Low
Verdict: FP
Rationale: The live bridge path moves USDC only through deployToHyperLiquid, postNAV, and returnPnLUSDC, with executor/keeper checks, blocklist checks, caps, and registry accounting. The asserted path was traced through those functions and no unsupported value movement or accounting branch matching the finding was found. This row is specific to “Live zero-nonce loss burns never notify VaultRegistry, so the real bridge path skips the same-block loss-resolution cooldown” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612
Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks.

### OPEN-86 — One directly executed proposal can schedule and execute arbitrary unscheduled payloads in the same transaction

Severity: Medium
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “One directly executed proposal can schedule and execute arbitrary unscheduled payloads in the same transaction” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### OPEN-87 — Direct timelock execution bypasses ForageGovernor's 1-day delay floor

Severity: High
Verdict: FP
Rationale: The live governance path was traced through proposal creation, cancellation validation, quorum/threshold calculation, timelock update, and execution. The triage-time code does not provide the bypass or uncancellable governance path asserted by this finding. This row is specific to “Direct timelock execution bypasses ForageGovernor's 1-day delay floor” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474
Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations.

### OPEN-88 — DeployMainnet hands off ownership before wiring governor-based emergency pause into the core vault/token stack

Severity: Informational
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “DeployMainnet hands off ownership before wiring governor-based emergency pause into the core vault/token stack” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### OPEN-89 — Blocklisted FORAGE holders keep full governance power through pre-arranged unblocked delegates

Severity: Medium
Verdict: TP
Rationale: ForageToken.delegate checks the holder and delegatee only when delegation is set, and ForageToken._update enforces the blocklist on later token movement. There is no current hook that clears or discounts an already-established delegate's votes when the original holder is blocklisted, so delegated voting power can remain live after the holder is blocked.
Damage: A holder can delegate before being blocklisted and the delegatee keeps the holder's voting power after the block. The reproduced path delegates 100 FORAGE votes to an unblocked delegatee, blocks the holder, and shows getVotes(delegatee) remains 100 FORAGE.
Recommended fix: On blocklist changes, clear or neutralize delegated voting power from blocked holders, or make governor vote/proposal accounting discount voting units sourced from blocked accounts; add a regression for pre-block delegation persistence.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_blockedHolderKeepsVotesThroughPrearrangedDelegate
Overlap root cause: blocked holder delegated voting persistence
Citation: openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410
Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked.

### OPEN-90 — Rotating the guardian module permanently severs guardian emergency control over HLTradingBridge

Severity: Medium
Verdict: TP
Rationale: HLTradingBridge stores guardianModule during initialize and later authorizes pause/freeze/cap controls by comparing msg.sender to that stored address. ForageGovernor has an independent setGuardianModule path, so rotating the governor's guardian module does not update the already-deployed bridge's cached guardianModule. This confirms the static guardian-module binding root cause in the triage-time source.
Damage: After a guardian-module rotation, the new module cannot use bridge emergency controls while the old cached module can still call them until the bridge itself is upgraded or reconfigured. The reproduced path shows a new module address cannot setDirectionalFreeze, while the old cached module still can.
Recommended fix: Make HLTradingBridge resolve the active guardian module dynamically from the governor, or add an explicit governed bridge guardian-module rotation coupled to ForageGovernor.setGuardianModule; add a regression proving the old module loses bridge authority after rotation.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_staticGuardianModuleBindingIgnoresGovernorRotation
Overlap root cause: guardian module static binding
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:185; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:347; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:469; openforage_smart_contracts/src/ForageGovernor.sol:345; openforage_smart_contracts/src/ForageGovernor.sol:349
Support rationale: Source-to-sink trace: the bridge caches guardianModule at initialization and checks that cached address for emergency controls, while the governor can rotate its guardianModule independently.

### OPEN-91 — Partnership vesting wallets never inherit the shared blocklist, letting blocked beneficiaries re-delegate up to 40M FORAGE

Severity: Medium
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Partnership vesting wallets never inherit the shared blocklist, letting blocked beneficiaries re-delegate up to 40M FORAGE” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### OPEN-92 — Global RISKUSD pause bricks atRISKUSD's advertised paused-withdrawal exit path

Severity: Medium
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Global RISKUSD pause bricks atRISKUSD's advertised paused-withdrawal exit path” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

### OPEN-93 — Queue entries keep priority after emergencyUnlock removes their FORAGE backing

Severity: Low
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Queue entries keep priority after emergencyUnlock removes their FORAGE backing” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### OPEN-94 — Partnership vesting wallets are permanently blocklist-less, letting blocked beneficiaries reroute unvested FORAGE votes to unblocked governance delegates

Severity: High
Verdict: TP
Rationale: FORAGETreasury.distributePartnership checks the beneficiary and delegatee before child-wallet creation, but then deploys a fresh DelegatingVestingWallet and immediately calls setForageToken without ever calling setBlocklist. DelegatingVestingWallet.setForageToken clears _tokenSetter, while release and delegateVotingPower consult _requireNotBlocked only against the child wallet's own _blocklist; when that value is unset, the blocklist check is a no-op. This confirms “Partnership vesting wallets are permanently blocklist-less, letting blocked beneficiaries reroute unvested FORAGE votes to unblocked governance delegates” as the shared partnership-wallet blocklist issue in the triage-time source.
Damage: A beneficiary screened at wallet creation can later become blocklisted and still release vested FORAGE and retain or redirect voting power from the blocklist-less child wallet. The reproduced path releases tokens to a now-blocklisted beneficiary after the treasury blocklist blocks that address.
Recommended fix: Pass the treasury blocklist into the DelegatingVestingWallet constructor or set it before burning the wallet's setter authority, and add a regression test that blocks the beneficiary after distribution and proves release/delegation reverts.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_partnershipWalletHasNoRetrofittedBlocklistAfterBeneficiaryBlocked
Overlap root cause: partnership blocklist vesting wallet authority
Citation: openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278
Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset.

### OPEN-95 — Routine guardian-seat rotation never changes the guardian set, leaving compromised guardians active after governance “finalization”

Severity: Medium
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Routine guardian-seat rotation never changes the guardian set, leaving compromised guardians active after governance “finalization”” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### OPEN-96 — Accelerated guardian rotation accepts the default zero successor and irreversibly burns honest seats

Severity: Low
Verdict: FP
Rationale: The live guardian path was traced through pause/cancel authority, accelerated and routine rotation entrypoints, and emergency calldata validation. The triage-time implementation constrains the relevant authority path rather than exposing the direct or stale operation assumed by the finding. This row is specific to “Accelerated guardian rotation accepts the default zero successor and irreversibly burns honest seats” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516
Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation.

### OPEN-97 — Supplemental audit docs publish internal Codex thread IDs, task IDs, and prompt/skill metadata

Severity: Informational
Verdict: TP
Rationale: This is a documentation-scope true positive. The retained supplemental audit markdown publishes opaque internal review provenance and prompt-basis metadata in public audit evidence files. The exposed values are not secrets and do not create an on-chain exploit path, but the finding is live because the retained documents still contain the provenance class described by the raw report.
Damage: Informational disclosure only. The leaked values are opaque review provenance rather than credentials or executable authority, so no direct fund loss or contract-control path is accepted; the damage is public disclosure of internal audit workflow metadata that the report says should be redacted from public review documents.
Recommended fix: Redact exact internal review identifiers and prompt-basis metadata from public supplemental audit markdown, replace them with sanitized public provenance such as review date/role/verdict, and add an export-content scan for this provenance class before publishing audit evidence.
Citation: documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md:5; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md:7; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md:5; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md:7; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md:3; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md:24
Support rationale: Documentation trace: retained supplemental audit evidence contains internal review identifiers and prompt-basis metadata, matching the raw OPEN-97 documentation-leak claim; severity remains Informational because the values are opaque provenance, not credentials or an exploitable control surface.

### OPEN-98 — Blocked balances remain fully votable through pre-blocklist delegates

Severity: High
Verdict: TP
Rationale: ForageToken.delegate checks the holder and delegatee only when delegation is set, and ForageToken._update enforces the blocklist on later token movement. There is no current hook that clears or discounts an already-established delegate's votes when the original holder is blocklisted, so delegated voting power can remain live after the holder is blocked.
Damage: A holder can delegate before being blocklisted and the delegatee keeps the holder's voting power after the block. The reproduced path delegates 100 FORAGE votes to an unblocked delegatee, blocks the holder, and shows getVotes(delegatee) remains 100 FORAGE.
Recommended fix: On blocklist changes, clear or neutralize delegated voting power from blocked holders, or make governor vote/proposal accounting discount voting units sourced from blocked accounts; add a regression for pre-block delegation persistence.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_blockedHolderKeepsVotesThroughPrearrangedDelegate
Overlap root cause: blocked holder delegated voting persistence
Citation: openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410
Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked.

### OPEN-99 — Expired opt-out tier holders can evade Tier-0 reversion indefinitely by rolling a dust pending withdrawal

Severity: High
Verdict: FP
Rationale: The live tier-vault path was traced through deposit, withdraw, redeem, loss absorption, withdrawal requests, no-loss gating, and weekly cap enforcement. The triage-time implementation does not expose the stale-share, loss-gate, or withdrawal bypass asserted by this finding. This row is specific to “Expired opt-out tier holders can evade Tier-0 reversion indefinitely by rolling a dust pending withdrawal” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195
Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement.

### OPEN-100 — Daily redemption cap can be permanently poisoned by an obsolete high-supply snapshot

Severity: Medium
Verdict: FP
Rationale: The live vault path was traced through deposit, redeem, attested-loss finalization, weekly/daily cap enforcement, and deployment-buffer enforcement. The triage-time code does not expose the unguarded settlement, cap, or loss-accounting path alleged by this finding. This row is specific to “Daily redemption cap can be permanently poisoned by an obsolete high-supply snapshot” and was rejected only after following the triage-time source surface named below.
Damage: No triage-time-code damage is accepted for this finding because the traced source-to-sink path does not reach the external report's claimed exploit condition in the triage-time snapshot.
No-fix rationale: No contract change is recommended for this ID in this triage round; keep the cited guard surface under regression review if the surrounding code changes.
Disagreement: The external report treats this issue as live, but the cited triage-time source path does not support the reported exploit path for this ID.
Citation: openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614
Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks.

### OPEN-101 — Revoked registry executor keeps full deploy and return authority because HLTradingBridge ignores ROLE_EXECUTOR

Severity: High
Verdict: TP
Rationale: HLTradingBridge.initialize caches the launch executor in _custodianExecutor, and deployToHyperLiquid reaches _requireExecutor, which checks only that cached address. CustodianRegistry.setCustodianRole and _setCoreRoles mutate a separate ROLE_EXECUTOR map, so revoking the executor in the registry does not change the bridge's live executor check. This confirms “Revoked registry executor keeps full deploy and return authority because HLTradingBridge ignores ROLE_EXECUTOR” as the cached-executor divergence in the triage-time source.
Damage: An executor removed from CustodianRegistry can still move vault USDC through the bridge executor path until the bridge itself is upgraded or otherwise reconfigured. The reproduced path revokes ROLE_EXECUTOR in the registry and then uses the same address to deploy USDC to the cold account.
Recommended fix: Make bridge executor authorization consult CustodianRegistry ROLE_EXECUTOR at the point of use, or add an owner/governance-controlled bridge executor rotation that is atomically coupled to registry role changes; add a regression proving a revoked registry executor cannot call deploy/return paths.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_revokedRegistryExecutorStillControlsBridgeCachedExecutor
Overlap root cause: HyperLiquid cached executor authority
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586
Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor.

### OPEN-102 — Revoked HyperLiquid executors retain permanent bridge control because executor rotation is dead config

Severity: Medium
Verdict: TP
Rationale: HLTradingBridge.initialize caches the launch executor in _custodianExecutor, and deployToHyperLiquid reaches _requireExecutor, which checks only that cached address. CustodianRegistry.setCustodianRole and _setCoreRoles mutate a separate ROLE_EXECUTOR map, so revoking the executor in the registry does not change the bridge's live executor check. This confirms “Revoked HyperLiquid executors retain permanent bridge control because executor rotation is dead config” as the cached-executor divergence in the triage-time source.
Damage: An executor removed from CustodianRegistry can still move vault USDC through the bridge executor path until the bridge itself is upgraded or otherwise reconfigured. The reproduced path revokes ROLE_EXECUTOR in the registry and then uses the same address to deploy USDC to the cold account.
Recommended fix: Make bridge executor authorization consult CustodianRegistry ROLE_EXECUTOR at the point of use, or add an owner/governance-controlled bridge executor rotation that is atomically coupled to registry role changes; add a regression proving a revoked registry executor cannot call deploy/return paths.
Foundry repro: ExternalAudit20260612Repros.t.sol::test_revokedRegistryExecutorStillControlsBridgeCachedExecutor
Overlap root cause: HyperLiquid cached executor authority
Citation: openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586
Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor.

## Total citation support matrix

| ID | Citation | Support rationale |
|---|---|---|
| OPEN-69 | openforage_smart_contracts/src/GuardianModule.sol:332; openforage_smart_contracts/src/GuardianModule.sol:335; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:383; openforage_smart_contracts/src/GuardianModule.sol:466; openforage_smart_contracts/src/GuardianModule.sol:471; openforage_smart_contracts/src/GuardianModule.sol:472; openforage_smart_contracts/src/GuardianModule.sol:473 | Support rationale: Source-to-sink trace: timelock precommit overwrite changes the live mapping, but accelerated proposal snapshots the old successor, execution trusts the stored Rotation, and guardian-seat replacement transfers permissions to that stale successor. |
| OPEN-70 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| OPEN-71 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| OPEN-72 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| OPEN-73 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| OPEN-74 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586 | Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor. |
| OPEN-75 | openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176 | Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors. |
| OPEN-76 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| OPEN-77 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| OPEN-78 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| OPEN-79 | openforage_smart_contracts/src/RISKUSDVault.sol:521; openforage_smart_contracts/src/RISKUSDVault.sol:525; openforage_smart_contracts/src/RISKUSDVault.sol:532; openforage_smart_contracts/src/RISKUSDVault.sol:589; openforage_smart_contracts/script/Deploy.s.sol:533; openforage_smart_contracts/script/Deploy.s.sol:536; openforage_smart_contracts/script/Deploy.s.sol:537; openforage_smart_contracts/src/USDCTreasury.sol:145; openforage_smart_contracts/src/USDCTreasury.sol:165; openforage_smart_contracts/src/USDCTreasury.sol:176 | Support rationale: Source-to-sink trace: deployment wires USDCTreasury as RISKUSDVault lossReporter, the vault accepts settlement only from that reporter, and USDCTreasury lacks the required loss-settlement wrapper selectors. |
| OPEN-80 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| OPEN-81 | openforage_smart_contracts/src/StakingQueue.sol:352; openforage_smart_contracts/src/StakingQueue.sol:484; openforage_smart_contracts/src/StakingQueue.sol:486; openforage_smart_contracts/src/StakingQueue.sol:1090; openforage_smart_contracts/src/StakingQueue.sol:1094; openforage_smart_contracts/src/StakingQueue.sol:1108; openforage_smart_contracts/src/ForageToken.sol:332 | Support rationale: Source-to-sink trace: joinQueue records the per-entry FORAGE lock, processQueue can leave the stale amount retryable after unlock failure, emergencyUnlock clears the aggregate token lock, and retryForageUnlock then spends the depositor's current queue locker balance for the stale ID. |
| OPEN-82 | openforage_smart_contracts/src/RISKUSD.sol:178; openforage_smart_contracts/src/RISKUSD.sol:193; openforage_smart_contracts/src/RISKUSD.sol:204; openforage_smart_contracts/src/RISKUSDVault.sol:1002; openforage_smart_contracts/src/RISKUSDVault.sol:1035; openforage_smart_contracts/src/StakingQueue.sol:1118; openforage_smart_contracts/src/StakingQueue.sol:1150; openforage_smart_contracts/src/atRISKUSD.sol:696; openforage_smart_contracts/src/atRISKUSD.sol:746; openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:180 | Support rationale: Source-to-sink trace: GuardianModule.guardianPause calls target.pause, and the target pause functions accept the guardian module only through a nonzero finalized forageGovernor; when that pointer is unset, the guardian fast path is unreachable. |
| OPEN-83 | openforage_smart_contracts/src/GuardianModule.sol:332; openforage_smart_contracts/src/GuardianModule.sol:335; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:343; openforage_smart_contracts/src/GuardianModule.sol:344; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:382; openforage_smart_contracts/src/GuardianModule.sol:383; openforage_smart_contracts/src/GuardianModule.sol:466; openforage_smart_contracts/src/GuardianModule.sol:471; openforage_smart_contracts/src/GuardianModule.sol:472; openforage_smart_contracts/src/GuardianModule.sol:473 | Support rationale: Source-to-sink trace: successor revocation updates preCommittedSuccessor, but the ready accelerated Rotation keeps the old successor and executeAcceleratedRotation installs it without a live mapping check. |
| OPEN-84 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| OPEN-85 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:221; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:274; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:593; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:612 | Support rationale: Trace: bridge value movement and NAV/PnL reporting are checked through deployToHyperLiquid, postNAV, returnPnLUSDC, cap enforcement, and registry accounting hooks. |
| OPEN-86 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| OPEN-87 | openforage_smart_contracts/src/ForageGovernor.sol:190; openforage_smart_contracts/src/ForageGovernor.sol:251; openforage_smart_contracts/src/ForageGovernor.sol:265; openforage_smart_contracts/src/ForageGovernor.sol:381; openforage_smart_contracts/src/ForageGovernor.sol:444; openforage_smart_contracts/src/ForageGovernor.sol:474 | Support rationale: Trace: governance behavior is evaluated through propose, cancel validation, quorum/threshold, timelock update, and execution operations. |
| OPEN-88 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| OPEN-89 | openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410 | Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked. |
| OPEN-90 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:185; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:347; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:469; openforage_smart_contracts/src/ForageGovernor.sol:345; openforage_smart_contracts/src/ForageGovernor.sol:349 | Support rationale: Source-to-sink trace: the bridge caches guardianModule at initialization and checks that cached address for emergency controls, while the governor can rotate its guardianModule independently. |
| OPEN-91 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| OPEN-92 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| OPEN-93 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| OPEN-94 | openforage_smart_contracts/src/FORAGETreasury.sol:141; openforage_smart_contracts/src/FORAGETreasury.sol:154; openforage_smart_contracts/src/FORAGETreasury.sol:158; openforage_smart_contracts/src/DelegatingVestingWallet.sol:82; openforage_smart_contracts/src/DelegatingVestingWallet.sol:125; openforage_smart_contracts/src/DelegatingVestingWallet.sol:140; openforage_smart_contracts/src/DelegatingVestingWallet.sol:278 | Support rationale: Source-to-sink trace: treasury screens before deployment, creates the wallet, sets the token, burns setter authority, then the wallet's release/delegation blocklist guard silently succeeds when _blocklist is unset. |
| OPEN-95 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| OPEN-96 | openforage_smart_contracts/src/GuardianModule.sol:165; openforage_smart_contracts/src/GuardianModule.sol:187; openforage_smart_contracts/src/GuardianModule.sol:341; openforage_smart_contracts/src/GuardianModule.sol:377; openforage_smart_contracts/src/GuardianModule.sol:389; openforage_smart_contracts/src/GuardianModule.sol:516 | Support rationale: Trace: guardian authority is evaluated through guardianPause, guardianCancel, accelerated/routine rotation entrypoints, and emergency calldata validation. |
| OPEN-97 | documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md:5; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/pashov-supplement.md:7; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md:5; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/nemesis-supplement.md:7; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md:3; documentation/smart_contract_audits/2026-06-09-audit/openforage-smart-contract-audit/codex-review.md:24 | Support rationale: Documentation trace: retained supplemental audit evidence contains internal review identifiers and prompt-basis metadata, matching the raw OPEN-97 documentation-leak claim. |
| OPEN-98 | openforage_smart_contracts/src/ForageToken.sol:118; openforage_smart_contracts/src/ForageToken.sol:120; openforage_smart_contracts/src/ForageToken.sol:385; openforage_smart_contracts/src/ForageToken.sol:396; openforage_smart_contracts/src/ForageToken.sol:410 | Support rationale: Source-to-sink trace: delegation checks blocklist only at delegation time, token movement checks blocklist later, and no triage-time path removes the existing delegatee votes when the holder is subsequently blocked. |
| OPEN-99 | openforage_smart_contracts/src/atRISKUSD.sol:196; openforage_smart_contracts/src/atRISKUSD.sol:246; openforage_smart_contracts/src/atRISKUSD.sol:268; openforage_smart_contracts/src/atRISKUSD.sol:347; openforage_smart_contracts/src/atRISKUSD.sol:372; openforage_smart_contracts/src/atRISKUSD.sol:1005; openforage_smart_contracts/src/atRISKUSD.sol:1195 | Support rationale: Trace: tier-vault behavior is evaluated through deposit/withdraw/redeem, absorbLoss, requestWithdrawal, no-loss gating, and weekly cap enforcement. |
| OPEN-100 | openforage_smart_contracts/src/RISKUSDVault.sol:323; openforage_smart_contracts/src/RISKUSDVault.sol:353; openforage_smart_contracts/src/RISKUSDVault.sol:606; openforage_smart_contracts/src/RISKUSDVault.sol:1468; openforage_smart_contracts/src/RISKUSDVault.sol:1496; openforage_smart_contracts/src/RISKUSDVault.sol:1614 | Support rationale: Trace: vault mint/redeem/loss/cap behavior is evaluated through deposit, redeem, finalizeAttestedLoss, weekly/daily cap enforcement, and deployment-buffer checks. |
| OPEN-101 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586 | Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor. |
| OPEN-102 | openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:190; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:200; openforage_smart_contracts/src/hyperliquid/HLTradingBridge.sol:670; openforage_smart_contracts/src/CustodianRegistry.sol:293; openforage_smart_contracts/src/CustodianRegistry.sol:586 | Support rationale: Source-to-sink trace: registry role revocation writes ROLE_EXECUTOR false, but bridge deploy authority still checks only the initialization-time _custodianExecutor. |
