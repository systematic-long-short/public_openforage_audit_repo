# Retest Results

Retest evidence after the checkpoint reconciliation, registry-destination,
registry-return, mainnet HyperLiquid route-finalization, and pre-expiry
initial-config finalization fixes:

- `forge build --force`: PASS in `_audit_work/logs/forge-build-final-r16.log`.
- `forge fmt --check script/Deploy.s.sol script/DeployMainnet.s.sol test/DeployMainnet.target.t.sol src/hyperliquid/HLTradingBridge.sol src/RISKUSDVault.sol src/USDCTreasury.sol`: PASS in `_audit_work/logs/forge-fmt-check-targeted-final-r16.log`.
- `forge test --match-path test/hyperliquid/HLTradingBridge.target.t.sol`: PASS, 19 tests in `_audit_work/logs/forge-test-hl-bridge-target-r9-m01.log`.
- `forge test --match-path test/USDCTreasury.target.t.sol`: PASS, 14 tests.
- `forge test --match-path test/DeployMainnet.target.t.sol`: PASS, 6 tests in `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m02.log`.
- `uv run --with pytest pytest -q --confcutdir=tests/harness tests/harness/test_smart_contract_mainnet_audit_gate.py`: PASS, 5 tests in `_audit_work/logs/pytest-smart-contract-mainnet-audit-gate-final-r16.log`.
- `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 uv run --with pytest pytest -q --noconftest tests/harness/test_spec_md_html_parity.py tests/harness/test_project_implementation_notes.py`: PASS, 2 tests in `_audit_work/logs/pytest-project-doc-parity-final-r16.log`.
- `make audit-static`: PASS, I-15 lint pass, Slither 59/59 suppressions, Semgrep 0 in `_audit_work/logs/make-audit-static-final-r16.log`.
- `make audit-formal`: PASS, 9 symbolic checks in `_audit_work/logs/make-audit-formal-final-r16.log`.
- `make audit-fuzz`: PASS, Echidna I1/I2/I4 over 50,400 calls in `_audit_work/logs/make-audit-fuzz-final-r16.log`.
- `make audit-foundry`: PASS, 14 suites / 91 tests in `_audit_work/logs/make-audit-foundry-final-r16.log`.
- `forge test --summary`: PASS twice after R16, each 219 suites / 2092 tests in `_audit_work/logs/forge-test-summary-rerun-1.log` and `_audit_work/logs/forge-test-summary-rerun-2.log`.
- Red-first checkpoint proof: `_audit_work/logs/red-dust-checkpoint-reconciliation.log`
  shows `test_TSCGB_A18_unsolicitedDustDoesNotBlockWithdrawalIntent` failed before
  the reconciliation checkpoint fix because the pre-existing dust was accepted as
  the new arrival.
- Red-first registry proof: `_audit_work/logs/red-r8-m01-registry-gate.log`
  shows the R8 tests and A15 registry-accounting assertion failed when
  `HLTradingBridge.deployToHyperLiquid` skipped `CustodianRegistry.recordDeployment`;
  `_audit_work/logs/green-r8-m01-registry-gate.log` shows the same focused set passing
  after the call was restored.
- Red-first registry-return proof: `_audit_work/logs/red-r9-m01-registry-return.log`
  shows the R9 tests and A16 registry-exposure assertion failed when
  `HLTradingBridge.returnPrincipalUSDC` skipped `CustodianRegistry.recordReturn` /
  `recordEmergencyReturn`; `_audit_work/logs/green-r9-m01-registry-return.log`
  shows the same focused set passing after the hook was restored.
- Red-first mainnet-route proof: `_audit_work/logs/red-r16-m01-mainnet-route-finalization.log`
  shows the DeployMainnet route/finalization test failed before the mainnet dry-run
  finalized the HyperLiquid custodian config and aligned registry peer state with
  the configured source account; `_audit_work/logs/green-r16-m01-mainnet-route-finalization.log`
  shows the focused test passing after the deploy wiring and finalization fix.
- Red-first mainnet initial-config expiry proof:
  `_audit_work/logs/red-r16-m02-mainnet-config-finalizes-before-expiry.log`
  shows `test_mainnetRunWithConfigUsesConfiguredCustodyRoute` failed with
  `initial custodian config expired` when finalization ran after production
  timelock registrations; `_audit_work/logs/green-r16-m02-mainnet-config-finalizes-before-expiry.log`
  shows the focused test passing after the proposal hook finalized the config
  before the registration/handoff sequence.
- Mutation-red evidence for earlier findings is retained in the `red-*.log` files
  listed in `regression-variant-results.md`.
- Codex review history and the artifact-retention note are tracked in
  `codex-review.md` and `round-retention.md`.

Each item is backed by a log under `_audit_work/logs/`.
