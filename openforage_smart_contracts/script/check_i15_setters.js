#!/usr/bin/env node
/*
 * I-15 critical-setter lint.
 *
 * Fails when a known trust-boundary setter is present without the delayed
 * propose/finalize surface required by defence_in_depth.md § I-15 / R-33.
 */

const fs = require("fs");
const path = require("path");

function renderStandardLogLine(record) {
  const information = String(record.information).replace(/[\r\n]+/g, "\\n");
  return (
    `severity=${record.severity} group=${record.groupId} log=${record.logId} ` +
    `SERVICE=${record.service} SUB-SERVICE=${record.subService} ` +
    `COMPONENT=${record.component} FUNCTION=${record.function} ` +
    `FILE:${record.file}:${record.line} information=${information}`
  );
}

let diagnosticLogId = 0;

function writeDiagnosticError(information) {
  diagnosticLogId += 1;
  process.stderr.write(
    `${renderStandardLogLine({
      severity: "ERROR",
      timestamp: new Date().toISOString(),
      groupId: "-",
      logId: diagnosticLogId,
      service: "scripts",
      subService: "smart_contracts",
      component: "check_i15_setters",
      function: "writeDiagnosticError",
      file: "openforage_smart_contracts/script/check_i15_setters.js",
      line: 19,
      information,
    })}\n`,
  );
}

const SRC_DIR = path.join(__dirname, "..", "src");
const MODULES_DIR = path.join(SRC_DIR, "modules");
const FINALIZE_DELAY_PROFILE = path.join(SRC_DIR, "FinalizeDelayProfile.sol");

const BASELINE_TRUST_SETTER_COUNT = 15;

const TRUST_SENSITIVE_SETTERS = {
  "atRISKUSD.sol:setYieldSource": {
    propose: "proposeYieldSource",
    finalize: "finalizeYieldSource",
    cancel: "clearPendingYieldSource",
  },
  "atRISKUSD.sol:setStakingQueue": {
    propose: "proposeStakingQueue",
    finalize: "finalizeStakingQueue",
    cancel: "clearPendingStakingQueue",
  },
  "atRISKUSD.sol:setForageGovernor": {
    propose: "setForageGovernor",
    finalize: "finalizeForageGovernor",
    cancel: "clearPendingForageGovernor",
  },
  "RISKUSD.sol:setMinter": {
    propose: "proposeMinter",
    finalize: "finalizeMinter",
    cancel: "clearPendingMinter",
  },
  "RISKUSD.sol:setForageGovernor": {
    propose: "setForageGovernor",
    finalize: "finalizeForageGovernor",
    cancel: "clearPendingForageGovernor",
  },
  "RISKUSDVault.sol:setCustodian": {
    propose: "proposeCustodian",
    finalize: "finalizeCustodian",
    cancel: "clearPendingCustodian",
  },
  "RISKUSDVault.sol:setLossReporter": {
    propose: "proposeLossReporter",
    finalize: "finalizeLossReporter",
    cancel: "clearPendingLossReporter",
  },
  "RISKUSDVault.sol:setForageGovernor": {
    propose: "setForageGovernor",
    finalize: "finalizeForageGovernor",
    cancel: "clearPendingForageGovernor",
  },
  "StakingQueue.sol:setForagePriceOracle": {
    propose: "proposeForagePriceOracle",
    finalize: "finalizeForagePriceOracle",
    cancel: "clearPendingForagePriceOracle",
  },
  "StakingQueue.sol:setForageGovernor": {
    propose: "setForageGovernor",
    finalize: "finalizeForageGovernor",
    cancel: "clearPendingForageGovernor",
  },
  "CustodianRegistry.sol:setAllowedPeer": {
    propose: "proposeAllowedPeer",
    finalize: "finalizeAllowedPeer",
    cancel: "cancelPendingAllowedPeer",
  },
  "CustodianRegistry.sol:setCustodianRole": {
    propose: "proposeCustodianRole",
    finalize: "finalizeCustodianRole",
    cancel: "cancelPendingCustodianRole",
  },
  "Allowlist.sol:proposeRegistrar": {
    propose: "proposeRegistrar",
    finalize: "finalizeRegistrar",
    cancel: "cancelRegistrar",
  },
  "Allowlist.sol:proposeGuardian": {
    propose: "proposeGuardian",
    finalize: "finalizeGuardian",
    cancel: "cancelGuardian",
  },
  "Allowlist.sol:proposeSystemRegistrar": {
    propose: "proposeSystemRegistrar",
    finalize: "finalizeSystemRegistrar",
    cancel: "cancelSystemRegistrar",
  },
};

const DOCUMENTED_NON_TRUST_BOUNDARY_SETTERS = {
  "FORAGETreasury.sol:setDistributor":
    "two-step setDistributor/acceptDistributor handoff: the owner stages _pendingDistributor and only that address can acceptDistributor, bounded by the tightening-only per-day distributor cap in shrinkDistributorDailyCap (DEC-1046 KYC-15).",
  "USDCTreasury.sol:setDistributor":
    "two-step setDistributor/acceptDistributor handoff: the owner stages _pendingDistributor and only that address can acceptDistributor, bounded by the per-day distributor cap (DEC-1046 KYC-15).",
  "RISKUSDVault.sol:setMinimumFirstDeposit":
    "KYC-03 basis floor: onlyAllowedCaller + onlyOwner writes the per-basis minimum first deposit the deposit path enforces; it moves no funds and no custody, so the caller gate plus owner authority is the control.",
  "RISKUSDVault.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "RISKUSD.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "atRISKUSD.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "StakingQueue.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "ForageToken.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "FORAGETreasury.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "USDCTreasury.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "ForageGovernor.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist under the timelock/executor authority; the target probe reverts AllowlistUnavailable on a bad target, so a bad target cannot silently lock the gate.",
  "GuardianModule.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist under the current-timelock authority; the target probe reverts AllowlistUnavailable on a bad target, so a bad target cannot silently lock the gate.",
  "Blocklist.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "CustodianRegistry.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist: the target must be a contract whose isSystemAccount(this) staticcall returns or the call reverts AllowlistUnavailable, so a bad target cannot silently lock the gate.",
  "VaultRegistry.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist; the entry is present before this adopter lands so the lint result does not depend on landing order.",
  "HLTradingBridge.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist under the current-timelock authority; the target probe reverts AllowlistUnavailable on a bad target, so a bad target cannot silently lock the gate.",
  "DelegatingVestingWallet.sol:setAllowlist":
    "probed caller-gate re-point through AllowlistGatedUpgradeable._setAllowlist under the token-setter authority; the target probe reverts AllowlistUnavailable on a bad target, so a bad target cannot silently lock the gate.",
  "Allowlist.sol:approveOperator":
    "owner-only direct operator approval with no expiry; revoke is open to the registrar or guardian, so the authority is revocable without a delayed rotation channel.",
  "Allowlist.sol:shrinkApprovalsPerDayCap":
    "owner-or-guardian tightening-only cap shrink (CapNotShrunk on any raise); it removes authority only, so a delay would only delay a safety action.",
  "Allowlist.sol:setSystemAccount":
    "owner-or-system-registrar boolean system flag; every adopter re-reads isAllowed per call through the caller gate, so the flag passes the gate without holding fund custody (KYC-01).",
};

const TRUST_NAME_PATTERN = /(?:Custodian|LossReporter|Depositor|Distributor|Executor|Guardian|Governor|Peer|Oracle|Minter|VaultRegistry|RISKUSDVault|YieldSource|StakingQueue|Allowlist|MinimumFirstDeposit)/;

function listSolidityFiles(dir) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listSolidityFiles(fullPath));
    } else if (entry.isFile() && entry.name.endsWith(".sol")) {
      files.push(fullPath);
    }
  }
  return files;
}

function lineNumberAt(source, index) {
  return source.slice(0, index).split("\n").length;
}

function findOnlyOwnerSetters(filePath, source) {
  const setters = [];
  const functionRegex = /function\s+(set[A-Za-z0-9_]*)\s*\(([^)]*)\)\s*([^{;]*)\{/g;
  let match;
  while ((match = functionRegex.exec(source)) !== null) {
    const [, name, params, modifiers] = match;
    if (!/\bonlyOwner\b/.test(modifiers)) continue;
    if (!/(address|bytes32|uint8|uint256)/.test(params)) continue;
    if (!TRUST_NAME_PATTERN.test(name)) continue;
    setters.push({
      file: path.basename(filePath),
      path: filePath,
      name,
      line: lineNumberAt(source, match.index),
    });
  }
  return setters;
}

function hasFunction(source, functionName) {
  return new RegExp(`function\\s+${functionName}\\s*\\(`).test(source);
}

function functionBody(source, functionName) {
  const signature = new RegExp(`function\\s+${functionName}\\s*\\(`, "g");
  const match = signature.exec(source);
  if (!match) return null;

  const open = source.indexOf("{", match.index);
  if (open === -1) return null;

  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") depth -= 1;
    if (depth === 0) return source.slice(match.index, i + 1);
  }
  return null;
}

function containsAll(body, needles) {
  return needles.every((needle) => body.includes(needle));
}

function moduleFunctionBody(functionName) {
  if (!fs.existsSync(MODULES_DIR)) return null;
  for (const filePath of listSolidityFiles(MODULES_DIR)) {
    const body = functionBody(fs.readFileSync(filePath, "utf8"), functionName);
    if (body) return body;
  }
  return null;
}

function resolveDelegatedBody(body, functionName) {
  if (!body || !body.includes("_delegateToModule()")) return body;
  return moduleFunctionBody(functionName) || body;
}

function parseDelaySeconds(source, constantName = "FINALIZE_DELAY") {
  const escapedName = constantName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(
    `uint256\\s+(?:public|internal|private)\\s+constant\\s+${escapedName}\\s*=\\s*([^;]+);`
  );
  const match = source.match(pattern);
  if (!match) return null;

  const expr = match[1].trim();
  const days = expr.match(/^(\d+)\s+days$/);
  if (days) return Number(days[1]) * 24 * 60 * 60;

  const hours = expr.match(/^(\d+)\s+hours$/);
  if (hours) return Number(hours[1]) * 60 * 60;

  const minutes = expr.match(/^(\d+)\s+minutes$/);
  if (minutes) return Number(minutes[1]) * 60;

  const seconds = expr.match(/^(\d+)$/);
  if (seconds) return Number(seconds[1]);

  return null;
}

function delaySourceSeconds(source, profileDelaySeconds) {
  return parseDelaySeconds(source) || (source.includes("FinalizeDelayProfile") ? profileDelaySeconds : null);
}

function cancelAuthorityKind(cancelBody) {
  if (cancelBody.includes("_canCancelPendingTrustChange()")) return "guardian-cancel";
  if (/\bonlyOwner\b/.test(cancelBody)) return "owner-only";
  if (cancelBody.includes("_isGuardianModule(msg.sender)") || cancelBody.includes("msg.sender != _guardianModule")) {
    return "guardian-module";
  }
  if (cancelBody.includes("msg.sender != _guardian") || cancelBody.includes("msg.sender == _guardian")) return "guardian";
  return "unknown";
}

function enforcesDelayAndExpiry(source, finalizeBody) {
  if (hasDelayGuard(finalizeBody) && finalizeBody.includes("PROPOSAL_EXPIRY")) return true;
  for (const helperName of ["_validatePendingDelay", "_requireProposalReady"]) {
    if (!finalizeBody.includes(helperName)) continue;
    const helperBody = functionBody(source, helperName) || "";
    if (hasDelayGuard(helperBody) && helperBody.includes("PROPOSAL_EXPIRY")) return true;
  }
  return false;
}

function hasDelayGuard(body) {
  return body.includes("FINALIZE_DELAY") || body.includes("_finalizeDelay()");
}

function parseArgs() {
  return {
    json: process.argv.includes("--json"),
  };
}

function validateTrustSetter(setter, source, finalizeDelaySeconds, failures) {
  const outcome = {
    checked: 0,
    delayChecked: 0,
    cancelChecked: 0,
    guardianCancelChecked: 0,
    registryRecheckChecked: 0,
  };
  const key = `${setter.file}:${setter.name}`;
  const spec = TRUST_SENSITIVE_SETTERS[key];
  if (!spec && DOCUMENTED_NON_TRUST_BOUNDARY_SETTERS[key]) return outcome;
  if (!spec) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 review missing for ${setter.name}. ` +
      "Add this setter to TRUST_SENSITIVE_SETTERS with propose/finalize coverage, " +
      "or document why it is not a trust-boundary setter."
    );
    return outcome;
  }

  outcome.checked += 1;
  const required = [spec.propose, spec.finalize, spec.cancel];
  const missing = required.filter((fn) => !hasFunction(source, fn));
  const finalizeBody = resolveDelegatedBody(functionBody(source, spec.finalize), spec.finalize);
  const proposeBody = functionBody(source, spec.propose);
  const cancelBody = functionBody(source, spec.cancel);

  if (missing.length > 0 || !finalizeDelaySeconds || finalizeDelaySeconds < 2 * 24 * 60 * 60) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 violation for ${setter.name}. ` +
      `Missing ${missing.join(", ") || "production finalize delay >= 2 days"}. ` +
      "Remediation: route the setter through a pending slot, propose* function, " +
      "finalize* function, and production finalize delay >= 2 days. See " +
      "documentation/smart_contract_audits/defence_in_depth.md § I-15 / R-33."
    );
    return outcome;
  }

  outcome.delayChecked += 1;

  if (!enforcesDelayAndExpiry(source, finalizeBody || "")) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 finalizer for ${setter.name} must enforce both ` +
      "the effective finalize delay and PROPOSAL_EXPIRY."
    );
  }

  if (!cancelBody) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 cancellation surface missing for ${setter.name}.`
    );
  } else {
    const authority = cancelAuthorityKind(cancelBody);
    if (authority === "unknown") {
      failures.push(
        `${setter.path}:${setter.line}: I-15 cancellation surface ${spec.cancel} has no recognizable ` +
        "owner/guardian authorization guard."
      );
    } else {
      outcome.cancelChecked += 1;
    }

    if (spec.guardianCancel) {
      if (authority !== "guardian-cancel" || !source.includes("PERMISSION_CAN_CANCEL")) {
        failures.push(
          `${setter.path}:${setter.line}: I-15 guardian-cancel path for ${setter.name} must use ` +
          "GuardianModule PERMISSION_CAN_CANCEL and must not grant finalize authority."
        );
      } else {
        outcome.guardianCancelChecked += 1;
      }
    }
  }

  if (spec.proposeChecks && !containsAll(proposeBody || "", spec.proposeChecks)) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 proposal-time allowlist/registry re-check missing for ${setter.name}.`
    );
  }

  if (spec.finalizeChecks && !containsAll(finalizeBody || "", spec.finalizeChecks)) {
    failures.push(
      `${setter.path}:${setter.line}: I-15 finalize-time allowlist/registry re-check missing for ${setter.name}.`
    );
  }

  if (spec.proposeChecks || spec.finalizeChecks) {
    outcome.registryRecheckChecked += 1;
  }

  return outcome;
}

function findAllowlistRotationSetters(source, filePath) {
  return Object.keys(TRUST_SENSITIVE_SETTERS)
    .filter((key) => key.startsWith("Allowlist.sol:"))
    .map((key) => {
      const name = key.slice("Allowlist.sol:".length);
      const match = new RegExp(`function\\s+${name}\\s*\\(`).exec(source);
      return {
        file: "Allowlist.sol",
        path: filePath,
        name,
        line: match ? lineNumberAt(source, match.index) : 1,
      };
    });
}

function main() {
  const args = parseArgs();
  const failures = [];
  let checked = 0;
  let delayChecked = 0;
  let cancelChecked = 0;
  let guardianCancelChecked = 0;
  let registryRecheckChecked = 0;
  const profileSource = fs.readFileSync(FINALIZE_DELAY_PROFILE, "utf8");
  const productionFinalizeDelaySeconds = parseDelaySeconds(profileSource, "_PRODUCTION_FINALIZE_DELAY");
  if (!productionFinalizeDelaySeconds || productionFinalizeDelaySeconds < 2 * 24 * 60 * 60) {
    failures.push(
      `${FINALIZE_DELAY_PROFILE}: I-15 violation. ` +
      "FinalizeDelayProfile production delay must remain >= 2 days."
    );
  }

  for (const filePath of listSolidityFiles(SRC_DIR)) {
    const source = fs.readFileSync(filePath, "utf8");
    if (!source.includes("onlyOwner")) continue;
    const finalizeDelaySeconds = delaySourceSeconds(source, productionFinalizeDelaySeconds);

    for (const setter of findOnlyOwnerSetters(filePath, source)) {
      const outcome = validateTrustSetter(setter, source, finalizeDelaySeconds, failures);
      checked += outcome.checked;
      delayChecked += outcome.delayChecked;
      cancelChecked += outcome.cancelChecked;
      guardianCancelChecked += outcome.guardianCancelChecked;
      registryRecheckChecked += outcome.registryRecheckChecked;
    }
  }

  const allowlistPath = path.join(SRC_DIR, "Allowlist.sol");
  const allowlistSource = fs.readFileSync(allowlistPath, "utf8");
  const allowlistDelaySeconds = delaySourceSeconds(allowlistSource, productionFinalizeDelaySeconds);
  for (const setter of findAllowlistRotationSetters(allowlistSource, allowlistPath)) {
    const outcome = validateTrustSetter(setter, allowlistSource, allowlistDelaySeconds, failures);
    checked += outcome.checked;
    delayChecked += outcome.delayChecked;
    cancelChecked += outcome.cancelChecked;
    guardianCancelChecked += outcome.guardianCancelChecked;
    registryRecheckChecked += outcome.registryRecheckChecked;
  }

  if (checked < BASELINE_TRUST_SETTER_COUNT) {
    failures.push(
      `I-15 regression: checked ${checked} trust-boundary setters, below baseline ${BASELINE_TRUST_SETTER_COUNT}.`
    );
  }

  if (failures.length > 0) {
    writeDiagnosticError("I-15 critical-setter lint failed:");
    for (const failure of failures) writeDiagnosticError(`- ${failure}`);
    process.exit(1);
  }

  const result = {
    checked,
    minChecked: BASELINE_TRUST_SETTER_COUNT,
    delayChecked,
    cancelChecked,
    guardianCancelChecked,
    registryRecheckChecked,
  };

  if (args.json) {
    console.log(JSON.stringify(result));
  } else {
    console.log(
      `I-15 critical-setter lint passed (${checked} trust-boundary setters checked; ` +
      `${delayChecked} production finalize delay>=2d; ${cancelChecked} cancel surfaces; ` +
      `${guardianCancelChecked} guardian-CANCEL surfaces; ${registryRecheckChecked} registry/allowlist re-checks).`
    );
  }
}

main();
