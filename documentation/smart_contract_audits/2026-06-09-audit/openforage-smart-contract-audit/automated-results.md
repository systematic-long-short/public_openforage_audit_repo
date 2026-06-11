# Automated Results

Evidence logs live under `_audit_work/logs/`.

| Gate | Result | Evidence |
| --- | --- | --- |
| `forge build --force` | PASS | `_audit_work/logs/forge-build-final-r16.log` |
| `forge fmt --check script/Deploy.s.sol script/DeployMainnet.s.sol test/DeployMainnet.target.t.sol src/hyperliquid/HLTradingBridge.sol src/RISKUSDVault.sol src/USDCTreasury.sol` | PASS | `_audit_work/logs/forge-fmt-check-targeted-final-r16.log` |
| `forge test --match-path test/hyperliquid/HLTradingBridge.target.t.sol` | PASS, 19 tests | `_audit_work/logs/forge-test-hl-bridge-target-r9-m01.log` |
| `forge test --match-path test/USDCTreasury.target.t.sol` | PASS, 14 tests | `_audit_work/logs/forge-test-usdc-treasury-target.log` |
| `forge test --match-path test/DeployMainnet.target.t.sol` | PASS, 6 tests | `_audit_work/logs/forge-test-deploy-mainnet-target-r16-m02.log` |
| `uv run --with pytest pytest -q --confcutdir=tests/harness tests/harness/test_smart_contract_mainnet_audit_gate.py` | PASS, 5 tests | `_audit_work/logs/pytest-smart-contract-mainnet-audit-gate-final-r16.log` |
| `PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 uv run --with pytest pytest -q --noconftest tests/harness/test_spec_md_html_parity.py tests/harness/test_project_implementation_notes.py` | PASS, 2 tests | `_audit_work/logs/pytest-project-doc-parity-final-r16.log` |
| `make audit-static` | PASS | `_audit_work/logs/make-audit-static-final-r16.log` |
| `make audit-formal` | PASS, 9 symbolic checks | `_audit_work/logs/make-audit-formal-final-r16.log` |
| `make audit-fuzz` | PASS, Echidna I1/I2/I4 over 50,400 calls | `_audit_work/logs/make-audit-fuzz-final-r16.log` |
| `make audit-foundry` | PASS, 14 suites / 91 tests | `_audit_work/logs/make-audit-foundry-final-r16.log` |
| `forge test --summary` rerun 1 | PASS, 219 suites / 2092 tests | `_audit_work/logs/forge-test-summary-rerun-1.log` |
| `forge test --summary` rerun 2 | PASS, 219 suites / 2092 tests | `_audit_work/logs/forge-test-summary-rerun-2.log` |

Static-analysis disposition:

- Slither reports 59 known findings and `check_slither_suppressions.js` validates 59 matching suppressions.
- Semgrep reports 0 findings over 55 tracked Solidity files.
- The I-15 critical-setter lint passes for 12 trust-boundary setters.
