# Audit scope

## Candidate and source map

This candidate continues PR #9 from public head `fbcdda4fc95adc6d345786787ce4ea7557df86a4`. The candidate has one parent, the recorded public parent. This review does not update the remote branch or PR.

The direct map remains 59 files: 33 production source, interface, and module files; 18 ABI artifacts; and 8 selected deployment-script and interface files. It includes the three paths previously added to PR #9. C9 changes the already-mapped `RISKUSDVault.sol`; no mapped ABI or selected script changed, and no new first-party source/interface/module/ABI mapping was added. Every mapped byte is checked against the exact source. The two root Gitlinks and all nine recursive pins stay unchanged.

Only the eight selected script/interface paths in the explicit map are copied. All other private scripts and tools, audit records, packet text, run logs, credentials, deployment records, and unlisted paths remain excluded. No first-party contract test path is copied.

## Finding scope and review status

The historical record preserves all 155 analysis 1–8 identities and their original counts. Warning 28 keeps its dated missing-capture gap. Analysis 9 remains separate, with 21 findings and 11 related cases. Its saved acknowledgements remain `Other`; no finding is marked resolved.

The latest source reviews accept the Treasury helper-readiness guard only as a bounded source correction; A9-02 is not fully closed. A9-03 remains `ACCEPT_BOUNDED` for net-basis accounting. Its related case is `ACCEPT_BOUNDED` at source level: ordinary redemption no longer refunds active-window public mint use. A redeemed position can leave shared daily/weekly mint headroom occupied until the corresponding active window resets; no fairness or risk-acceptance guarantee is claimed. A9-6 is bounded but cross-tier fairness and collectibility remain open. A9-9 is accepted only for cash-backed pricing. A9-10 and A9-14 are bounded to the reviewed fresh-state settlement and exact-nonce paths. A9-19 and A9-20 remain bounded source findings, not live-state proof. A9-21 whole-query gas remains unmeasured. No legacy-proxy, deployment, or current Octane proof exists.

The earlier static-triage record classifies 28 Queue rows and 44 Token rows individually; its per-row source dispositions remain separate from the later analyzer-row review. `SL-28` still needs a current `RISKUSDVault.sol` source rebind. A separate independent review agrees with 187 introduced analyzer-row dispositions at their stated source-bounded scope. One scanner-coverage issue remains under private repair, so the final Semgrep evidence is not accepted as exact-bound. Pre-existing Slither and Semgrep rows remain separate and open; none of these dispositions is a new scan or a full static pass.

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

Forge 1.3.5 and Solc 0.8.24 compiled 130 inputs in both profiles with the first-party test tree excluded. Default code generation completed with zero compiler errors, but its child exited 1 on three EIP-170 runtime overages: ForageGovernor (27,458 bytes), StakingQueue (27,382 bytes), USDCTreasury (27,671 bytes). Default initcode has no overage; CustodianRegistry is 1 byte below EIP-170 and atRISKUSD initcode is 48,156 bytes, 996 bytes below EIP-3860. Deploy exited 0 with all 22 first-party runtime/initcode pairs fitting; USDCTreasury is 24,168 runtime bytes, 408 bytes below EIP-170. The complete table is in [`review_commands.md`](review_commands.md).

All 18 ABI files match the mapped source; 17 have compiler source definitions and `FoundationTreasury.json` remains source-less. The historical storage check remains red at 14 OK and 7 divergences; no baseline changed.

Full Slither, configured Semgrep, the static-audit route, and the full gate table did not run on this public candidate. The 187 introduced analyzer-row dispositions are source-bounded and independently reviewed row by row; a scanner-coverage issue remains, and pre-existing analyzer rows remain separate and open. Two Windows CLI rows remain failed. No first-party test, EVM/runtime/gas simulation, RPC, chain, deployment, or Octane action ran. No live-proxy or deployed-state claim is made.
