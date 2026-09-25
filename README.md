# OpenForage Public Smart Contract Audit Snapshot

This repository is a selective production-source snapshot for external review. It is not a deployment repository or a copy of the private monorepo. Refreshes use a reviewed branch from public `main`; the public `main` branch is never rewritten.

## Source and preparation identities

The runtime-source identity for this snapshot is private commit `8d4a 2d4c 44ba 7d83 cdc5 1d93 4e11 8655 049c 78ca`. It identifies the Solidity source used for the remediation, not the later no-tests packaging changes. The public tree is a selective snapshot and is not claimed to be byte-identical to the whole private tree at that commit.

All 26 production Solidity source files and all 18 ABI artifacts were measured against that source identity. In the measured 20-file production-source set, 19 files differed from the observed public `main` and were synchronized; `DelegatingVestingWallet.sol` already matched. The other six source files in the full 26-file inventory also already matched. Fifteen ABI files differed and were synchronized; three were already identical. A standalone `IAllowlistSettable` interface was extracted intact from a test-only helper, and the retained deployment script's import alone was redirected to that interface.

This later public preparation removes first-party tests and test-only campaign inputs. It does not alter the runtime-source identity above, and it does not make a whole-tree-equality claim. The removed 235-file test tree and seven test-only files were preserved outside this repository before deletion. No Solidity test, fuzz, invariant, formal, Anvil, or deployment command was run for this preparation.

## Verification status

- `forge build --root openforage_smart_contracts --skip test` compiled 121 files with Solc 0.8.24 and completed successfully with compiler warnings.
- The no-tests inventory guard passed. The I-15 checker passed for 15 trust-boundary setters. The approved legacy-transport scanner passed from both the contract directory and repository root.
- Seventeen source-associated ABI definitions matched the Forge output after JSON normalization. `FoundationTreasury.json` remains the one source-less ABI artifact; it was retained unchanged. All 18 ABI files were byte-compared with the selected source identity.
- Forge produced storage layouts for 17 concrete contract types. `forge tree` produced the production import graph, and the production build resolved its imports.
- Static results remain red: Slither reported 206 results and the public suppression checker reported 194 unsuppressed plus 56 stale entries. Semgrep reported 9 blocking findings across 65 tracked files. The Semgrep rule-coverage checker passed. The simplify regression checker stops at the missing `ProtocolTreasury` build artifact named by its preserved baseline. Removing tests does not clear any of these findings.

The private historical Octane remediation record reported 2,540 full-suite passes and 105 failures; its historical static results were 90 unsuppressed Slither findings, 55 stale suppressions, and 114 Semgrep findings. Those figures describe an earlier private candidate, not this public no-tests snapshot. They are not a clearance claim. No new Octane analysis was run.

See `documentation/audit_scope.md`, `documentation/review_commands.md`, and `documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md` for scope, review steps, and current limitations.

## Included and excluded

- `openforage_smart_contracts/` contains production Solidity source and ABI artifacts, the approved deployment and static-checker scripts, static-analysis configuration, and pinned Solidity dependency gitlinks.
- `documentation/` contains public-safe audit scope, review guidance, and historical assessments.
- First-party contract tests, test helpers, fuzz/formal harnesses, deployment manifests, generated output, private audit captures, local caches, credentials, and vendored dependency contents are not included.

## Dependency pins

Initialize the public dependencies with:

```bash
git submodule update --init --recursive
```

The top-level pins are Chainlink CCIP `bccd d15b 734e a6c0 e6d1 b3d3 6c48 2e64 ced2 d441` and OpenZeppelin upgradeable contracts `7bf4 727a acdb faa0 f36c bd66 4654 d0c9 e1dc 52bf`. The `lib/` paths remain gitlinks, not vendored copies.
