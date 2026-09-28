# Audit Scope

## Snapshot under review

The review target is the public production-source snapshot in `openforage_smart_contracts/`. The copied public history starts at PR 9 head `bd005bad4fe3432401a6e4ae920830e267369e38`, based on public commit `6fbbc51c4da48fce46f7119d1053088ba119d7bf`.

The prepared overlay contains 62 mapped paths: 30 Solidity sources, 18 ABI artifacts, two public status documents, two Semgrep manifest/exception files, and ten scripts or interfaces. `README.md` is an additional required path. `documentation/review_commands.md` remains unchanged. The 91 source files counted by the Semgrep import manifest are dependency inputs, not Gitlinks.

## Source and artifact scope

The source overlay includes candidate changes to governance payload bounds and Guardian behavior; historical vote eligibility; vault claim, cap, and loss accounting; Queue admission, FIFO, and expiry rules; Bridge NAV, intent, return, and loss accounting; Registry totals; Treasury claim funding and fee remainders; and deployment initialization order. It also includes existing deployment and scanner controls needed to review those sources.

The saved final compiler pair binds 125 Solidity inputs under both profiles. Its shared source map is retained outside this public repository. The pair is evidence for this source snapshot only. The checker and manifest updates change no Solidity input, and this update did not run a build. The default profile produced no compiler errors but exited 1 on six runtime-size overages and one `atRISKUSD` initcode overage. The Deploy profile exited 0 and fit all 20 reported size pairs. Compiler warnings remain in both profiles.

The saved ABI comparison matches all 17 source-backed artifacts. `FoundationTreasury.json` remains an orphan without a source match. The bounded layout comparison covers 19 nonempty raw targets out of 20 selected targets. The historical storage checker remains red at 14 passes and five divergences. Neither comparison proves old-proxy state, migration, or upgrade safety.

## Finding and disclosure scope

The public remediation record carries all 155 captured `(analysis, UUID)` pairs from analyses 1–8. The counts are 55, 11, 9, 14, 9, 5, 28, and 24. The row codes and UUIDs remain exact. Source dispositions are cross-referenced by mechanism family; they do not change Octane labels.

The latest completed analysis in this evidence set is analysis 8, with all 24 rows acknowledged. An acknowledgement affects later automation reports only. This snapshot does not mark any row resolved because it was acknowledged or absent from a later report.

Warning 28 retains UUID `3c2ba48b-3798-4f57-beba-90dc904af4d8`. A later description capture is identified. The original 2026-09-24 capture bytes are unavailable, so this record does not reconstruct them.

The public pages contain no private workspace, packet, guide, run, infrastructure, or credential references. The inventory retains the public dependency Gitlinks, dated public audit history, and scanner configuration. The dated 2026-06-09 log files are historical records; their names do not show that this packet ran those commands. No private raw audit capture or run log is included.

## Dependencies and imported sources

The two top-level Solidity dependency Gitlinks are Chainlink CCIP `bccdd15b734ea6c0e6d1b3d36c482e64ced2d441` and OpenZeppelin upgradeable contracts `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`. The recursive tree has nine pinned Gitlinks. The copied Git metadata resolves these pins without changing them. The 91 dependency-source-file count is distinct from the nine recursive pins.

Initialize the public dependencies before a later build:

```bash
git submodule update --init --recursive
```

## Test and deployment inventory

`make -C openforage_smart_contracts no-tests` returned `NO_TESTS_INVENTORY_PASS` on this candidate tree. The target checks whether the first-party `test/` tree and named test-only scripts or campaign configuration files exist, then checks their tracked paths. It is an inventory result, not a contract-test pass.

The pinned upstream submodules contain their own test-looking files. They are vendor files under dependency Gitlinks, not first-party tests in this repository. The no-tests target does not inspect the contents of every upstream Gitlink. The dated 2026-06-09 audit record retains historical log files, including earlier test-named logs; this packet did not execute, refresh, or treat them as current evidence. Deployment scripts remain reviewable controls and were not run.

## Accepted economic and authority boundaries

| Topic | Policy represented in source | Limit |
|---|---|---|
| Distributor payments | The configured trusted distributor may pay a non-allow-listed recipient if that recipient is not blocklisted. Direct claims retain self-call and eligibility checks. | A paid recipient gains no system-account status or restricted-call permission. |
| External vesting recipients | A distinct recipient may receive finite, renewable approval through the vesting system. | Approval does not grant distributor or restricted-operation authority. |
| Profit recognition | Holders at the recognition point own that tier's claim. Ordinary share transfers carry the claim. | A source/accounting statement is not deployed-state proof. |
| Withdrawals | A redemption pays only available funded cash. | A queue or cooldown does not reserve cash or promise a date. |
| Guardian recovery | One designated Guardian may use its reserved proposal slot under normal proposal, voting, and timelock rules. | A Guardian cannot veto its own authority change outside the normal process. |
| Keeper reconciliation | Reconciliation uses the existing narrow, checked return route. | No arbitrary balance credit or broader keeper authority is implied. |
| Fees and losses | Fractional fee remainders carry per vault. Only loss charged to a tier consumes that tier's loss-rate budget. | Full loss settlement and reserve accounting remain; this is not a loss guarantee. |
| Queue priority | Failed revalidation demotes the same queue ID to standard FIFO at its original position. | The operation does not refund or create a new queue entry. |
| Expired positions | Only authorized automatic processing of an expired higher-tier position bypasses the Tier 0 admission cap. | New Tier 0 admissions and manual reversion remain capped. Other caller and safety guards remain. |

## Exclusions and result limits

- No first-party contract test, fuzz or formal campaign, Forge test, Anvil run, runtime, gas simulation, RPC observation, deployment, or chain action was run for this packet.
- No full Octane audit, new Octane analysis, public push, pull-request mutation, or public `main` change was performed.
- Static output is not clean. The saved Slither, Semgrep, suppression, source-layout, and size findings remain visible in the remediation record.
- A8-14 remains `Other` and open. Its conditional calculation of 31,555,113 required and 29,061,962 spent is not measured gas or a complete transaction-envelope proof against a current cap. Arbitrary providers and legacy funded proxies remain unresolved.
- Static checks, retained compiler artifacts, documentation, and no-tests inventory do not establish public source acceptance, old-proxy applicability, production safety, or finding resolution.
