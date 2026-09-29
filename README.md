# OpenForage public contract review

This repository is a selective source snapshot for independent review. It is not a deployment repository or a copy of the private monorepo.

## Snapshot scope

The direct map remains 59 files: 33 Solidity source, interface, and module files; 18 ABI files; and 8 selected deployment-script and interface files. It includes the three source paths previously added to PR #9, including the Treasury accounting module. C9 changes the already-mapped `RISKUSDVault.sol`; no mapped ABI or selected script changed, and no new first-party source/interface/module/ABI path was added. Both root dependency Gitlinks and all nine recursive pins remain unchanged. Vendor source stays behind those pins. Private audit records, run logs, packet text, deployment state, credentials, and non-allowlisted scripts and tooling are excluded.

No first-party contract test path is copied.

## Analysis 9 status

See [`Analysis 9 dispositions`](documentation/smart_contract_audits/2026-09-29-analysis-9-dispositions.md) for all 21 primary findings, 11 related cases, and the current bounded review results. The 155 analysis 1–8 identities remain unchanged in [`the historical record`](documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md). Warning 28 retains its dated missing-capture gap. The saved Analysis 9 acknowledgements remain `Other`; no finding is marked resolved.

Completed source reviews keep every Analysis 9 disposition bounded. The Treasury helper-readiness guard is accepted only as a source correction; A9-02 is not fully closed. A9-03 remains `ACCEPT_BOUNDED` for net-basis accounting. The related case is now `ACCEPT_BOUNDED` at source level: ordinary redemption leaves active-window public mint use consumed, so a redeemed position can leave shared headroom occupied until its active window resets. This is temporary aggregate cap contention, not a fairness guarantee or a risk-acceptance decision. A9-6, A9-9, A9-10, A9-14, A9-19, and A9-20 retain their specific source limits. No legacy-proxy, deployment, or current Octane proof exists. A9-21 whole-query gas remains unmeasured.

The separate introduced-analyzer review agrees with 187 source-bounded row dispositions. One scanner-coverage issue remains under private repair, so the final Semgrep evidence is not treated as exact-bound. Pre-existing analyzer rows remain separate and open; no full static pass is claimed.

## Policy boundaries

Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported. In the Blocklist, the legacy importer and interval-translation path are removed; fresh initialization sets the layout version and every state-changing entrypoint checks it before effects. The historical checkpoint lookup uses `wasBlockedAt`; the retained pre-checkpoint mapping is inert and remains only for layout. Completed review 0645 accepts this Blocklist repair as a source-only bounded result; it proves no old-proxy or deployed-state behavior. The first upgrade still uses the authorizer in the implementation already installed. These rules do not prove every deployed proxy or upgrade path.

Profit belongs to the holders at recognition. Unpaid profit stays a separate claim and is paid only when cash arrives. Withdrawals use cash-backed share value and available cash; they promise no payment date. A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid that loss stay frozen through settlement.

The distributor is the trusted payer, not the recipient. Payment grants no system-account status or restricted-call permission.

## Build and verification limits

Forge 1.3.5 and Solc 0.8.24 compiled 130 inputs in both profiles with the first-party test tree excluded. Default code generation completed with zero compiler errors, but its child exited 1 on three EIP-170 runtime overages: ForageGovernor (27,458 bytes), StakingQueue (27,382 bytes), USDCTreasury (27,671 bytes). Default initcode has no overage; CustodianRegistry is 1 byte below EIP-170 and atRISKUSD initcode is 48,156 bytes, 996 bytes below EIP-3860. Deploy exited 0 with all 22 first-party runtime/initcode pairs fitting; USDCTreasury is 24,168 runtime bytes, 408 bytes below EIP-170. See [`review commands and sizes`](documentation/review_commands.md).

All 18 ABI files match the mapped source; 17 have compiler source definitions and `FoundationTreasury.json` remains source-less. The historical storage check remains red at 14 OK and 7 divergences.

Full Slither, configured Semgrep, and the full static-audit route did not run on this candidate. The 187 introduced analyzer rows retain their per-row source-bounded independent-review dispositions; one scanner-coverage issue remains, and pre-existing analyzer rows remain separate. `SL-28` still needs a current `RISKUSDVault.sol` source rebind. Two Windows CLI rows remain failed. No first-party contract test, runtime, deployed-state, chain, or Octane result is claimed.
