# Audit scope

## Candidate and source map

This candidate is based on the previous PR #9 head `ef049358efb6496f8304faef11a99c34d2610e62`, the base of this update. The earlier commit `fbcdda4fc95adc6d345786787ce4ea7557df86a4` is the historical parent of that head. If committed, the public candidate will have one parent, `ef049358efb6496f8304faef11a99c34d2610e62`. This review does not update the remote branch or PR.

The direct map contains 59 files: 33 production source, interface, and module files; 18 ABI artifacts; and 8 selected deployment-script and interface files. The exact private source inventory contains no unmapped first-party source, interface, module, or ABI path; the three previously added sources remain explicitly mapped. Every mapped byte is checked against the exact source. The two root Gitlinks and all nine recursive pins stay unchanged.

Only the eight selected script/interface paths in the explicit map are copied. All other private scripts and tools, audit records, packet text, run logs, credentials, deployment records, and unlisted paths remain excluded. No first-party contract test path is copied.

## Finding scope and review status

The historical record preserves all 155 analysis 1–8 identities and their original counts. Warning 28 keeps its dated missing-capture gap. Analysis 9 has 21 findings and 11 related cases; see its [source dispositions](smart_contract_audits/2026-09-29-analysis-9-dispositions.md). Analysis 10 has 17 findings and the related case under A10-11; see its [source dispositions](smart_contract_audits/2026-09-30-analysis-10-dispositions.md). Analysis 9 acknowledgements remain `Other`; no finding is marked resolved.

The Analysis 10 dispositions also record their latest source reviews; A10-17 remains an open liveness warning. The latest source reviews accept the Treasury helper-readiness guard only as a bounded source correction; A9-02 is not fully closed. A9-03 remains `ACCEPT_BOUNDED` for net-basis accounting. Its related case is `ACCEPT_BOUNDED` at source level: ordinary redemption no longer refunds active-window public mint use. A redeemed position can leave shared daily/weekly mint headroom occupied until the corresponding active window resets; no fairness or risk-acceptance guarantee is claimed. A9-06 is bounded but cross-tier fairness and collectibility remain open. A9-09 is accepted only for cash-backed pricing. A9-10 and A9-14 are bounded to the reviewed fresh-state settlement and exact-nonce paths. A9-19 and A9-20 remain bounded source findings, not live-state proof. A9-21 whole-query gas remains unmeasured. No legacy-proxy, deployment, or current Octane proof exists.

The earlier 72-row table retains 28 Queue and 44 Token triage items; all 72 independent-review statuses remain pending. The separate public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row names each cited candidate file's Git blob SHA-1, which identifies the exact file bytes in this candidate tree; `ef049358efb6496f8304faef11a99c34d2610e62` is the previous PR #9 head and base of this update, not the source of these lines. Forty rows have bounded source-only review and seven remain pending. `SL-28` still needs a current `RISKUSDVault.sol` source rebind. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open.

## Policy boundaries

- Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported.
- The first upgrade is authorized by the implementation already installed. A source guard in the new implementation cannot prove the first upgrade path.
- The Blocklist's legacy importer and interval-translation path are removed. Fresh initialization establishes its layout version, and each state-changing entrypoint requires that version before effects. The historical lookup uses checkpoint-only `wasBlockedAt`; the retained pre-checkpoint mapping is inert layout storage. Completed review 0645 accepts this fresh-only source repair at source level only; it proves no deployed or old-proxy state.
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

Forge 1.3.5 and Solc 0.8.24 compiled 130 public inputs in each profile with zero compiler errors. Default code generation completed, but the child exited 1 on three EIP-170 runtime-size overages: ForageGovernor 27,842 bytes (3,266 over), StakingQueue 27,382 bytes (2,806 over), and USDCTreasury 27,723 bytes (3,147 over). Default initcode has no overage. ForageToken fits at 23,835 runtime bytes, 741 below EIP-170. Deploy exited 0 and all 22 first-party runtime/initcode pairs fit; ForageToken is 23,437 runtime bytes (1,139 below), and USDCTreasury is 24,210 (366 below). The complete table is in [`review_commands.md`](review_commands.md).

All 18 ABI files match the mapped source; 17 have compiler source definitions and `FoundationTreasury.json` remains source-less. The source-matched storage-baseline comparison remains red at 16 OK and 7 historical divergences; no baseline changed.

No fresh full `audit-static` pass is established for this public materialization. The public analyzer table contains 47 analyzer identities (7 Semgrep, 40 Slither); 40 have bounded source-only review and seven remain pending. All independent reviews in the earlier 72-row table remain pending. Retained Slither and Semgrep results are red, per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open. Two Windows CLI rows remain failed. No first-party test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No live-proxy or deployed-state claim is made.
