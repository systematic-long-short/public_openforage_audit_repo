# Review Commands

These commands are intended as starting points for local review of the
`e5c2c76d55e197044e30392c407b52af598a1681` source snapshot. They do not replace
reviewer-specific tooling or constitute a fresh security audit.

## Smart Contracts

```bash
git submodule update --init --recursive
cd openforage_smart_contracts
forge build --force
node script/check_i15_setters.js
node script/check_semgrep_rule_coverage.js .semgrep/openforage.yml
node script/check_no_legacy_transport.js
forge test --match-path test/Allowlist.t.sol
forge test --match-path test/AllowlistGated.storage.t.sol
forge test --match-path 'test/*.gate.t.sol' --fuzz-runs 64
forge test --match-path test/ForageToken.delegateGate.t.sol --fuzz-runs 64
forge test --match-path test/Gate.sweep.t.sol
forge test --match-path test/Allowlist.fuzz.t.sol --fuzz-runs 64
```

The focused commands above were run during this refresh: the build completed
with compiler warnings, the selected static helper checks passed, and the test
commands passed 100 tests in total. The Allowlist fuzz suite used 64 runs.

The full Foundry suite, Slither, Semgrep execution, Echidna, Halmos, and
high-depth fuzz/invariant campaigns were not run for this refresh. The retained
June audit evidence and the existing public suppression/waiver files are
historical and do not verify the current source revision.
