# Review Commands

These are production-source and static-review commands for this public snapshot. The first-party test tree is intentionally absent. Do not run Forge tests, fuzzing, invariant or formal harnesses, Echidna, Halmos, Anvil, a deployment script, or a chain action.

## Dependency and no-tests checks

From the public repository root:

```bash
git submodule update --init --recursive
make -C openforage_smart_contracts no-tests
```

The top-level submodule status must remain `bccdd15b734ea6c0e6d1b3d36c482e64ced2d441` for Chainlink CCIP and `7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf` for OpenZeppelin upgradeable contracts. `make no-tests` must print `NO_TESTS_INVENTORY_PASS`.

## Production build and source graph

From the public repository root:

```bash
forge build --root openforage_smart_contracts --skip test
forge tree --root openforage_smart_contracts
```

The build compiles the production sources and retained deployment scripts. The dependency graph should resolve from the pinned public gitlinks. These commands do not run tests or deployment scripts.

## ABI and storage-layout inspection

From `openforage_smart_contracts/`, inspect each source-backed ABI contract and compare the returned JSON with its file under `abi/`:

```bash
forge inspect Allowlist abi --json
forge inspect Allowlist storageLayout --build-info --json
```

Repeat the ABI command for every source-backed artifact. Compare parsed JSON when the inspector's whitespace differs from the checked-in JSON. `FoundationTreasury.json` is retained as the one source-less artifact and must not be reported as a source match. Extract layouts for concrete contract types with `storageLayout --build-info`; the abstract `AllowlistGatedUpgradeable` mixin has no direct concrete layout output, and its storage is represented by its adopters.

## Retained static checks

From `openforage_smart_contracts/` after the production build:

```bash
make no-tests
node script/check_i15_setters.js
node script/check_semgrep_rule_coverage.js .semgrep/openforage.yml
node script/check_no_legacy_transport.js
make audit-simplify
make audit-static
```

The legacy-transport scanner should also be invoked from the public repository root:

```bash
node openforage_smart_contracts/script/check_no_legacy_transport.js
```

`SLITHER` and `SEMGREP` may be overridden on the Make command line when their installed binaries are not in `.venv/bin`; do not disable a detector or edit its suppression ledger to obtain a green result.

## Observed preparation results

The production build compiled 121 files with Solc 0.8.24 and succeeded with warnings. Seventeen source-associated ABI definitions matched Forge after JSON normalization, and 17 concrete storage layouts were inspected. The no-tests guard, I-15 checker, Semgrep rule-coverage checker, and both legacy-scanner cwd forms passed.

Static analysis is not green. The public Slither run produced 206 results; the suppression checker reported 194 unsuppressed and 56 stale entries. Semgrep ran five rules over 65 tracked files and reported nine blocking findings. The simplify regression checker could not resolve the `ProtocolTreasury` artifact named by its preserved baseline. These are open review limitations, not passes or finding clearances. The earlier private candidate's test/static results are historical and do not verify this public snapshot.
