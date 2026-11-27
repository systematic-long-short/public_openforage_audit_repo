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

function contractsRootFromArguments() {
  const index = process.argv.indexOf("--contracts-root");
  if (index < 0) return path.resolve(__dirname, "..");
  const requestedRoot = process.argv[index + 1];
  if (!requestedRoot || requestedRoot.startsWith("--")) {
    writeDiagnosticError("I-15 source checker requires a path after --contracts-root.");
    process.exit(64);
  }
  return path.resolve(requestedRoot);
}

const CONTRACTS_ROOT = contractsRootFromArguments();
const SRC_DIR = path.join(CONTRACTS_ROOT, "src");
const MODULES_DIR = path.join(SRC_DIR, "modules");
const FINALIZE_DELAY_PROFILE = path.join(SRC_DIR, "FinalizeDelayProfile.sol");
const DEPLOY_SCRIPT = path.join(CONTRACTS_ROOT, "script", "Deploy.s.sol");

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
  "USDCTreasury.sol:setLossRateCapBps":
    "numeric loss-rate policy parameter, not a recipient, role, or provider writer; onlyOwner sets the cap while the guardian path can only tighten it. DEC-10 measures depositor-tier loss and excludes reserve-absorbed loss.",
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
  "FORAGETreasury.sol:setVestingWalletAllowlist":
    "owner and current-eligible forwarder restricted to a recorded Treasury wallet and the ForageToken's active or pending Allowlist; the route only completes a staged provider handoff and cannot select a foreign registry.",
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
  "CustodianRegistry.sol:setEmergencyPrincipalLane":
    "DEC-41 freezes a direct owner, onlyAllowedCaller, freshOnly binding; the selected lane must have code and its current principalLaneOpen view controls only the principal-return cap bypass.",
  "HLTradingBridge.sol:setEmergencyPrincipalLane":
    "DEC-41 binds the fresh-deployment setter to the owner and allowlisted caller; it rejects zero or code-less lanes and emits the old and new binding, while the configured lane only disables the daily principal-return cap and the host retains deployed-principal, blocklist, open-lane and current-guardian checks.",
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

const TRUST_NAME_PATTERN = /(?:Custodian|LossReporter|Depositor|Distributor|Executor|Guardian|Governor|Peer|Oracle|Minter|Registrar|VaultRegistry|RISKUSDVault|YieldSource|StakingQueue|Allowlist|MinimumFirstDeposit|EmergencyPrincipalLane)/;

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

function maskSolidityNonCode(source) {
  const characters = source.split("");
  let state = "code";
  let quote = "";
  for (let index = 0; index < characters.length; index += 1) {
    const current = characters[index];
    const next = characters[index + 1];
    if (state === "line-comment") {
      if (current === "\n") state = "code";
      else characters[index] = " ";
      continue;
    }
    if (state === "block-comment") {
      if (current === "*" && next === "/") {
        characters[index] = " ";
        characters[index + 1] = " ";
        index += 1;
        state = "code";
      } else if (current !== "\n") {
        characters[index] = " ";
      }
      continue;
    }
    if (state === "string") {
      if (current === "\\") {
        if (current !== "\n") characters[index] = " ";
        if (index + 1 < characters.length) {
          if (characters[index + 1] !== "\n") characters[index + 1] = " ";
          index += 1;
        }
        continue;
      }
      if (current === quote) state = "code";
      if (current !== "\n") characters[index] = " ";
      continue;
    }
    if (current === "/" && next === "/") {
      characters[index] = " ";
      characters[index + 1] = " ";
      index += 1;
      state = "line-comment";
      continue;
    }
    if (current === "/" && next === "*") {
      characters[index] = " ";
      characters[index + 1] = " ";
      index += 1;
      state = "block-comment";
      continue;
    }
    if (current === "\"" || current === "'") {
      quote = current;
      characters[index] = " ";
      state = "string";
    }
  }
  return characters.join("");
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function matchingDelimiter(source, start, left, right) {
  let depth = 0;
  for (let index = start; index < source.length; index += 1) {
    if (source[index] === left) depth += 1;
    if (source[index] === right) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function solidityDeclarations(source, keyword, name) {
  const code = maskSolidityNonCode(source);
  const namePattern = name === undefined ? "[A-Za-z_][A-Za-z0-9_]*" : escapeRegex(name);
  const pattern = new RegExp("\\b" + keyword + "\\s+(" + namePattern + ")\\s*\\(", "g");
  const declarations = [];
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const openParen = match.index + match[0].lastIndexOf("(");
    const closeParen = matchingDelimiter(code, openParen, "(", ")");
    if (closeParen < 0) return declarations;
    const openBrace = code.indexOf("{", closeParen + 1);
    const semicolon = code.indexOf(";", closeParen + 1);
    const hasBody = openBrace >= 0 && (semicolon < 0 || openBrace < semicolon);
    let headerEnd = semicolon < 0 ? code.length : semicolon;
    let body = null;
    let nextIndex = headerEnd + 1;
    if (hasBody) {
      const closeBrace = matchingDelimiter(code, openBrace, "{", "}");
      if (closeBrace < 0) return declarations;
      headerEnd = openBrace;
      body = code.slice(openBrace + 1, closeBrace);
      nextIndex = closeBrace + 1;
    }
    declarations.push({
      name: match[1],
      parameters: code.slice(openParen + 1, closeParen),
      header: code.slice(match.index, headerEnd),
      body,
      line: lineNumberAt(source, match.index),
    });
    pattern.lastIndex = Math.max(nextIndex, match.index + match[0].length);
  }
  return declarations;
}

function solidityFunctionDeclarations(source, name) {
  return solidityDeclarations(source, "function", name);
}

function solidityModifierDeclarations(source, name) {
  return solidityDeclarations(source, "modifier", name);
}

function compactSolidity(source) {
  return maskSolidityNonCode(source).replace(/\s+/g, "");
}

function hasEligibleOwnerGuard(source) {
  const code = maskSolidityNonCode(source);
  if (/\bassembly\b|\bdelegatecall\b/.test(code)) return false;
  const modifiers = solidityModifierDeclarations(source, "onlyEligibleOwner");
  if (modifiers.length !== 1 || modifiers[0].body === null) return false;
  if (compactSolidity(modifiers[0].header) !== "modifieronlyEligibleOwner()") return false;
  if (compactSolidity(modifiers[0].parameters) !== "") return false;
  if (compactSolidity(modifiers[0].body) !== "_requireEligibleOwner();_;") return false;

  const helpers = solidityFunctionDeclarations(source, "_requireEligibleOwner");
  if (helpers.length !== 1 || helpers[0].body === null) return false;
  if (compactSolidity(helpers[0].header) !== "function_requireEligibleOwner()privateview") return false;
  if (compactSolidity(helpers[0].parameters) !== "") return false;
  if (
    compactSolidity(helpers[0].body) !==
    "if(msg.sender!=owner()||!_isAllowed(msg.sender)){revertOwnableUnauthorizedAccount(msg.sender);}"
  ) return false;

  const eligibility = solidityFunctionDeclarations(source, "_isAllowed");
  if (eligibility.length !== 1 || eligibility[0].body === null) return false;
  if (compactSolidity(eligibility[0].header) !== "function_isAllowed(addressaccount)privateviewreturns(bool)") return false;
  if (compactSolidity(eligibility[0].parameters) !== "addressaccount") return false;
  return compactSolidity(eligibility[0].body) ===
    "return_systemAccounts[account]||_allowedUntil[account]>=uint64(block.timestamp);";
}

function functionHasEligibleOwnerGuard(record, source) {
  if (!record || record.body === null) return false;
  const closeParameters = record.header.indexOf(")");
  if (closeParameters < 0) return false;
  const suffix = compactSolidity(record.header.slice(closeParameters + 1));
  return suffix === "externalonlyEligibleOwner" && hasEligibleOwnerGuard(source);
}

function stateWritePattern(namePattern) {
  const slot = namePattern + "(?:\\s*\\[[^\\]]*\\])*";
  const lvalue = "(?:\\(\\s*)*" + slot + "(?:\\s*\\))*";
  return new RegExp(
    "(?:" + lvalue + "\\s*(?:=(?!=)|\\+=|-=|\\*=|/=|%=|\\|=|&=|\\^=|<<=|>>=|\\+\\+|--|\\.(?:push|pop|add|remove|set|clear)\\s*\\()|" +
    "(?:\\+\\+|--)\\s*" + lvalue + "|\\bdelete\\s+" + lvalue + ")",
    "i"
  );
}

const ALLOWLIST_ROTATION_FIELDS = {
  _registrar: ["finalizeRegistrar"],
  _pendingRegistrar: ["proposeRegistrar", "finalizeRegistrar", "cancelRegistrar"],
  _pendingRegistrarProposedAt: ["proposeRegistrar", "finalizeRegistrar", "cancelRegistrar"],
  _guardian: ["initialize", "finalizeGuardian"],
  _pendingGuardian: ["proposeGuardian", "finalizeGuardian", "cancelGuardian"],
  _pendingGuardianProposedAt: ["proposeGuardian", "finalizeGuardian", "cancelGuardian"],
  _systemRegistrars: ["finalizeSystemRegistrar"],
  _pendingSystemRegistrar: ["proposeSystemRegistrar", "finalizeSystemRegistrar", "cancelSystemRegistrar"],
  _pendingSystemRegistrarIsSystem: ["proposeSystemRegistrar", "finalizeSystemRegistrar", "cancelSystemRegistrar"],
  _pendingSystemRegistrarProposedAt: ["proposeSystemRegistrar", "finalizeSystemRegistrar", "cancelSystemRegistrar"],
};

const ALLOWLIST_CALLER_ROLE_READERS = {
  _registrar: ["approve", "revoke"],
  _guardian: ["revoke", "shrinkApprovalsPerDayCap"],
  _systemRegistrars: ["setSystemAccount"],
};

const ALLOWLIST_CALLER_POLICY_READERS = {
  _systemAccounts: ["acceptOwnership", "approve", "approveOperator", "approveVestingBeneficiary", "cancelGuardian",
    "cancelRegistrar", "cancelSystemRegistrar", "finalizeGuardian", "finalizeRegistrar", "finalizeSystemRegistrar",
    "proposeGuardian", "proposeRegistrar", "proposeSystemRegistrar", "registerVoteEligibilityObserver", "revoke",
    "setSystemAccount", "shrinkApprovalsPerDayCap", "transferOwnership", "_authorizeUpgrade"],
  _allowedUntil: ["acceptOwnership", "approve", "approveOperator", "approveVestingBeneficiary", "cancelGuardian",
    "cancelRegistrar", "cancelSystemRegistrar", "finalizeGuardian", "finalizeRegistrar", "finalizeSystemRegistrar",
    "proposeGuardian", "proposeRegistrar", "proposeSystemRegistrar", "revoke", "setSystemAccount",
    "shrinkApprovalsPerDayCap", "transferOwnership", "_authorizeUpgrade"],
  _voteEligibilityObserver: ["registerVoteEligibilityObserver", "unregisterVoteEligibilityObserver"],
};

const ALLOWLIST_CALLER_WRITERS = {
  _systemAccounts: ["revoke", "setSystemAccount"],
  _allowedUntil: ["_approveOperator", "approve", "approveOperator", "approveVestingBeneficiary", "initialize", "revoke"],
  _voteEligibilityObserver: ["registerVoteEligibilityObserver", "unregisterVoteEligibilityObserver"],
};

function allowlistStateFields(source) {
  const code = maskSolidityNonCode(source);
  const contractIndex = code.indexOf("contract Allowlist");
  const open = code.indexOf("{", contractIndex);
  if (contractIndex < 0 || open < 0) return new Set();
  const close = matchingDelimiter(code, open, "{", "}");
  if (close < 0) return new Set();
  const fields = new Set();
  let depth = 0;
  let start = open + 1;
  for (let index = open + 1; index < close; index += 1) {
    if (code[index] === "{") depth += 1;
    else if (code[index] === "}") depth -= 1;
    else if (code[index] === ";" && depth === 0) {
      const declaration = code.slice(start, index).trim();
      const field = declaration.match(/\b(?:public|private|internal)\s+(?:(?:constant|immutable)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*(?:=|$)/);
      const implicit = declaration.match(/^(?:mapping\s*\([^;]*\)|[A-Za-z_][A-Za-z0-9_.]*(?:\s*\[[^\]]*\])?)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*(?:=|$)/);
      if (field) fields.add(field[1]);
      else if (implicit && !/^(?:using|event|error|function|modifier)\b/.test(declaration)) fields.add(implicit[1]);
      start = index + 1;
    }
  }
  return fields;
}

function solidityConditions(body) {
  const code = maskSolidityNonCode(body || "");
  const conditions = [];
  const matcher = /\b(?:if|require)\s*\(/g;
  let match;
  while ((match = matcher.exec(code)) !== null) {
    const open = code.indexOf("(", match.index);
    const close = matchingDelimiter(code, open, "(", ")");
    if (close < 0) return [];
    conditions.push(code.slice(open + 1, close));
    matcher.lastIndex = close + 1;
  }
  return conditions;
}

function calledFunctionNames(source, text) {
  const names = new Set();
  for (const match of maskSolidityNonCode(text || "").matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) {
    if (solidityFunctionDeclarations(source, match[1]).some((record) => record.body !== null)) names.add(match[1]);
  }
  return names;
}

function localStateAliases(body, stateFields) {
  const code = maskSolidityNonCode(body || "");
  const aliases = new Map();
  const pattern = /\b(?:address|bool|u?int\d*|bytes\d*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;]+);/g;
  let changed = true;
  while (changed) {
    changed = false;
    for (const match of code.matchAll(pattern)) {
      const [, local, expression] = match;
      const field = [...stateFields].find((item) => new RegExp(`\\b${escapeRegex(item)}\\b`).test(expression)) ||
        [...aliases].find(([name]) => new RegExp(`\\b${escapeRegex(name)}\\b`).test(expression))?.[1];
      if (field && aliases.get(local) !== field) {
        aliases.set(local, field);
        changed = true;
      }
    }
  }
  return aliases;
}

function localStorageStateAliases(body, field) {
  const code = maskSolidityNonCode(body || "");
  const declarations = [...code.matchAll(/\bstorage\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*([^;]+))?;/g)]
    .map((match) => ({name: match[1], expression: match[2] || ""}));
  const locals = new Set(declarations.map((item) => item.name));
  const aliases = new Set();
  const fieldPattern = new RegExp(`\\b${escapeRegex(field)}\\b`);
  const refersToField = (expression) => fieldPattern.test(expression) || [...aliases].some((alias) =>
    new RegExp(`\\b${escapeRegex(alias)}\\b`).test(expression));
  let changed = true;
  while (changed) {
    changed = false;
    for (const declaration of declarations) {
      if (refersToField(declaration.expression) && !aliases.has(declaration.name)) {
        aliases.add(declaration.name);
        changed = true;
      }
    }
    for (const local of locals) {
      const assignment = new RegExp(`\\b${escapeRegex(local)}\\s*=(?!=)\\s*([^;]+);`, "g");
      for (const match of code.matchAll(assignment)) {
        if (refersToField(match[1]) && !aliases.has(local)) {
          aliases.add(local);
          changed = true;
        }
      }
    }
  }
  const storageReference = new RegExp(`\\bstorage\\b[^;]*\\b${escapeRegex(field)}\\b`).test(code);
  const modeledReference = declarations.some((item) => aliases.has(item.name));
  let writeCode = code.replace(/\bstorage\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:=\s*[^;]+)?;/g, " ");
  for (const local of locals) {
    const assignment = new RegExp(`\\b${escapeRegex(local)}\\s*=(?!=)\\s*[^;]+;`, "g");
    writeCode = writeCode.replace(assignment, " ");
  }
  return {aliases, unmodelled: storageReference && !modeledReference, writeCode};
}

function allowlistFieldIsStorageReference(source, field) {
  const code = maskSolidityNonCode(source);
  const contractIndex = code.indexOf("contract Allowlist");
  const open = code.indexOf("{", contractIndex);
  if (contractIndex < 0 || open < 0) return true;
  const close = matchingDelimiter(code, open, "{", "}");
  if (close < 0) return true;
  const enums = new Set([...code.matchAll(/\benum\s+([A-Za-z_][A-Za-z0-9_]*)/g)].map((match) => match[1]));
  const values = new Set([...code.matchAll(/\btype\s+([A-Za-z_][A-Za-z0-9_]*)\s+is\b/g)].map((match) => match[1]));
  const contracts = new Set([...code.matchAll(/\b(?:contract|interface|library)\s+([A-Za-z_][A-Za-z0-9_]*)/g)]
    .map((match) => match[1]));
  const target = new RegExp(`\\b${escapeRegex(field)}\\b`);
  let depth = 0;
  let start = open + 1;
  for (let index = open + 1; index < close; index += 1) {
    if (code[index] === "{") depth += 1;
    else if (code[index] === "}") depth -= 1;
    else if (code[index] === ";" && depth === 0) {
      const declaration = code.slice(start, index).trim();
      const match = target.exec(declaration);
      if (match) {
        const before = declaration.slice(0, match.index).replace(/\b(?:public|private|internal|constant|immutable)\b/g, " ")
          .replace(/\s+/g, " ").trim();
        const after = declaration.slice(match.index + field.length);
        if (/\bmapping\s*\(|\b(?:bytes|string)\b|\[[^\]]*\]/.test(before) || /^\s*\[[^\]]*\]/.test(after)) {
          return true;
        }
        const typeName = before.split(" ").pop() || "";
        const scalar = /^(?:address(?: payable)?|payable|bool|u?int\d*|bytes(?:[1-9]|[12]\d|3[0-2])|fixed\d*x\d+|ufixed\d*x\d+)$/;
        const qualified = typeName.split(".").pop();
        if (scalar.test(before) || enums.has(qualified) || values.has(qualified) || contracts.has(qualified)) return false;
        return true;
      }
      start = index + 1;
    }
  }
  return true;
}

function splitSolidityArguments(source) {
  if (!source.trim()) return [];
  const argumentsList = [];
  let start = 0;
  let parentheses = 0;
  let brackets = 0;
  let braces = 0;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (character === "," && parentheses === 0 && brackets === 0 && braces === 0) {
      argumentsList.push(source.slice(start, index));
      start = index + 1;
    } else if (character === "(") parentheses += 1;
    else if (character === ")") parentheses -= 1;
    else if (character === "[") brackets += 1;
    else if (character === "]") brackets -= 1;
    else if (character === "{") braces += 1;
    else if (character === "}") braces -= 1;
  }
  argumentsList.push(source.slice(start));
  return argumentsList;
}

function compactOuterParentheses(source) {
  let compact = source.replace(/\s+/g, "");
  while (compact.startsWith("(") && matchingDelimiter(compact, 0, "(", ")") === compact.length - 1) {
    compact = compact.slice(1, -1);
  }
  return compact;
}

function callArgumentLists(body) {
  const code = maskSolidityNonCode(body || "");
  const argumentLists = [];
  for (const match of code.matchAll(/\b[A-Za-z_][A-Za-z0-9_]*\s*\(/g)) {
    const open = code.indexOf("(", match.index);
    const close = matchingDelimiter(code, open, "(", ")");
    if (close < 0) return null;
    argumentLists.push(splitSolidityArguments(code.slice(open + 1, close)));
  }
  return argumentLists;
}

function passesSelectedStorageReference(body, field, aliases, source) {
  if (!allowlistFieldIsStorageReference(source, field)) return false;
  const argumentsList = callArgumentLists(body);
  if (argumentsList === null) return true;
  const references = new Set([field, ...aliases]);
  return argumentsList.some((callArguments) => callArguments.some((argument) =>
    references.has(compactOuterParentheses(argument))));
}

function returnsSelectedStorageReference(record, field, aliases) {
  if (!record || record.body === null) return false;
  const returns = /\breturns\s*\(/.exec(record.header || "");
  if (!returns) return false;
  const open = record.header.indexOf("(", returns.index);
  const close = matchingDelimiter(record.header, open, "(", ")");
  if (close < 0 || !/\bstorage\b/.test(record.header.slice(open + 1, close))) return close < 0;
  const references = new Set([field, ...aliases]);
  return [...references].some((reference) => new RegExp(`\\b${escapeRegex(reference)}\\b`).test(record.body));
}

function collectHelperStateFields(source, body, stateFields, helpers, result, visited) {
  for (const field of stateFields) {
    if (new RegExp(`\\b${escapeRegex(field)}\\b`).test(body || "")) result.add(field);
  }
  for (const name of calledFunctionNames(source, body)) {
    if (visited.has(name)) continue;
    visited.add(name);
    for (const helper of helpers.filter((record) => record.name === name && record.body !== null)) {
      collectHelperStateFields(source, helper.body, stateFields, helpers, result, visited);
    }
  }
}

function allowlistCallerFieldReaders(source) {
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const modifiers = solidityModifierDeclarations(source).filter((record) => record.body !== null);
  const helpers = [...functions, ...modifiers];
  const stateFields = allowlistStateFields(source);
  const readers = new Map([...stateFields].map((field) => [field, new Set()]));
  for (const record of functions) {
    const fields = new Set();
    const aliases = localStateAliases(record.body, stateFields);
    for (const condition of solidityConditions(record.body)) {
      if (!/\bmsg\.sender\b/.test(condition)) continue;
      collectHelperStateFields(source, condition, stateFields, helpers, fields, new Set());
      for (const [local, field] of aliases) {
        if (new RegExp(`\\b${escapeRegex(local)}\\b`).test(condition)) fields.add(field);
      }
    }
    const suffix = record.header.slice(record.header.indexOf(")") + 1);
    for (const modifier of modifiers) {
      if (new RegExp(`\\b${escapeRegex(modifier.name)}\\b(?:\\s*\\([^)]*\\))?`).test(suffix)) {
        collectHelperStateFields(source, modifier.body, stateFields, helpers, fields, new Set());
      }
    }
    const externallyReachable = /\b(?:external|public)\b|\bonly[A-Z_][A-Za-z0-9_]*\b/.test(record.header);
    if (!externallyReachable) continue;
    for (const field of fields) readers.get(field)?.add(record.name);
  }
  return readers;
}

function functionWritesStateField(record, field, source, functions, visited = new Set()) {
  if (!record || record.body === null || visited.has(record.name)) return false;
  visited.add(record.name);
  if (stateWritePattern(`\\b${escapeRegex(field)}\\b`).test(record.body)) return true;
  const storageAliases = localStorageStateAliases(record.body, field);
  if (storageAliases.unmodelled) return true;
  for (const alias of storageAliases.aliases) {
    if (stateWritePattern(`\\b${escapeRegex(alias)}\\b`).test(storageAliases.writeCode)) return true;
  }
  if (passesSelectedStorageReference(record.body, field, storageAliases.aliases, source)) return true;
  if (returnsSelectedStorageReference(record, field, storageAliases.aliases)) return true;
  for (const name of calledFunctionNames(source, record.body)) {
    const helper = functions.find((item) => item.name === name && item.body !== null);
    if (helper && functionWritesStateField(helper, field, source, functions, visited)) return true;
  }
  return false;
}

function allowlistAuthorityGraphFailures(source, filePath) {
  const failures = [];
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const readers = allowlistCallerFieldReaders(source);
  const expectedReaders = {...ALLOWLIST_CALLER_ROLE_READERS, ...ALLOWLIST_CALLER_POLICY_READERS};
  for (const [field, expectedNames] of Object.entries(expectedReaders)) {
    const actualNames = [...(readers.get(field) || [])].sort();
    if (JSON.stringify(actualNames) !== JSON.stringify([...expectedNames].sort())) {
      failures.push(`${filePath}: I-15 caller-authority reader inventory changed for ${field}: ${actualNames.join(",")}.`);
    }
  }
  const knownFields = new Set(Object.keys(expectedReaders));
  for (const [field, actualNames] of readers) {
    if (!actualNames.size || knownFields.has(field)) continue;
    const writers = functions.filter((record) => functionWritesStateField(record, field, source, functions))
      .map((record) => record.name).sort();
    failures.push(`${filePath}: unclassified caller authority field ${field}; consumers=${[...actualNames].sort().join(",")}; writers=${writers.join(",")}.`);
  }
  for (const [field, expectedWriters] of Object.entries(ALLOWLIST_CALLER_WRITERS)) {
    const actualWriters = functions.filter((record) => functionWritesStateField(record, field, source, functions))
      .map((record) => record.name).sort();
    if (JSON.stringify(actualWriters) !== JSON.stringify([...expectedWriters].sort())) {
      failures.push(`${filePath}: Allowlist caller-authority writer inventory changed for ${field}: ${actualWriters.join(",")}.`);
    }
  }
  return failures;
}

function allowlistRotationEdgeFailures(source, filePath) {
  const failures = [];
  const expected = new Set(Object.keys(TRUST_SENSITIVE_SETTERS)
    .filter((key) => key.startsWith("Allowlist.sol:"))
    .flatMap((key) => {
      const spec = TRUST_SENSITIVE_SETTERS[key];
      return [spec.propose, spec.finalize, spec.cancel];
    }));
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  for (const name of expected) {
    const definitions = functions.filter((record) => record.name === name);
    if (definitions.length !== 1 || !functionHasEligibleOwnerGuard(definitions[0], source)) {
      failures.push(`${filePath}: I-15 staged Allowlist edge ${name} must remain unique and currently owner-eligible.`);
    }
  }
  const writerFailure = (field, expectedWriters) => {
    const actual = functions.filter((record) => functionWritesStateField(record, field, source, functions) &&
      !(field === "_guardian" && record.name === "initialize" &&
        compactSolidity(record.body).includes("_guardian=guardian_;")))
      .map((record) => record.name).sort();
    const expectedNames = [...expectedWriters].filter((name) => name !== "initialize").sort();
    if (JSON.stringify(actual) !== JSON.stringify(expectedNames)) {
      failures.push(`${filePath}: I-15 staged-role storage writer inventory changed for ${field}.`);
    }
  };
  for (const [field, expectedWriters] of Object.entries(ALLOWLIST_ROTATION_FIELDS)) {
    writerFailure(field, expectedWriters);
  }
  return failures;
}

function allowlistRegistrationOperationFailures(source, filePath) {
  const failures = [];
  const revoke = solidityFunctionDeclarations(source, "revoke");
  const systemSetter = solidityFunctionDeclarations(source, "setSystemAccount");
  const registration = solidityFunctionDeclarations(source, "_updateVestingSourceRegistration");
  const pendingSetter = solidityFunctionDeclarations(source, "_setVestingSourceRegistrationPending");
  if (revoke.length !== 1 || systemSetter.length !== 1 || registration.length !== 1 || pendingSetter.length !== 1) {
    return [`${filePath}: Allowlist registration-operation inventory is incomplete or ambiguous.`];
  }
  const revokeBody = compactSolidity(revoke[0].body);
  const revokeRole = revokeBody.indexOf("if(msg.sender!=_registrar&&msg.sender!=_guardian)revertNotGuardianOrRegistrar();");
  const revokeEligibility = revokeBody.indexOf("if(!_isAllowed(msg.sender))revertIAllowlist.CallerNotAllowed(msg.sender);");
  const revokeEffect = revokeBody.indexOf("_captureEligibilityBaseline(account);");
  if (revokeRole < 0 || revokeEligibility <= revokeRole || revokeEffect <= revokeEligibility ||
      !revokeBody.includes("_updateVestingSourceRegistration(account,false);")) {
    failures.push(`${filePath}: Allowlist.revoke must retain registrar/guardian identity and current eligibility before effects.`);
  }
  const systemBody = compactSolidity(systemSetter[0].body);
  const systemRole = systemBody.indexOf("if(msg.sender!=owner()&&!_systemRegistrars[msg.sender])revertNotSystemRegistrar();");
  const systemEligibility = systemBody.indexOf("if(!_isAllowed(msg.sender))revertIAllowlist.CallerNotAllowed(msg.sender);");
  const systemZero = systemBody.indexOf("if(account==address(0))revertZeroAddress();");
  const systemRegistration = systemBody.indexOf("_updateVestingSourceRegistration(account,isSystem);");
  const systemWrite = systemBody.indexOf("_systemAccounts[account]=isSystem;");
  if (systemRole < 0 || systemEligibility <= systemRole || systemZero <= systemEligibility ||
      systemRegistration <= systemZero || systemWrite <= systemRegistration) {
    failures.push(`${filePath}: Allowlist.setSystemAccount must retain owner/system-registrar eligibility before state writes.`);
  }
  if (!compactSolidity(registration[0].header).includes("private") ||
      !compactSolidity(pendingSetter[0].header).includes("private")) {
    failures.push(`${filePath}: vesting registration marker helpers must remain private.`);
  }
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const registrationCallers = functions.filter((record) => record.body.includes("_updateVestingSourceRegistration("))
    .map((record) => record.name).sort();
  const pendingCallers = functions.filter((record) => record.name !== "_setVestingSourceRegistrationPending" &&
    record.body.includes("_setVestingSourceRegistrationPending("))
    .map((record) => record.name).sort();
  const markerWrites = functions.filter((record) =>
    stateWritePattern("\\b_pendingVestingSourceRegistration\\b").test(record.body)).map((record) => record.name).sort();
  if (JSON.stringify(registrationCallers) !== JSON.stringify(["revoke", "setSystemAccount"]) ||
      JSON.stringify(pendingCallers) !== JSON.stringify(["_updateVestingSourceRegistration"]) ||
      JSON.stringify(markerWrites) !== JSON.stringify(["_setVestingSourceRegistrationPending"])) {
    failures.push(`${filePath}: vesting marker helpers must remain an internal route behind the two guarded Allowlist operations.`);
  }
  return failures;
}

function allowlistAuthorityGraphFailures(source, filePath) {
  const failures = [];
  const stateFields = allowlistStateFields(source);
  const readers = allowlistCallerFieldReaders(source);
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const expectedReaders = {...ALLOWLIST_CALLER_ROLE_READERS, ...ALLOWLIST_CALLER_POLICY_READERS};
  for (const [field, expectedNames] of Object.entries(expectedReaders)) {
    if (!stateFields.has(field)) {
      failures.push(`${filePath}: caller-authority state field is missing ${field}.`);
      continue;
    }
    const actualNames = [...(readers.get(field) || [])].sort();
    if (JSON.stringify(actualNames) !== JSON.stringify([...expectedNames].sort())) {
      failures.push(`${filePath}: caller-authority consumer inventory changed for ${field}: ${actualNames.join(",")}.`);
    }
  }
  const knownFields = new Set(Object.keys(expectedReaders));
  for (const [field, consumers] of readers) {
    if (consumers.size && !knownFields.has(field)) {
      const writers = functions.filter((record) => functionWritesStateField(record, field, source, functions))
        .map((record) => record.name).sort();
      failures.push(`${filePath}: unclassified caller authority field ${field}; consumers=${[...consumers].sort().join(",")}; writers=${writers.join(",")}.`);
    }
  }
  for (const [field, expectedWriters] of Object.entries(ALLOWLIST_CALLER_WRITERS)) {
    const actualWriters = functions.filter((record) => functionWritesStateField(record, field, source, functions))
      .map((record) => record.name).sort();
    if (JSON.stringify(actualWriters) !== JSON.stringify([...expectedWriters].sort())) {
      failures.push(`${filePath}: caller-authority writer inventory changed for ${field}: ${actualWriters.join(",")}.`);
    }
  }
  return failures;
}

function allowlistPendingMutationFailures(source, filePath) {
  const code = maskSolidityNonCode(source);
  const failures = [];
  if (/\bassembly\b|\bdelegatecall\b/.test(code)) {
    failures.push(`${filePath}: I-15 staged-role check refuses assembly or delegatecall in Allowlist.`);
  }
  if (/\bmodifier\s+[A-Za-z_][A-Za-z0-9_]*\b(?!\s*\()/.test(code)) {
    failures.push(`${filePath}: I-15 staged-role check refuses unsupported modifier declarations.`);
  }
  failures.push(...allowlistRotationEdgeFailures(source, filePath));
  failures.push(...allowlistRegistrationOperationFailures(source, filePath));
  failures.push(...allowlistAuthorityGraphFailures(source, filePath));
  for (const [field, expectedWriters] of Object.entries(ALLOWLIST_ROTATION_FIELDS)) {
    if (!expectedWriters.length) failures.push(`${filePath}: I-15 staged-role field inventory is empty for ${field}.`);
  }
  return failures;
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

function cancelAuthorityKind(cancelRecord, source) {
  if (!cancelRecord || cancelRecord.body === null) return "unknown";
  const cancelBody = cancelRecord.body;
  if (cancelBody.includes("_canCancelPendingTrustChange()")) return "guardian-cancel";
  if (/\bonlyOwner\b/.test(cancelRecord.header)) return "owner-only";
  if (/\bonlyEligibleOwner\b/.test(cancelRecord.header) && hasEligibleOwnerGuard(source)) return "owner-only";
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
    staticControls: process.argv.includes("--static-controls"),
  };
}

function setupFailure(failures, filePath, finding, detail) {
  failures.push(`${filePath}: ${finding}: ${detail}`);
}

function setupFunction(source, name, filePath, finding, failures) {
  const declarations = solidityFunctionDeclarations(source, name);
  if (declarations.length !== 1 || declarations[0].body === null) {
    setupFailure(failures, filePath, "SETUP-PARSER-UNSUPPORTED", `${finding}: expected one parsed ${name} body.`);
    return null;
  }
  return declarations[0];
}

function setupCallOrder(record, calls, filePath, finding, failures) {
  if (!record) return;
  const code = compactSolidity(record.body);
  let previous = -1;
  for (const call of calls) {
    const needle = compactSolidity(call);
    const position = code.indexOf(needle);
    const matches = code.match(new RegExp(escapeRegex(needle), "g")) || [];
    if (position < 0 || matches.length !== 1 || position <= previous) {
      setupFailure(failures, filePath, finding, `unsupported call order near ${call}; each reviewed call must occur once.`);
      return;
    }
    previous = position;
  }
}

function setupHeader(record, expected, filePath, finding, failures) {
  if (!record) return;
  if (compactSolidity(record.header) !== compactSolidity(expected)) {
    setupFailure(failures, filePath, finding, "setter or initializer header changed from its reviewed gate.");
  }
}

function checkForageInitialization(source, filePath, failures) {
  const initialize = setupFunction(source, "initialize", filePath, "bootstrap initializer", failures);
  if (!initialize) return;
  setupHeader(
    initialize,
    "function initialize(address teamVestingAddress_, address forageTreasuryAddress_, address initialOwner_) external onlyDuringConstructionBeforeInitialization initializer",
    filePath,
    "SETUP-FORAGE-BOOTSTRAP",
    failures,
  );
  const code = compactSolidity(initialize.body);
  const calls = Array.from(initialize.body.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g), (match) => match[1]);
  const allowed = new Set([
    "if",
    "address",
    "ZeroAddress",
    "__ERC20_init",
    "__ERC20Permit_init",
    "__ERC20Votes_init",
    "__Ownable_init",
    "__Ownable2Step_init",
    "_delegateStateModuleInitialization",
    "abi",
    "encodeCall",
    "initializeSourceInventory",
    "_mint",
  ]);
  const unexpected = calls.filter((name) => !allowed.has(name));
  const genesisMints = [
    "_mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);",
    "_mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);",
  ];
  const inventoryCallSource = "_delegateStateModuleInitialization(abi.encodeCall(ForageTokenStateModule.initializeSourceInventory, ()));";
  const initializationWithoutInventoryCall = initialize.body.replace(inventoryCallSource, "");
  if (
    unexpected.length > 0 ||
    /\bassembly\b|\bdelegatecall\b|\bstaticcall\b|\.\s*[A-Za-z_]\w*\s*\(/.test(initializationWithoutInventoryCall)
  ) {
    setupFailure(failures, filePath, "SETUP-PARSER-UNSUPPORTED", `bootstrap initializer call graph changed: ${unexpected.join(", ") || "external-call shape"}.`);
  }
  const mintPositions = genesisMints.map((mint) => code.indexOf(compactSolidity(mint)));
  const inventoryCall = compactSolidity(inventoryCallSource);
  const inventoryPosition = code.indexOf(inventoryCall);
  const inventoryCallCount = code.match(new RegExp(escapeRegex(inventoryCall), "g")) || [];
  const mintCounts = genesisMints.map((mint) => code.match(new RegExp(escapeRegex(compactSolidity(mint)), "g")) || []);
  const mintCalls = code.match(/\b_mint\s*\(/g) || [];
  if (inventoryPosition < 0 || inventoryCallCount.length !== 1 || inventoryPosition > mintPositions[0]) {
    setupFailure(failures, filePath, "SETUP-FORAGE-INVENTORY", "fresh inventory marker must be initialized before the first genesis mint.");
  }
  if (mintCalls.length !== genesisMints.length) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BOOTSTRAP", `expected exactly two initializer mint calls, found ${mintCalls.length}.`);
  }
  if (mintPositions.some((position) => position < 0) || mintPositions[0] >= mintPositions[1]) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BOOTSTRAP", "the two canonical genesis mints must occur in order.");
  }
  for (const [index, mint] of genesisMints.entries()) {
    const needle = compactSolidity(mint);
    if (mintCounts[index].length !== 1) {
      setupFailure(failures, filePath, "SETUP-FORAGE-BOOTSTRAP", `expected one genesis mint ${needle}.`);
    }
  }
}

function replaceSetupText(source, before, after, name) {
  const position = source.indexOf(before);
  if (position < 0) throw new Error(`static setup control is missing ${name}`);
  return `${source.slice(0, position)}${after}${source.slice(position + before.length)}`;
}

function expectSetupRefusal(name, predicate, expectedFinding = null) {
  const failures = [];
  predicate(failures);
  if (failures.length === 0) throw new Error(`static setup control was accepted: ${name}`);
  if (expectedFinding && !failures.some((failure) => failure.includes(expectedFinding))) {
    throw new Error(`static setup control missed ${expectedFinding}: ${name}`);
  }
  return {name, predicateReached: true, rejected: true, findings: failures.map((failure) => failure.split(": ").slice(1).join(": "))};
}

function evaluateAllowancePositiveControl(name, tokenSource, initialState, actions) {
  const tokenPath = path.join(SRC_DIR, "ForageToken.sol");
  const failures = [];
  checkForageNormalCalls(tokenSource, tokenPath, failures);
  checkForageSetterGates(tokenSource, tokenPath, failures);
  const resetGuard = solidityFunctionDeclarations(tokenSource, "_requireExplicitAllowanceReset");
  const resetCode = resetGuard.length === 1 && resetGuard[0].body !== null
    ? compactSolidity(resetGuard[0].body)
    : "";
  const expectedReset = compactSolidity(
    "uint256 currentAllowance = allowance(owner_, spender); " +
    "if (currentAllowance != 0 || _explicitZeroResetRequired[owner_][spender]) { " +
    "revert AllowanceChangeRequiresZero(spender, currentAllowance, value); }",
  );
  if (resetCode !== expectedReset) {
    failures.push(`${tokenPath}: SETUP-FORAGE-PERMIT-POLICY: allowance predicate is outside its reviewed source shape.`);
  }
  const predicateReached = failures.length === 0;
  const state = {allowance: initialState.allowance, marker: initialState.marker};
  const trace = [];
  if (predicateReached) {
    for (const action of actions) {
      const resetRequired = state.allowance !== 0 || state.marker;
      const blocked = action.value !== 0 && resetRequired;
      const accepted = !blocked;
      trace.push({
        operation: action.operation,
        value: action.value,
        allowanceBefore: state.allowance,
        markerBefore: state.marker,
        resetPredicate: action.value !== 0 ? resetRequired : false,
        accepted,
      });
      if (!accepted) break;
      state.allowance = action.value;
      state.marker = action.value !== 0;
    }
  }
  const accepted = predicateReached && trace.length === actions.length && trace.every((step) => step.accepted);
  return {
    name,
    target: {path: "src/ForageToken.sol", functions: ["approve", "permit", "_requireExplicitAllowanceReset"]},
    sourceSha256Base64Url: require("node:crypto").createHash("sha256").update(Buffer.from(tokenSource)).digest("base64url"),
    predicateReached,
    accepted,
    initialState,
    trace,
    finalState: state,
    scope: "bounded source-shape predicate evaluation; inherited calls are assumed successful; no Solidity execution",
  };
}

function runSetupControls() {
  const tokenPath = path.join(SRC_DIR, "ForageToken.sol");
  const riskusdPath = path.join(SRC_DIR, "RISKUSD.sol");
  const deployPath = DEPLOY_SCRIPT;
  const token = fs.readFileSync(tokenPath, "utf8");
  const riskusd = fs.readFileSync(riskusdPath, "utf8");
  const deploy = fs.readFileSync(deployPath, "utf8");
  const positiveFailures = [];
  checkForageInitialization(token, tokenPath, positiveFailures);
  checkForageGuard(token, tokenPath, positiveFailures);
  checkForageNormalCalls(token, tokenPath, positiveFailures);
  checkForageSetterGates(token, tokenPath, positiveFailures);
  checkRiskusdFreshOnly(riskusd, riskusdPath, positiveFailures);
  checkRiskusdAllowancePolicy(riskusd, riskusdPath, positiveFailures);
  checkDeploySetup(deploy, deployPath, positiveFailures);
  if (positiveFailures.length > 0) throw new Error(`real-source setup positive failed: ${positiveFailures.join("; ")}`);
  const allowancePositiveControls = [
    evaluateAllowancePositiveControl("first-permit-on-zero-allowance", token,
      {allowance: 0, marker: false}, [{operation: "permit", value: 60}]),
    evaluateAllowancePositiveControl("zero-reset-sequence", token,
      {allowance: 40, marker: true}, [{operation: "approve", value: 0}, {operation: "permit", value: 60}]),
  ];
  if (allowancePositiveControls.some((control) => !control.predicateReached || !control.accepted)) {
    throw new Error("allowance positive controls did not pass their evaluated source predicates");
  }
  const riskusdAllowanceControls = [
    evaluateRiskusdAllowanceControl("first-approval-from-zero", riskusd,
      {allowance: 0, marker: false}, [{operation: "approve", value: 60}], true),
    evaluateRiskusdAllowanceControl("zero-reset-after-live-allowance", riskusd,
      {allowance: 40, marker: true}, [{operation: "approve", value: 0}, {operation: "approve", value: 60}], true),
    evaluateRiskusdAllowanceControl("spent-old-allowance-still-requires-zero", riskusd,
      {allowance: 40, marker: true}, [{operation: "transferFrom", value: 40}, {operation: "approve", value: 60}], false),
  ];
  if (riskusdAllowanceControls.some((control) => !control.predicateReached || control.accepted !== control.expectedAccepted)) {
    throw new Error("RISKUSD allowance controls did not match their evaluated source predicates");
  }

  const controls = [];
  const thirdMint = replaceSetupText(token,
    "_mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);",
    "_mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);\n        _mint(address(0xBEEF), 1);",
    "third initializer mint");
  controls.push(expectSetupRefusal("third-initializer-mint", (failures) => checkForageInitialization(thirdMint, tokenPath, failures)));

  const mintOrder = replaceSetupText(token,
    "_mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);\n        _mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);",
    "_mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);\n        _mint(teamVestingAddress_, TEAM_VESTING_ALLOCATION);",
    "genesis mint order");
  controls.push(expectSetupRefusal("reversed-genesis-mints", (failures) => checkForageInitialization(mintOrder, tokenPath, failures)));

  const mintCount = replaceSetupText(token,
    "        _mint(forageTreasuryAddress_, FORAGE_TREASURY_ALLOCATION);\n",
    "",
    "missing second genesis mint");
  controls.push(expectSetupRefusal("missing-genesis-mint", (failures) => checkForageInitialization(mintCount, tokenPath, failures)));

  const missingActivationCallerGate = replaceSetupText(token,
    "function activateBlocklistRotation() external freshInventoryReady onlyAllowedCaller onlyOwner",
    "function activateBlocklistRotation() external freshInventoryReady onlyOwner",
    "rotation activation caller gate");
  controls.push(expectSetupRefusal("rotation-activation-caller-gate", (failures) => checkForageSetterGates(missingActivationCallerGate, tokenPath, failures)));

  const earlyRotationPointer = replaceSetupText(token,
    "ForageTokenStateModule.beginBlocklistRotation, (blocklist_)",
    "ForageTokenStateModule.activateBlocklistRotation, ()",
    "active pointer switch before staging");
  controls.push(expectSetupRefusal("rotation-pointer-switch-before-reconciliation", (failures) => checkForageSetterGates(earlyRotationPointer, tokenPath, failures)));

  const openEligibilityBridge = replaceSetupText(token,
    "        if (msg.sender != address(this)) revert UnauthorizedTokenQuery(msg.sender);\n",
    "",
    "public provider-eligibility helper");
  controls.push(expectSetupRefusal("eligibility-bridge-self-caller", (failures) => checkForageSetterGates(openEligibilityBridge, tokenPath, failures)));

  const rotationModulePath = path.join(MODULES_DIR, "ForageTokenStateModule.sol");
  const rotationModule = fs.readFileSync(rotationModulePath, "utf8");
  const staleSchemaStatus = replaceSetupText(rotationModule,
    "status.inventorySupported = state.inventoryVersion == 1 && state.projectionSchemaVersion == 4\n            && state.vestingMembershipSchemaVersion == 1 && state.voteEligibilitySyncSchemaVersion == 6\n            && state.epochs.length != 0;",
    "status.inventorySupported = state.inventoryVersion == 1 && state.projectionSchemaVersion == 3\n            && state.vestingMembershipSchemaVersion == 1 && state.voteEligibilitySyncSchemaVersion == 2\n            && state.epochs.length != 0;",
    "stale projection and sync schema status control");
  controls.push(expectSetupRefusal("stale-projection-and-sync-schema-refusal", (failures) =>
    checkForageFreshOnly(token, staleSchemaStatus, tokenPath, rotationModulePath, failures),
  "SETUP-FORAGE-LEGACY-REFUSAL"));
  const pastVotesFallback = replaceSetupText(token,
    "if (projection.blocked) return 0;\n        uint256 trackedVotes = projection.indexedVotes;",
    "if (projection.blocked) return 0;\n        uint256 trackedVotes = projection.indexedVotes + _pastLegacyEligibleVotes(account, timepoint, projection.blocklist);",
    "past legacy-source query fallback");
  controls.push(expectSetupRefusal("fresh-only-past-votes-legacy-fallback", (failures) =>
    checkForageFreshOnly(pastVotesFallback, rotationModule, tokenPath, rotationModulePath, failures)));

  const missingFreshRefusal = replaceSetupText(token,
    "if (!status.inventorySupported || status.epochCount == 0) {\n            revert LegacySourceInventoryUnavailable(_blocklist, address(0));\n        }",
    "",
    "fresh inventory refusal");
  controls.push(expectSetupRefusal("fresh-only-pre-fresh-refusal", (failures) =>
    checkForageFreshOnly(missingFreshRefusal, rotationModule, tokenPath, rotationModulePath, failures)));

  const beneficiaryFallback = replaceSetupText(rotationModule,
    "_historicalVestingSourceRegistration(query.allowlist, query.source, timepoint)",
    "_currentVestingSourceRegistration(query.source, query.allowlist)",
    "current beneficiary registration at queue drain");
  controls.push(expectSetupRefusal("fresh-only-beneficiary-fallback", (failures) =>
    checkForageFreshOnly(token, beneficiaryFallback, tokenPath, rotationModulePath, failures)));

  const unboundedRotationPage = replaceSetupText(rotationModule,
    "uint256 length = remaining > BLOCKLIST_ROTATION_PAGE_SIZE ? BLOCKLIST_ROTATION_PAGE_SIZE : remaining;",
    "uint256 length = remaining;",
    "unbounded rotation page");
  controls.push(expectSetupRefusal("unbounded-rotation-page", (failures) => checkForageRotationModule(unboundedRotationPage, rotationModulePath, failures)));

  const incompleteRotationActivation = replaceSetupText(rotationModule,
    "state.cursor != snapshot || state.processed < snapshot || state.dirty != 0",
    "state.cursor != snapshot || state.dirty != 0",
    "incomplete rotation acceptance");
  controls.push(expectSetupRefusal("rotation-activation-with-unprocessed-source", (failures) => checkForageRotationModule(incompleteRotationActivation, rotationModulePath, failures)));

  const mutableRotationPage = replaceSetupText(rotationModule,
    "uint256 remaining = snapshot - state.cursor;",
    "uint256 remaining = state.sources.length - state.cursor;",
    "live rotation inventory length");
  controls.push(expectSetupRefusal("rotation-page-uses-live-inventory", (failures) => checkForageRotationModule(mutableRotationPage, rotationModulePath, failures)));

  const movedRotationSnapshot = replaceSetupText(rotationModule,
    "state.pendingSnapshotLength = state.sources.length;",
    "state.pendingSnapshotLength = state.sources.length + 1;",
    "rotation snapshot capture");
  controls.push(expectSetupRefusal("rotation-snapshot-capture", (failures) => checkForageRotationModule(movedRotationSnapshot, rotationModulePath, failures)));

  const missingPendingProjection = replaceSetupText(rotationModule,
    "        _syncPendingProjection(rotation, sync);\n",
    "",
    "pending projection write");
  controls.push(expectSetupRefusal("missing-pending-projection-write",
    (failures) => checkForageRotationModule(missingPendingProjection, rotationModulePath, failures)));

  const approveGuard = replaceSetupText(token,
    "        if (value != 0) {\n            _requireNotBlocked(spender);\n            _requireExplicitAllowanceReset(owner_, spender, value);\n        }\n        bool approved = super.approve(spender, value);",
    "        bool approved = super.approve(spender, value);",
    "approve Blocklist/reset guard");
  controls.push(expectSetupRefusal("approve-guard-removed", (failures) =>
    checkForageNormalCalls(approveGuard, tokenPath, failures)));

  const permitGuard = replaceSetupText(token,
    "        if (value != 0) {\n            _requireNotBlocked(spender);\n            _requireExplicitAllowanceReset(owner_, spender, value);\n        }\n        super.permit(owner_, spender, value, deadline, v, r, s);",
    "        super.permit(owner_, spender, value, deadline, v, r, s);",
    "permit Blocklist/reset guard");
  controls.push(expectSetupRefusal("permit-guard-removed", (failures) =>
    checkForageSetterGates(permitGuard, tokenPath, failures)));

  const markerClearedOnSpend = replaceSetupText(token,
    "        return super.transferFrom(from, to, value);\n",
    "        bool transferred = super.transferFrom(from, to, value);\n        if (transferred) _explicitZeroResetRequired[from][msg.sender] = false;\n        return transferred;\n",
    "allowance marker clear on spend");
  controls.push(expectSetupRefusal("marker-cleared-on-spend", (failures) =>
    checkForageNormalCalls(markerClearedOnSpend, tokenPath, failures)));

  const approveMarkerBeforeSuccess = replaceSetupText(token,
    "        bool approved = super.approve(spender, value);\n        if (approved) _explicitZeroResetRequired[owner_][spender] = value != 0;",
    "        _explicitZeroResetRequired[owner_][spender] = value != 0;\n        bool approved = super.approve(spender, value);",
    "approve marker before inherited success");
  controls.push(expectSetupRefusal("approve-marker-written-before-success", (failures) =>
    checkForageNormalCalls(approveMarkerBeforeSuccess, tokenPath, failures)));

  const permitMarkerBeforeSuccess = replaceSetupText(token,
    "        super.permit(owner_, spender, value, deadline, v, r, s);\n        _explicitZeroResetRequired[owner_][spender] = value != 0;",
    "        _explicitZeroResetRequired[owner_][spender] = value != 0;\n        super.permit(owner_, spender, value, deadline, v, r, s);",
    "permit marker before inherited success");
  controls.push(expectSetupRefusal("permit-marker-written-before-success", (failures) =>
    checkForageSetterGates(permitMarkerBeforeSuccess, tokenPath, failures)));

  const directApproveBypass = replaceSetupText(token,
    "            _requireExplicitAllowanceReset(owner_, spender, value);\n",
    "            if (value != 0) return super.approve(spender, value);\n            _requireExplicitAllowanceReset(owner_, spender, value);\n",
    "direct nonzero approve bypass");
  controls.push(expectSetupRefusal("direct-nonzero-approve-bypasses-helper", (failures) =>
    checkForageNormalCalls(directApproveBypass, tokenPath, failures)));

  const missingMarkerPredicate = replaceSetupText(token,
    "currentAllowance != 0 || _explicitZeroResetRequired[owner_][spender]",
    "currentAllowance != 0",
    "shared reset helper marker predicate");
  controls.push(expectSetupRefusal("reset-helper-requires-live-allowance-or-marker", (failures) =>
    checkForageSetterGates(missingMarkerPredicate, tokenPath, failures)));

  const tokenOrderWithoutDelegate = replaceSetupText(deploy,
    "        DelegatingVestingWallet(deployedVestingWallet).setInitialDelegatee(cfg.launchVotingDelegate);\n",
    "",
    "initial delegation before Token Blocklist");
  const tokenOrder = replaceSetupText(tokenOrderWithoutDelegate,
    "        forageToken.setBlocklist(deployedBlocklist);\n",
    "        DelegatingVestingWallet(deployedVestingWallet).setInitialDelegatee(cfg.launchVotingDelegate);\n        forageToken.setBlocklist(deployedBlocklist);\n",
    "Token Blocklist wiring order");
  controls.push(expectSetupRefusal("token-blocklist-order", (failures) => checkDeploySetup(tokenOrder, deployPath, failures)));

  const queueOrder = replaceSetupText(deploy,
    "        StakingQueue(deployedStakingQueue).setBlocklist(deployedBlocklist);\n        StakingQueue(deployedStakingQueue).setVaultId(targetVaultId);",
    "        StakingQueue(deployedStakingQueue).setVaultId(targetVaultId);\n        StakingQueue(deployedStakingQueue).setBlocklist(deployedBlocklist);",
    "Queue Blocklist wiring order");
  controls.push(expectSetupRefusal("queue-blocklist-order", (failures) => checkDeploySetup(queueOrder, deployPath, failures)));

  const floorOrder = replaceSetupText(deploy,
    "        RISKUSDVault(deployedRiskusdVault).setVaultModule(implRiskusdVaultModule);\n        RISKUSDVault(deployedRiskusdVault).setMinimumFirstDeposit(2, 200_000e6);\n        StakingQueue(deployedStakingQueue).setQueueModule(implStakingQueueModule);",
    "        RISKUSDVault(deployedRiskusdVault).setVaultModule(implRiskusdVaultModule);\n        StakingQueue(deployedStakingQueue).setQueueModule(implStakingQueueModule);\n        RISKUSDVault(deployedRiskusdVault).setMinimumFirstDeposit(2, 200_000e6);",
    "basis-2 floor order");
  controls.push(expectSetupRefusal("basis2-floor-order", (failures) => checkDeploySetup(floorOrder, deployPath, failures)));

  const missingGuard = replaceSetupText(token,
    "        if (blocklist_ == address(0) && !_isInitializing()) revert InvalidBlocklist(address(0));\n",
    "",
    "zero Blocklist guard");
  controls.push(expectSetupRefusal("forage-blocklist-guard", (failures) => checkForageGuard(missingGuard, tokenPath, failures)));

  const missingBootstrap = replaceSetupText(token,
    "if (blocklist_ == address(0) && !_isInitializing()) revert InvalidBlocklist(address(0));",
    "if (blocklist_ == address(0)) revert InvalidBlocklist(address(0));",
    "initializer Blocklist exception");
  controls.push(expectSetupRefusal("forage-blocklist-bootstrap", (failures) => checkForageGuard(missingBootstrap, tokenPath, failures)));

  const riskusdApproveGuard = replaceSetupText(riskusd,
    "            _requireExplicitAllowanceReset(owner_, spender, value);\n",
    "",
    "RISKUSD approval reset guard");
  controls.push(expectSetupRefusal("riskusd-approve-replacement-guard", (failures) =>
    checkRiskusdAllowancePolicy(riskusdApproveGuard, riskusdPath, failures)));

  const riskusdMarkerPredicate = replaceSetupText(riskusd,
    "currentAllowance != 0 || _explicitZeroResetRequired[owner_][spender]",
    "currentAllowance != 0",
    "RISKUSD sticky reset marker predicate");
  controls.push(expectSetupRefusal("riskusd-spent-allowance-sticky-reset", (failures) =>
    checkRiskusdAllowancePolicy(riskusdMarkerPredicate, riskusdPath, failures)));

  const riskusdMarkerClearedOnSpend = replaceSetupText(riskusd,
    "        return super.transferFrom(from, to, value);\n",
    "        bool transferred = super.transferFrom(from, to, value);\n" +
      "        if (transferred) _explicitZeroResetRequired[from][msg.sender] = false;\n" +
      "        return transferred;\n",
    "RISKUSD reset marker cleared on transferFrom");
  controls.push(expectSetupRefusal("riskusd-marker-not-cleared-on-spend", (failures) =>
    checkRiskusdAllowancePolicy(riskusdMarkerClearedOnSpend, riskusdPath, failures)));

  const riskusdApproveGuardMissing = replaceSetupText(riskusd,
    "function approve(address spender, uint256 value) public override freshLayout returns (bool)",
    "function approve(address spender, uint256 value) public override returns (bool)",
    "RISKUSD approve fresh-layout guard");
  controls.push(expectSetupRefusal("riskusd-approve-fresh-layout-guard", (failures) =>
    checkRiskusdFreshOnly(riskusdApproveGuardMissing, riskusdPath, failures)));

  const riskusdEnumerationGuardMissing = replaceSetupText(riskusd,
    "function exemptAddresses() external view freshLayout returns (address[] memory)",
    "function exemptAddresses() external view returns (address[] memory)",
    "RISKUSD exemption enumeration fresh-layout guard");
  controls.push(expectSetupRefusal("riskusd-exempt-addresses-fresh-layout-guard", (failures) =>
    checkRiskusdFreshOnly(riskusdEnumerationGuardMissing, riskusdPath, failures)));

  const riskusdAdminGuardMissing = replaceSetupText(riskusd,
    "function setBlocklist(address blocklist_) external freshLayout onlyAllowedCaller onlyOwner",
    "function setBlocklist(address blocklist_) external onlyAllowedCaller onlyOwner",
    "RISKUSD administration fresh-layout guard");
  controls.push(expectSetupRefusal("riskusd-administration-fresh-layout-guard", (failures) =>
    checkRiskusdFreshOnly(riskusdAdminGuardMissing, riskusdPath, failures)));

  const riskusdUpdateGuardMissing = replaceSetupText(riskusd,
    "function _update(address from, address to, uint256 value) internal override freshLayout",
    "function _update(address from, address to, uint256 value) internal override",
    "RISKUSD token update fresh-layout guard");
  controls.push(expectSetupRefusal("riskusd-token-update-fresh-layout-guard", (failures) =>
    checkRiskusdFreshOnly(riskusdUpdateGuardMissing, riskusdPath, failures)));

  const riskusdUpgradeGuardMissing = replaceSetupText(riskusd,
    "function _authorizeUpgrade(address) internal override freshLayout onlyOwner",
    "function _authorizeUpgrade(address) internal override onlyOwner",
    "RISKUSD UUPS authorization fresh-layout guard");
  controls.push(expectSetupRefusal("riskusd-uups-fresh-layout-guard", (failures) =>
    checkRiskusdFreshOnly(riskusdUpgradeGuardMissing, riskusdPath, failures)));

  const riskusdMarkerMissing = replaceSetupText(riskusd,
    "        _freshLayoutVersion = _FRESH_LAYOUT_VERSION;\n",
    "",
    "RISKUSD fresh initializer marker");
  controls.push(expectSetupRefusal("riskusd-fresh-marker-initializer", (failures) =>
    checkRiskusdFreshOnly(riskusdMarkerMissing, riskusdPath, failures)));

  return {
    scope: "copied Solidity source text only; no compilation or contract execution",
    positive: {name: "exact-current-initializer-and-deploy", predicateReached: true, accepted: true},
    allowancePositiveControls,
    riskusdAllowanceControls,
    negativeCount: controls.length,
    negatives: controls,
  };
}

function rejectsI15SemanticControl(name, target, expectedFinding, changedSource, evaluate) {
  const findings = evaluate();
  const refusal = findings.find((item) => item.includes(expectedFinding));
  if (!refusal) throw new Error(`I-15 semantic control missed ${name}: ${findings.join("; ") || "mutation accepted"}`);
  return {name, target, sourceSha256Base64Url: require("node:crypto").createHash("sha256")
    .update(Buffer.from(changedSource)).digest("base64url"), predicateReached: true, rejected: true,
  semanticRefusal: refusal};
}

function runAllowlistRotationControls() {
  const filePath = path.join(SRC_DIR, "Allowlist.sol");
  const source = fs.readFileSync(filePath, "utf8");
  const sourceFailures = allowlistPendingMutationFailures(source, filePath);
  if (sourceFailures.length) throw new Error(`current Allowlist source failed focused I-15 controls: ${sourceFailures.join("; ")}`);
  const positives = [
    {name: "revoke-registrar-or-guardian-current-eligibility", target: {path: "src/Allowlist.sol", function: "Allowlist.revoke(address)"},
      predicateReached: true, accepted: true},
    {name: "set-system-account-owner-or-registrar-current-eligibility", target: {path: "src/Allowlist.sol", function: "Allowlist.setSystemAccount(address,bool)"},
      predicateReached: true, accepted: true},
    {name: "private-registration-transition-helper", target: {path: "src/Allowlist.sol", function: "Allowlist._updateVestingSourceRegistration(address,bool)"},
      predicateReached: true, accepted: true},
    {name: "private-pending-marker-helper", target: {path: "src/Allowlist.sol", function: "Allowlist._setVestingSourceRegistrationPending(address,bool)"},
      predicateReached: true, accepted: true},
  ];
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const currentReader = functions.find((record) => record.name === "setSystemAccount");
  const currentFinalizer = functions.find((record) => record.name === "finalizeSystemRegistrar");
  if (!currentReader || !currentReader.body.includes("_systemRegistrars[msg.sender]") ||
      !functionWritesStateField(currentFinalizer, "_systemRegistrars", source, functions)) {
    throw new Error("current system-registrar reader/apply positives changed");
  }
  const rolePathPositives = [
    {name: "ordinary-system-registrar-role-read", target: {path: "src/Allowlist.sol", function: "Allowlist.setSystemAccount(address,bool)"},
      predicateReached: true, accepted: true},
    {name: "selected-system-registrar-finalize-apply", target: {path: "src/Allowlist.sol", function: "Allowlist.finalizeSystemRegistrar()"},
      predicateReached: true, accepted: true},
  ];
  const indexedReadMarker = "    function isAllowed(address account) external view freshOnly returns (bool) {";
  const indexedReadSource = source.replace(indexedReadMarker,
    "    function _readSystemRegistrarValue(bool selected) internal pure returns (bool) { return selected; }\n\n" +
    "    function _indexedSystemRegistrarRead() private view returns (bool) {\n" +
    "        return _readSystemRegistrarValue(_systemRegistrars[msg.sender]);\n" +
    "    }\n\n" + indexedReadMarker);
  if (indexedReadSource === source) throw new Error("indexed role-read argument positive was not applied");
  const indexedReadFailures = allowlistPendingMutationFailures(indexedReadSource, filePath);
  if (indexedReadFailures.length) {
    throw new Error(`indexed role-read argument positive failed: ${indexedReadFailures.join("; ")}`);
  }
  rolePathPositives.push({name: "safe-indexed-role-value-read-argument",
    target: {path: "src/Allowlist.sol", expression: "_readSystemRegistrarValue(_systemRegistrars[msg.sender])"},
    predicateReached: true, accepted: true});
  const missingEdge = source.replace(
    "function finalizeRegistrar() external onlyEligibleOwner {",
    "function finalizeRegistrar() external {",
  );
  if (missingEdge === source) throw new Error("I-15 static control is missing the exact finalizeRegistrar modifier");
  const missingAuthorization = rejectsI15SemanticControl("missing-staged-edge-authorization",
    {path: "src/Allowlist.sol", function: "Allowlist.finalizeRegistrar()", mutation: "removed onlyEligibleOwner"},
    "I-15 staged Allowlist edge finalizeRegistrar", missingEdge,
    () => allowlistPendingMutationFailures(missingEdge, filePath));
  const contractEnd = source.lastIndexOf("}");
  if (contractEnd < 0) throw new Error("I-15 static control cannot locate the end of the Allowlist contract");
  const addedSetter = `${source.slice(0, contractEnd)}\n    function setRegistrar(address account) external onlyOwner { _registrar = account; }\n${source.slice(contractEnd)}`;
  const newTrustSetter = rejectsI15SemanticControl("new-unclassified-trust-writer-name-and-onlyOwner",
    {path: "src/Allowlist.sol", field: "_registrar", writer: "setRegistrar(address)"},
    "I-15 staged-role storage writer inventory changed for _registrar", addedSetter,
    () => allowlistPendingMutationFailures(addedSetter, filePath));

  const exactAdmission = source
    .replace("mapping(address => bool) private _pendingVestingSourceRegistration;",
      "mapping(address => bool) private _pendingVestingSourceRegistration;\n    address private _admissionController;")
    .replace("if (msg.sender != _registrar) revert NotRegistrar();",
      "if (msg.sender != _registrar && msg.sender != _admissionController) revert NotRegistrar();")
    .replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
      "    function setAdmissionController(address account) external onlyOwner { _admissionController = account; }\n\n" +
      "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (exactAdmission === source) throw new Error("I-15 E5 admission-controller mutation did not reach its three source fragments");
  const admissionController = rejectsI15SemanticControl("0483-E5-admission-controller-exact-counterexample",
    {path: "src/Allowlist.sol", field: "_admissionController", writer: "setAdmissionController(address)",
      consumer: "approve(address,uint64,uint8,bytes32)"},
    "unclassified caller authority field _admissionController", exactAdmission,
    () => allowlistPendingMutationFailures(exactAdmission, filePath));

  const renamedRole = source
    .replace("mapping(address => bool) private _pendingVestingSourceRegistration;",
      "mapping(address => bool) private _pendingVestingSourceRegistration;\n    address private routeLatch;")
    .replace("if (msg.sender != _registrar) revert NotRegistrar();",
      "if (msg.sender != _registrar && msg.sender != routeLatch) revert NotRegistrar();")
    .replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
      "    function bindRoute(address account) external { routeLatch = account; }\n\n" +
      "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (renamedRole === source) throw new Error("I-15 naming/modifier mutation did not reach its source fragments");
  const renamedAuthority = rejectsI15SemanticControl("unusual-role-and-writer-name-without-owner-modifier",
    {path: "src/Allowlist.sol", field: "routeLatch", writer: "bindRoute(address)",
      consumer: "approve(address,uint64,uint8,bytes32)"},
    "unclassified caller authority field routeLatch", renamedRole,
    () => allowlistPendingMutationFailures(renamedRole, filePath));

  const modifierRole = source
    .replace("mapping(address => bool) private _pendingVestingSourceRegistration;",
      "mapping(address => bool) private _pendingVestingSourceRegistration;\n    address private dispatchMark;")
    .replace("    modifier onlyEligibleOwner() {",
      "    modifier relayAdmission() { if (msg.sender != dispatchMark) revert NotRegistrar(); _; }\n\n" +
      "    modifier onlyEligibleOwner() {")
    .replace("function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external freshOnly {",
      "function approve(address account, uint64 until, uint8 basis_, bytes32 caseRef_) external freshOnly relayAdmission {")
    .replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
      "    function updateRelay(address account) external { dispatchMark = account; }\n\n" +
      "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (modifierRole === source) throw new Error("I-15 custom-modifier mutation did not reach its source fragments");
  const modifierAuthority = rejectsI15SemanticControl("custom-modifier-and-unknown-writer",
    {path: "src/Allowlist.sol", field: "dispatchMark", writer: "updateRelay(address)",
      consumer: "approve(address,uint64,uint8,bytes32)", modifier: "relayAdmission"},
    "unclassified caller authority field dispatchMark", modifierRole,
    () => allowlistPendingMutationFailures(modifierRole, filePath));

  const addedConsumer = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function reviewRegistrarState() external view returns (bool) {\n" +
    "        if (msg.sender != _registrar) revert NotRegistrar();\n" +
    "        return true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (addedConsumer === source) throw new Error("I-15 caller-consumer mutation did not reach its source fragments");
  const consumerChange = rejectsI15SemanticControl("new-caller-consumer-of-existing-registrar-role",
    {path: "src/Allowlist.sol", field: "_registrar", consumer: "reviewRegistrarState()"},
    "caller-authority consumer inventory changed for _registrar", addedConsumer,
    () => allowlistPendingMutationFailures(addedConsumer, filePath));

  const renamedWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function rerouteAdmission(address account) external { _registrar = account; }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (renamedWriter === source) throw new Error("I-15 authority-writer mutation did not reach its source fragment");
  const writerChange = rejectsI15SemanticControl("new-authority-writer-independent-of-set-prefix",
    {path: "src/Allowlist.sol", field: "_registrar", writer: "rerouteAdmission(address)"},
    "I-15 staged-role storage writer inventory changed for _registrar", renamedWriter,
    () => allowlistPendingMutationFailures(renamedWriter, filePath));

  const aliasWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function grantSystemRegistrar(address account) external onlyOwner {\n" +
    "        mapping(address => bool) storage roleIndex = _systemRegistrars;\n" +
    "        roleIndex[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (aliasWriter === source) throw new Error("I-15 local storage-alias control was not applied");
  const aliasWriterRefusal = rejectsI15SemanticControl("0492-local-storage-alias-system-registrar-writer",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "grantSystemRegistrar(address)", alias: "roleIndex"},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", aliasWriter,
    () => allowlistPendingMutationFailures(aliasWriter, filePath));

  const chainedAliasWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function attachRole(address account) external {\n" +
    "        mapping(address => bool) storage firstIndex = _systemRegistrars;\n" +
    "        mapping(address => bool) storage secondIndex = (firstIndex);\n" +
    "        secondIndex[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (chainedAliasWriter === source) throw new Error("I-15 chained storage-alias control was not applied");
  const chainedAliasRefusal = rejectsI15SemanticControl("chained-storage-alias-system-registrar-writer",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "attachRole(address)", aliases: ["firstIndex", "secondIndex"]},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", chainedAliasWriter,
    () => allowlistPendingMutationFailures(chainedAliasWriter, filePath));

  const reboundAliasWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function assignRole(address account) external {\n" +
    "        mapping(address => bool) storage roleIndex = _systemAccounts;\n" +
    "        roleIndex = _systemRegistrars;\n" +
    "        roleIndex[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (reboundAliasWriter === source) throw new Error("I-15 storage-alias rebinding control was not applied");
  const reboundAliasRefusal = rejectsI15SemanticControl("storage-alias-rebound-to-system-registrars",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "assignRole(address)", alias: "roleIndex"},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", reboundAliasWriter,
    () => allowlistPendingMutationFailures(reboundAliasWriter, filePath));
  const helperAliasWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function grantSystemRegistrar(address account) external onlyOwner {\n" +
    "        mapping(address => bool) storage roleIndex = _systemRegistrars;\n" +
    "        _setSystemRegistrarFromAlias(roleIndex, account);\n" +
    "    }\n\n" +
    "    function _setSystemRegistrarFromAlias(mapping(address => bool) storage roleIndex, address account) internal {\n" +
    "        roleIndex[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (helperAliasWriter === source) throw new Error("exact 0500 storage-helper alias mutation was not applied");
  const helperAliasRefusal = rejectsI15SemanticControl("0500-selected-storage-alias-passed-to-helper",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "grantSystemRegistrar(address)", helper: "_setSystemRegistrarFromAlias"},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", helperAliasWriter,
    () => allowlistPendingMutationFailures(helperAliasWriter, filePath));

  const directReferenceWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function grantSystemRegistrarDirect(address account) external onlyOwner {\n" +
    "        _setSystemRegistrarDirect(_systemRegistrars, account);\n" +
    "    }\n\n" +
    "    function _setSystemRegistrarDirect(mapping(address => bool) storage selectedRole, address account) internal {\n" +
    "        selectedRole[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (directReferenceWriter === source) throw new Error("direct selected mapping-reference mutation was not applied");
  const directReferenceRefusal = rejectsI15SemanticControl("direct-selected-mapping-passed-to-helper",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "grantSystemRegistrarDirect(address)", helper: "_setSystemRegistrarDirect"},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", directReferenceWriter,
    () => allowlistPendingMutationFailures(directReferenceWriter, filePath));

  const chainedReferenceWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function grantSystemRegistrarChain(address account) external onlyOwner {\n" +
    "        _setSystemRegistrarThroughChain(_systemRegistrars, account);\n" +
    "    }\n\n" +
    "    function _setSystemRegistrarThroughChain(mapping(address => bool) storage firstBinding, address account) internal {\n" +
    "        _finishSystemRegistrarWrite(firstBinding, account);\n" +
    "    }\n\n" +
    "    function _finishSystemRegistrarWrite(mapping(address => bool) storage renamedBinding, address account) internal {\n" +
    "        renamedBinding[account] = true;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (chainedReferenceWriter === source) throw new Error("helper-chain selected mapping-reference mutation was not applied");
  const chainedReferenceRefusal = rejectsI15SemanticControl("helper-chain-renamed-storage-parameters",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "grantSystemRegistrarChain(address)", parameters: ["firstBinding", "renamedBinding"]},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", chainedReferenceWriter,
    () => allowlistPendingMutationFailures(chainedReferenceWriter, filePath));

  const returnedReferenceWriter = source.replace("    function isAllowed(address account) external view freshOnly returns (bool) {",
    "    function grantSystemRegistrarFromReference(address account) external onlyOwner {\n" +
    "        mapping(address => bool) storage returnedRoles = _selectedSystemRegistrarReference();\n" +
    "        returnedRoles[account] = true;\n" +
    "    }\n\n" +
    "    function _selectedSystemRegistrarReference() internal view returns (mapping(address => bool) storage) {\n" +
    "        return _systemRegistrars;\n" +
    "    }\n\n" +
    "    function isAllowed(address account) external view freshOnly returns (bool) {");
  if (returnedReferenceWriter === source) throw new Error("returned storage-reference mutation was not applied");
  const returnedReferenceRefusal = rejectsI15SemanticControl("selected-storage-reference-returned-from-helper",
    {path: "src/Allowlist.sol", field: "_systemRegistrars", writer: "grantSystemRegistrarFromReference(address)", helper: "_selectedSystemRegistrarReference"},
    "I-15 staged-role storage writer inventory changed for _systemRegistrars", returnedReferenceWriter,
    () => allowlistPendingMutationFailures(returnedReferenceWriter, filePath));
  return {
    scope: "copied Allowlist source and selected I-15 edge inventory; no compilation or contract execution",
    storageReferenceBoundary: "whole selected storage references passed to helpers or returned by storage-reference helpers fail closed; indexed value reads passed as helper arguments remain supported",
    sourceSha256Base64Url: require("node:crypto").createHash("sha256").update(Buffer.from(source)).digest("base64url"),
    checkerSha256Base64Url: require("node:crypto").createHash("sha256").update(fs.readFileSync(__filename)).digest("base64url"),
    selectedAllowlistRotations: Object.entries(TRUST_SENSITIVE_SETTERS)
      .filter(([key]) => key.startsWith("Allowlist.sol:"))
      .map(([key, value]) => ({setter: key.slice("Allowlist.sol:".length), ...value})),
    positives,
    rolePathPositives,
    negatives: [missingAuthorization, newTrustSetter, admissionController, renamedAuthority, modifierAuthority,
      consumerChange, writerChange, aliasWriterRefusal, chainedAliasRefusal, reboundAliasRefusal,
      helperAliasRefusal, directReferenceRefusal, chainedReferenceRefusal, returnedReferenceRefusal],
  };
}

function checkForageGuard(source, filePath, failures) {
  const guard = setupFunction(source, "_requireNotBlocked", filePath, "normal-call Blocklist guard", failures);
  if (!guard) return;
  const code = compactSolidity(guard.body);
  const normalCall = "if (blocklist_ == address(0) && !_isInitializing()) revert InvalidBlocklist(address(0));";
  const noBootstrapException = "if (blocklist_ == address(0)) revert InvalidBlocklist(address(0));";
  const configured = "if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) { revert BlockedAddress(account); }";
  if (!code.includes("revertInvalidBlocklist(address(0));")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BLOCKLIST-GUARD", "zero Blocklist must revert InvalidBlocklist(address(0)) on normal calls.");
  }
  if (!code.includes(compactSolidity(normalCall))) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BLOCKLIST-BOOTSTRAP", "only the active Initializable path may bypass the zero-pointer rejection.");
  }
  if (!code.includes(compactSolidity(configured))) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BLOCKLIST-GUARD", "configured Blocklist must still check the requested account.");
  }
  const expected = compactSolidity(`address blocklist_ = _blocklist; ${normalCall} ${configured}`);
  const missingBootstrap = compactSolidity(`address blocklist_ = _blocklist; ${noBootstrapException} ${configured}`);
  const failOpen = compactSolidity("address blocklist_ = _blocklist; if (blocklist_ == address(0)) return; if (blocklist_ != address(0) && IBlocklist(blocklist_).isBlocked(account)) { revert BlockedAddress(account); }");
  if (code !== expected && code !== missingBootstrap && code !== failOpen) {
    setupFailure(failures, filePath, "SETUP-PARSER-UNSUPPORTED", "Blocklist helper is outside the reviewed fail-closed source shape.");
  }
}

function checkForageNormalCalls(source, filePath, failures) {
  const approve = setupFunction(source, "approve", filePath, "open approve path", failures);
  const transferFrom = setupFunction(source, "transferFrom", filePath, "open transferFrom path", failures);
  const update = setupFunction(source, "_update", filePath, "open transfer path", failures);
  if (!approve || !transferFrom || !update) return;
  setupHeader(approve, "function approve(address spender, uint256 value) public override freshInventoryReady returns (bool)", filePath, "SETUP-FORAGE-OPEN-APPROVAL", failures);
  setupHeader(transferFrom, "function transferFrom(address from, address to, uint256 value) public override freshInventoryReady returns (bool)", filePath, "SETUP-FORAGE-OPEN-TRANSFERFROM", failures);
  const approveCode = compactSolidity(approve.body);
  const transferCode = compactSolidity(transferFrom.body);
  const updateCode = compactSolidity(update.body);
  const guardedApproval = "addressowner_=_msgSender();_requireNotBlocked(owner_);if(value!=0){_requireNotBlocked(spender);_requireExplicitAllowanceReset(owner_,spender,value);}boolapproved=super.approve(spender,value);if(approved)_explicitZeroResetRequired[owner_][spender]=value!=0;returnapproved;";
  if (approveCode !== guardedApproval) {
    setupFailure(failures, filePath, "SETUP-FORAGE-OPEN-APPROVAL", "approve must retain owner and conditional spender Blocklist checks, the shared reset guard, and a post-success marker write.");
  }
  if (transferCode !== "_requireNotBlocked(msg.sender);returnsuper.transferFrom(from,to,value);") {
    setupFailure(failures, filePath, "SETUP-FORAGE-OPEN-TRANSFERFROM", "transferFrom must retain the spender check and inherited allowance path without clearing the explicit-zero marker on spend.");
  }
  const endpoints = "if(from!=address(0)){_requireNotBlocked(from);}if(to!=address(0)){_requireNotBlocked(to);}super._update(from,to,value);";
  if (!updateCode.includes(endpoints)) {
    setupFailure(failures, filePath, "SETUP-FORAGE-OPEN-TRANSFER", "transfer must retain endpoint Blocklist checks before ERC20 update.");
  }
  if (updateCode.includes("_explicitZeroResetRequired")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-OPEN-TRANSFER", "spending and token updates must not clear the explicit-zero marker.");
  }
  if (solidityFunctionDeclarations(source, "transfer").length !== 0) {
    setupFailure(failures, filePath, "SETUP-FORAGE-OPEN-TRANSFER", "transfer must remain on the inherited ERC20 update path.");
  }
  const initializationTail = "super._update(from,to,value);if(!_isInitializing()){_delegateStateModule(abi.encodeCall(ForageTokenStateModule.syncSourceFromToken,(from,to,value)));}";
  if (!updateCode.endsWith(initializationTail)) {
    setupFailure(failures, filePath, "SETUP-FORAGE-BOOTSTRAP", "vote-source synchronization must remain outside Initializable initialization.");
  }
}

function checkRiskusdFreshOnly(source, filePath, failures) {
  const freshGuard = setupFunction(source, "_requireFreshLayout", filePath, "fresh-layout guard", failures);
  const freshModifier = solidityModifierDeclarations(source, "freshLayout");
  const constructionGuard = solidityModifierDeclarations(source, "onlyDuringConstructionBeforeInitialization");
  const initialize = setupFunction(source, "initialize", filePath, "fresh initializer", failures);
  if (!freshGuard || !initialize) return;
  if (!source.includes("error FreshDeploymentRequired(uint256 version);")) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-ERROR", "the legacy refusal must use FreshDeploymentRequired(uint256).");
  }
  if (freshModifier.length !== 1 || compactSolidity(freshModifier[0].body || "") !== "_requireFreshLayout();_;") {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-GUARD", "freshLayout must run the typed guard before the function body.");
  }
  if (constructionGuard.length !== 1 || compactSolidity(constructionGuard[0].body || "") !==
      "if(address(this).code.length!=0||_getInitializedVersion()!=0)revertInvalidInitialization();_;") {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-INITIALIZER", "initialize must be limited to proxy construction before the first initialized version.");
  }
  if (compactSolidity(freshGuard.body) !==
      "uint256version=_freshLayoutVersion;if(version!=_FRESH_LAYOUT_VERSION)revertFreshDeploymentRequired(version);") {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-GUARD", "the marker must fail closed on every version other than the fresh version.");
  }
  setupHeader(
    initialize,
    "function initialize(address initialOwner_) external onlyDuringConstructionBeforeInitialization initializer",
    filePath,
    "SETUP-RISKUSD-FRESH-INITIALIZER",
    failures,
  );
  const initCode = compactSolidity(initialize.body);
  const markerWrite = "_freshLayoutVersion=_FRESH_LAYOUT_VERSION;";
  if ((initCode.match(new RegExp(escapeRegex(markerWrite), "g")) || []).length !== 1 ||
      initCode.indexOf(markerWrite) < initCode.indexOf("__Pausable_init();")) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-INITIALIZER", "fresh initialization must write the marker once after the OpenZeppelin initialization calls.");
  }
  const requiredHeaders = [
    ["setAllowlist", "function setAllowlist(address allowlist_) external freshLayout onlyOwner"],
    ["mint", "function mint(address to, uint256 amount) external freshLayout onlyAllowedCaller whenNotPaused nonReentrant"],
    ["burn", "function burn(address from, uint256 amount) external freshLayout onlyAllowedCaller nonReentrant"],
    ["approve", "function approve(address spender, uint256 value) public override freshLayout returns (bool)"],
    ["transferFrom", "function transferFrom(address from, address to, uint256 value) public override freshLayout returns (bool)"],
    ["setMinter", "function setMinter(address minter_) external freshLayout onlyAllowedCaller onlyOwner"],
    ["proposeMinter", "function proposeMinter(address newMinter_) public freshLayout onlyAllowedCaller onlyOwner"],
    ["acceptMinter", "function acceptMinter() external freshLayout onlyAllowedCaller"],
    ["finalizeMinter", "function finalizeMinter() external freshLayout onlyAllowedCaller onlyOwner"],
    ["clearPendingMinter", "function clearPendingMinter() external freshLayout onlyAllowedCaller onlyOwner"],
    ["pause", "function pause() external freshLayout onlyAllowedCaller"],
    ["unpause", "function unpause() external freshLayout onlyAllowedCaller"],
    ["setForageGovernor", "function setForageGovernor(address forageGovernor_) external freshLayout onlyAllowedCaller onlyOwner"],
    ["finalizeForageGovernor", "function finalizeForageGovernor() external freshLayout onlyAllowedCaller onlyOwner"],
    ["clearPendingForageGovernor", "function clearPendingForageGovernor() external freshLayout onlyAllowedCaller onlyOwner"],
    ["setTransferExempt", "function setTransferExempt(address account, bool exempt) external freshLayout onlyAllowedCaller onlyOwner"],
    ["setBlocklist", "function setBlocklist(address blocklist_) external freshLayout onlyAllowedCaller onlyOwner"],
    ["exemptAddresses", "function exemptAddresses() external view freshLayout returns (address[] memory)"],
    ["_update", "function _update(address from, address to, uint256 value) internal override freshLayout"],
    ["renounceOwnership", "function renounceOwnership() public view override freshLayout"],
    ["upgradeToAndCall", "function upgradeToAndCall(address newImplementation, bytes memory data) public payable override freshLayout onlyAllowedCaller"],
    ["transferOwnership", "function transferOwnership(address newOwner) public override freshLayout onlyAllowedCaller"],
    ["acceptOwnership", "function acceptOwnership() public override freshLayout onlyAllowedCaller"],
    ["_authorizeUpgrade", "function _authorizeUpgrade(address) internal override freshLayout onlyOwner"],
  ];
  for (const [name, header] of requiredHeaders) {
    setupHeader(setupFunction(source, name, filePath, `fresh ${name}`, failures), header,
      filePath, "SETUP-RISKUSD-FRESH-ROUTE", failures);
  }
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const markerWriters = functions.filter((record) =>
    functionWritesStateField(record, "_freshLayoutVersion", source, functions)).map((record) => record.name).sort();
  if (JSON.stringify(markerWriters) !== JSON.stringify(["initialize"])) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-INITIALIZER", `marker writers must be initializer-only: ${markerWriters.join(",")}.`);
  }
  const unguarded = functions.filter((record) =>
    /\b(?:external|public)\b/.test(record.header) && !/\b(?:view|pure)\b/.test(record.header) &&
    record.name !== "initialize" && !/\bfreshLayout\b/.test(record.header)).map((record) => record.name).sort();
  if (unguarded.length > 0) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-FRESH-ROUTE", `state-changing public routes lack freshLayout: ${unguarded.join(",")}.`);
  }
  if (solidityFunctionDeclarations(source, "permit").length !== 0) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-PERMIT-POLICY", "RISKUSD has no reviewed permit route; do not add one without the same reset predicate.");
  }
}

function checkRiskusdAllowancePolicy(source, filePath, failures) {
  const approve = setupFunction(source, "approve", filePath, "RISKUSD approve", failures);
  const transferFrom = setupFunction(source, "transferFrom", filePath, "RISKUSD transferFrom", failures);
  const resetGuard = setupFunction(source, "_requireExplicitAllowanceReset", filePath, "RISKUSD zero-reset guard", failures);
  if (!approve || !transferFrom || !resetGuard) return;
  const expectedApprove = compactSolidity(
    "address owner_ = _msgSender(); _requireNotBlocked(owner_); " +
    "if (value != 0) { _requireNotBlocked(spender); _requireExplicitAllowanceReset(owner_, spender, value); } " +
    "bool approved = super.approve(spender, value); " +
    "if (approved) _explicitZeroResetRequired[owner_][spender] = value != 0; return approved;",
  );
  if (compactSolidity(approve.body) !== expectedApprove) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-ALLOWANCE", "approve must preserve Blocklist checks, sticky zero-reset, and post-success marker update.");
  }
  const expectedReset = compactSolidity(
    "uint256 currentAllowance = allowance(owner_, spender); " +
    "if (currentAllowance != 0 || _explicitZeroResetRequired[owner_][spender]) { " +
    "revert AllowanceChangeRequiresZero(spender, currentAllowance, value); }",
  );
  if (compactSolidity(resetGuard.body) !== expectedReset) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-ALLOWANCE", "nonzero approval must require both a zero allowance and an explicit reset after prior approval.");
  }
  if (compactSolidity(transferFrom.body) !== "_requireNotBlocked(msg.sender);returnsuper.transferFrom(from,to,value);") {
    setupFailure(failures, filePath, "SETUP-RISKUSD-ALLOWANCE", "transferFrom must keep the spender gate and inherited allowance consumption without clearing the reset marker.");
  }
  const functions = solidityFunctionDeclarations(source).filter((record) => record.body !== null);
  const markerWriters = functions.filter((record) =>
    functionWritesStateField(record, "_explicitZeroResetRequired", source, functions)).map((record) => record.name).sort();
  if (JSON.stringify(markerWriters) !== JSON.stringify(["approve"])) {
    setupFailure(failures, filePath, "SETUP-RISKUSD-ALLOWANCE", `zero-reset marker writers must be approve-only: ${markerWriters.join(",")}.`);
  }
}

function evaluateRiskusdAllowanceControl(name, source, initialState, actions, expectedAccepted) {
  const filePath = path.join(SRC_DIR, "RISKUSD.sol");
  const failures = [];
  checkRiskusdFreshOnly(source, filePath, failures);
  checkRiskusdAllowancePolicy(source, filePath, failures);
  const predicateReached = failures.length === 0;
  const state = {allowance: initialState.allowance, marker: initialState.marker};
  const trace = [];
  if (predicateReached) {
    for (const action of actions) {
      let accepted;
      if (action.operation === "transferFrom") {
        accepted = action.value <= state.allowance;
        if (accepted) state.allowance -= action.value;
      } else {
        const resetRequired = state.allowance !== 0 || state.marker;
        accepted = action.value === 0 || !resetRequired;
        if (accepted) {
          state.allowance = action.value;
          state.marker = action.value !== 0;
        }
      }
      trace.push({operation: action.operation, value: action.value, allowance: state.allowance, marker: state.marker, accepted});
      if (!accepted) break;
    }
  }
  const accepted = predicateReached && trace.length === actions.length && trace.every((step) => step.accepted);
  if (accepted !== expectedAccepted) {
    throw new Error(`RISKUSD allowance control ${name} expected accepted=${expectedAccepted}, got ${accepted}`);
  }
  return {
    name,
    target: {path: "src/RISKUSD.sol", functions: ["approve", "transferFrom", "_requireExplicitAllowanceReset"]},
    sourceSha256Base64Url: require("node:crypto").createHash("sha256").update(Buffer.from(source)).digest("base64url"),
    predicateReached,
    accepted,
    expectedAccepted,
    initialState,
    trace,
    finalState: state,
    scope: "bounded source-shape allowance state model; no Solidity execution",
  };
}

function checkForageSetterGates(source, filePath, failures) {
  const blocklist = setupFunction(source, "setBlocklist", filePath, "Blocklist setter", failures);
  const allowlist = setupFunction(source, "setAllowlist", filePath, "Allowlist setter", failures);
  const progress = setupFunction(source, "processBlocklistRotation", filePath, "Blocklist rotation progress", failures);
  const activation = setupFunction(source, "activateBlocklistRotation", filePath, "Blocklist rotation activation", failures);
  const allowlistProgress = setupFunction(source, "processAllowlistReindex", filePath, "Allowlist reindex progress", failures);
  const allowlistActivation = setupFunction(source, "activateAllowlistReindex", filePath, "Allowlist reindex activation", failures);
  const allowlistCancel = setupFunction(source, "cancelAllowlistReindex", filePath, "Allowlist reindex cancellation", failures);
  const eligibility = setupFunction(source, "sourceEligibilityForBlocklist", filePath, "module eligibility bridge", failures);
  const permit = setupFunction(source, "permit", filePath, "permit allowance policy", failures);
  const resetGuard = setupFunction(source, "_requireExplicitAllowanceReset", filePath, "shared allowance reset guard", failures);
  setupHeader(blocklist, "function setBlocklist(address blocklist_) external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-SETTER-GATE", failures);
  setupHeader(allowlist, "function setAllowlist(address allowlist_) external freshInventoryReady onlyOwner", filePath, "SETUP-FORAGE-SETTER-GATE", failures);
  setupHeader(progress, "function processBlocklistRotation() external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-ROTATION-GATE", failures);
  setupHeader(activation, "function activateBlocklistRotation() external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-ROTATION-GATE", failures);
  setupHeader(allowlistProgress, "function processAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-GATE", failures);
  setupHeader(allowlistActivation, "function activateAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-GATE", failures);
  setupHeader(allowlistCancel, "function cancelAllowlistReindex() external freshInventoryReady onlyAllowedCaller onlyOwner", filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-GATE", failures);
  setupHeader(permit, "function permit(address owner_, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public override freshInventoryReady", filePath, "SETUP-FORAGE-PERMIT-POLICY", failures);
  setupHeader(resetGuard, "function _requireExplicitAllowanceReset(address owner_, address spender, uint256 value) private view", filePath, "SETUP-FORAGE-PERMIT-POLICY", failures);
  if (!blocklist || !progress || !activation || !eligibility || !permit || !resetGuard) return;
  const blocklistCode = compactSolidity(blocklist.body);
  const progressCode = compactSolidity(progress.body);
  const activationCode = compactSolidity(activation.body);
  const allowlistCode = compactSolidity(allowlist.body);
  const allowlistActivationCode = compactSolidity(allowlistActivation?.body || "");
  const allowlistCancelCode = compactSolidity(allowlistCancel?.body || "");
  const permitCode = compactSolidity(permit.body);
  const resetGuardCode = compactSolidity(resetGuard.body);
  const beginAt = blocklistCode.indexOf("ForageTokenStateModule.beginBlocklistRotation");
  const registerPositions = [...blocklistCode.matchAll(/_registerBlocklistObserver\(blocklist_\)/g)].map((match) => match.index);
  const validateAt = blocklistCode.indexOf("_requireValidBlocklist(blocklist_);");
  const sameBranchAt = blocklistCode.indexOf("if(oldBlocklist==blocklist_){");
  const freshBranchAt = blocklistCode.indexOf("if(freshEmptyInventory){");
  const bindAt = blocklistCode.indexOf("ForageTokenStateModule.bindInitialBlocklist");
  if (
    validateAt < 0 || registerPositions.length !== 3 || sameBranchAt < 0 || freshBranchAt < 0 ||
    beginAt < 0 || bindAt < registerPositions[1] || registerPositions[0] < validateAt ||
    registerPositions[1] <= freshBranchAt || registerPositions[1] >= bindAt ||
    bindAt >= beginAt || registerPositions[2] <= beginAt
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-ORDER", "candidate validation must precede observer registration; fresh binding and staged observer registration must remain distinct.");
  }
  if (/_blocklist\s*=(?!=)/.test(blocklist.body) || !progressCode.includes("ForageTokenStateModule.processBlocklistRotation")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-ACTIVATION", "the setter must not switch the live pointer and progress must use the bounded module page.");
  }
  if (
    !activationCode.includes("_unregisterBlocklistObserverStrict(status.activeBlocklist);") ||
    !activationCode.includes("ForageTokenStateModule.activateBlocklistRotation")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-ACTIVATION", "activation must unregister only after reconciliation and switch through the guarded module path.");
  }
  const allowlistBeginAt = allowlistCode.indexOf("ForageTokenStateModule.beginAllowlistReindex");
  const pendingObserverAt = allowlistCode.indexOf("_registerAllowlistObserver(allowlist_);", allowlistBeginAt);
  const initialSyncAt = allowlistCode.indexOf("ForageTokenStateModule.syncInitialVestingSources", allowlistBeginAt);
  if (
    allowlistBeginAt < 0 || pendingObserverAt <= allowlistBeginAt || initialSyncAt <= pendingObserverAt ||
    allowlistCode.slice(allowlistBeginAt).includes("_transitionAllowlist(allowlist_);")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-ORDER", "a provider replacement must stage and sync its candidate before it becomes active.");
  }
  if (
    !allowlistActivationCode.includes("_unregisterAllowlistObserver(oldAllowlist);") ||
    allowlistActivationCode.indexOf("_transitionAllowlist(nextAllowlist);") < 0 ||
    allowlistActivationCode.indexOf("_transitionAllowlist(nextAllowlist);") >
      allowlistActivationCode.indexOf("ForageTokenStateModule.activateAllowlistReindex")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-ACTIVATION", "the candidate provider must become active only with its completed projection generation.");
  }
  if (
    !allowlistCancelCode.includes("_unregisterAllowlistObserver(candidateAllowlist);") ||
    !allowlistCancelCode.includes("ForageTokenStateModule.cancelAllowlistReindex")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ALLOWLIST-REINDEX-CANCEL", "cancelling a failed reindex must unregister and discard the candidate projection.");
  }
  if (!compactSolidity(eligibility.body).startsWith("if(msg.sender!=address(this))revertUnauthorizedTokenQuery(msg.sender);")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ELIGIBILITY-BRIDGE", "the provider-eligibility bridge must be Token-self-only.");
  }
  const expectedPermit = "_requireNotBlocked(owner_);if(value!=0){_requireNotBlocked(spender);_requireExplicitAllowanceReset(owner_,spender,value);}super.permit(owner_,spender,value,deadline,v,r,s);_explicitZeroResetRequired[owner_][spender]=value!=0;";
  const expectedResetGuard = "uint256currentAllowance=allowance(owner_,spender);if(currentAllowance!=0||_explicitZeroResetRequired[owner_][spender]){revertAllowanceChangeRequiresZero(spender,currentAllowance,value);}";
  if (permitCode !== expectedPermit || resetGuardCode !== expectedResetGuard) {
    setupFailure(failures, filePath, "SETUP-FORAGE-PERMIT-POLICY", "permit must retain owner and conditional spender Blocklist checks, the shared current-allowance-or-marker guard, and a marker write after super.permit succeeds.");
  }
  const modulePath = path.join(MODULES_DIR, "ForageTokenStateModule.sol");
  const moduleSource = fs.readFileSync(modulePath, "utf8");
  checkForageRotationModule(moduleSource, modulePath, failures);
  const rotationStatus = setupFunction(moduleSource, "blocklistRotationStatus", modulePath, "combined rotation status", failures);
  const beginAllowlist = setupFunction(moduleSource, "beginAllowlistReindex", modulePath, "allowlist reindex start", failures);
  const processAllowlist = setupFunction(moduleSource, "processAllowlistReindex", modulePath, "allowlist reindex page", failures);
  const allowlistModuleSync = setupFunction(moduleSource, "_syncPendingProjection", modulePath, "allowlist reindex source writer", failures);
  const rotationStatusCode = compactSolidity(rotationStatus?.body || "");
  const beginAllowlistCode = compactSolidity(beginAllowlist?.body || "");
  const processAllowlistCode = compactSolidity(processAllowlist?.body || "");
  const pendingSyncCode = compactSolidity(allowlistModuleSync?.body || "");
  if (
    !beginAllowlistCode.includes("state.pendingAllowlist=allowlist_;") ||
    !beginAllowlistCode.includes("state.pendingSnapshotLength=state.sources.length") ||
    !processAllowlistCode.includes("ForageTokenVoteEligibilitySyncQueue.processAllowlistPage,(_SELF)") ||
    !rotationStatusCode.includes("status.allowlistReindexActive=state.pendingAllowlist!=address(0)") ||
    !rotationStatusCode.includes("status.pendingAllowlist=state.pendingAllowlist;") ||
    !pendingSyncCode.includes("pendingAllowlist==address(0)")
  ) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-ALLOWLIST-REINDEX", "the candidate Allowlist must be staged on a bounded projection snapshot.");
  }
  checkForageFreshOnly(source, moduleSource, filePath, modulePath, failures);
}

function checkForageRotationModule(source, filePath, failures) {
  const start = setupFunction(source, "beginBlocklistRotation", filePath, "rotation start", failures);
  const allowlistStart = setupFunction(source, "beginAllowlistReindex", filePath, "allowlist reindex start", failures);
  const page = setupFunction(source, "processBlocklistRotation", filePath, "rotation page", failures);
  const pageCore = setupFunction(source, "processRotationPage", filePath, "rotation page core", failures);
  const allowlistPageCore = setupFunction(source, "processAllowlistPage", filePath, "allowlist projection page core", failures);
  const queuePage = setupFunction(source, "_queueProjectionPage", filePath, "FIFO projection page queue", failures);
  const pageCompletion = setupFunction(source, "_completeProjectionPage", filePath, "projection page completion", failures);
  const ensureCut = setupFunction(source, "ensureProjectionComplete", filePath, "projection cut barrier", failures);
  const appendTask = setupFunction(source, "_appendTask", filePath, "monotonic FIFO task append", failures);
  const removeTask = setupFunction(source, "_removeTask", filePath, "FIFO task removal", failures);
  const activate = setupFunction(source, "_activateProjection", filePath, "projection activation", failures);
  const sync = setupFunction(source, "_prepareSourceSync", filePath, "source inventory writer", failures);
  const sourceSync = setupFunction(source, "_syncSource", filePath, "source update router", failures);
  const sourceApply = setupFunction(source, "_applySourceSync", filePath, "source projection router", failures);
  const activeSync = setupFunction(source, "_syncActiveProjection", filePath, "active projection writer", failures);
  const pendingSync = setupFunction(source, "_syncPendingProjection", filePath, "pending projection writer", failures);
  const beginCode = compactSolidity(start?.body || "");
  const allowlistStartCode = compactSolidity(allowlistStart?.body || "");
  const beginHeader = compactSolidity(start?.header || "");
  const allowlistStartHeader = compactSolidity(allowlistStart?.header || "");
  const pageCode = compactSolidity(page?.body || "");
  const pageCoreCode = compactSolidity(pageCore?.body || "");
  const allowlistPageCode = compactSolidity(allowlistPageCore?.body || "");
  const queuePageCode = compactSolidity(queuePage?.body || "");
  const pageCompletionCode = compactSolidity(pageCompletion?.body || "");
  const ensureCutCode = compactSolidity(ensureCut?.body || "");
  const appendTaskCode = compactSolidity(appendTask?.body || "");
  const removeTaskCode = compactSolidity(removeTask?.body || "");
  const activationCode = compactSolidity(activate?.body || "");
  const syncCode = compactSolidity(sync?.body || "");
  const allowlistPendingWrite = allowlistStartCode.indexOf("state.pendingAllowlist=allowlist_;");
  const pendingWrite = beginCode.indexOf("state.pendingBlocklist=blocklist;");
  const inventoryAppend = syncCode.indexOf("_recordVoteSource(rotation,source);");
  const beneficiaryWrite = syncCode.indexOf("_rememberRegisteredBeneficiary(source,sync.registeredBeneficiary);");
  const sourceSyncCode = compactSolidity(sourceSync?.body || "");
  const sourceApplyCode = compactSolidity(sourceApply?.body || "");
  const activeSyncCode = compactSolidity(activeSync?.body || "");
  const pendingSyncCode = compactSolidity(pendingSync?.body || "");
  const prepareSource = sourceSyncCode.indexOf("_prepareSourceSync(");
  const applySource = sourceSyncCode.indexOf("_applySourceSync(sync,timepoint);");
  const activeProjection = sourceApplyCode.indexOf("_syncActiveProjection(rotation,sync);");
  const pendingProjection = sourceApplyCode.indexOf("_syncPendingProjection(rotation,sync);");
  const activeProjectionUpdate = activeSyncCode.indexOf("_applyProjectionSourceUpdate(");
  const activeMembershipUpdate = activeSyncCode.indexOf("_updateProjectionVestingSourceMembership(");
  const pendingProjectionUpdate = pendingSyncCode.indexOf("_applyProjectionSourceUpdate(");
  const pendingMembershipUpdate = pendingSyncCode.indexOf("_updateProjectionVestingSourceMembership(");
  const pendingProjectionCalls = sourceApplyCode.match(/_syncPendingProjection\(rotation,sync\);/g) || [];
  if (!page || !pageCode.includes("ForageTokenVoteEligibilitySyncQueue.processRotationPage,(_SELF)") ||
      !source.includes("uint256 private constant BLOCKLIST_ROTATION_PAGE_SIZE = 8;") ||
      !pageCoreCode.includes("remaining>BLOCKLIST_ROTATION_PAGE_SIZE") ||
      !beginCode.includes("state.pendingSnapshotLength=state.sources.length;")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-PAGE", "staging must process a source-fixed bounded page.");
  }
  if (!pageCoreCode.includes("snapshot=state.pendingSnapshotLength") || !pageCoreCode.includes("remaining=snapshot-state.cursor")) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-PAGE", "page boundaries must use the start-time inventory snapshot.");
  }
  if (
    !allowlistPageCode.includes("state.cursor<state.pendingSnapshotLength") ||
    !allowlistPageCode.includes("remaining>BLOCKLIST_ROTATION_PAGE_SIZE") ||
    !allowlistPageCode.includes("_queueProjectionPage(stateModule,state,start,start") ||
    !queuePageCode.includes("_queueObserver(state,source,timepoint)") ||
    !queuePageCode.includes("state.pendingProjectionPageEnd=end") ||
    !queuePageCode.includes("state.pendingProjectionPageBarrier=state.pendingVoteSyncTailTaskId+1") ||
    !pageCompletionCode.includes("head!=0&&head<=barrier") ||
    !pageCompletionCode.includes("barrier=barrierPlusOne-1") ||
    pageCompletionCode.includes("_voteEligibilitySyncCount") ||
    !pageCompletionCode.includes("state.cursor=end") ||
    !pageCompletionCode.includes("state.pendingProjectionPageBarrier=0") ||
    !ensureCutCode.includes("state.pendingProjectionPageBarrier==0") ||
    !appendTaskCode.includes("taskId=tailTask+1") ||
    !removeTask || removeTaskCode.includes("state.pendingVoteSyncTailTaskId=0") ||
    !activationCode.includes("ForageTokenVoteEligibilitySyncQueue.ensureProjectionComplete")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-FIFO", "projection pages must commit only after their captured FIFO prefix completes.");
  }
  if (!beginHeader.includes("onlyFreshDelegateCall") || pendingWrite < 0) {
    setupFailure(failures, filePath, "SETUP-FORAGE-LEGACY-REFUSAL", "the fresh-only marker guard must run before pending provider mutation.");
  }
  if (!allowlistStartHeader.includes("onlyFreshDelegateCall") || allowlistPendingWrite < 0) {
    setupFailure(failures, filePath, "SETUP-FORAGE-LEGACY-REFUSAL", "the fresh-only marker guard must run before pending Allowlist mutation.");
  }
  if (inventoryAppend < 0 || beneficiaryWrite < inventoryAppend) {
    setupFailure(failures, filePath, "SETUP-FORAGE-INVENTORY-ORDER", "each source must enter the unique inventory before beneficiary or projection writes.");
  }
   if (prepareSource < 0 || applySource < prepareSource) {
     setupFailure(failures, filePath, "SETUP-FORAGE-INVENTORY-ORDER", "source inventory preparation must precede active and pending projection updates.");
   }
  if (
    !sourceApply || activeProjection < 0 || pendingProjection <= activeProjection || pendingProjectionCalls.length !== 1 ||
    activeProjectionUpdate < 0 || activeMembershipUpdate <= activeProjectionUpdate ||
    pendingProjectionUpdate < 0 || pendingMembershipUpdate <= pendingProjectionUpdate
  ) {
    setupFailure(
      failures,
      filePath,
      "SETUP-FORAGE-ROTATION-DUAL-WRITE",
      "one pending projection sync must follow the active sync, and each projection must update its own vesting membership after votes."
    );
  }
  if (
    !activationCode.includes("state.cursor!=snapshot") ||
    !activationCode.includes("state.processed<snapshot") ||
    !activationCode.includes("state.dirty!=0")
  ) {
    setupFailure(failures, filePath, "SETUP-FORAGE-ROTATION-COMPLETENESS", "activation must require the complete snapshot cursor, processed count, and clean delta state.");
  }
}

function checkForageFreshOnly(tokenSource, moduleSource, tokenPath, modulePath, failures, allowlistSourceOverride) {
  const inventory = setupFunction(tokenSource, "_requireFreshInventory", tokenPath, "fresh-only guard", failures);
  const liveVotes = setupFunction(tokenSource, "getVotes", tokenPath, "live vote query", failures);
  const pastVotes = setupFunction(tokenSource, "getPastVotes", tokenPath, "historical vote query", failures);
  const transferUpdate = setupFunction(tokenSource, "_update", tokenPath, "fresh-only token update", failures);
  const legacySync = solidityFunctionDeclarations(tokenSource, "syncDelegateSources");
  const sourceEligibilityForwarder = setupFunction(tokenSource, "sourceEligibilityForBlocklist", tokenPath, "eligibility bridge forwarder", failures);
  const sourceEligibilityDelegate = setupFunction(tokenSource, "_delegateSourceEligibilityForBlocklist", tokenPath, "eligibility delegate call", failures);
  const sourceEligibility = setupFunction(moduleSource, "sourceEligibilityForBlocklistModule", modulePath, "registered-beneficiary eligibility", failures);
  const pastProjectionEntry = setupFunction(moduleSource, "pastIndexedProjection", modulePath, "historical projection entry", failures);
  const historicalBlock = setupFunction(moduleSource, "_wasBlockedAtTimepoint", modulePath, "registered historical beneficiary", failures);
  const liveProjection = setupFunction(moduleSource, "_liveIndexedEligibleVotes", modulePath, "fresh live projection", failures);
  const pastProjection = setupFunction(moduleSource, "_pastIndexedEligibleVotes", modulePath, "fresh historical projection", failures);
  const epoch = setupFunction(moduleSource, "_epochAt", modulePath, "fresh epoch selection", failures);
  const sourceSync = setupFunction(moduleSource, "_prepareSourceSync", modulePath, "fresh source inventory", failures);
  const allowlistPath = path.join(SRC_DIR, "Allowlist.sol");
  const allowlistSource = allowlistSourceOverride || fs.readFileSync(allowlistPath, "utf8");
  const registrationHistory = setupFunction(allowlistSource, "_recordEligibilityChange", allowlistPath, "registration history writer", failures);
  const registrationWriter = setupFunction(allowlistSource, "_updateVestingSourceRegistration", allowlistPath, "vesting registration writer", failures);
  const registrationHistoryView = setupFunction(allowlistSource, "vestingSourceRegistrationAt", allowlistPath, "historical vesting registration view", failures);
  const allowlistFreshGuard = setupFunction(allowlistSource, "_requireFreshLayout", allowlistPath, "fresh Allowlist layout guard", failures);
  const allowlistFreshMarker = setupFunction(allowlistSource, "_setFreshLayoutVersion", allowlistPath, "fresh Allowlist layout marker", failures);
  checkForageMarkerSchema(tokenSource, moduleSource, tokenPath, modulePath, failures);
  if (!inventory || !liveVotes || !pastVotes || !transferUpdate || !sourceEligibilityForwarder ||
      !sourceEligibilityDelegate || !sourceEligibility || !pastProjectionEntry || !historicalBlock ||
      !liveProjection || !pastProjection || !epoch || !sourceSync || !registrationHistory ||
      !registrationWriter || !registrationHistoryView || !allowlistFreshGuard || !allowlistFreshMarker) return;
  const inventoryCode = compactSolidity(inventory.body);
  const liveCode = compactSolidity(liveVotes.body);
  const pastCode = compactSolidity(pastVotes.body);
  const updateCode = compactSolidity(transferUpdate.body);
  const liveProjectionCode = compactSolidity(liveProjection.body);
  const pastProjectionCode = compactSolidity(pastProjection.body);
  const epochCode = compactSolidity(epoch.body);
  const sourceSyncCode = compactSolidity(sourceSync.body);
  const sourceEligibilityForwarderCode = compactSolidity(sourceEligibilityForwarder.body);
  const sourceEligibilityDelegateCode = compactSolidity(sourceEligibilityDelegate.body);
  const sourceEligibilityCode = compactSolidity(sourceEligibility.body);
  const pastProjectionEntryCode = compactSolidity(pastProjectionEntry.body);
  const historicalBlockCode = compactSolidity(historicalBlock.body);
  const registrationHistoryCode = compactSolidity(registrationHistory.body);
  const registrationWriterCode = compactSolidity(registrationWriter.body);
  const registrationHistoryViewCode = compactSolidity(registrationHistoryView.body);
  const allowlistFreshGuardCode = compactSolidity(allowlistFreshGuard.body);
  const allowlistFreshMarkerCode = compactSolidity(allowlistFreshMarker.body);
  if (!inventoryCode.includes("!status.inventorySupported||status.epochCount==0") ||
      !inventoryCode.includes("revertLegacySourceInventoryUnavailable(_blocklist,address(0))")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-FRESH-ONLY", "pre-fresh storage must typed-refuse before new behavior.");
  }
  if (!liveCode.includes("projection.indexedVotes") || liveCode.includes("_liveLegacyEligibleVotes")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-FRESH-ONLY", "live votes must not translate legacy source mappings.");
  }
  if (!pastCode.includes("projection.indexedVotes") || pastCode.includes("_pastLegacyEligibleVotes")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-FRESH-ONLY", "past votes must preserve snapshots without a legacy-source loop.");
  }
  if (!updateCode.startsWith("if(!_isInitializing())_requireFreshInventory();") ||
      updateCode.indexOf("_requireFreshInventory()") > updateCode.indexOf("super._update(")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-FRESH-ONLY", "token mutations must reject unsupported legacy state before balance effects.");
  }
  if (legacySync.length !== 0) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-FRESH-ONLY", "legacy delegate-source synchronization entrypoint must be absent.");
  }
  setupHeader(sourceEligibility,
    "function sourceEligibilityForBlocklistModule(ForageTokenSourceEligibilityQuery calldata query) external view onlyFreshDelegateCall returns (ForageTokenSourceEligibility memory eligibility)",
    modulePath, "SETUP-FORAGE-LEGACY-REFUSAL", failures);
  if (!sourceEligibilityForwarderCode.startsWith("if(msg.sender!=address(this))revertUnauthorizedTokenQuery(msg.sender);return_readSourceEligibilityForBlocklist(")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-ELIGIBILITY-BRIDGE", "the self-only host selector must forward to the delegated eligibility helper.");
  }
  if (!sourceEligibilityDelegateCode.includes("ForageTokenSourceEligibilityQuery({") ||
      !sourceEligibilityDelegateCode.includes("rememberedBeneficiary:_vestingBeneficiaryBySource[source]") ||
      !sourceEligibilityDelegateCode.includes("timepoint:timepoint") ||
      !sourceEligibilityDelegateCode.includes("ForageTokenStateModule.sourceEligibilityForBlocklistModule,(query)")) {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-ELIGIBILITY-BRIDGE", "the delegate query must carry the explicit remembered beneficiary slot value.");
  }
  if (!sourceEligibilityCode.includes("uint48timepoint=query.timepoint") ||
      sourceEligibilityCode.includes("_voteEligibilitySyncTimepoint") ||
      !sourceEligibilityCode.includes("_historicalVestingSourceRegistration(query.allowlist,query.source,timepoint)") ||
      !sourceEligibilityCode.includes("registered!=beneficiary||query.registrationKnown!=(registered!=address(0))") ||
      !sourceEligibilityCode.includes("if(registrationPending)revertVestingSourceRegistrationRequired(query.source,beneficiary)") ||
      !sourceEligibilityCode.includes("if(unsupportedBeneficiary)revertUnsupportedLegacyVestingBeneficiary(query.source)") ||
      sourceEligibilityCode.includes("vestingSourceBeneficiary(query.source)") ||
      sourceEligibilityCode.includes("_readOptionalVestingBeneficiary(query.source)")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "source eligibility must verify registration and pending/unsupported state at the task timepoint without a live fallback.");
  }
  if (!pastCode.includes("projection.blocked") ||
      !pastProjectionEntryCode.includes("projection.blocked=_wasBlockedAtTimepoint(delegatee,timepoint,projection.blocklist,projection.allowlist)") ||
      !historicalBlockCode.includes("_historicalVestingSourceRegistration(allowlist_,account,timepoint)") ||
      historicalBlockCode.includes("_vestingBeneficiaryBySource[account]")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "historical vote blocking must use task-time registered-beneficiary history.");
  }
  if (!registrationHistoryCode.includes("_vestingSourceRegistrationCheckpoints[account].push(timepoint,registration)") ||
      !registrationHistoryViewCode.includes("_vestingSourceRegistrationCheckpoints[source].upperLookupRecent(uint48(timepoint))") ||
      !compactSolidity(registrationHistoryView.header).includes("viewfreshOnly") ||
      !registrationWriterCode.includes("_vestingSourceBeneficiary[source]") ||
      !allowlistFreshGuardCode.includes("layoutVersion!=2") ||
      !allowlistFreshMarkerCode.includes("value=2")) {
    setupFailure(failures, allowlistPath, "SETUP-FORAGE-LEGACY-REFUSAL", "historical vesting registration must be checkpointed and exposed only from the fresh schema.");
  }
  if (!liveProjectionCode.includes("projections[generation]") || liveProjectionCode.includes("_eligibleDelegateVotes") ||
      !pastProjectionCode.includes("projections[generation]") || pastProjectionCode.includes("_eligibleDelegateVotes")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "all generations must read their own isolated projection.");
  }
  if (!epochCode.includes("state.inventoryVersion!=1||length==0") ||
      !epochCode.includes("revertLegacySourceInventoryUnavailable(_blocklist,address(0))") ||
      epochCode.includes("return(0,_blocklist)")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "historical epoch queries must fail closed without a fresh epoch.");
  }
  const registrationAt = sourceSyncCode.indexOf("_vestingSourceRegistrationAt(source,token.allowlist(),timepoint)");
  const pendingRefusal = sourceSyncCode.indexOf("if(sync.registrationPending)");
  const unsupportedRefusal = sourceSyncCode.indexOf("if(sync.systemAccount&&sync.unsupportedRegistration)");
  const inventoryWrite = sourceSyncCode.indexOf("_recordVoteSource(rotation,source);");
  if (registrationAt < 0 || pendingRefusal < registrationAt || unsupportedRefusal < pendingRefusal ||
      inventoryWrite < unsupportedRefusal || sourceSyncCode.includes("unindexedLegacy")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "task-time vesting registration and unsupported-source refusals must precede inventory writes.");
  }
  if (moduleSource.includes("function legacySourceEligibleNow") || moduleSource.includes("_historicalDelegateSources[")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-FRESH-ONLY", "legacy source translation paths must be absent from the fresh-only module.");
  }
}

function checkForageMarkerSchema(tokenSource, moduleSource, tokenPath, modulePath, failures) {
  const moduleGuard = setupFunction(moduleSource, "_requireFreshInventory", modulePath, "marker-ready inventory guard", failures);
  const moduleStatus = setupFunction(moduleSource, "blocklistRotationStatus", modulePath, "marker-ready inventory status", failures);
  const initializeInventory = setupFunction(moduleSource, "initializeSourceInventory", modulePath, "fresh schema initializer", failures);
  const tokenStatus = setupFunction(tokenSource, "blocklistRotationStatus", tokenPath, "marker-ready host status", failures);
  const upgrade = setupFunction(tokenSource, "upgradeToAndCall", tokenPath, "upgrade preflight", failures);
  const authorizeUpgrade = setupFunction(tokenSource, "_authorizeUpgrade", tokenPath, "upgrade authorization", failures);
  if (!moduleGuard || !moduleStatus || !initializeInventory || !tokenStatus || !upgrade || !authorizeUpgrade) return;
  const moduleGuardCode = compactSolidity(moduleGuard.body);
  const moduleStatusCode = compactSolidity(moduleStatus.body);
  const initializeCode = compactSolidity(initializeInventory.body);
  const tokenStatusCode = compactSolidity(tokenStatus.body);
  const upgradeCode = compactSolidity(upgrade.body);
  const authorizeCode = compactSolidity(authorizeUpgrade.body);
  const schema6Guard = "if(state.inventoryVersion!=1||state.projectionSchemaVersion!=4||state.vestingMembershipSchemaVersion!=1||state.voteEligibilitySyncSchemaVersion!=6||state.epochs.length==0){revertLegacySourceInventoryUnavailable(_blocklist,address(0));}";
  const schema6Status = "status.inventorySupported=state.inventoryVersion==1&&state.projectionSchemaVersion==4&&state.vestingMembershipSchemaVersion==1&&state.voteEligibilitySyncSchemaVersion==6&&state.epochs.length!=0;";
  if (!moduleGuardCode.includes(schema6Guard) || !moduleStatusCode.includes(schema6Status)) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-LEGACY-REFUSAL", "projection schema 4 and sync schema 6 must gate inventory support and module access.");
  }
  if (!initializeCode.includes("state.projectionSchemaVersion!=0") ||
      !initializeCode.includes("state.projectionSchemaVersion=4;") ||
      !initializeCode.includes("state.vestingMembershipSchemaVersion!=0") ||
      !initializeCode.includes("state.vestingMembershipSchemaVersion=1;") ||
      !initializeCode.includes("state.voteEligibilitySyncSchemaVersion!=0") ||
      !initializeCode.includes("state.voteEligibilitySyncSchemaVersion=6;") ||
      !initializeCode.includes("state.pendingVoteSyncHeadTaskId!=0") ||
      !initializeCode.includes("state.pendingVoteSyncTailTaskId!=0") ||
      !initializeCode.includes("state.pendingProjectionPageBarrier!=0") ||
      !initializeCode.includes("state.epochs.push(")) {
    setupFailure(failures, modulePath, "SETUP-FORAGE-LEGACY-REFUSAL", "fresh schema markers must be set only by empty-state initialization, with no legacy backfill.");
  }
  if (tokenStatusCode !== "return_requireFreshInventory();") {
    setupFailure(failures, tokenPath, "SETUP-FORAGE-LEGACY-REFUSAL", "the host status entry must typed-refuse unsupported marker storage.");
  }
  setupHeader(upgrade,
    "function upgradeToAndCall(address newImplementation, bytes memory data) public payable override freshInventoryReady onlyAllowedCaller",
    tokenPath, "SETUP-FORAGE-UPGRADE-PREFLIGHT", failures);
  if (upgradeCode !== "super.upgradeToAndCall(newImplementation,data);" ||
      !authorizeCode.includes("_requireFreshInventory();")) {
     setupFailure(failures, tokenPath, "SETUP-FORAGE-UPGRADE-PREFLIGHT", "upgrade must preflight the fresh source inventory before the implementation switch.");
  }
}

function checkDeploySetup(source, filePath, failures) {
  const deploy = setupFunction(source, "_deployWithConfig", filePath, "deployment call graph", failures);
  const riskStackDeployment = setupFunction(source, "_deployRiskStack", filePath, "fresh Vault initialization", failures);
  const wiring = setupFunction(source, "_wireTargetStack", filePath, "target-stack wiring", failures);
  const modules = setupFunction(source, "_wireModules", filePath, "module wiring", failures);
  const allowlist = setupFunction(source, "_wireSharedAllowlist", filePath, "shared Allowlist wiring", failures);
  const targets = setupFunction(source, "_allowlistTargets", filePath, "Allowlist target inventory", failures);
  setupCallOrder(deploy, [
    "_deployTokenAndTreasuries(cfg, predicted);",
    "_deployGovernanceAndRegistry(cfg, predicted);",
    "_deployRiskStack(cfg, predicted);",
    "_deployTierStack(predicted);",
    "_wireTargetStack(cfg);",
  ], filePath, "SETUP-DEPLOY-CALLGRAPH", failures);
  setupCallOrder(wiring, [
    "_wireSharedAllowlist(cfg);",
    "_wireModules();",
    "forageToken.setBlocklist(deployedBlocklist);",
    "forageToken.processBlocklistRotation();",
    "forageToken.activateBlocklistRotation();",
    "DelegatingVestingWallet(deployedVestingWallet).setInitialDelegatee(cfg.launchVotingDelegate);",
    "DelegatingVestingWallet(deployedVestingWallet).precommitForageToken(deployedForageToken);",
    "DelegatingVestingWallet(deployedVestingWallet).setForageToken(deployedForageToken);",
  ], filePath, "SETUP-TOKEN-BLOCKLIST-ORDER", failures);
  setupCallOrder(wiring, [
    "StakingQueue(deployedStakingQueue).setBlocklist(deployedBlocklist);",
    "StakingQueue(deployedStakingQueue).setVaultId(targetVaultId);",
  ], filePath, "SETUP-QUEUE-BLOCKLIST-ORDER", failures);
  if (!compactSolidity(riskStackDeployment?.body || "").includes(
    "VaultRegistry.initialize,(cfg.deployer,predicted.riskusdVault)")) {
    setupFailure(failures, filePath, "SETUP-FRESH-REGISTRY-INITIALIZATION", "fresh Registry initialization must establish its Vault pointer.");
  }
  if (!compactSolidity(riskStackDeployment?.body || "").includes(
    "deployedRiskusd=_proxy(implRiskusd,abi.encodeCall(RISKUSD.initialize,(cfg.deployer)))")) {
    setupFailure(failures, filePath, "SETUP-FRESH-RISKUSD-INITIALIZATION", "fresh RISKUSD must initialize in the proxy constructor data.");
  }
  if (!compactSolidity(riskStackDeployment?.body || "").includes(
    "RISKUSDVault.initializeTarget,(cfg.usdc,deployedRiskusd,deployedVaultRegistry,cfg.deployer,deployedHLTradingBridge,deployedUSDCTreasury)")) {
    setupFailure(failures, filePath, "SETUP-FRESH-VAULT-INITIALIZATION", "fresh Vault initialization must establish reciprocal Registry wiring.");
  }
  if (/\.(?:initializeV2|initializeV3)\s*\(/.test(maskSolidityNonCode(source))) {
    setupFailure(failures, filePath, "SETUP-FRESH-INITIALIZATION", "legacy post-deployment reinitializer calls must be absent.");
  }
  checkModuleFloor(source, modules, filePath, failures);
  checkSharedAllowlist(source, allowlist, targets, filePath, failures);
}

function checkModuleFloor(source, modules, filePath, failures) {
  if (!modules) return;
  const moduleCode = compactSolidity(modules.body);
  const vaultModule = "RISKUSDVault(deployedRiskusdVault).setVaultModule(implRiskusdVaultModule);";
  const floor = "RISKUSDVault(deployedRiskusdVault).setMinimumFirstDeposit(2, 200_000e6);";
  const queueModule = "StakingQueue(deployedStakingQueue).setQueueModule(implStakingQueueModule);";
  setupCallOrder(modules, [vaultModule, floor, queueModule], filePath, "SETUP-BASIS2-FLOOR-ORDER", failures);
  if (!moduleCode.includes(compactSolidity(`${vaultModule} ${floor}`))) {
    setupFailure(failures, filePath, "SETUP-BASIS2-FLOOR-ORDER", "basis-2 floor must immediately follow Vault module installation.");
  }
  const fullSource = compactSolidity(source);
  const floorMatches = fullSource.match(new RegExp(escapeRegex(compactSolidity(floor)), "g")) || [];
  if (floorMatches.length !== 1) {
    setupFailure(failures, filePath, "SETUP-BASIS2-FLOOR-ORDER", "the existing basis-2 floor call must remain unique.");
  }
}

function checkSharedAllowlist(source, allowlist, targets, filePath, failures) {
  if (!allowlist || !targets) return;
  const targetCode = compactSolidity(targets.body);
  for (const target of ["deployedBlocklist", "deployedForageToken", "deployedRiskusdVault", "deployedStakingQueue"]) {
    if (!targetCode.includes(target)) setupFailure(failures, filePath, "SETUP-ALLOWLIST-PREREQUISITE", `Allowlist target inventory must include ${target}.`);
  }
  setupCallOrder(allowlist, [
    "registry.setSystemAccount(targets[i], true);",
    "registry.setSystemAccount(cfg.deployer, true);",
    "IAllowlistSettable(targets[i]).setAllowlist(deployedAllowlist);",
    "_assertSharedAllowlistMandate();",
  ], filePath, "SETUP-ALLOWLIST-PREREQUISITE", failures);
  if (!compactSolidity(source).includes("Blocklist.initialize")) {
    setupFailure(failures, filePath, "SETUP-ALLOWLIST-PREREQUISITE", "fresh Deploy must retain the initialized Blocklist proxy.");
  }
}

function checkFreshDeploymentSetup(failures) {
  const tokenPath = path.join(SRC_DIR, "ForageToken.sol");
  const riskusdPath = path.join(SRC_DIR, "RISKUSD.sol");
  const registryPath = path.join(SRC_DIR, "CustodianRegistry.sol");
  if (!fs.existsSync(tokenPath) || !fs.existsSync(riskusdPath) || !fs.existsSync(registryPath) || !fs.existsSync(DEPLOY_SCRIPT)) {
    setupFailure(failures, CONTRACTS_ROOT, "SETUP-PARSER-UNSUPPORTED", "source root must contain src/ForageToken.sol, src/RISKUSD.sol, src/CustodianRegistry.sol and script/Deploy.s.sol.");
    return;
  }
  const tokenSource = fs.readFileSync(tokenPath, "utf8");
  const riskusdSource = fs.readFileSync(riskusdPath, "utf8");
  const registrySource = fs.readFileSync(registryPath, "utf8");
  const deploySource = fs.readFileSync(DEPLOY_SCRIPT, "utf8");
  checkForageInitialization(tokenSource, tokenPath, failures);
  checkForageGuard(tokenSource, tokenPath, failures);
  checkForageNormalCalls(tokenSource, tokenPath, failures);
  checkForageSetterGates(tokenSource, tokenPath, failures);
  checkRiskusdFreshOnly(riskusdSource, riskusdPath, failures);
  checkRiskusdAllowancePolicy(riskusdSource, riskusdPath, failures);
  checkRegistryEmergencyPrincipalLane(registrySource, registryPath, failures);
  checkDeploySetup(deploySource, DEPLOY_SCRIPT, failures);
}

function checkRegistryEmergencyPrincipalLane(source, filePath, failures) {
  const setter = setupFunction(source, "setEmergencyPrincipalLane", filePath, "Registry emergency lane setter", failures);
  if (setter) {
    const header = compactSolidity(setter.header);
    const body = compactSolidity(setter.body);
    for (const gate of ["freshOnly", "onlyAllowedCaller", "onlyOwner"]) {
      if (!header.includes(gate)) setupFailure(failures, filePath, "I15-REGISTRY-EMERGENCY-LANE", `setter is missing ${gate}.`);
    }
    for (const required of ["lane==address(0)", "lane.code.length==0", "capital.emergencyPrincipalLane=lane;", "emitEmergencyPrincipalLaneSet(previousLane,lane);"]) {
      if (!body.includes(required)) setupFailure(failures, filePath, "I15-REGISTRY-EMERGENCY-LANE", `setter is missing ${required}.`);
    }
  }
  const getter = setupFunction(source, "emergencyPrincipalLane", filePath, "Registry emergency lane getter", failures);
  if (getter && !compactSolidity(getter.header).includes("externalviewfreshOnlyreturns(address)")) {
    setupFailure(failures, filePath, "I15-REGISTRY-EMERGENCY-LANE", "getter must remain external view and freshOnly.");
  }
  if (!compactSolidity(source).includes("_FRESH_LAYOUT_VERSION=6;")) {
    setupFailure(failures, filePath, "I15-REGISTRY-EMERGENCY-LANE", "Registry fresh-layout version must be 6.");
  }
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
  const cancelDefinitions = solidityFunctionDeclarations(source, spec.cancel);
  const cancelRecord = cancelDefinitions.length === 1 ? cancelDefinitions[0] : null;

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

  if (!cancelRecord || cancelRecord.body === null) {
    failures.push(
      setter.path + ":" + setter.line + ": I-15 cancellation surface missing or ambiguous for " + setter.name + "."
    );
  } else {
    const authority = cancelAuthorityKind(cancelRecord, source);
    if (authority === "unknown") {
      failures.push(
        setter.path + ":" + setter.line + ": I-15 cancellation surface " + spec.cancel + " has no recognizable owner/guardian authorization guard."
      );
    } else {
      outcome.cancelChecked += 1;
    }

    if (spec.guardianCancel) {
      if (authority !== "guardian-cancel" || !source.includes("PERMISSION_CAN_CANCEL")) {
        failures.push(
          setter.path + ":" + setter.line + ": I-15 guardian-cancel path for " + setter.name + " must use " +
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
  if (args.staticControls) {
    try {
      console.log(JSON.stringify({...runSetupControls(), i15: runAllowlistRotationControls()}));
      return;
    } catch (error) {
      writeDiagnosticError(`I-15 static controls failed: ${error.message}`);
      process.exitCode = 1;
      return;
    }
  }
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

  checkFreshDeploymentSetup(failures);

  const allowlistPath = path.join(SRC_DIR, "Allowlist.sol");
  const allowlistSource = fs.readFileSync(allowlistPath, "utf8");
  failures.push(...allowlistPendingMutationFailures(allowlistSource, allowlistPath));
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
