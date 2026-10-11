# OPENFORAGE_AUDIT_GATE_MAKEFILE_R37

FORGE ?= forge
SLITHER ?= .venv/bin/slither
SEMGREP ?= .venv/bin/semgrep
AUDIT_CAPTURE_DIR ?= ../../.tmp/audit-static-captures

.PHONY: audit audit-static audit-i15 audit-legacy audit-simplify no-tests

audit: audit-static

audit-static: no-tests audit-i15 audit-legacy
	FORGE="$(FORGE)" SLITHER="$(SLITHER)" node script/check_semgrep_rule_coverage.js --capture-audit "$(AUDIT_CAPTURE_DIR)"
	node script/check_semgrep_rule_coverage.js --static-controls
	node script/check_semgrep_rule_coverage.js --preflight
	AUDIT_CAPTURE_DIR="$(AUDIT_CAPTURE_DIR)" SEMGREP="$(SEMGREP)" node script/check_semgrep_rule_coverage.js --run .semgrep/openforage.yml
	AUDIT_CAPTURE_DIR="$(AUDIT_CAPTURE_DIR)" SEMGREP="$(SEMGREP)" node script/check_semgrep_rule_coverage.js --run .semgrep/disjointness-grant-role.yml
	node script/check_semgrep_rule_coverage.js --reuse-audit "$(AUDIT_CAPTURE_DIR)"

audit-i15: no-tests
	node script/check_i15_setters.js

audit-legacy: no-tests
	node script/check_no_legacy_transport.js

audit-simplify: no-tests
	FOUNDRY_PROFILE=default node script/check_simplify_regression.js

no-tests:
	@if [ -e test ]; then printf '%s\n' 'NO_TESTS_INVENTORY_FAIL path=test/'; exit 1; fi
	@for path in script/DeployTestEnv.s.sol script/FinalAuditWetPrimaryFlow.s.sol script/TestContracts.sol script/gen_selector_sweep.py script/hyperliquid/HyperCoreAgentApprovalProbe.sol echidna.yaml halmos.toml; do \
		if [ -e "$$path" ]; then printf 'NO_TESTS_INVENTORY_FAIL path=%s\n' "$$path"; exit 1; fi; \
	done
	@tracked_status=0; tracked="$$(git -C .. ls-files -- 'openforage_smart_contracts/test/**' 'openforage_smart_contracts/script/DeployTestEnv.s.sol' 'openforage_smart_contracts/script/FinalAuditWetPrimaryFlow.s.sol' 'openforage_smart_contracts/script/TestContracts.sol' 'openforage_smart_contracts/script/gen_selector_sweep.py' 'openforage_smart_contracts/script/hyperliquid/HyperCoreAgentApprovalProbe.sol' 'openforage_smart_contracts/echidna.yaml' 'openforage_smart_contracts/halmos.toml' 2>/dev/null)" || tracked_status=$$?; \
		if [ "$$tracked_status" -ne 0 ]; then printf '%s\n' 'NO_TESTS_INVENTORY_GIT_CONTEXT_UNAVAILABLE'; exit 2; fi; \
		if [ -n "$$tracked" ]; then printf 'NO_TESTS_INVENTORY_FAIL tracked paths:\n%s\n' "$$tracked"; exit 1; fi
	@printf '%s\n' 'NO_TESTS_INVENTORY_PASS'
