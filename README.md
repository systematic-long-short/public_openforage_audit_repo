# OpenForage Public Smart Contract Audit Snapshot

This repository is a selective production-source snapshot for external review. It is not a deployment repository or a copy of the private monorepo. The reviewed branch is append-only from public `main`; public `main` is never rewritten.

## Source and preparation identities

The accepted private production-source checkpoint for this reconciled snapshot is `c0f8db4d79825da948ce170150f77e099cc08fc5`. It identifies the source selection, not the whole private tree or private history. `openforage_smart_contracts/src/FORAGETreasury.sol` is copied byte-for-byte from that accepted source and has SHA-256 `cb97eeee0db40031b9f847793aaef9b7f0b279bc8e4ec28be5c3a35bf86cf596`.

The final Treasury source keeps direct `claimAgent` self-called and eligibility-gated. Its authorized distributor route may pay a non-allowlisted recipient when that recipient is not blocklisted. This is the accepted source policy, not a separate security conclusion.

All 26 production Solidity sources and 18 ABI artifacts were accounted against the accepted private source. Relative to the retained public-only snapshot, only `FORAGETreasury.sol` changed among those sources; the other 25 source hashes and all 18 ABI hashes remain unchanged. The generated Treasury ABI is byte-identical to its committed artifact and the accepted-source ABI. Seventeen source-associated ABI artifacts match; `FoundationTreasury.json` remains the one source-less artifact. The Treasury storage-layout output is unchanged from both the retained snapshot and the accepted source proof.

The public-only baseline, extracted `IAllowlistSettable` interface and signature, deployment script and order, import graph, no-tests guard, public-safe scanner and analyzer variants, and dependency gitlinks are preserved from the retained snapshot. The source update adds no import, interface, ABI, or storage change.

## Verification status

- The production-only Forge build compiled 98 files with Solc 0.8.24 and completed successfully with compiler warnings. No tests or scripts were executed.
- The no-tests inventory guard passed on the candidate worktree and committed tree. That proves the forbidden test inputs are absent; it is not a test pass.
- Forge ABI and storage inspections matched the committed Treasury ABI and the accepted private source outputs. The production import graph matched the retained graph byte-for-byte.
- Static checks are not green. The retained 0072 public static run, against the earlier public Treasury source hash `59d6a498ab7e3ed93533df220c6f71c222472e97d75ae59aa12ebb9bf04e9a9b`, reported 206 Slither results, 194 unsuppressed and 56 stale suppression entries, and 9 blocking Semgrep findings; the simplify checker stopped at its missing `ProtocolTreasury` build artifact. These results are from that earlier public source, not a rerun on this replacement.
- A separate private-source-bound Slither scan at the accepted source reported 206 raw results and process exit 255 despite `success: true` and `error: null` in its JSON. It has no finding dispositions and is not a public-snapshot static pass. No static scanner was rerun for this public candidate; no private suppressions or scanner proposals were applied.

Removing tests or changing the payout source does not clear any audit finding. Historical private test counts describe an earlier candidate and do not prove this public snapshot. No new Octane analysis, test suite, fuzz/formal campaign, Anvil run, deployment, chain action, push, or pull request was performed.

See `documentation/audit_scope.md`, `documentation/review_commands.md`, and `documentation/smart_contract_audits/2026-06-17-external-audit/OctaneAnalysis7Remediation.md` for scope, review steps, and limitations.

## Included and excluded

- `openforage_smart_contracts/` contains production Solidity source and ABI artifacts, approved deployment and static-checker sources, static-analysis configuration, and pinned Solidity dependency gitlinks.
- `documentation/` contains public-safe audit scope, review guidance, and historical assessments.
- First-party tests, test helpers, fuzz/formal harnesses, deployment manifests, generated output, private audit captures, local caches, credentials, and vendored dependency contents are not included.

## Dependency pins

Initialize the public dependencies with:

```bash
git submodule update --init --recursive
```

The top-level pins are Chainlink CCIP `bccdd15b734ea6c0e6d1b3d36c482e64ced2d441` and OpenZeppelin upgradeable contracts `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf`. The `lib/` paths remain gitlinks, not vendored copies.
