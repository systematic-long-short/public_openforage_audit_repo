// Materialized from documentation/smart_contract_audits/2026-05-30-cantina-audit/openforage_audit_repo — Scan #4 — findings.md lines 3517-3674.
// Original audit path: terminal/static tooling PoC. Finding: OPEN-54 (Informational).
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AuditSemgrepRuleAssertions.sol";

/**
 * @title Fix proof: Semgrep solvency rule targets live RISKUSDVault path
 * @notice The audit gate must scan the live RISKUSDVault file that owns value-moving
 * paths and _assertSolvency(); the retired RISKUSDCVault glob must not be accepted.
 */
contract POC_AuditToolingSolvencyRule_OPEN54 is AuditSemgrepRuleAssertions {
    function test_semgrepSolvencyRuleTargetsLiveRiskusdVault() public view {
        string memory semgrep = vm.readFile(".semgrep/openforage.yml");
        string memory rule = _semgrepRule(semgrep, "openforage-no-skip-of-assert-solvency");
        string memory vault = vm.readFile("src/RISKUSDVault.sol");

        _assertContains(
            rule,
            "    paths:\n      include:\n        - \"**/src/RISKUSDVault.sol\"\n",
            "solvency rule must include exactly the live RISKUSDVault glob"
        );
        _assertNotContains(rule, "**/src/RISKUSDCVault.sol", "retired RISKUSDCVault glob must be removed");
        _assertNotContains(rule, "RISKUSDVault.sol.bak", "dead RISKUSDVault suffix globs must not pass");

        _assertContains(vault, "function deposit(uint256 usdcAmount)", "live vault has deposit path");
        _assertContains(vault, "function redeem(uint256 riskusdAmount)", "live vault has redeem path");
        _assertContains(vault, "function deployCapital(uint256 usdcAmount)", "live vault has deploy path");
        _assertContains(vault, "function _assertSolvency()", "live vault has solvency guard");

        string memory makefile = vm.readFile("Makefile");
        string memory guard = vm.readFile("script/check_semgrep_rule_coverage.js");
        _assertContains(
            makefile,
            "node script/check_semgrep_rule_coverage.js .semgrep/openforage.yml",
            "audit-static must run the semgrep zero-file guard"
        );
        _assertContains(guard, "OPENFORAGE_SEMGREP_RULE_COVERAGE", "semgrep rule coverage guard sentinel missing");
        _assertContains(guard, "globToRegExp", "semgrep guard must resolve include globs");
    }
}
