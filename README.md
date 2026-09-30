# OpenForage public contract review

This repository is a selective source snapshot for independent review. It is not a deployment repository or a copy of the private monorepo.

## Snapshot scope

The direct map contains 59 files: 33 Solidity source, interface, and module files; 18 ABI files; and 8 selected deployment-script and interface files. The current private source inventory has no unlisted first-party source, interface, module, or ABI path; the three previously added source paths remain explicit in the map. Both root dependency Gitlinks and all nine recursive pins remain unchanged. Vendor source stays behind those pins. Private audit records, run logs, packet text, deployment state, credentials, and non-allowlisted scripts and tooling are excluded.

No first-party contract test path is copied.

## Analysis 9 and 10 status

See [`Analysis 9 dispositions`](documentation/smart_contract_audits/2026-09-29-analysis-9-dispositions.md) for all 21 primary findings, 11 related cases, and their latest source-review limits. See [`Analysis 10 dispositions`](documentation/smart_contract_audits/2026-09-30-analysis-10-dispositions.md) for all 17 findings, the A10-11 related case, and the latest independent source-review status. The 155 analysis 1–8 identities remain unchanged in [`the historical record`](documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md). Warning 28 retains its dated missing-capture gap. Analysis 9 acknowledgements remain `Other`; neither publication nor source review marks a finding resolved.

The Analysis 9 source findings remain bounded. The Treasury helper-readiness guard is accepted only as a source correction; A9-02 is not fully closed. A9-03 and its related case remain `ACCEPT_BOUNDED` within the reviewed accounting limits: ordinary redemption leaves active-window public mint use consumed, so shared headroom can remain occupied until reset. This is temporary aggregate-cap contention, not a fairness guarantee. A9-06, A9-09, A9-10, A9-14, A9-19, and A9-20 retain their specific source limits. A9-21 whole-query gas remains unmeasured. The 16 Analysis 10 vulnerabilities have bounded source dispositions and review within their limits. A10-17 remains open; whole-call gas fit is unmeasured. No legacy-proxy, deployment, or current Octane closure is claimed.

The public analyzer table contains 47 analyzer identities: 7 Semgrep and 40 Slither. Each row names each cited candidate file's Git blob SHA-1, which identifies the exact file bytes in this candidate tree; `ef049358efb6496f8304faef11a99c34d2610e62` is the previous PR #9 head and base of this update, not the source of these lines. Forty rows have bounded source-only review; seven stale or unresolved rows remain pending. The earlier 72-row table remains separate with all independent reviews pending. No fresh full `audit-static` pass is established; retained Slither and Semgrep results remain red, per-ID Slither suppression reconciliation is in progress, and the scanner-coverage gap remains open.

## Policy boundaries

Only fresh deployments are supported. New code must refuse pre-fresh state before changing it. No legacy migration engine is supported. In the Blocklist, the legacy importer and interval-translation path are removed; fresh initialization sets the layout version and every state-changing entrypoint checks it before effects. The historical checkpoint lookup uses `wasBlockedAt`; the retained pre-checkpoint mapping is inert and remains only for layout. Completed review 0645 accepts this Blocklist repair as a source-only bounded result; it proves no old-proxy or deployed-state behavior. The first upgrade still uses the authorizer in the implementation already installed. These rules do not prove every deployed proxy or upgrade path.

Profit belongs to the holders at recognition. Unpaid profit stays a separate claim and is paid only when cash arrives. Withdrawals use cash-backed share value and available cash; they promise no payment date. A reported custodian loss belongs to holders at report time. Transfers and exits that could avoid that loss stay frozen through settlement.

The distributor is the trusted payer, not the recipient. Payment grants no system-account status or restricted-call permission.

## Build and verification limits

Forge 1.3.5 and Solc 0.8.24 compiled 130 public inputs in each profile with zero compiler errors. Default code generation completed, but the child exited 1 on three EIP-170 runtime-size overages: ForageGovernor 27,842 bytes (3,266 over), StakingQueue 27,382 bytes (2,806 over), and USDCTreasury 27,723 bytes (3,147 over). Default initcode has no overage. ForageToken fits at 23,835 runtime bytes, 741 below EIP-170. Deploy exited 0 and all 22 first-party runtime/initcode pairs fit; ForageToken is 23,437 runtime bytes (1,139 below), and USDCTreasury is 24,210 (366 below). See [`review commands and sizes`](documentation/review_commands.md) for every first-party runtime/initcode pair and margin.

All 18 ABI files match the mapped source; 17 have compiler source definitions and `FoundationTreasury.json` remains source-less. The source-matched storage-baseline comparison remains red at 16 OK and 7 historical divergences; no baseline changed.

No fresh full Slither, configured Semgrep, or `audit-static` pass is established for this public materialization. The 47-row analyzer table records 7 Semgrep and 40 Slither identities; 40 are bounded source-only dispositions and seven remain pending. The earlier 72-row table remains separate with all independent reviews pending. Retained Slither and Semgrep results remain red; per-ID suppression reconciliation is in progress, the scanner-coverage gap remains open, and `SL-28` still needs a current `RISKUSDVault.sol` source rebind. Two Windows CLI rows remain failed. No first-party contract test, runtime, deployed-state, chain, or Octane result is claimed.
