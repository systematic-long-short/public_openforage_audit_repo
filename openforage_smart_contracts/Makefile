# OPENFORAGE_AUDIT_GATE_MAKEFILE_R37

SLITHER ?= .venv/bin/slither
SLITHER_JSON ?= /tmp/openforage-slither-results.json
SEMGREP ?= .venv/bin/semgrep
ECHIDNA_IMAGE ?= trailofbits/echidna:latest
ECHIDNA ?= env PATH=$(CURDIR)/.venv/bin:$(PATH) .venv/bin/echidna
ECHIDNA_CONTRACT ?= EchidnaCrownInvariants
HALMOS ?= .venv/bin/halmos

.PHONY: audit audit-static audit-fuzz audit-fuzz-long audit-formal audit-all audit-foundry audit-i15

audit: audit-static audit-fuzz audit-formal audit-foundry

audit-all: audit-static audit-fuzz-long audit-formal audit-foundry

audit-static: audit-i15
	$(RM) $(SLITHER_JSON)
	$(SLITHER) . --config-file slither.config.json --json $(SLITHER_JSON) || node script/check_slither_suppressions.js $(SLITHER_JSON) slither_suppressions.json
	node script/check_semgrep_rule_coverage.js .semgrep/openforage.yml
	$(SEMGREP) --config .semgrep/openforage.yml --error

audit-i15:
	node script/check_i15_setters.js

audit-fuzz:
	$(ECHIDNA) test/echidna/EchidnaCrownInvariants.sol --contract $(ECHIDNA_CONTRACT) --config echidna.yaml --test-limit 50000

audit-fuzz-long:
	$(ECHIDNA) test/echidna/EchidnaCrownInvariants.sol --contract $(ECHIDNA_CONTRACT) --config echidna.yaml --test-limit 200000

audit-formal:
	$(HALMOS) --config halmos.toml --match-contract "Halmos_I1_Solvency"
	$(HALMOS) --config halmos.toml --match-contract "Halmos_I2_BurnBeforeWithdraw|Halmos_I2_BurnBeforeWithdraw_AtRISKUSD"
	$(HALMOS) --config halmos.toml --match-contract "Halmos_I4_BackingPerShareMonotonic"

audit-foundry:
	forge test --match-contract '.*(Invariant|I4_BackingPerShareMonotonicity).*'
