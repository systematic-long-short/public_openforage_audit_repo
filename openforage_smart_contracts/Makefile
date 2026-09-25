# OPENFORAGE_AUDIT_GATE_MAKEFILE_R37

SLITHER ?= .venv/bin/slither
SLITHER_JSON ?= /tmp/openforage-slither-results.json
SEMGREP ?= .venv/bin/semgrep

.PHONY: audit audit-static audit-i15 audit-simplify no-tests

audit: audit-static

audit-static: no-tests audit-i15
	$(RM) $(SLITHER_JSON)
	$(SLITHER) . --config-file slither.config.json --json $(SLITHER_JSON) || node script/check_slither_suppressions.js $(SLITHER_JSON) slither_suppressions.json
	node script/check_semgrep_rule_coverage.js .semgrep/openforage.yml
	$(SEMGREP) --config .semgrep/openforage.yml --error

audit-i15: no-tests
	node script/check_i15_setters.js

audit-simplify: no-tests
	node script/check_simplify_regression.js

no-tests:
	@if [ -e test ]; then printf '%s\n' 'NO_TESTS_INVENTORY_FAIL path=test/'; exit 1; fi
	@for path in script/DeployTestEnv.s.sol script/FinalAuditWetPrimaryFlow.s.sol script/TestContracts.sol script/gen_selector_sweep.py script/hyperliquid/HyperCoreAgentApprovalProbe.sol echidna.yaml halmos.toml; do \
		if [ -e "$$path" ]; then printf 'NO_TESTS_INVENTORY_FAIL path=%s\n' "$$path"; exit 1; fi; \
	done
	@tracked="$$(git -C .. ls-files -- 'openforage_smart_contracts/test/**' 'openforage_smart_contracts/script/DeployTestEnv.s.sol' 'openforage_smart_contracts/script/FinalAuditWetPrimaryFlow.s.sol' 'openforage_smart_contracts/script/TestContracts.sol' 'openforage_smart_contracts/script/gen_selector_sweep.py' 'openforage_smart_contracts/script/hyperliquid/HyperCoreAgentApprovalProbe.sol' 'openforage_smart_contracts/echidna.yaml' 'openforage_smart_contracts/halmos.toml')"; \
		if [ -n "$$tracked" ]; then printf 'NO_TESTS_INVENTORY_FAIL tracked paths:\n%s\n' "$$tracked"; exit 1; fi
	@printf '%s\n' 'NO_TESTS_INVENTORY_PASS'
