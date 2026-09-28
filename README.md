# OpenForage Public Smart Contract Audit Snapshot

This repository is a selective production-source snapshot for independent review. It is not a deployment repository or a copy of the private monorepo.

## Public snapshot identity

The copied public history starts at PR 9 head `bd005bad4fe3432401a6e4ae920830e267369e38`, based on public commit `6fbbc51c4da48fce46f7119d1053088ba119d7bf`. This packet prepares a local review candidate only. It does not update a remote branch, open a pull request, change a label, or start an Octane analysis.

The measured source overlay covers 62 paths: 30 Solidity sources, 18 ABI artifacts, two public status documents, two Semgrep manifest/exception files, and ten scripts or interfaces. `README.md` is an additional required path. `documentation/review_commands.md` remains unchanged.

The import inventory distinguishes 91 dependency source files from the two top-level and nine recursive Gitlinks. The top-level pins are Chainlink CCIP `bccdd15b734ea6c0e6d1b3d36c482e64ced2d441` and OpenZeppelin upgradeable contracts `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`. The `lib/` entries remain Gitlinks, not copied vendor trees.

## Candidate source changes

The public source overlay includes candidate changes to governance bounds, voting history, vault accounting, Bridge settlement, queue ordering, expiry handling, Registry accounting, Treasury claim funding, and deployment setup. The exact paths remain under `openforage_smart_contracts/`. These are source claims, not deployed behavior or final independent acceptance.

The configured distributor route may pay a recipient who is not allow-listed when that recipient is not blocklisted. A paid recipient gains no system-account status or restricted-call permission. External vesting approval does not create those rights either.

## Saved proof and open findings

The saved final compiler pair used Forge 1.3.5, Solidity 0.8.24, and Cancun settings against 125 source inputs. The checker repair updates JavaScript source-text controls and their bound manifest only; it changes no Solidity compiler input or ABI. This candidate reuses the saved pair and does not rerun a compiler or analyzer.

- The default-profile compiler produced no compiler errors, but its command exited 1. Six runtime-size limits and the `atRISKUSD` initcode limit remain over the configured boundaries.
- The Deploy profile exited 0, produced no compiler errors, and fit all 20 measured runtime/initcode pairs. This result does not clear the default profile.
- The saved ABI comparison matched all 17 source-backed artifacts. `FoundationTreasury.json` remains the source-less orphan.
- The storage baseline remains red at 14 checks and five divergences. The saved current-layout comparison does not establish old-proxy state, a migration, or upgrade safety.
- Slither reported 326 unique findings with process exit 255, while its JSON says `success: true` and `error: null`. The unchanged suppression checker matched 8 rows, left 318 unmatched and 60 stale, and exited 1.
- Configured Semgrep reported seven findings over 48 inputs. The disjointness configuration reported zero over 34 inputs. The exception-free configuration reported 57 over 48 inputs. These outputs are separate; none is a full static pass.
- Two Windows MSVC checks remain red because the required native compiler and SDK were not available. No Windows result is inferred from another target.

All 155 captured `(analysis, UUID)` identities remain in the public remediation ledger. The counts are 55, 11, 9, 14, 9, 5, 28, and 24 for analyses 1 through 8. The latest completed analysis is 8; its 24 rows are acknowledged. Acknowledgement changes workflow reporting only. This candidate does not claim a finding is resolved because of an acknowledgement or a missing later result.

Warning 28 retains UUID `3c2ba48b-3798-4f57-beba-90dc904af4d8`. The later 2026-09-25 description capture remains identified, but the original 2026-09-24 capture bytes are missing. No original description has been reconstructed.

A8-14 remains `Other` and open. A conditional source calculation reported 31,555,113 required and 29,061,962 spent against a dated 32,000,000 comparison. This is not measured gas or a complete transaction bound. The current transaction cap, arbitrary-provider behavior, and legacy funded-proxy state remain unanswered.

## Test and deployment boundaries

`make -C openforage_smart_contracts no-tests` returned `NO_TESTS_INVENTORY_PASS`. It checks the first-party test paths, named test-only controls, and their tracked paths. It is an inventory result, not a contract-test pass. This packet ran no contract test, fuzz/formal campaign, Anvil stack, runtime simulation, or gas simulation.

The pinned upstream submodules contain their own test-looking files. They are vendor files under dependency Gitlinks, not first-party tests in this repository. The dated 2026-06-09 audit record retains historical log files, including earlier test-named logs; this packet did not execute, refresh, or treat them as current evidence. Deployment scripts remain reviewable controls and were not run.

Removing tests does not clear any finding. No full Octane audit, new Octane analysis, public write, deployment, or chain action was performed for this candidate.

## Review documents

See [`documentation/audit_scope.md`](documentation/audit_scope.md), [`documentation/review_commands.md`](documentation/review_commands.md), and [`documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md`](documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md) for scope, commands, the finding census, source changes, and remaining conditions.
