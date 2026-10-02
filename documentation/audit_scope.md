# Audit scope

## Candidate and source map

This candidate is based on the previous PR #9 head `01f4abe7768f03d2a21e6ab0a0221795d315d79b`, the base of this update. The parent `6efd4cd86a9b2fec7f484c0da073f71385900308` and older commits are historical. If committed, the public candidate will have one parent, `01f4abe7768f03d2a21e6ab0a0221795d315d79b`. This review does not update the remote branch or PR.

The direct map contains 61 files: 35 production source, interface, library, and module files; 18 ABI artifacts; and 8 selected deployment-script and interface files. It explicitly includes `GuardianAuthorityClassifier.sol` and `IRISKUSDSettlement.sol`. The exact private source inventory contains no unmapped first-party source, interface, library, module, or ABI path. Every mapped byte is checked against the exact source. The two root Gitlinks and all nine recursive pins stay unchanged.

Only the eight selected script/interface paths in the explicit map are copied. All other private scripts and tools, audit records, packet text, run logs, credentials, deployment records, and unlisted paths remain excluded. No first-party contract test path is copied.

## Finding scope and review status

The historical record preserves all 155 Analysis 1–8 identities and their original counts. Warning 28 keeps its dated missing-capture gap. Analysis 9 has 21 findings and 11 related cases; see its [source dispositions](smart_contract_audits/2026-09-29-analysis-9-dispositions.md). Analysis 10 has 17 findings and one related case; see its [source dispositions](smart_contract_audits/2026-09-30-analysis-10-dispositions.md). Analysis 11 has 11 findings and three related cases; see its [source dispositions](smart_contract_audits/2026-10-01-analysis-11-dispositions.md). The [whole-source pre-scan review](smart_contract_audits/2026-10-02-pre-scan-review.md) records rounds 1–10 and the declared limits. Analysis 9 acknowledgements remain `Other`; no finding is marked resolved.

The Analysis 10 record says A10-17 remains open and whole-call gas fit remains unmeasured. The Treasury helper-readiness guard is accepted only as a bounded source correction; A9-02 is not fully closed. A9-03 remains bounded to net-basis accounting. Its related case is bounded at source level: ordinary redemption no longer refunds active-window public mint use. A redeemed position can leave daily or weekly mint headroom occupied until the window resets; no fairness guarantee is claimed. A9-06 remains open on cross-tier fairness and collectibility. A9-09 is accepted only for cash-backed pricing. A9-10 and A9-14 are bounded to fresh-state settlement and exact-nonce paths. A9-19 and A9-20 remain bounded source findings, not live-state proof. A9-21 whole-query gas remains unmeasured. A11-01 remains open because repeated address rotation can refill the bounded ordinary proposal cap and a Succeeded-but-unqueued proposal lacks expiry; A11-10 remains an open warning with no whole-call gas result. A11-04's latest bounded review includes remembered-wallet handoff continuity after candidate-first declassification. A11-05 is limited to selector-only classification of the retired Registry routes; the separate absent/already-expired rotation predicate and A10-04 CANCELLER preflight boundary are not part of that UUID. No legacy-proxy, deployment, or current Octane closure is claimed.

The earlier 72-row table retains 28 Queue and 44 Token triage items; all 72 independent-review statuses remain pending. The separate public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row pins its source lines to a candidate-file blob. The previous PR #9 head and base of this update is `01f4abe7768f03d2a21e6ab0a0221795d315d79b`; `6efd4cd86a9b2fec7f484c0da073f71385900308`, `ef049358efb6496f8304faef11a99c34d2610e62`, and older commits are historical. Forty rows have bounded source-only review and seven remain pending. `SL-28` still needs a current `RISKUSDVault.sol` source rebind. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, suppression reconciliation is in progress, and the scanner-coverage gap remains open.

## Policy boundaries

- Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported.
- The first upgrade is authorized by the implementation already installed. A source guard in the new implementation cannot prove the first upgrade path.
- The Blocklist's legacy importer and interval-translation path are removed. Fresh initialization establishes its layout version, and each state-changing entrypoint requires that version before effects. The historical lookup uses checkpoint-only `wasBlockedAt`; the retained pre-checkpoint mapping is inert layout storage. An independent source review accepts this fresh-only repair at source level only; it proves no deployed or old-proxy state.
- Holders at recognition own profit. Unpaid profit remains a separate claim and is payable only after cash arrives.
- Withdrawal share pricing uses cash-backed value. Withdrawals pay available cash only and promise no payment date.
- A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid it stay frozen through settlement.
- Loss settlement uses the configured keeper and existing checked return path. Reserve-covered loss does not use the depositor-tier loss-rate cap.
- Fractional fee remainders carry across payments. Queue demotion keeps its original ID and standard-queue position.
- One designated Guardian keeps one proposal slot under ordinary voting and timelock controls. It cannot veto its own authority change.
- Only automatic expiry return from a higher tier is exempt from the Tier 0 admission cap. New admissions and manual reversions remain capped.
- External vesting recipients need renewable approval and remain registered. Payment grants no system-account status.
- The distributor is the trusted payer, not the recipient. A recipient gains no restricted-call permission.
- Two Windows CLI rows remain failed. No Visual Studio license or toolchain was installed, purchased, or accepted.

These policy choices do not prove that every path follows them. The disposition record lists the source paths and remaining evidence gaps.

## Build, ABI, storage, and proof limits

Forge 1.3.5 and Solc 0.8.24 compiled 132 public inputs in each profile with zero compiler errors. Default code generation completed; its size child exited 1 with EIP-170 runtime overages: ForageGovernor 28,436 bytes (3,860 over); StakingQueue 27,439 bytes (2,863 over); USDCTreasury 27,905 bytes (3,329 over); EIP-3860 initcode overages: none. Deploy exited 0 and all 22 first-party contract runtime/initcode pairs fit. The table lists all 26 compiled contract/library artifacts. GuardianModule links GuardianAuthorityClassifier; ForageGovernorTimelockGuard links ForageGovernorTimelockMigrationGuard. GuardianAuthorityClassifier is 8,994/9,047 bytes in Default and 7,735/7,768 in Deploy; ForageGovernorTimelockMigrationGuard is 3,976/4,029 bytes in Default and 3,337/3,368 in Deploy.

All 18 ABI files match the mapped source; 17 have compiler source definitions and `FoundationTreasury.json` remains source-less. The latest recorded source-matched storage comparison is red at 17 OK and 7 historical divergences; no baseline changed, and no fresh public storage check ran in this update.

No fresh full `audit-static` pass is established for this public materialization. The public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither; 40 have bounded source-only review and seven remain pending. All independent reviews in the earlier 72-row table remain pending. Retained Slither and Semgrep results are red, suppression reconciliation is in progress, and the scanner-coverage gap remains open. A copied-source control for the Guardian Registry selector set remains incomplete; that gap does not show the current Solidity contains the retired branch. Two Windows CLI rows remain failed. No first-party test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No live-proxy or deployed-state claim is made.
