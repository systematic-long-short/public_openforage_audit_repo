#!/usr/bin/env node
/*
 * I-15 critical-setter lint.
 *
 * Fails when a known trust-boundary setter is present without the delayed
 * propose/finalize surface required by defence_in_depth.md § I-15 / R-33.
 */

const fs = require("fs");
const path = require("path");

const SRC_DIR = path.join(__dirname, "..", "src");
const FINALIZE_DELAY_PROFILE = path.join(SRC_DIR, "FinalizeDelayProfile.sol");

const BASELINE_TRUST_SETTER_COUNT = 12;

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
};

const DOCUMENTED_NON_TRUST_BOUNDARY_SETTERS = {};

const TRUST_NAME_PATTERN = /(?:Custodian|LossReporter|Depositor|Distributor|Executor|Guardian|Governor|Peer|Oracle|Minter|VaultRegistry|RISKUSDVault|YieldSource|StakingQueue)/;

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
    if (!/(address|bytes32)/.test(params)) continue;
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
  if (!finalizeBody.includes("_validatePendingDelay")) return false;
  const helperBody = functionBody(source, "_validatePendingDelay") || "";
  return hasDelayGuard(helperBody) && helperBody.includes("PROPOSAL_EXPIRY");
}

function hasDelayGuard(body) {
  return body.includes("FINALIZE_DELAY") || body.includes("_finalizeDelay()");
}

function parseArgs() {
  return {
    json: process.argv.includes("--json"),
  };
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
      const key = `${setter.file}:${setter.name}`;
      const spec = TRUST_SENSITIVE_SETTERS[key];
      if (!spec && DOCUMENTED_NON_TRUST_BOUNDARY_SETTERS[key]) continue;
      if (!spec) {
        failures.push(
          `${setter.path}:${setter.line}: I-15 review missing for ${setter.name}. ` +
          "Add this setter to TRUST_SENSITIVE_SETTERS with propose/finalize coverage, " +
          "or document why it is not a trust-boundary setter."
        );
        continue;
      }

      checked += 1;
      const required = [spec.propose, spec.finalize, spec.cancel];
      const missing = required.filter((fn) => !hasFunction(source, fn));
      const finalizeBody = functionBody(source, spec.finalize);
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
        continue;
      }

      delayChecked += 1;

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
          cancelChecked += 1;
        }

        if (spec.guardianCancel) {
          if (authority !== "guardian-cancel" || !source.includes("PERMISSION_CAN_CANCEL")) {
            failures.push(
              `${setter.path}:${setter.line}: I-15 guardian-cancel path for ${setter.name} must use ` +
              "GuardianModule PERMISSION_CAN_CANCEL and must not grant finalize authority."
            );
          } else {
            guardianCancelChecked += 1;
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
        registryRecheckChecked += 1;
      }
    }
  }

  if (checked < BASELINE_TRUST_SETTER_COUNT) {
    failures.push(
      `I-15 regression: checked ${checked} trust-boundary setters, below baseline ${BASELINE_TRUST_SETTER_COUNT}.`
    );
  }

  if (failures.length > 0) {
    console.error("I-15 critical-setter lint failed:");
    for (const failure of failures) console.error(`- ${failure}`);
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
