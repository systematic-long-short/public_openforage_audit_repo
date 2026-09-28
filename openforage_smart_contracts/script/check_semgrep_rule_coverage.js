#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const {spawnSync} = require("child_process");

const SENTINEL = "OPENFORAGE_PUBLIC_SEMGREP_COVERAGE";
const CONTRACT_ROOT = path.resolve(__dirname, "..");
const AUDIT_CAPTURE_SCHEMA = "openforage.public-audit-capture.v1";
const AUDIT_CAPTURE_INDEX_SCHEMA = "openforage.public-audit-capture-index.v1";
const AUDIT_CAPTURE_BASE_KINDS = ["default-build", "deploy-build", "slither-scan", "slither-validator"];
const AUDIT_CAPTURE_SEMGREP_KINDS = ["semgrep-openforage", "semgrep-disjointness"];
const AUDIT_CAPTURE_KINDS = [...AUDIT_CAPTURE_BASE_KINDS, ...AUDIT_CAPTURE_SEMGREP_KINDS];
const AUDIT_TOOL_PINS = {
  forge: {version: "1.3.5-v1.3.5", sha256: "0439acf59828c9bdd3e594c97b2108fe27b9c267d78d3a9376bd19d9e4442213"},
  solc: {configuredVersion: "0.8.24", version: "0.8.24+commit.e11b9ed9",
    sha256: "fb03a29a517452b9f12bcf459ef37d0a543765bb3bbc911e70a87d6a37c30d5f"},
  slither: {version: "0.11.6", sha256: "80f504f8d08cda76f3c69269ea64d0192691a3a89d7e9dc2191a11d01adda4d7"},
  semgrep: {version: "1.177.0", sha256: "14ee68b198c5fda4036bab76a39a1454f8629547357506720b9b06da1623e8a1"},
};
const AUDIT_SINGLETON_FUNCTIONS = ["auditResolveLatest", "auditFileRecord", "auditWriteJson", "auditWriteLatest",
  "auditReceiptRow", "writeSemgrepAuditReceipt", "auditReceiptEnvelope", "auditCaptureControls", "auditValidateReuse"];
const SOURCE_MANIFEST_PATH = ".semgrep/source-manifest.json";
const EXCEPTIONS_PATH = ".semgrep/source-exceptions.json";
const CONFIGS = [".semgrep/openforage.yml", ".semgrep/disjointness-grant-role.yml"];
const PUBLIC_INCLUDE_GLOBS = new Set([
  "src/**/*.sol",
  "script/**/*.sol",
  "/src/**/*.sol",
  "/script/**/*.sol",
  "**/src/**/*.sol",
  "**/src/RISKUSDVault.sol",
  "**/src/modules/RISKUSDVaultModule.sol",
]);
const REQUIRED_ALLOWLIST_FUNCTION_NAMES = [
  "transfer",
  "approve",
  "transferFrom",
  "initialize",
  "initializeTarget",
  "setAllowlist",
  "setVaultModule",
  "setQueueModule",
  "approveOperator",
  "revoke",
  "shrinkApprovalsPerDayCap",
  "setSystemAccount",
  "proposeRegistrar",
  "finalizeRegistrar",
  "cancelRegistrar",
  "proposeGuardian",
  "finalizeGuardian",
  "cancelGuardian",
  "proposeSystemRegistrar",
  "finalizeSystemRegistrar",
  "cancelSystemRegistrar",
];
const PUBLIC_SOURCE_PREDICATE_SPECS = [
  {
    id: "allowlist-register-observer",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    signature: "registerVoteEligibilityObserver()",
    predicate: "code-bearing-system-account-and-single-observer-slot",
    helperFunctions: [
      ["src/ForageToken.sol", "_registerAllowlistObserver(address)"],
      ["src/ForageToken.sol", "setAllowlist(address)"],
      ["script/Deploy.s.sol", "_wireSharedAllowlist(DeployConfig)"],
      ["script/Deploy.s.sol", "_allowlistTargets()"],
    ],
  },
  {
    id: "allowlist-unregister-observer",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    signature: "unregisterVoteEligibilityObserver()",
    predicate: "registered-observer-only-pointer-cleanup",
    helperFunctions: [
      ["src/ForageToken.sol", "_unregisterAllowlistObserver(address)"],
      ["src/ForageToken.sol", "setAllowlist(address)"],
    ],
  },
  {
    id: "allowlist-transfer-ownership",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    signature: "transferOwnership(address)",
    predicate: "current-eligible-owner-two-step-transfer",
    helperFunctions: [["src/Allowlist.sol", "_requireEligibleOwner()"]],
  },
  {
    id: "allowlist-accept-ownership",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    signature: "acceptOwnership()",
    predicate: "eligible-pending-owner-acceptance",
    helperFunctions: [
      ["src/Allowlist.sol", "_isAllowed(address)"],
      ["lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol", "acceptOwnership()"],
      ["lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol", "pendingOwner()"],
    ],
  },
  {
    id: "blocklist-unregister-observer",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Blocklist.sol",
    signature: "unregisterVoteEligibilityObserver()",
    predicate: "registered-observer-only-pointer-cleanup",
    helperFunctions: [
      ["src/ForageToken.sol", "_unregisterBlocklistObserver(address)"],
      ["src/ForageToken.sol", "setBlocklist(address)"],
    ],
  },
  {
    id: "forage-token-sync-observer",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/ForageToken.sol",
    signature: "syncVoteEligibility(address)",
    predicate: "current-allowlist-or-blocklist-observer",
    helperFunctions: [
      ["src/Allowlist.sol", "_recordEligibilityChange(address)"],
      ["src/Blocklist.sol", "_notifyVoteEligibilityObserver(address)"],
    ],
  },
  {
    id: "allowlist-renewable-beneficiary",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    signature: "approveVestingBeneficiary(address)",
    predicate: "finite-renewable-external-beneficiary-approval",
    helperFunctions: [
      ["src/Allowlist.sol", "_requireEligibleOwner()"],
      ["src/Allowlist.sol", "_countApproval()"],
      ["src/Allowlist.sol", "_captureEligibilityBaseline(address)"],
      ["src/Allowlist.sol", "_recordEligibilityChange(address)"],
      ["script/Deploy.s.sol", "_deployAllowlist(DeployConfig)"],
      ["script/Deploy.s.sol", "_allowlistTargets()"],
    ],
  },
];
const PUBLIC_SEMGREP_PREDICATE_IDS = new Set([
  "allowlist-register-observer",
  "allowlist-unregister-observer",
  "allowlist-transfer-ownership",
  "allowlist-accept-ownership",
  "blocklist-unregister-observer",
  "forage-token-sync-observer",
  "allowlist-renewable-beneficiary",
]);
const PUBLIC_SOURCE_POLICY_SPECS = [
  {
    id: "atrisk-allowlist-transition",
    ruleId: "openforage-allowlist-gate-missing-modifier",
    path: "src/atRISKUSD.sol",
    signature: "setAllowlist(address)",
    predicate: "installed-owner-and-canonical-candidate-system-membership",
    helperFunctions: [
      ["src/AllowlistGatedUpgradeable.sol", "_validateAllowlistTransition(address)"],
      ["src/AllowlistGatedUpgradeable.sol", "_requireTransitionCandidate(address,address)"],
      ["src/AllowlistGatedUpgradeable.sol", "_readCanonicalBoolean(address,bytes)"],
    ],
  },
];
const REQUIRED_ATRISK_EXITS = [
  "executeWithdrawal()",
  "executeWithdrawal(uint256)",
  "cancelWithdrawal()",
  "recoverPendingWithdrawal()",
  "burnWorthlessShares(uint256)",
];
const DISJOINTNESS_RULE_ID = "disjointness-no-proposer-role-to-guardian";
const DISJOINTNESS_EXCEPTION_ID = "disjointness-public-proposer-guardian-separation";
const DISJOINTNESS_GRANT_FUNCTION = "_wireTargetStack(DeployConfig)";
const DISJOINTNESS_INITIALIZER_FUNCTION = "_deployGovernanceAndRegistry(DeployConfig,PredictedAddresses)";
const DISJOINTNESS_GRANT = "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE,deployedForageGovernor);";
const DISJOINTNESS_GRANT_SOURCE = "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, deployedForageGovernor);";
const DISJOINTNESS_GUARD = "if(GuardianModule(deployedGuardianModule).isGuardian(deployedForageGovernor)){revertGovernanceProposerIsGuardian(deployedForageGovernor);}";
const OPENZEPPELIN_ADMIN_PIN = "7bf4727aacdbfaa0f36cbd664654d0c9e1dc52bf";

function fail(message) {
  throw new Error(`${SENTINEL}_FAIL ${message}`);
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function isSha256Digest(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

function safeRelativePath(value) {
  return typeof value === "string" && value.length > 0 && !value.startsWith("/") &&
    !value.includes("\\") && !value.split("/").includes("..") && path.posix.normalize(value) === value;
}

function projectFile(relativePath) {
  if (!safeRelativePath(relativePath)) fail(`unsafe public relative path ${relativePath}`);
  const absolute = path.resolve(CONTRACT_ROOT, ...relativePath.split("/"));
  if (!absolute.startsWith(`${CONTRACT_ROOT}${path.sep}`)) fail(`public path escapes contract root ${relativePath}`);
  return absolute;
}

function readBytes(relativePath) {
  try {
    const filePath = projectFile(relativePath);
    const stat = fs.lstatSync(filePath);
    if (!stat.isFile() || stat.isSymbolicLink()) fail(`public input is not a regular file ${relativePath}`);
    return fs.readFileSync(filePath);
  } catch (error) {
    if (error.message.startsWith(`${SENTINEL}_FAIL`)) throw error;
    fail(`cannot read public input ${relativePath}: ${error.message}`);
  }
}

function readText(relativePath) {
  return readBytes(relativePath).toString("utf8");
}

function readJson(relativePath) {
  try {
    return JSON.parse(readText(relativePath));
  } catch (error) {
    if (error.message.startsWith(`${SENTINEL}_FAIL`)) throw error;
    fail(`invalid JSON in ${relativePath}: ${error.message}`);
  }
}

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function sameSet(actual, expected, label) {
  const actualSorted = sorted(actual);
  const expectedSorted = sorted(expected);
  if (JSON.stringify(actualSorted) !== JSON.stringify(expectedSorted)) {
    fail(`${label} differs; expected ${expectedSorted.length} items, found ${actualSorted.length}`);
  }
}

function collectFiles(relativeRoot, predicate = () => true) {
  const rootPath = projectFile(relativeRoot);
  let rootStat;
  try {
    rootStat = fs.lstatSync(rootPath);
  } catch (error) {
    fail(`required public root is missing ${relativeRoot}: ${error.message}`);
  }
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail(`required public root is not a directory ${relativeRoot}`);
  const output = [];
  function visit(directory) {
    for (const entry of fs.readdirSync(directory, {withFileTypes: true}).sort((left, right) => left.name.localeCompare(right.name))) {
      const absolute = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) fail(`public inventory refuses symlink ${absolute}`);
      if (entry.isDirectory()) {
        if (new Set([".git", ".venv", "broadcast", "cache", "node_modules", "out"]).has(entry.name)) continue;
        visit(absolute);
      } else if (entry.isFile()) {
        const relative = path.relative(CONTRACT_ROOT, absolute).split(path.sep).join("/");
        if (predicate(relative)) output.push(relative);
      }
    }
  }
  visit(rootPath);
  return sorted(output);
}

function maskSolidity(source) {
  const characters = source.split("");
  let state = "code";
  let quote = "";
  for (let index = 0; index < characters.length; index += 1) {
    const current = characters[index];
    const next = characters[index + 1];
    if (state === "line") {
      if (current === "\n") state = "code";
      else characters[index] = " ";
      continue;
    }
    if (state === "block") {
      if (current === "*" && next === "/") {
        characters[index] = " ";
        characters[index + 1] = " ";
        index += 1;
        state = "code";
      } else if (current !== "\n") characters[index] = " ";
      continue;
    }
    if (state === "string") {
      if (current === "\\") {
        characters[index] = " ";
        if (index + 1 < characters.length) {
          if (characters[index + 1] !== "\n") characters[index + 1] = " ";
          index += 1;
        }
      } else {
        if (current === quote) state = "code";
        if (current !== "\n") characters[index] = " ";
      }
      continue;
    }
    if (current === "/" && next === "/") {
      characters[index] = " ";
      characters[index + 1] = " ";
      index += 1;
      state = "line";
    } else if (current === "/" && next === "*") {
      characters[index] = " ";
      characters[index + 1] = " ";
      index += 1;
      state = "block";
    } else if (current === "\"" || current === "'") {
      quote = current;
      characters[index] = " ";
      state = "string";
    }
  }
  if (state === "block" || state === "string") fail("unclosed Solidity comment or string");
  return characters.join("");
}

function matchingDelimiter(source, start, left, right) {
  let depth = 0;
  for (let index = start; index < source.length; index += 1) {
    if (source[index] === left) depth += 1;
    else if (source[index] === right) {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  return -1;
}

function normalizeParameter(parameter) {
  const words = parameter.replace(/\b(memory|calldata|storage|indexed|payable)\b/g, " ").trim().split(/\s+/).filter(Boolean);
  if (words.length > 1 && /^[A-Za-z_$][\w$]*$/.test(words[words.length - 1])) words.pop();
  return words.join("").replace(/payable/g, "");
}

function functionDeclarations(source) {
  const code = maskSolidity(source);
  const records = [];
  const pattern = /\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g;
  let match;
  while ((match = pattern.exec(code)) !== null) {
    const openParen = code.indexOf("(", match.index);
    const closeParen = matchingDelimiter(code, openParen, "(", ")");
    if (closeParen < 0) fail(`unclosed function parameters for ${match[1]}`);
    const openBrace = code.indexOf("{", closeParen + 1);
    const semicolon = code.indexOf(";", closeParen + 1);
    const hasBody = openBrace >= 0 && (semicolon < 0 || openBrace < semicolon);
    const headerEnd = hasBody ? openBrace : (semicolon < 0 ? code.length : semicolon);
    let body = null;
    let nextIndex = headerEnd + 1;
    if (hasBody) {
      const closeBrace = matchingDelimiter(code, openBrace, "{", "}");
      if (closeBrace < 0) fail(`unclosed function body for ${match[1]}`);
      body = code.slice(openBrace + 1, closeBrace);
      nextIndex = closeBrace + 1;
    }
    const parameters = code.slice(openParen + 1, closeParen).split(",").filter((item) => item.trim()).map(normalizeParameter);
    records.push({
      name: match[1],
      signature: `${match[1]}(${parameters.join(",")})`,
      header: code.slice(match.index, headerEnd),
      body,
      line: source.slice(0, match.index).split("\n").length,
    });
    pattern.lastIndex = nextIndex;
  }
  return records;
}

function functionBySignature(source, signature, filePath) {
  const matches = functionDeclarations(source).filter((item) => item.signature === signature);
  if (matches.length !== 1 || matches[0].body === null) fail(`${filePath} must contain exactly one ${signature}`);
  return matches[0];
}

function modifierBody(source, name, filePath) {
  const code = maskSolidity(source);
  const pattern = new RegExp(`\\bmodifier\\s+${name}\\s*\\([^)]*\\)\\s*\\{`, "g");
  const matches = [...code.matchAll(pattern)];
  if (matches.length !== 1) fail(`${filePath} must contain exactly one ${name} modifier`);
  const open = code.indexOf("{", matches[0].index);
  const close = matchingDelimiter(code, open, "{", "}");
  if (close < 0) fail(`${filePath} has an unclosed ${name} modifier`);
  return code.slice(open + 1, close);
}

function compact(source) {
  return maskSolidity(source).replace(/\s+/g, "");
}

function predicateFunction(sourceReader, filePath, signature) {
  const fn = functionBySignature(sourceReader(filePath), signature, filePath);
  return {header: compact(fn.header), body: compact(fn.body), declaration: compact(`${fn.header}{${fn.body}}`)};
}

function requirePredicateSequence(source, fragments, label) {
  let cursor = 0;
  for (const fragment of fragments) {
    const token = compact(fragment);
    const index = source.indexOf(token, cursor);
    if (!token || index < 0) fail(`public source predicate is missing ${label}`);
    cursor = index + token.length;
  }
}

function verifyEligibleOwnerModifier(sourceReader) {
  const body = compact(modifierBody(sourceReader("src/Allowlist.sol"), "onlyEligibleOwner", "src/Allowlist.sol"));
  if (body !== "_requireEligibleOwner();_;") fail("Allowlist onlyEligibleOwner must execute the exact eligibility helper");
  const owner = predicateFunction(sourceReader, "src/Allowlist.sol", "_requireEligibleOwner()");
  if (owner.body !== "if(msg.sender!=owner()||!_isAllowed(msg.sender)){revertOwnableUnauthorizedAccount(msg.sender);}") {
    fail("Allowlist eligible-owner helper must require current owner identity and eligibility");
  }
  const currentEligibility = predicateFunction(sourceReader, "src/Allowlist.sol", "_isAllowed(address)");
  if (currentEligibility.body !== "return_systemAccounts[account]||_allowedUntil[account]>=uint64(block.timestamp);") {
    fail("Allowlist owner and beneficiary predicates must read current eligibility");
  }
}

function dailyCapPolicyStatus(sourceReader = readText) {
  const binding = sourcePolicyBindingRow(sourceReader);
  const count = compact(predicateFunction(sourceReader, "src/Allowlist.sol", "_countApproval()").body);
  const setter = predicateFunction(sourceReader, "src/Allowlist.sol", "shrinkApprovalsPerDayCap(uint32)").body;
  const reset = count.indexOf("_approvalsTodayCount=1;return;");
  const capCheck = count.indexOf("_approvalsTodayCount>=_approvalsPerDayCap");
  const zeroCapGuard = count.indexOf("if(_approvalsPerDayCap==0)revertDailyCapReached();");
  const zeroAllowed = !setter.includes("newCap==0") && setter.includes("_approvalsPerDayCap=newCap");
  const rolloverBeforeCap = reset >= 0 && capCheck > reset;
  const zeroCapRejectedBeforeRollover = zeroCapGuard >= 0 && zeroCapGuard < reset;
  return {
    id: "allowlist-zero-daily-cap-rollover",
    status: rolloverBeforeCap && zeroAllowed && !zeroCapRejectedBeforeRollover ? "RED_UNVERIFIED" : "REVIEW_REQUIRED",
    evidence: zeroCapRejectedBeforeRollover
      ? "_countApproval rejects a zero cap before UTC-day rollover; positive-cap behavior remains subject to review"
      : "_countApproval may reset a new UTC day before checking a zero cap",
    sourceOnly: true,
    binding,
  };
}

function sourcePolicyBindingRow(sourceReader = readText) {
  const filePath = "src/Allowlist.sol";
  const source = sourceReader(filePath);
  const fn = functionBySignature(source, "_countApproval()", filePath);
  return {
    id: "allowlist-zero-daily-cap-rollover",
    path: filePath,
    signature: fn.signature,
    sourceSha256: sha256(Buffer.from(source, "utf8")),
    bodySha256: sha256(Buffer.from(compact(fn.body), "utf8")),
    declarationSha256: sha256(Buffer.from(compact(`${fn.header}{${fn.body}}`), "utf8")),
  };
}

function verifySourcePolicyDisclosure(exceptions) {
  const record = exceptions.sourcePolicyReview;
  const current = sourcePolicyBindingRow();
  const status = dailyCapPolicyStatus();
  if (!record || !["RED_UNVERIFIED", "REVIEW_REQUIRED"].includes(record.status) || record.status !== status.status ||
      JSON.stringify({id: record.id, path: record.path, signature: record.signature,
        sourceSha256: record.sourceSha256, bodySha256: record.bodySha256,
        declarationSha256: record.declarationSha256}) !== JSON.stringify(current) ||
      !record.rationale || /private|packet|checkpoint|workspace|dec-/i.test(record.rationale)) {
    fail("public zero-daily-cap source status and identity must remain explicitly bound");
  }
}

function verifyExistingAtRiskPolicySemantics(sourceReader = readText) {
  const transition = predicateFunction(sourceReader, "src/atRISKUSD.sol", "setAllowlist(address)");
  requirePredicateSequence(transition.body, [
    "if(allowlist()==address(0))",
    "if(msg.sender!=owner())",
    "proposedAllowlist.isAllowed(msg.sender)",
    "if (!proposedAllowlist.isSystemAccount(address(this)))",
    "_setAllowlist(allowlist_)",
    "_checkAllowedCaller()",
    "if(msg.sender!=owner())",
    "_validateAllowlistTransition(allowlist_)",
    "_setAllowlist(allowlist_)",
  ], "atRISKUSD replacement must keep bootstrap and installed-registry authorization separate");
  const transitionHelper = predicateFunction(sourceReader,
    "src/AllowlistGatedUpgradeable.sol", "_validateAllowlistTransition(address)");
  requirePredicateSequence(transitionHelper.body, [
    "_checkAllowedCaller()",
    "_requireTransitionCandidate(allowlist_, msg.sender)",
  ], "atRISKUSD replacement helper must check the installed caller before candidate authority");
  const candidateHelper = predicateFunction(sourceReader,
    "src/AllowlistGatedUpgradeable.sol", "_requireTransitionCandidate(address,address)");
  requirePredicateSequence(candidateHelper.body, [
    "candidate.code.length == 0",
    "_readCanonicalBoolean(candidate, abi.encodeCall(IAllowlist.isAllowed, (caller)))",
    "_readCanonicalBoolean(candidate, abi.encodeCall(IAllowlist.isSystemAccount, (address(this))))",
  ], "atRISKUSD candidate transition must require code, current caller eligibility, and system membership");
  const canonicalBoolean = predicateFunction(sourceReader,
    "src/AllowlistGatedUpgradeable.sol", "_readCanonicalBoolean(address,bytes)");
  requirePredicateSequence(canonicalBoolean.body, [
    "returnedData.length != 32",
    "value > 1",
    "return value == 1",
  ], "atRISKUSD candidate booleans must be canonical and fail closed");
  return {id: "atrisk-allowlist-transition", status: "bounded source policy satisfied"};
}

function verifyReviewedSourcePredicateSemantics(sourceReader = readText) {
  const allowlist = sourceReader("src/Allowlist.sol");
  const deploy = sourceReader("script/Deploy.s.sol");
  verifyEligibleOwnerModifier(sourceReader);
  const allowlistRegister = predicateFunction(sourceReader, "src/Allowlist.sol", "registerVoteEligibilityObserver()");
  if (!allowlistRegister.body.startsWith("if(msg.sender.code.length==0||!_systemAccounts[msg.sender])revertNotSystemRegistrar();")) {
    fail("Allowlist observer registration must require a code-bearing current system account");
  }
  requirePredicateSequence(allowlistRegister.body, [
    "msg.sender.code.length == 0",
    "!_systemAccounts[msg.sender]",
    "address previous = _voteEligibilityObserver",
    "previous != address(0) && previous != msg.sender",
    "_voteEligibilityObserver = msg.sender",
    "_ensureEligibilityHistory()",
    "emit VoteEligibilityObserverSet(previous, msg.sender)",
  ], "Allowlist observer registration must retain its code, system-account, and single-slot checks");

  const tokenRegister = predicateFunction(sourceReader, "src/ForageToken.sol", "_registerAllowlistObserver(address)");
  requirePredicateSequence(tokenRegister.body, [
    "_isSystemAccountAt(address(this), clock())",
    "_supportsAllowlistVoteEligibility(allowlist_)",
    "IAllowlist(allowlist_).isSystemAccount(address(this))",
    "IAllowlistVoteEligibility(allowlist_).registerVoteEligibilityObserver()",
  ], "Token registration call path must retain the current system check and observer call");
  const wireAllowlist = predicateFunction(sourceReader, "script/Deploy.s.sol", "_wireSharedAllowlist(DeployConfig)");
  requirePredicateSequence(wireAllowlist.body, [
    "registry.setSystemAccount(targets[i], true)",
    "registry.setSystemAccount(cfg.deployer, true)",
    "IAllowlistSettable(targets[i]).setAllowlist(deployedAllowlist)",
  ], "public Deploy must bind Token system registration before registry wiring");
  const allowlistTargets = predicateFunction(sourceReader, "script/Deploy.s.sol", "_allowlistTargets()");
  if (!allowlistTargets.body.includes("targets[2]=deployedVestingWallet") ||
      !allowlistTargets.body.includes("targets[4]=deployedForageToken")) {
    fail("public Deploy must register the vesting wallet and Token as distinct system targets");
  }

  const allowlistUnregister = predicateFunction(sourceReader, "src/Allowlist.sol", "unregisterVoteEligibilityObserver()");
  if (!allowlistUnregister.body.startsWith("if(_voteEligibilityObserver==address(0))return;")) {
    fail("Allowlist observer cleanup must keep the empty-slot no-op");
  }
  requirePredicateSequence(allowlistUnregister.body, [
    "msg.sender != _voteEligibilityObserver",
    "_voteEligibilityObserver = address(0)",
    "emit VoteEligibilityObserverSet(previous, address(0))",
  ], "Allowlist observer cleanup must remain bound to the stored observer pointer");
  const tokenAllowlistReplacement = predicateFunction(sourceReader, "src/ForageToken.sol", "setAllowlist(address)");
  requirePredicateSequence(tokenAllowlistReplacement.body, [
    "_unregisterAllowlistObserver(oldAllowlist)",
    "_transitionAllowlist(allowlist_)",
    "_registerAllowlistObserver(allowlist_)",
  ], "Token Allowlist replacement must retain old-pointer cleanup before new registration");

  const allowlistTransfer = predicateFunction(sourceReader, "src/Allowlist.sol", "transferOwnership(address)");
  if (!allowlistTransfer.header.includes("onlyEligibleOwner") ||
      allowlistTransfer.body !== "super.transferOwnership(newOwner);") {
    fail("Allowlist ownership transfer must retain its exact eligible-owner handoff");
  }
  const eligibleOwner = predicateFunction(sourceReader, "src/Allowlist.sol", "_requireEligibleOwner()");
  if (!eligibleOwner.body.includes("msg.sender!=owner()||!_isAllowed(msg.sender)")) {
    fail("Allowlist ownership transfer helper must bind owner identity and current eligibility");
  }

  const allowlistAccept = predicateFunction(sourceReader, "src/Allowlist.sol", "acceptOwnership()");
  requirePredicateSequence(allowlistAccept.body, [
    "_isAllowed(msg.sender)",
    "super.acceptOwnership()",
  ], "Allowlist ownership acceptance must check current eligibility before parent acceptance");
  const parentAccept = predicateFunction(sourceReader,
    "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol", "acceptOwnership()");
  if (!parentAccept.body.includes("pendingOwner()!=sender") ||
      !parentAccept.body.includes("_transferOwnership(sender)")) {
    fail("Allowlist ownership acceptance must preserve the parent pending-owner identity check");
  }
  const parentPendingOwner = predicateFunction(sourceReader,
    "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol", "pendingOwner()");
  if (parentPendingOwner.body !== "Ownable2StepStoragestorage$=_getOwnable2StepStorage();return$._pendingOwner;") {
    fail("pinned two-step parent must read the current pending-owner slot");
  }

  const blocklistUnregister = predicateFunction(sourceReader, "src/Blocklist.sol", "unregisterVoteEligibilityObserver()");
  if (!blocklistUnregister.body.startsWith("if(_voteEligibilityObserver==address(0))return;")) {
    fail("Blocklist observer cleanup must keep the empty-slot no-op");
  }
  requirePredicateSequence(blocklistUnregister.body, [
    "msg.sender != _voteEligibilityObserver",
    "_voteEligibilityObserver = address(0)",
    "emit VoteEligibilityObserverSet(previous, address(0))",
  ], "Blocklist observer cleanup must remain bound to the stored observer pointer");
  const tokenBlocklistReplacement = predicateFunction(sourceReader, "src/ForageToken.sol", "setBlocklist(address)");
  requirePredicateSequence(tokenBlocklistReplacement.body, [
    "_unregisterBlocklistObserver(oldBlocklist)",
    "_delegateStateModuleCalldata()",
    "_registerBlocklistObserver(blocklist_)",
  ], "Token Blocklist replacement must preserve separate old and new observer routes");

  const tokenSync = predicateFunction(sourceReader, "src/ForageToken.sol", "syncVoteEligibility(address)");
  if (!tokenSync.body.startsWith("if(msg.sender!=allowlist()&&msg.sender!=_blocklist){revertUnauthorizedEligibilityObserver(msg.sender);}")) {
    fail("Token eligibility callback must require the exact current Allowlist AND Blocklist caller condition");
  }
  requirePredicateSequence(tokenSync.body, [
    "_syncDelegateSourceContribution(account)",
    "_syncVestingSources(account)",
  ], "Token vote synchronization must retain exact Allowlist and Blocklist pointer authorization");
  const allowlistCallback = predicateFunction(sourceReader, "src/Allowlist.sol", "_recordEligibilityChange(address)");
  if (!allowlistCallback.body.includes("IVoteEligibilityObserver(observer).syncVoteEligibility(account)")) {
    fail("Allowlist eligibility callback must reach the Token observer");
  }
  const blocklistCallback = predicateFunction(sourceReader, "src/Blocklist.sol", "_notifyVoteEligibilityObserver(address)");
  if (!blocklistCallback.body.includes("IVoteEligibilityObserver(observer).syncVoteEligibility(account)")) {
    fail("Blocklist callback must reach the Token observer");
  }

  const beneficiary = predicateFunction(sourceReader, "src/Allowlist.sol", "approveVestingBeneficiary(address)");
  if (!beneficiary.header.includes("onlyEligibleOwner")) {
    fail("renewable vesting approval must remain owner-gated and outside the name-exception list");
  }
  requirePredicateSequence(beneficiary.body, [
    "account == address(0)",
    "block.timestamp > uint256(type(uint64).max) - APPROVAL_TERM_LIMIT",
    "uint64 until = uint64(block.timestamp + APPROVAL_TERM_LIMIT)",
    "_countApproval()",
    "_captureEligibilityBaseline(account)",
    "_allowedUntil[account] = until",
    "_basis[account] = 0",
    "_caseRef[account] = bytes32(0)",
    "emit Approved(account, until, 0, bytes32(0))",
    "_recordEligibilityChange(account)",
  ], "renewable vesting approval must stay finite and history-recorded");
  if (beneficiary.body.includes("_systemAccounts[account]") ||
      beneficiary.body.includes("setSystemAccount(account")) {
    fail("renewable vesting approval must not grant system-account status");
  }
  if (!compact(allowlist).includes("APPROVAL_TERM_LIMIT=400days;")) {
    fail("renewable vesting approval term must remain 400 days");
  }
  const deployApproval = predicateFunction(sourceReader, "script/Deploy.s.sol", "_deployAllowlist(DeployConfig)");
  if (!deployApproval.body.includes("registry.approveVestingBeneficiary(cfg.beneficiary)")) {
    fail("public Deploy must approve its external beneficiary through the renewable API");
  }
  const deployTargets = predicateFunction(sourceReader, "script/Deploy.s.sol", "_allowlistTargets()");
  if (!deployTargets.body.includes("targets[2]=deployedVestingWallet") ||
      compact(deploy).includes("setSystemAccount(cfg.beneficiary")) {
    fail("public Deploy must keep the vesting wallet registered without promoting its beneficiary");
  }

  return {
    predicates: PUBLIC_SOURCE_PREDICATE_SPECS.map((item) => ({id: item.id, status: "bounded caller predicate satisfied"})),
    sourcePolicy: dailyCapPolicyStatus(sourceReader),
  };
}

function sourcePredicateBindingRows(sourceReader = readText) {
  return PUBLIC_SOURCE_PREDICATE_SPECS.map((item) => {
    const source = sourceReader(item.path);
    const fn = functionBySignature(source, item.signature, item.path);
    const helperBindings = item.helperFunctions.map(([helperPath, signature]) => {
      const helperSource = sourceReader(helperPath);
      const helper = functionBySignature(helperSource, signature, helperPath);
      return {
        path: helperPath,
        signature,
        sha256: sha256(Buffer.from(helperSource, "utf8")),
        bodySha256: sha256(Buffer.from(compact(helper.body), "utf8")),
        declarationSha256: sha256(Buffer.from(compact(`${helper.header}{${helper.body}}`), "utf8")),
      };
    });
    return {
      id: item.id,
      ruleId: item.ruleId,
      path: item.path,
      signature: item.signature,
      predicate: item.predicate,
      sourceSha256: sha256(readBytes(item.path)),
      bodySha256: sha256(Buffer.from(compact(fn.body), "utf8")),
      declarationSha256: sha256(Buffer.from(compact(`${fn.header}{${fn.body}}`), "utf8")),
      helperBindings,
    };
  });
}

function sourcePolicyPredicateBindingRows(sourceReader = readText) {
  return PUBLIC_SOURCE_POLICY_SPECS.map((item) => {
    const source = sourceReader(item.path);
    const fn = functionBySignature(source, item.signature, item.path);
    const helperBindings = item.helperFunctions.map(([helperPath, signature]) => {
      const helperSource = sourceReader(helperPath);
      const helper = functionBySignature(helperSource, signature, helperPath);
      return {path: helperPath, signature, sha256: sha256(Buffer.from(helperSource, "utf8")),
        bodySha256: sha256(Buffer.from(compact(helper.body), "utf8")),
        declarationSha256: sha256(Buffer.from(compact(`${helper.header}{${helper.body}}`), "utf8"))};
    });
    return {id: item.id, ruleId: item.ruleId, path: item.path, signature: item.signature,
      predicate: item.predicate, sourceSha256: sha256(Buffer.from(source, "utf8")),
      bodySha256: sha256(Buffer.from(compact(fn.body), "utf8")),
      declarationSha256: sha256(Buffer.from(compact(`${fn.header}{${fn.body}}`), "utf8")), helperBindings};
  });
}

function verifyReviewedSourcePredicates(exceptions, manifest) {
  const records = exceptions.reviewedSourcePredicates;
  if (!Array.isArray(records) || records.length !== PUBLIC_SOURCE_PREDICATE_SPECS.length) {
    fail("public source predicate inventory must contain exactly the reviewed record set");
  }
  sameSet(records.map((item) => item.id), PUBLIC_SOURCE_PREDICATE_SPECS.map((item) => item.id),
    "public source predicate identifiers");
  const currentBindings = sourcePredicateBindingRows();
  const inputMap = new Map(manifest.inputs.map((item) => [item.path, item]));
  const nodeMap = new Map(manifest.importGraph.nodes.map((item) => [item.path, item]));
  for (const expected of PUBLIC_SOURCE_PREDICATE_SPECS) {
    const record = records.find((item) => item.id === expected.id);
    const current = currentBindings.find((item) => item.id === expected.id);
    if (record.ruleId !== expected.ruleId || record.path !== expected.path ||
        record.signature !== expected.signature || record.predicate !== expected.predicate ||
        record.sourceSha256 !== current.sourceSha256 || record.bodySha256 !== current.bodySha256 ||
        record.declarationSha256 !== current.declarationSha256) {
      fail(`public source predicate binding differs from current source: ${expected.id}`);
    }
    const actualHelpers = Array.isArray(record.helperBindings) ? record.helperBindings : [];
    if (JSON.stringify(actualHelpers) !== JSON.stringify(current.helperBindings)) {
      fail(`public source predicate helper bindings differ from current source: ${expected.id}`);
    }
    const sourceInput = inputMap.get(expected.path);
    if (!sourceInput || sourceInput.sha256 !== current.sourceSha256) {
      fail(`public source predicate path is not bound by the source manifest: ${expected.id}`);
    }
    for (const helper of actualHelpers) {
      const input = inputMap.get(helper.path);
      const node = nodeMap.get(helper.path);
      if ((!input && !node) || (input && input.sha256 !== helper.sha256) ||
          (node && node.sha256 !== helper.sha256)) {
        fail(`public source predicate helper is not bound by the source manifest: ${expected.id}`);
      }
    }
    if (!record.rationale || /private|packet|checkpoint|workspace|dec-/i.test(record.rationale)) {
      fail(`public source predicate rationale is missing or contains private provenance: ${expected.id}`);
    }
    if (expected.id === "allowlist-renewable-beneficiary" && /daily[- ]capped/i.test(record.rationale)) {
      fail("beneficiary caller recognition must not claim daily-cap behavior");
    }
    if (/private|packet|checkpoint|workspace|dec-/i.test(JSON.stringify(record))) {
      fail(`public source predicate metadata contains private provenance: ${expected.id}`);
    }
  }
  verifyReviewedSourcePredicateSemantics();
}

function verifyReviewedSourcePolicies(exceptions, manifest) {
  const records = exceptions.reviewedSourcePolicies;
  if (!Array.isArray(records) || records.length !== PUBLIC_SOURCE_POLICY_SPECS.length) {
    fail("public source-policy inventory must contain exactly its reviewed non-Semgrep policy set");
  }
  sameSet(records.map((item) => item.id), PUBLIC_SOURCE_POLICY_SPECS.map((item) => item.id),
    "public source-policy identifiers");
  const bindings = sourcePolicyPredicateBindingRows();
  const inputMap = new Map(manifest.inputs.map((item) => [item.path, item]));
  const nodeMap = new Map(manifest.importGraph.nodes.map((item) => [item.path, item]));
  for (const expected of PUBLIC_SOURCE_POLICY_SPECS) {
    const record = records.find((item) => item.id === expected.id);
    const current = bindings.find((item) => item.id === expected.id);
    if (record.ruleId !== expected.ruleId || record.path !== expected.path ||
        record.signature !== expected.signature || record.predicate !== expected.predicate ||
        record.sourceSha256 !== current.sourceSha256 || record.bodySha256 !== current.bodySha256 ||
        record.declarationSha256 !== current.declarationSha256 ||
        JSON.stringify(record.helperBindings) !== JSON.stringify(current.helperBindings)) {
      fail(`public source-policy binding differs from current source: ${expected.id}`);
    }
    const sourceInput = inputMap.get(expected.path);
    if (!sourceInput || sourceInput.sha256 !== current.sourceSha256) {
      fail(`public source-policy path is not bound by the source manifest: ${expected.id}`);
    }
    for (const helper of current.helperBindings) {
      const input = inputMap.get(helper.path);
      const node = nodeMap.get(helper.path);
      if ((!input && !node) || (input && input.sha256 !== helper.sha256) || (node && node.sha256 !== helper.sha256)) {
        fail(`public source-policy helper is not bound by the source manifest: ${expected.id}`);
      }
    }
    if (!record.rationale || /private|packet|checkpoint|workspace|dec-/i.test(record.rationale) ||
        /private|packet|checkpoint|workspace|dec-/i.test(JSON.stringify(record))) {
      fail(`public source-policy rationale is missing or contains private provenance: ${expected.id}`);
    }
  }
  verifyExistingAtRiskPolicySemantics();
}

function verifyReviewedSourcePredicateControls() {
  const semantic = verifyReviewedSourcePredicateSemantics();
  const negatives = [];
  const rejectMutations = (name, changes) => {
    const overrides = new Map();
    for (const [filePath, before, after] of changes) {
      const initial = overrides.get(filePath) || readText(filePath);
      overrides.set(filePath, replaceExactlyOnce(initial, before, after, name));
    }
    negatives.push(refuse(name, () => verifyReviewedSourcePredicateSemantics((pathValue) =>
      overrides.get(pathValue) || readText(pathValue))));
  };
  const allowlistEmptySlot = "if (_voteEligibilityObserver == address(0)) return;";
  const blocklistEmptySlot = "if (_voteEligibilityObserver == address(0)) return;";
  rejectMutations("allowlist-register-without-code-length", [["src/Allowlist.sol",
    "msg.sender.code.length == 0", "msg.sender.code.length != 0"]]);
  rejectMutations("allowlist-register-without-system-account", [["src/Allowlist.sol",
    "!_systemAccounts[msg.sender]", "_systemAccounts[msg.sender]"]]);
  rejectMutations("allowlist-register-without-single-slot-check", [["src/Allowlist.sol",
    "previous != address(0) && previous != msg.sender",
    "previous != address(0) && previous == msg.sender"]]);
  rejectMutations("allowlist-unregister-without-empty-slot-noop", [["src/Allowlist.sol",
    allowlistEmptySlot, ""]]);
  rejectMutations("allowlist-unregister-without-current-pointer", [["src/Allowlist.sol",
    "msg.sender != _voteEligibilityObserver", "msg.sender != address(0)"]]);
  rejectMutations("allowlist-transfer-without-eligible-owner", [["src/Allowlist.sol",
    "function transferOwnership(address newOwner) public override onlyEligibleOwner",
    "function transferOwnership(address newOwner) public override"]]);
  rejectMutations("allowlist-transfer-without-current-eligibility", [["src/Allowlist.sol",
    "msg.sender != owner() || !_isAllowed(msg.sender)", "msg.sender != owner() || true"]]);
  rejectMutations("allowlist-accept-without-current-eligibility", [["src/Allowlist.sol",
    "if (!_isAllowed(msg.sender)) revert IAllowlist.CallerNotAllowed(msg.sender);\n        super.acceptOwnership();",
    "super.acceptOwnership();"]]);
  rejectMutations("parent-accept-without-pending-owner-check", [[
    "lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol",
    "if (pendingOwner() != sender) {", "if (pendingOwner() == sender) {"]]);
  rejectMutations("blocklist-unregister-without-empty-slot-noop", [["src/Blocklist.sol",
    blocklistEmptySlot, ""]]);
  rejectMutations("blocklist-unregister-without-current-pointer", [["src/Blocklist.sol",
    "msg.sender != _voteEligibilityObserver", "msg.sender != address(0)"]]);
  rejectMutations("token-sync-without-current-observer-pointers", [["src/ForageToken.sol",
    "msg.sender != allowlist() && msg.sender != _blocklist",
    "msg.sender != allowlist() || msg.sender != _blocklist"]]);
  rejectMutations("token-sync-without-current-blocklist-pointer", [["src/ForageToken.sol",
    "msg.sender != _blocklist", "msg.sender != address(0)"]]);
  rejectMutations("vesting-beneficiary-approval-without-owner-eligibility", [["src/Allowlist.sol",
    "function approveVestingBeneficiary(address account) external onlyEligibleOwner",
    "function approveVestingBeneficiary(address account) external"]]);
  rejectMutations("vesting-beneficiary-approval-without-finite-term", [["src/Allowlist.sol",
    "uint64 until = uint64(block.timestamp + APPROVAL_TERM_LIMIT);",
    "uint64 until = type(uint64).max;"]]);
  rejectMutations("deploy-beneficiary-does-not-use-renewable-api", [["script/Deploy.s.sol",
    "registry.approveVestingBeneficiary(cfg.beneficiary);",
    "registry.approveOperator(cfg.beneficiary);"]]);
  const controls = {
    scope: "copied public source text only; no Semgrep, compiler, contract test, or execution",
    positiveCount: semantic.predicates.length,
    negativeCount: negatives.length,
    positives: semantic.predicates,
    negatives,
    sourcePolicy: semantic.sourcePolicy,
  };
  return controls;
}

function verifyReviewedSourcePolicyControls() {
  const dailyCap = dailyCapPolicyStatus();
  if (dailyCap.status !== "REVIEW_REQUIRED") fail("the zero-cap source repair must remain review-required");
  const positives = [verifyExistingAtRiskPolicySemantics(), dailyCap];
  const source = readText("src/atRISKUSD.sol");
  const mutated = replaceExactlyOnce(source, "if (!proposedAllowlist.isSystemAccount(address(this))) {",
    "if (proposedAllowlist.isSystemAccount(address(this))) {", "atRISKUSD system-membership control");
  const allowlist = readText("src/Allowlist.sol");
  const missingZeroCapGuard = replaceExactlyOnce(allowlist,
    "if (_approvalsPerDayCap == 0) revert DailyCapReached();", "", "Allowlist zero-cap control");
  const negatives = [
    refuse("atRisk-replacement-without-system-membership", () =>
      verifyExistingAtRiskPolicySemantics((pathValue) => pathValue === "src/atRISKUSD.sol" ? mutated : readText(pathValue))),
    refuse("allowlist-zero-cap-guard-removal", () => {
      const status = dailyCapPolicyStatus((pathValue) =>
        pathValue === "src/Allowlist.sol" ? missingZeroCapGuard : readText(pathValue));
      if (status.status === "RED_UNVERIFIED") fail("removed zero-cap guard restores the red source classification");
      if (status.status !== "REVIEW_REQUIRED") fail("zero-cap guard removal did not reach the expected policy predicate");
    }),
  ];
  return {scope: "copied public source text only; no Semgrep, compiler, contract test, or execution",
    positiveCount: positives.length, negativeCount: negatives.length, positives, negatives};
}

function skipWhitespace(source, start) {
  let index = start;
  while (index < source.length && /\s/.test(source[index])) index += 1;
  return index;
}

function topLevelStatementEnd(source, start) {
  let parentheses = 0;
  let brackets = 0;
  let braces = 0;
  for (let index = start; index < source.length; index += 1) {
    const current = source[index];
    if (current === "(") parentheses += 1;
    else if (current === ")") parentheses -= 1;
    else if (current === "[") brackets += 1;
    else if (current === "]") brackets -= 1;
    else if (current === "{") braces += 1;
    else if (current === "}") {
      braces -= 1;
      if (braces < 0) fail("unbalanced top-level Solidity statement");
      if (braces === 0 && parentheses === 0 && brackets === 0) {
        const next = skipWhitespace(source, index + 1);
        if (/^(?:else|catch)\b/.test(source.slice(next))) continue;
        return index + 1;
      }
    } else if (current === ";" && parentheses === 0 && brackets === 0 && braces === 0) {
      const next = skipWhitespace(source, index + 1);
      if (/^(?:else|catch)\b/.test(source.slice(next))) continue;
      return index + 1;
    }
  }
  fail("unrecognized or unterminated top-level Solidity statement");
}

function topLevelStatements(body) {
  const source = maskSolidity(body);
  const statements = [];
  let cursor = skipWhitespace(source, 0);
  while (cursor < source.length) {
    const end = topLevelStatementEnd(source, cursor);
    const text = source.slice(cursor, end).trim();
    const kind = text.match(/^([A-Za-z_$][\w$]*)/)?.[1] || "block";
    statements.push({kind, text});
    cursor = skipWhitespace(source, end);
  }
  return statements;
}

function sourceStatementRecords(source, signature, filePath) {
  const fn = functionBySignature(source, signature, filePath);
  return topLevelStatements(fn.body).map((item) => ({kind: item.kind, text: item.text, code: compact(item.text)}));
}

function bracedStatementBody(statementText, expectedHeader, label) {
  const source = maskSolidity(statementText);
  const open = source.indexOf("{");
  const close = open < 0 ? -1 : matchingDelimiter(source, open, "{", "}");
  if (open < 0 || close !== source.length - 1 || compact(source.slice(0, open)) !== expectedHeader) {
    fail(`${label} has an unsupported parsed statement shape`);
  }
  return source.slice(open + 1, close);
}

function splitCallArguments(source) {
  const parts = [];
  let start = 0;
  let parentheses = 0;
  let brackets = 0;
  let braces = 0;
  for (let index = 0; index < source.length; index += 1) {
    const current = source[index];
    if (current === "(") parentheses += 1;
    else if (current === ")") parentheses -= 1;
    else if (current === "[") brackets += 1;
    else if (current === "]") brackets -= 1;
    else if (current === "{") braces += 1;
    else if (current === "}") braces -= 1;
    else if (current === "," && parentheses === 0 && brackets === 0 && braces === 0) {
      parts.push(source.slice(start, index).trim());
      start = index + 1;
    }
  }
  const last = source.slice(start).trim();
  if (last) parts.push(last);
  return parts.map(compact);
}

function methodArguments(source, methodName) {
  const code = maskSolidity(source);
  const calls = [];
  const pattern = new RegExp(`\\b${methodName}\\s*\\(`, "g");
  for (const match of code.matchAll(pattern)) {
    const open = code.indexOf("(", match.index);
    const close = matchingDelimiter(code, open, "(", ")");
    if (close < 0) fail(`unclosed ${methodName} call`);
    calls.push(splitCallArguments(code.slice(open + 1, close)));
  }
  return calls;
}

function assertRoleRevocation(source, signature, account, label) {
  const fn = functionBySignature(source, signature, label);
  const statements = topLevelStatements(fn.body).map((item) => compact(item.text));
  const expected = [
    "TimelockControllertimelock=TimelockController(payable(deployedTimelock));",
    `timelock.revokeRole(PROPOSER_ROLE,${account});`,
    `timelock.revokeRole(CANCELLER_ROLE,${account});`,
    `timelock.revokeRole(EXECUTOR_ROLE,${account});`,
    `timelock.revokeRole(bytes32(0),${account});`,
  ];
  if (JSON.stringify(statements) !== JSON.stringify(expected)) {
    fail(`${label} does not revoke the broadcaster's DEFAULT_ADMIN_ROLE last`);
  }
}

function assertDeploymentAdminHandoff(deploySource, mainnetSource, manifest) {
  const deployCode = maskSolidity(deploySource);
  const run = functionBySignature(deploySource, "run()", "script/Deploy.s.sol");
  const runCode = compact(run.body);
  if (!runCode.includes("if(deployerKey==0){vm.startBroadcast();}else{vm.startBroadcast(deployerKey);}")) {
    fail("public broadcast entrypoint no longer has both configured signer branches");
  }
  if ([...deployCode.matchAll(/\bvm\s*\.\s*startBroadcast\s*\(/g)].length !== 2) {
    fail("public Deploy.s.sol broadcast call inventory changed");
  }
  const runStatements = topLevelStatements(run.body).map((item) => compact(item.text));
  const suffix = [
    "_deployWithConfig(cfg,deployer);",
    "_revokeDeployerOperationalRoles(deployer);",
    "vm.stopBroadcast();",
  ];
  if (JSON.stringify(runStatements.slice(-suffix.length)) !== JSON.stringify(suffix)) {
    fail("public broadcaster does not complete setup and revoke authority before stopBroadcast");
  }
  const configured = functionBySignature(deploySource,
    "runWithConfig(address,address,address,address,address,address,address,address)", "script/Deploy.s.sol");
  if (/\bvm\s*\.\s*(?:startBroadcast|stopBroadcast)\s*\(/.test(maskSolidity(configured.body))) {
    fail("public non-broadcast runWithConfig entrypoint changed role");
  }
  const constructor = functionBySignature(deploySource, "_deployTimelock(address)", "script/Deploy.s.sol");
  const constructorCode = compact(constructor.body);
  if (!constructorCode.includes("proposers[0]=deployer;") || !constructorCode.includes("executors[0]=deployer;") ||
      !constructorCode.includes("newTimelockController(_minDelay(),proposers,executors,deployer)")) {
    fail("public Timelock bootstrap admin must remain the deployer until setup is complete");
  }
  assertRoleRevocation(deploySource, "_revokeDeployerOperationalRoles(address)", "deployer", "public Deploy");
  const mainnetCode = maskSolidity(mainnetSource);
  if (/\bvm\s*\.\s*(?:startBroadcast|stopBroadcast)\s*\(/.test(mainnetCode)) {
    fail("public mainnet placeholder variant must remain no-broadcast");
  }
  const mainnetRun = functionBySignature(mainnetSource, "run()", "script/DeployMainnet.s.sol");
  if (compact(mainnetRun.body) !== "runDryRunWithPlaceholders();") {
    fail("public mainnet entrypoint no longer selects its placeholder dry-run");
  }
  for (const signature of [
    "runWithConfig(address,address,address,address,address,address,address,address)",
    "runDryRunWithPlaceholders()",
  ]) {
    const entrypoint = functionBySignature(mainnetSource, signature, "script/DeployMainnet.s.sol");
    const body = compact(entrypoint.body);
    if (!body.includes("deployer:address(this)") || !body.includes("_deployWithConfig(") ||
        !body.includes("_handoffToProductionGovernance();")) {
      fail(`public no-broadcast entrypoint lost setup or governance handoff ${signature}`);
    }
  }
  const handoff = functionBySignature(mainnetSource, "_handoffToProductionGovernance()", "script/DeployMainnet.s.sol");
  if (topLevelStatements(handoff.body).map((item) => compact(item.text)).at(-1) !== "_revokeDeployerTimelockRoles();") {
    fail("public mainnet governance handoff does not end with its existing Timelock role cleanup");
  }
  assertRoleRevocation(mainnetSource, "_revokeDeployerTimelockRoles()", "address(this)", "public DeployMainnet");
  const pinnedOpenZeppelin = manifest.dependencies?.find((item) => item.path === "lib/openzeppelin-contracts-upgradeable");
  if (!pinnedOpenZeppelin || pinnedOpenZeppelin.commit !== OPENZEPPELIN_ADMIN_PIN) {
    fail("public Timelock self-admin boundary is not bound to its unchanged OpenZeppelin Gitlink");
  }
  return {constructorAdminArgument: "deployer", deployerOperationalRolesRevoked: true,
    defaultAdminRevokedLast: true, mainnetPlaceholderNoBroadcast: true,
    mainnetDefaultAdminRevokeRetained: true, selfAdminDependencyPin: pinnedOpenZeppelin.commit,
    selfAdminSourceMaterialized: false};
}

function verifyTopLevelProposerGuard(source, signature, label) {
  const fn = functionBySignature(source, signature, label);
  const statements = topLevelStatements(fn.body);
  const normalized = statements.map((item) => compact(item.text));
  const guardPositions = normalized.flatMap((item, index) => item === DISJOINTNESS_GUARD ? [index] : []);
  const grantPositions = normalized.flatMap((item, index) => item === DISJOINTNESS_GRANT ? [index] : []);
  const prelude = JSON.stringify(normalized.slice(0, 2));
  const acceptedPrelude = [
    JSON.stringify(["_wireModules();", "_wireSharedAllowlist(cfg);"]),
    JSON.stringify(["_wireSharedAllowlist(cfg);", "_wireModules();"]),
  ].includes(prelude);
  if (guardPositions.length !== 1 || grantPositions.length !== 1 ||
      statements[guardPositions[0]].kind !== "if" || grantPositions[0] !== guardPositions[0] + 1 ||
       guardPositions[0] !== 2 || !acceptedPrelude) {
    fail("public proposer grant lacks a dominating same-address GuardianModule membership refusal");
  }
  const grants = methodArguments(source, "grantRole");
  const expectedGrants = [
    ["PROPOSER_ROLE", "deployedForageGovernor"],
    ["CANCELLER_ROLE", "deployedForageGovernor"],
    ["EXECUTOR_ROLE", "deployedForageGovernor"],
  ];
  if (JSON.stringify(grants) !== JSON.stringify(expectedGrants)) {
    fail("public deployment grants an extra or aliased proposer/admin role");
  }
  if (/\bdeployed(?:ForageGovernor|GuardianModule)\s*=/.test(maskSolidity(fn.body))) {
    fail("public guardian or Governor address is rebound inside the guard/grant function");
  }
  const guardCount = compact(source).split(DISJOINTNESS_GUARD).length - 1;
  if (guardCount !== 1) fail("public deployment has a duplicate or ambiguous genesis membership refusal");
  return {function: signature, guardStatement: guardPositions[0], grantStatement: grantPositions[0],
    guardAndGrantAdjacent: true, topLevel: true, uniqueProposerGrant: true};
}

function parseRuleBlocks(config) {
  const lines = config.split(/\r?\n/);
  const starts = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index].match(/^\s{2}- id:\s*([A-Za-z0-9_-]+)\s*$/);
    if (match) starts.push({index, id: match[1]});
  }
  return starts.map((item, index) => {
    const end = starts[index + 1]?.index ?? lines.length;
    const block = lines.slice(item.index, end).join("\n");
    return {
      id: item.id,
      includes: yamlList(block, "include"),
      excludes: yamlList(block, "exclude"),
      block,
    };
  });
}

function yamlList(block, key) {
  const lines = block.split(/\r?\n/);
  const output = [];
  let active = false;
  for (const line of lines) {
    if (new RegExp(`^\\s{6}${key}:\\s*$`).test(line)) {
      active = true;
      continue;
    }
    if (!active) continue;
    const item = line.match(/^\s+-\s*["']?([^"']+?)["']?\s*$/);
    if (item) {
      output.push(item[1].trim());
      continue;
    }
    if (!line.trim()) continue;
    break;
  }
  return output;
}

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function globRegex(glob) {
  if (glob.startsWith("/")) glob = glob.slice(1);
  let output = "^";
  for (let index = 0; index < glob.length;) {
    if (glob.startsWith("**/", index)) {
      output += "(?:.*/)?";
      index += 3;
    } else if (glob.startsWith("**", index)) {
      output += ".*";
      index += 2;
    } else if (glob[index] === "*") {
      output += "[^/]*";
      index += 1;
    } else if (glob[index] === "?") {
      output += "[^/]";
      index += 1;
    } else {
      output += escapeRegex(glob[index]);
      index += 1;
    }
  }
  return new RegExp(`${output}$`);
}

function targetsForRule(rule, sourcePaths) {
  if (!rule.includes.length) fail(`rule ${rule.id} has no explicit public path include`);
  if (rule.includes.some((item) => !PUBLIC_INCLUDE_GLOBS.has(item))) {
    fail(`rule ${rule.id} has a path glob outside the public production input set`);
  }
  const includes = rule.includes.map(globRegex);
  const excludes = rule.excludes.map(globRegex);
  return sourcePaths.filter((item) => includes.some((regex) => regex.test(item)) && !excludes.some((regex) => regex.test(item)));
}

function loadInputs() {
  const manifest = readJson(SOURCE_MANIFEST_PATH);
  const exceptions = readJson(EXCEPTIONS_PATH);
  if (manifest.schema !== "openforage.public-review-source-manifest.v1") fail("unsupported public source manifest schema");
  if (exceptions.schema !== "openforage.public-semgrep-exceptions.v1") fail("unsupported public exception manifest schema");
  verifyManifestFiles(manifest);
  verifyPublicInventory(manifest);
  verifyDependencies(manifest);
  const dependencyStatus = verifyImportGraph(manifest);
  const configs = new Map();
  const graphPaths = manifest.importGraph.nodes.map((item) => item.path);
  for (const configPath of CONFIGS) {
    const bytes = readBytes(configPath);
    const rules = parseRuleBlocks(bytes.toString("utf8"));
    const expected = manifest.ruleInventory.find((item) => item.config === configPath);
    if (!expected) fail(`manifest omits Semgrep config ${configPath}`);
    if (sha256(bytes) !== expected.sha256) fail(`Semgrep config bytes changed ${configPath}`);
    sameSet(rules.map((item) => item.id), expected.ruleIds, `rule inventory for ${configPath}`);
    if (JSON.stringify(rules.map(({id, includes, excludes}) => ({id, includes, excludes}))) !==
        JSON.stringify(expected.rules.map(({id, includes, excludes}) => ({id, includes, excludes})))) {
      fail(`rule path policy changed ${configPath}`);
    }
    for (const rule of rules) {
      const manifestRule = expected.rules.find((item) => item.id === rule.id);
      if (!manifestRule) fail(`manifest omits rule target paths for ${rule.id}`);
      rule.targetPaths = targetsForRule(rule, graphPaths);
      sameSet(rule.targetPaths, manifestRule.targetPaths, `expanded public target set for ${configPath} ${rule.id}`);
    }
    const scanInputs = sorted(new Set(rules.flatMap((rule) => rule.targetPaths)));
    sameSet(scanInputs, expected.scanInputs, `public Semgrep input set for ${configPath}`);
    configs.set(configPath, {bytes, rules, expected, scanInputs});
  }
  verifyMakefile(configs);
  verifyExceptions(exceptions, manifest, configs);
  return {manifest, exceptions, configs, dependencyStatus};
}

function verifyPublicInventory(manifest) {
  const sourceRoots = collectFiles("src", (relativePath) => relativePath.endsWith(".sol"));
  sameSet(sourceRoots, manifest.sourceRoots, "dynamic production source-root inventory");
  const scriptFiles = collectFiles("script");
  sameSet(scriptFiles, manifest.publicScriptFiles, "public deployment/checker file inventory");
  const deploymentSources = manifest.deploymentInputs;
  if (!Array.isArray(deploymentSources) || deploymentSources.length < 4) fail("public deployment-source inventory is incomplete");
  for (const required of ["script/Deploy.s.sol", "script/DeployMainnet.s.sol", "script/RegisterAllowlist.s.sol", "script/interfaces/IAllowlistSettable.sol"]) {
    if (!deploymentSources.includes(required)) fail(`public deployment input is missing ${required}`);
  }
  if (sourceRoots.length !== 30) fail(`current production Solidity root count changed: expected 30, found ${sourceRoots.length}`);
  const requiredOutputs = new Set(REQUIRED_ATRISK_EXITS);
  const manifestExits = manifest.protectedAtRiskExitGates?.map((item) => item.signature) || [];
  sameSet(manifestExits, [...requiredOutputs], "protected atRISKUSD exit gate inventory");
}

function verifyDependencies(manifest) {
  const expected = [
    {path: "lib/chainlink-ccip", url: "https://github.com/smartcontractkit/chainlink-ccip.git"},
    {path: "lib/openzeppelin-contracts-upgradeable", url: "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable"},
  ];
  if (!Array.isArray(manifest.dependencies) || manifest.dependencies.length !== expected.length) fail("public dependency inventory must contain exactly two Git links");
  for (const item of expected) {
    const found = manifest.dependencies.find((candidate) => candidate.path === item.path && candidate.url === item.url);
    if (!found || !/^[0-9a-f]{40}$/.test(found.commit)) fail(`public dependency pin is missing or malformed ${item.path}`);
  }
  const gitmodules = fs.readFileSync(path.resolve(CONTRACT_ROOT, "..", ".gitmodules"), "utf8");
  for (const item of expected) {
    const publicPath = `openforage_smart_contracts/${item.path}`;
    if (!gitmodules.includes(`path = ${publicPath}`) || !gitmodules.includes(item.url)) fail(`public .gitmodules entry changed ${publicPath}`);
  }
}

function parseRemappings() {
  return readText("remappings.txt").split(/\r?\n/).filter(Boolean).map((line) => {
    const split = line.indexOf("=");
    if (split < 1) fail(`malformed public remapping ${line}`);
    return {prefix: line.slice(0, split), target: line.slice(split + 1)};
  }).sort((left, right) => right.prefix.length - left.prefix.length);
}

function parseImports(filePath, source) {
  const imports = [];
  const pattern = /\bimport\s+(?:[^;]*?\s+from\s+)?["']([^"']+)["']\s*;/gs;
  for (const match of maskSolidityComments(source).matchAll(pattern)) imports.push({source: filePath, specifier: match[1]});
  return imports;
}

function maskSolidityComments(source) {
  const chars = source.split("");
  let state = "code";
  let quote = "";
  for (let index = 0; index < chars.length; index += 1) {
    const current = chars[index];
    const next = chars[index + 1];
    if (state === "line") {
      if (current === "\n") state = "code";
      else chars[index] = " ";
    } else if (state === "block") {
      if (current === "*" && next === "/") {
        chars[index] = chars[index + 1] = " ";
        index += 1;
        state = "code";
      } else if (current !== "\n") chars[index] = " ";
    } else if (state === "string") {
      if (current === "\\") index += 1;
      else if (current === quote) state = "code";
    } else if (current === "/" && next === "/") {
      chars[index] = chars[index + 1] = " ";
      index += 1;
      state = "line";
    } else if (current === "/" && next === "*") {
      chars[index] = chars[index + 1] = " ";
      index += 1;
      state = "block";
    } else if (current === "\"" || current === "'") {
      quote = current;
      state = "string";
    }
  }
  return chars.join("");
}

function buildImportGraph(manifest) {
  const remappings = parseRemappings();
  const firstParty = new Set([...manifest.sourceRoots, ...manifest.deploymentInputs]);
  const dependencyPaths = new Set(manifest.dependencies.map((item) => item.path));
  const edges = [];
  for (const importer of [...firstParty].sort()) {
    if (!importer.endsWith(".sol")) continue;
    const source = readText(importer);
    for (const item of parseImports(importer, source)) {
      if (item.specifier.startsWith("./") || item.specifier.startsWith("../")) {
        const target = path.posix.normalize(path.posix.join(path.posix.dirname(importer), item.specifier));
        if (!firstParty.has(target)) fail(`relative Solidity import is outside the public source/deployment inventory: ${importer} -> ${target}`);
        edges.push({source: importer, specifier: item.specifier, target, kind: "first-party"});
        continue;
      }
      const remapping = remappings.find((entry) => item.specifier.startsWith(entry.prefix));
      if (!remapping) fail(`unresolved public Solidity import ${importer} -> ${item.specifier}`);
      const mapped = path.posix.normalize(path.posix.join(remapping.target, item.specifier.slice(remapping.prefix.length)));
      const dependency = [...dependencyPaths].find((dep) => mapped === dep || mapped.startsWith(`${dep}/`));
      if (!dependency) fail(`external import does not resolve to a public Git link ${importer} -> ${item.specifier}`);
      edges.push({source: importer, specifier: item.specifier, target: mapped, kind: "pinned-dependency", dependency});
    }
  }
  return edges.sort((left, right) => {
    const a = `${left.source}:${left.specifier}`;
    const b = `${right.source}:${right.specifier}`;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

function verifyImportGraph(manifest) {
  const actual = buildImportGraph(manifest);
  if (JSON.stringify(actual) !== JSON.stringify(manifest.imports)) {
    const limit = Math.max(actual.length, manifest.imports.length);
    const index = Array.from({length: limit}, (_, item) => item).find((item) =>
      JSON.stringify(actual[item]) !== JSON.stringify(manifest.imports[item]));
    fail(`public first-party import graph changed at edge ${index}: expected ${JSON.stringify(manifest.imports[index])}, found ${JSON.stringify(actual[index])}`);
  }
  const graph = manifest.importGraph;
  if (!graph || !Array.isArray(graph.nodes) || !Array.isArray(graph.edges) || !Array.isArray(graph.dependencyInputs)) {
    fail("full pinned public import graph is missing");
  }
  if (graph.unresolvedImports?.length) fail("public import graph contains unresolved imports");
  if (graph.nodeCount !== graph.nodes.length || graph.edgeCount !== graph.edges.length ||
      graph.dependencyNodeCount !== graph.dependencyInputs.length) fail("public import graph counts are inconsistent");
  const firstPartyPaths = sorted([...manifest.sourceRoots, ...manifest.deploymentInputs]);
  sameSet(graph.rootPaths, firstPartyPaths, "full graph root inventory");
  const nodes = new Map(graph.nodes.map((item) => [item.path, item]));
  if (nodes.size !== graph.nodes.length) fail("full import graph repeats a node path");
  const localInputs = new Map(manifest.inputs.map((item) => [item.path, item]));
  const dependencyPins = new Map(manifest.dependencies.map((item) => [item.path, item.commit]));
  const missingDependencies = [];
  for (const node of graph.nodes) {
    if (!safeRelativePath(node.path) || !/^[0-9a-f]{64}$/.test(node.sha256) || !Number.isInteger(node.bytes)) {
      fail(`full import graph node is malformed: ${node.path}`);
    }
    if (node.owner === "dependency") {
      if (!dependencyPins.has(node.dependencyPath) || node.dependencyPin !== dependencyPins.get(node.dependencyPath)) {
        fail(`dependency node is not bound to a public Git-link pin: ${node.path}`);
      }
      const absolute = projectFile(node.path);
      if (!fs.existsSync(absolute)) {
        missingDependencies.push(node.path);
      } else {
        const stat = fs.lstatSync(absolute);
        const bytes = fs.readFileSync(absolute);
        const mode = `100${(stat.mode & 0o777).toString(8).padStart(3, "0")}`;
        if (!stat.isFile() || stat.isSymbolicLink() || bytes.length !== node.bytes || sha256(bytes) !== node.sha256 || mode !== node.mode) {
          fail(`materialized dependency differs from the public import manifest: ${node.path}`);
        }
      }
    } else {
      const input = localInputs.get(node.path);
      if (!input || input.sha256 !== node.sha256 || input.bytes !== node.bytes || input.mode !== node.mode) {
        fail(`first-party import node differs from the public source manifest: ${node.path}`);
      }
    }
  }
  const edgeKeys = new Set();
  for (const edge of graph.edges) {
    if (!nodes.has(edge.from) || !nodes.has(edge.to) || !edge.import) fail(`public import edge is malformed: ${edge.from} -> ${edge.to}`);
    const key = `${edge.from}\0${edge.import}\0${edge.to}`;
    if (edgeKeys.has(key)) fail(`public import edge repeats: ${edge.from} -> ${edge.to}`);
    edgeKeys.add(key);
  }
  const dependencyNodePaths = graph.nodes.filter((item) => item.owner === "dependency").map((item) => item.path);
  sameSet(dependencyNodePaths, graph.dependencyInputs.map((item) => item.path), "pinned dependency file inventory");
  const firstPartySet = new Set(firstPartyPaths);
  const graphFirstPartyEdges = graph.edges.filter((item) => firstPartySet.has(item.from)).map((item) => {
    const target = nodes.get(item.to);
    return {
      source: item.from,
      specifier: item.import,
      target: item.to,
      kind: target.owner === "dependency" ? "pinned-dependency" : "first-party",
      ...(target.owner === "dependency" ? {dependency: target.dependencyPath} : {}),
    };
  }).sort((left, right) => {
    const a = `${left.source}:${left.specifier}`;
    const b = `${right.source}:${right.specifier}`;
    return a < b ? -1 : a > b ? 1 : 0;
  });
  if (JSON.stringify(graphFirstPartyEdges) !== JSON.stringify(actual)) fail("full graph first-party edges differ from the live candidate import walk");
  if (manifest.sourceRoots.length !== 30 || graph.firstPartyNodeCount !== 34 || graph.dependencyNodeCount !== 91 || graph.nodeCount !== 125 || graph.edgeCount !== 397) {
    fail("measured public source/import/dependency inventory changed; remeasure the complete closure");
  }
  return {expected: graph.dependencyNodeCount, materialized: graph.dependencyNodeCount - missingDependencies.length, missing: missingDependencies};
}

function occurrenceCount(source, value) {
  return source.split(value).length - 1;
}

function verifyAuditDispatch(source) {
  for (const name of AUDIT_SINGLETON_FUNCTIONS) {
    const declaration = new RegExp(`^function\\s+${name}\\s*\\(`, "gm");
    if ([...source.matchAll(declaration)].length !== 1) fail(`audit helper declaration is not unique: ${name}`);
  }
  for (const name of ["auditCapture", "auditCaptureStage", "auditRunDirectory", "auditStageInputs",
    "auditOutputRecords", "auditWriteIndex"]) {
    if (new RegExp(`^function\\s+${name}\\s*\\(`, "m").test(source)) {
      fail(`obsolete audit helper remains active: ${name}`);
    }
  }
  const captureRoute = ["args[0]", " === ", '"--capture-audit"'].join("");
  const reuseRoute = ["args[0]", " === ", '"--reuse-audit"'].join("");
  const captureCall = ["captureAudit", "(args[1]);"].join("");
  const reuseCall = ["auditValidateReuse", "(args[1]);"].join("");
  if (occurrenceCount(source, captureRoute) !== 1 || occurrenceCount(source, captureCall) !== 1 ||
      occurrenceCount(source, reuseRoute) !== 1 || occurrenceCount(source, reuseCall) !== 1) {
    fail("audit CLI routes must select the single capture and reuse implementations");
  }
  if (/\bauditCapture\s*\(/.test(source) || /\bauditCaptureStage\s*\(/.test(source)) {
    fail("obsolete capture implementation remains reachable from the checker");
  }
  return {singletonHelpers: AUDIT_SINGLETON_FUNCTIONS.length, captureRoute: "captureAudit",
    reuseRoute: "auditValidateReuse", obsoleteCaptureRoutes: 0};
}

function auditDispatchControls() {
  const source = readText("script/check_semgrep_rule_coverage.js");
  const positive = verifyAuditDispatch(source);
  const receiptDeclaration = ["function ", "auditReceiptRow", "("].join("");
  const duplicateDeclaration = ["function ", "auditReceiptRow", "() {}\nfunction ", "auditReceiptRow", "("].join("");
  const duplicate = replaceExactlyOnce(source, receiptDeclaration, duplicateDeclaration, "duplicate receipt helper control");
  const captureCall = ["captureAudit", "(args[1]);"].join("");
  const alternateCall = ["auditCapture", "(args[1]);"].join("");
  const wrongCapture = replaceExactlyOnce(source, captureCall, alternateCall, "capture CLI dispatch control");
  const duplicateRejected = refuse("duplicate-top-level-receipt-helper", () => verifyAuditDispatch(duplicate));
  const wrongRouteRejected = refuse("capture-cli-dispatches-to-obsolete-path", () => verifyAuditDispatch(wrongCapture));
  return {positive, negativeCount: 2, negatives: [duplicateRejected, wrongRouteRejected]};
}

function auditToolSelectionControls() {
  const forgePin = AUDIT_TOOL_PINS.forge;
  const solcPin = AUDIT_TOOL_PINS.solc;
  const forgeVersion = auditToolVersion("forge", "forge Version: 1.3.5-v1.3.5\nCommit SHA: retained\n");
  const solcVersion = auditToolVersion("solc", "solc\nVersion: 0.8.24+commit.e11b9ed9.Linux.g++\n");
  const slitherVersion = auditToolVersion("slither", "0.11.6\n");
  const semgrepVersion = auditToolVersion("semgrep", "1.177.0\n");
  const versions = {forge: forgeVersion, solc: solcVersion, slither: slitherVersion, semgrep: semgrepVersion};
  for (const [name, version] of Object.entries(versions)) {
    const pin = AUDIT_TOOL_PINS[name];
    if (version !== pin.version) fail(`version parser did not bind the reviewed ${name} version`);
    auditVerifyToolPin(name, {version, sha256: pin.sha256});
  }
  const manifest = {compilerProfiles: {settingsSource: "foundry.toml",
    default: {solc: "0.8.24"}, deploy: {solc: "0.8.24"}}};
  const configuration = readText("foundry.toml");
  const canonicalPath = auditPinnedSolcPath("/control-home", solcPin.configuredVersion);
  const alternatePath = path.join("/control-home", ".svm", solcPin.configuredVersion,
    `solc-${solcPin.configuredVersion}`);
  const solcPath = auditResolvePinnedSolc("/control-home", solcPin.configuredVersion,
    (candidate) => candidate === canonicalPath, (candidate) => candidate);
  const solc = {path: solcPath, version: solcPin.version, sha256: solcPin.sha256};
  const environment = {...auditCommandEnvironment("default"), HOME: "/control-home"};
  const deployEnvironment = {...auditCommandEnvironment("deploy"), HOME: "/control-home"};
  const binding = auditCompilerBinding(manifest, configuration, solc, null,
    {pinnedSolcPath: solcPath, childEnvironment: environment});
  const forge = {path: "/control/forge"};
  const buildInvocations = [
    auditForgeBuildStage(forge, "default", solc, "/control/capture", environment),
    auditForgeBuildStage(forge, "deploy", solc, "/control/capture", deployEnvironment),
  ];
  for (const stage of buildInvocations) {
    const argv = stage.command.argv;
    const selector = argv.indexOf("--use");
    const child = stage.command.environment;
    if (selector < 0 || argv.indexOf("--use", selector + 1) >= 0 || argv[selector + 1] !== solc.path ||
        child.FOUNDRY_PROFILE !== stage.command.profile || child.FOUNDRY_OFFLINE !== "true" ||
        Object.hasOwn(child, "SOLC_BINARY") || Object.hasOwn(child, "FOUNDRY_SOLC")) {
      fail(`Forge ${stage.command.profile} invocation does not bind the approved Solc path and offline environment`);
    }
  }
  const wrongSolc = refuse("SOLC_BINARY-version-or-digest-mismatch", () => auditCompilerBinding(manifest,
    configuration, solc, {...solc, path: alternatePath, version: "0.8.25+commit.invalid", sha256: "mismatched"},
    {pinnedSolcPath: solcPath, SOLC_BINARY: alternatePath, childEnvironment: environment}));
  const alternateCache = refuse("alternate-SVM-cache-path-rejected", () => auditCompilerBinding(manifest,
    configuration, {...solc, path: alternatePath}, null,
    {pinnedSolcPath: solcPath, childEnvironment: environment}));
  const missingApprovedPath = refuse("missing-approved-Solc-does-not-fall-back-to-another-cache", () =>
    auditResolvePinnedSolc("/control-home", solcPin.configuredVersion,
      (candidate) => candidate === alternatePath, (candidate) => candidate));
  const malformedForgePin = refuse("malformed-Forge-SHA256-pin-rejected", () => auditVerifyToolPin("forge",
    {version: forgePin.version, sha256: forgePin.sha256}, {...forgePin, sha256: forgePin.sha256.slice(0, 62)}));
  const malformedSolcPin = refuse("malformed-Solc-SHA256-pin-rejected", () => auditVerifyToolPin("solc",
    {version: solcPin.version, sha256: solcPin.sha256}, {...solcPin, sha256: solcPin.sha256.slice(0, 62)}));
  const mismatchedForgePin = refuse("mismatched-Forge-SHA256-pin-rejected", () => auditVerifyToolPin("forge",
    {version: forgePin.version, sha256: forgePin.sha256}, {...forgePin, sha256: "0".repeat(64)}));
  const malformedIdentity = refuse("malformed-tool-identity-SHA256-rejected", () => auditVerifyToolPin("forge",
    {version: forgePin.version, sha256: forgePin.sha256.slice(0, 62)}));
  const forwardedSelector = refuse("Foundry-selector-not-allowlisted", () => auditCompilerBinding(manifest,
    configuration, solc, null, {pinnedSolcPath: solcPath, FOUNDRY_SOLC: "0.8.25",
      childEnvironment: {...environment, FOUNDRY_SOLC: "0.8.25"}}));
  const changedDefault = configuration.replace('solc = "0.8.24"', 'solc = "0.8.25"');
  const profileMismatch = refuse("default-profile-config-differs-from-manifest", () =>
    auditCompilerBinding(manifest, changedDefault, solc, null,
      {pinnedSolcPath: solcPath, childEnvironment: environment}));
  if (environment.FOUNDRY_PROFILE !== "default" || environment.FOUNDRY_OFFLINE !== "true" ||
      Object.hasOwn(environment, "SOLC_BINARY") || Object.hasOwn(environment, "FOUNDRY_SOLC")) {
    fail("Forge child environment includes an unapproved compiler selector");
  }
  if (deployEnvironment.FOUNDRY_PROFILE !== "deploy" || deployEnvironment.FOUNDRY_OFFLINE !== "true") {
    fail("Deploy profile settings were not retained in the child environment");
  }
  return {versions, solcBinding: binding, buildInvocations, defaultProfile: environment.FOUNDRY_PROFILE,
    deployProfile: deployEnvironment.FOUNDRY_PROFILE,
    rejected: [wrongSolc, alternateCache, missingApprovedPath, malformedForgePin, malformedSolcPin,
      mismatchedForgePin, malformedIdentity, forwardedSelector, profileMismatch]};
}

function verifyMakefile(configs) {
  const makefile = readText("Makefile");
  for (const configPath of CONFIGS) {
    if (!makefile.includes(`--run ${configPath}`)) fail(`Makefile does not run Semgrep config ${configPath}`);
  }
  if (!makefile.includes("--preflight")) fail("Makefile omits public Semgrep preflight");
  const captureCommand = "node script/check_semgrep_rule_coverage.js --capture-audit";
  const reuseCommand = "node script/check_semgrep_rule_coverage.js --reuse-audit";
  const controlsCommand = "node script/check_semgrep_rule_coverage.js --static-controls";
  if (occurrenceCount(makefile, captureCommand) !== 1 || occurrenceCount(makefile, reuseCommand) !== 1 ||
      occurrenceCount(makefile, controlsCommand) !== 1 ||
      !makefile.includes('AUDIT_CAPTURE_DIR="$(AUDIT_CAPTURE_DIR)" SEMGREP="$(SEMGREP)"')) {
    fail("public audit-static must call one capture, the production controls, and one reuse implementation");
  }
  const staticRunner = readText("script/check_semgrep_rule_coverage.js");
  verifyAuditDispatch(staticRunner);
  for (const required of ["--foundry-ignore-compile", "--foundry-out-directory", "--foundry-build-info-directory",
    "writeSemgrepAuditReceipt", "observedChildExit", "receipt-index.json", "AUDIT_TOOL_PINS",
    "auditCompilerBinding", "auditReadReceiptChain", "trustedRunnerPrecondition"]) {
    if (!staticRunner.includes(required)) fail(`public audit capture caller omits ${required}`);
  }
  const unqualifiedPass = ["CAPTURED", "_PASS"].join("");
  if (staticRunner.includes(unqualifiedPass)) fail("public reuse must name its trusted-runner precondition, not a bare pass");
  if (/^\s*\$\(SLITHER\)\s+\.\s/m.test(makefile) ||
      /(?:DEFAULT|DEPLOY|SLITHER)_EXIT\s*\?=/.test(makefile)) {
    fail("public audit-static must not use bare Slither or caller-supplied exit knobs");
  }
  if (!makefile.includes("git -C .. ls-files") ||
      !makefile.includes("NO_TESTS_INVENTORY_GIT_CONTEXT_UNAVAILABLE")) {
    fail("public tracked no-tests inventory must preserve Git and refuse an absent Git context explicitly");
  }
  for (const {rules} of configs.values()) {
    if (!rules.length) fail("Semgrep config has no rules");
  }
}

function verifyExceptions(exceptions, manifest, configs) {
  if (!Array.isArray(exceptions.allowlistFunctionNames) || !exceptions.allowlistFunctionNames.length) {
    fail("public allowlist exception names are missing");
  }
  const allowlistRule = configs.get(".semgrep/openforage.yml").rules.find((item) => item.id === "openforage-allowlist-gate-missing-modifier");
  if (!allowlistRule) fail("public allowlist rule is missing");
  sameSet(exceptions.allowlistFunctionNames, REQUIRED_ALLOWLIST_FUNCTION_NAMES,
    "the existing 21-name public allowlist list");
  if (exceptions.allowlistFunctionNames.includes("approveVestingBeneficiary")) {
    fail("renewable vesting approval must not become a function-name exception");
  }
  const match = allowlistRule.block.match(/\(\?!\(\?:([^)]*)\)(?:\\b)?\)/);
  if (!match) fail("public allowlist rule's exact function exception list is not parseable");
  const configuredNames = match[1].split("|").filter(Boolean).map((item) => item.replace(/\\b$/, ""));
  sameSet(configuredNames, exceptions.allowlistFunctionNames, "public allowlist function exception list");
  if (JSON.stringify(exceptions.allowlistPathExclusions) !== JSON.stringify(["**/src/interfaces/**"])) {
    fail("public allowlist path exclusion differs from its documented interface-only policy");
  }
  const bareCallRule = configs.get(".semgrep/openforage.yml").rules.find((item) => item.id === "openforage-no-bare-call-with-value");
  if (!bareCallRule) fail("public bare-call rule is missing");
  sameSet(bareCallRule.includes, ["/src/**/*.sol", "/script/**/*.sol"],
    "public bare-call source and script root globs");
  if (exceptions.protectedAtRiskExitGates?.some((item) => exceptions.allowlistFunctionNames.includes(item.signature.split("(")[0]))) {
    fail("a protected atRISKUSD exit was added to the allowlist exception set");
  }
  if (!Array.isArray(exceptions.exceptions)) fail("public exception records must be an array");
  for (const item of exceptions.exceptions) {
    if (!item.id || !item.ruleId || !item.path || !item.rationale) fail("public exception record is incomplete");
    if (/private|packet|checkpoint|workspace/i.test(JSON.stringify(item))) fail(`public exception contains private provenance ${item.id}`);
  }
  const requiredExceptionIds = new Set(["vault-solvency-module-forwarder", DISJOINTNESS_EXCEPTION_ID]);
  if (exceptions.exceptions.length !== requiredExceptionIds.size) fail("public exception inventory contains an unreviewed record");
  const exceptionIds = new Set(exceptions.exceptions.map((item) => item.id));
  for (const id of requiredExceptionIds) if (!exceptionIds.has(id)) fail(`required public-only exception is missing ${id}`);
  if (exceptions.exceptions.some((item) => item.path === "src/atRISKUSD.sol")) fail("public exception policy must not suppress an atRISKUSD exit");
  const atRiskSource = readText("src/atRISKUSD.sol");
  for (const expected of REQUIRED_ATRISK_EXITS) {
    const fn = functionBySignature(atRiskSource, expected, "src/atRISKUSD.sol");
    if (!fn.header.includes("onlyAllowedCaller")) fail(`atRISKUSD caller gate is missing ${expected}`);
    if (exceptions.exceptions.some((item) => item.path === "src/atRISKUSD.sol" && item.signature === expected)) {
      fail(`atRISKUSD exit gate is exempted ${expected}`);
    }
  }
  verifySolvencyForwarder(exceptions.solvencyForwarder);
  verifySourcePolicyDisclosure(exceptions);
  verifyDisjointnessException(
    exceptions.disjointnessGuard,
    configs.get(".semgrep/disjointness-grant-role.yml"),
    exceptions.exceptions,
  );
  if (manifest.protectedAtRiskExitGates.length !== 5) fail("the five protected atRISKUSD exits must remain bound");
  verifyReviewedSourcePredicates(exceptions, manifest);
  verifyReviewedSourcePolicies(exceptions, manifest);
}

function verifySolvencyForwarder(binding) {
  if (!binding || binding.path !== "src/RISKUSDVault.sol" || binding.modulePath !== "src/modules/RISKUSDVaultModule.sol") {
    fail("public solvency forwarder mapping is incomplete");
  }
  const host = functionBySignature(readText(binding.path), binding.hostSignature, binding.path);
  if (!host.header.includes("onlyAllowedCaller") || compact(host.body) !== "_delegateToModule();") {
    fail("public Vault deployCapital wrapper no longer delegates through the reviewed guard");
  }
  const module = functionBySignature(readText(binding.modulePath), binding.moduleSignature, binding.modulePath);
  const body = compact(module.body);
  const transfer = body.indexOf("_usdc.safeTransfer(_custodian,usdcAmount);");
  const assertion = body.indexOf("_assertSolvency();");
  if (!module.header.includes("onlyDelegateCall") || transfer < 0 || assertion <= transfer || body.indexOf("_assertSolvency();", assertion + 1) >= 0) {
    fail("public Vault module must assert solvency once after the custodian transfer");
  }
}

function verifyDisjointnessException(binding, config, exceptionRecords, overrides = {}) {
  const expectedBinding = {
    ruleId: DISJOINTNESS_RULE_ID,
    path: "script/Deploy.s.sol",
    signature: DISJOINTNESS_GRANT_FUNCTION,
    grantCall: "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, deployedForageGovernor);",
    grantAddress: "deployedForageGovernor",
    guardianModule: "deployedGuardianModule",
    guardianMethod: "isGuardian(address)",
    guardianInitializer: DISJOINTNESS_INITIALIZER_FUNCTION,
    guardianSource: "_guardianAddresses(cfg.deployer)",
    configuredGuardianCount: 7,
    guardError: "GovernanceProposerIsGuardian(address proposer)",
    broadcastEntryPoint: "Deploy.run()",
    constructorAdmin: "deployer",
    deployerCleanupFunction: "_revokeDeployerOperationalRoles(address)",
    deployerRoleRevokeOrder: ["PROPOSER_ROLE", "CANCELLER_ROLE", "EXECUTOR_ROLE", "DEFAULT_ADMIN_ROLE"],
    adminRoleExpression: "bytes32(0)",
    stopAfterCleanup: "vm.stopBroadcast()",
    noBroadcastEntryPoint: "DeployMainnet",
    noBroadcastCleanupFunction: "_revokeDeployerTimelockRoles()",
    selfAdminDependencyPin: OPENZEPPELIN_ADMIN_PIN,
    selfAdminSourceStatus: "pinned-but-not-materialized",
  };
  if (!binding || Object.entries(expectedBinding).some(([key, value]) =>
    JSON.stringify(binding[key]) !== JSON.stringify(value))) {
    fail("public disjointness exception does not bind the actual Timelock grant and GuardianModule query");
  }
  const records = Array.isArray(exceptionRecords) ? exceptionRecords : [];
  const record = records.filter((item) => item.id === DISJOINTNESS_EXCEPTION_ID);
  if (record.length !== 1 || record[0].ruleId !== binding.ruleId || record[0].path !== binding.path ||
      record[0].signature !== binding.signature || !record[0].rationale) {
    fail("public disjointness exception record does not match its exact grant binding");
  }

  const rule = config?.rules?.find((item) => item.id === binding.ruleId);
  if (!rule || !rule.block.includes("severity: ERROR") || rule.excludes.length) {
    fail("public disjointness rule must remain ERROR severity with no path exclusions");
  }
  sameSet(rule.includes, ["src/**/*.sol", "script/**/*.sol"], "public disjointness rule path set");
  if (rule.block.includes("pattern-not:") || rule.block.includes("isKnownGuardian") || rule.block.includes("ignoreline")) {
    fail("public disjointness rule contains a blanket, unsupported, or inline suppression");
  }
  const patternStart = rule.block.indexOf("pattern-not-inside:");
  if (patternStart < 0) fail("public disjointness rule has no dominating GuardianModule predicate");
  const patternContext = rule.block.slice(patternStart);
  const functionPattern = "function _wireTargetStack(DeployConfig memory cfg) internal {";
  const membershipPattern = "if (GuardianModule($GM).isGuardian($ADDR)) {";
  const grantPattern = "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, $ADDR);";
  const functionIndex = patternContext.indexOf(functionPattern);
  const membershipIndex = patternContext.indexOf(membershipPattern);
  const grantIndex = patternContext.indexOf(grantPattern);
  const guardedPattern = patternContext.slice(membershipIndex, grantIndex + grantPattern.length);
  if (functionIndex < 0 || membershipIndex < functionIndex || grantIndex <= membershipIndex ||
      (guardedPattern.match(/\$ADDR/g) || []).length !== 2) {
    fail("public disjointness Semgrep pattern does not bind the same address in the dominating guard and grant");
  }

  const source = overrides.deploySource === undefined ? readText(binding.path) : overrides.deploySource;
  const mainnetSource = overrides.mainnetSource === undefined ? readText("script/DeployMainnet.s.sol") : overrides.mainnetSource;
  const guardianSource = overrides.guardianSource === undefined ? readText("src/GuardianModule.sol") : overrides.guardianSource;
  const contextBytes = {
    "script/Deploy.s.sol": Buffer.from(source, "utf8"),
    "script/DeployMainnet.s.sol": Buffer.from(mainnetSource, "utf8"),
    "src/GuardianModule.sol": Buffer.from(guardianSource, "utf8"),
    "abi/GuardianModule.json": overrides.contextBytes?.["abi/GuardianModule.json"] || readBytes("abi/GuardianModule.json"),
  };
  verifyDisjointnessSourceBindings(binding, contextBytes);
  const errorDeclaration = [...maskSolidity(source).matchAll(/\berror\s+GovernanceProposerIsGuardian\s*\(\s*address\s+proposer\s*\)\s*;/g)];
  if (errorDeclaration.length !== 1) fail("public membership refusal must retain its exact typed script error");
  verifyTopLevelProposerGuard(source, binding.signature, binding.path);
  assertDeploymentAdminHandoff(source, mainnetSource, overrides.sourceManifest || readJson(SOURCE_MANIFEST_PATH));
  verifyGuardianMembershipInputs(
    binding,
    source,
    mainnetSource,
    guardianSource,
    overrides.guardianAbi === undefined ? readJson("abi/GuardianModule.json") : overrides.guardianAbi,
  );
}

function verifyDisjointnessSourceBindings(binding, contextBytes) {
  const expected = {
    deploy: "script/Deploy.s.sol",
    mainnet: "script/DeployMainnet.s.sol",
    guardianModule: "src/GuardianModule.sol",
    guardianAbi: "abi/GuardianModule.json",
  };
  if (!binding.sourceBindings || Object.keys(binding.sourceBindings).length !== Object.keys(expected).length) {
    fail("public disjointness exception omits its deployment and GuardianModule source-context hashes");
  }
  for (const [name, expectedPath] of Object.entries(expected)) {
    const record = binding.sourceBindings[name];
    const bytes = contextBytes[expectedPath];
    if (!record || record.path !== expectedPath || !/^[0-9a-f]{64}$/.test(record.sha256) || !bytes ||
        sha256(bytes) !== record.sha256) {
      fail(`public disjointness source/context hash is stale ${name}`);
    }
  }
}

function verifyGuardianMembershipInputs(binding, deploySource, mainnetSource, guardianSource, guardianAbi) {
  if (!Array.isArray(guardianAbi)) fail("candidate GuardianModule ABI input is missing or malformed");
  const memberships = guardianAbi.filter((item) => item.type === "function" && item.name === "isGuardian");
  if (memberships.length !== 1 || memberships[0].stateMutability !== "view" ||
      JSON.stringify(memberships[0].inputs?.map((item) => item.type)) !== JSON.stringify(["address"]) ||
      JSON.stringify(memberships[0].outputs?.map((item) => item.type)) !== JSON.stringify(["bool"])) {
    fail("candidate GuardianModule ABI does not expose exactly isGuardian(address) view returns (bool)");
  }
  const membership = functionBySignature(guardianSource, "isGuardian(address)", "src/GuardianModule.sol");
  if (compact(membership.body) !== "returnguardianPermissions[account]!=0;") {
    fail("candidate GuardianModule isGuardian does not read current guardian membership");
  }
  const initializer = functionBySignature(
    guardianSource,
    "initialize(address,address,address[],uint256[])",
    "src/GuardianModule.sol",
  );
  const initializerCode = compact(initializer.body);
  for (const required of [
    "if(initialGuardians_[i]==address(0))revertZeroAddress();",
    "if(initialGuardianPermissions_[i]==0)revertInvalidParameter();",
    "if(guardianPermissions[initialGuardians_[i]]!=0)revertDuplicateGuardian();",
    "guardianPermissions[initialGuardians_[i]]=initialGuardianPermissions_[i];",
    "_guardianList.push(initialGuardians_[i]);",
  ]) {
    if (!initializerCode.includes(required)) fail(`candidate GuardianModule initializer no longer binds configured members: ${required}`);
  }

  verifyGuardianFlowFromInputs(binding, deploySource, mainnetSource);

  const guardianSetup = functionBySignature(deploySource, binding.guardianInitializer, binding.path);
  const setupCode = compact(guardianSetup.body);
  const moduleInit = setupCode.indexOf("GuardianModule.initialize,(predicted.forageGovernor,deployedTimelock,guardians,permissions)");
  const governorDeploy = setupCode.indexOf("deployedForageGovernor=_proxy(implForageGovernor,");
  for (const required of [
    "address[]memoryguardians=_guardianAddresses(cfg.deployer);",
    "uint256[]memorypermissions=newuint256[](guardians.length);",
    "uint256proposalPermission=GuardianModule(implGuardianModule).PERMISSION_CAN_PROPOSE();",
    "permissions[i]=GUARDIAN_PERMISSION_PAUSE;",
    "if(guardians[i]==_reservedProposalGuardian)permissions[i]|=proposalPermission;",
  ]) {
    if (!setupCode.includes(required)) fail(`public deployment no longer initializes all configured guardians: ${required}`);
  }
  if ((setupCode.match(/PERMISSION_CAN_PROPOSE/g) || []).length !== 1 ||
      (setupCode.match(/permissions\[i\]\s*\|=/g) || []).length !== 1) {
    fail("public genesis setup adds an unreviewed proposer permission path");
  }
  if (moduleInit < 0 || governorDeploy <= moduleInit) {
    fail("public deployment no longer initializes GuardianModule before the actual Governor address");
  }
  if (!setupCode.slice(governorDeploy).includes("ForageGovernor.initialize") ||
      !setupCode.slice(governorDeploy).includes("deployedGuardianModule")) {
    fail("public Governor initialization is not bound to the same GuardianModule");
  }

  const guardianAddresses = functionBySignature(deploySource, "_guardianAddresses(address)", binding.path);
  const addressCode = compact(guardianAddresses.body);
  if (!addressCode.includes("guardians=newaddress[](7);") || !addressCode.includes("guardians[i]=vm.envAddress(key);") ||
      !addressCode.includes("guardians[i]!=address(0)")) {
    fail("public deployment no longer binds seven nonzero configured guardian addresses");
  }
  const explicitCheck = functionBySignature(deploySource, "_requireExplicitGuardianConfig()", binding.path);
  const explicitCode = compact(explicitCheck.body);
  if (explicitCode !== "_configuredProposalGuardian(_guardianAddresses(address(0)));") {
    fail("public explicit-guardian check no longer delegates to the accepted configured-guardian validator");
  }
  const explicitRun = compact(functionBySignature(deploySource, "run()", binding.path).body);
  const explicitSet = explicitRun.indexOf("cfgRequireExplicitGuardians=true;");
  const explicitRequire = explicitRun.indexOf("_requireExplicitGuardianConfig();");
  const broadcast = explicitRun.indexOf("vm.startBroadcast(");
  if (explicitSet < 0 || explicitRequire <= explicitSet || broadcast <= explicitRequire) {
    fail("public deployment no longer validates all seven configured guardian inputs before broadcast");
  }
  const selection = compact(functionBySignature(deploySource, "_configuredProposalGuardian(address[])", binding.path).body);
  if (!maskSolidityComments(deploySource).includes('vm.envOr("RESERVED_PROPOSAL_GUARDIAN", address(0))') ||
      !selection.includes("if(selectedGuardian==address(0)){if(cfgRequireExplicitGuardians)revertReservedProposalGuardianMissing();selectedGuardian=guardians[0];}") ||
      !selection.includes("if(guardians[i]==selectedGuardian)returnselectedGuardian;") ||
      !selection.includes("revertReservedProposalGuardianNotConfigured(selectedGuardian);")) {
    fail("public reserved proposal guardian must be one configured roster member");
  }
  const explicitValidationCode = compact(functionBySignature(deploySource,
    "_requireExplicitGuardianConfig()", binding.path).body);
  if (explicitValidationCode !== "_configuredProposalGuardian(_guardianAddresses(address(0)));") {
    fail("public explicit guardian validation no longer delegates to the configured-guardian validator");
  }
  const configuredRun = compact(functionBySignature(deploySource,
    "runWithConfig(address,address,address,address,address,address,address,address)", binding.path).body);
  if (!configuredRun.includes("cfgRequireExplicitGuardians=true;") ||
      !configuredRun.includes("_requireExplicitGuardianConfig();")) {
    fail("public configured run no longer requires the reserved guardian selection");
  }
  const deployFlow = compact(functionBySignature(deploySource, "_deployWithConfig(DeployConfig,address)", binding.path).body);
  const setupIndex = deployFlow.indexOf("_deployGovernanceAndRegistry(cfg,predicted);");
  const wiringIndex = deployFlow.indexOf("_wireTargetStack(cfg);");
  if (setupIndex < 0 || wiringIndex <= setupIndex) {
    fail("public deployment no longer initializes GuardianModule before the Timelock grant flow");
  }
}

function verifyGuardianFlowFromInputs(binding, deploySource, mainnetSource) {
  const addressRecords = sourceStatementRecords(deploySource, "_guardianAddresses(address)", binding.path);
  if (addressRecords.length !== 2 || addressRecords[0].code !== "guardians=newaddress[](7);" ||
      addressRecords[1].kind !== "for") {
    fail("public deployment must construct and visit all seven guardian input slots");
  }
  const addressLoop = bracedStatementBody(addressRecords[1].text,
    "for(uint256i;i<guardians.length;)", "guardian input loop");
  const addressSteps = topLevelStatements(addressLoop).map((item) => compact(item.text));
  const keyStep = compact('string memory key = string.concat("", vm.toString(i));');
  const inputStep = compact(`if (cfgRequireExplicitGuardians) {
    guardians[i] = vm.envAddress(key);
    require(guardians[i] != address(0), "");
  } else {
    guardians[i] = vm.envOr(key, address(uint160(uint256(keccak256(abi.encode(deployer, i, block.chainid))))));
  }`);
  if (JSON.stringify(addressSteps) !== JSON.stringify([keyStep, inputStep, compact("unchecked { ++i; }")])) {
    fail("each explicit guardian input must be read from its numbered key and reject zero");
  }
  const visibleInputs = maskSolidityComments(deploySource);
  if (!visibleInputs.includes('string.concat("GUARDIAN_", vm.toString(i))') ||
      !visibleInputs.includes('require(guardians[i] != address(0), "guardian required")')) {
    fail("each explicit guardian input must use its numbered key and reject zero");
  }

  const selectionRecords = sourceStatementRecords(deploySource, "_configuredProposalGuardian(address[])", binding.path);
  if (selectionRecords.length !== 4 ||
      selectionRecords[0].code !== compact('selectedGuardian = vm.envOr("", address(0));') ||
      selectionRecords[1].kind !== "if" || selectionRecords[2].kind !== "for" ||
      selectionRecords[3].code !== "revertReservedProposalGuardianNotConfigured(selectedGuardian);") {
    fail("configured Guardian selection must fail closed unless a roster member is selected");
  }
  const missingSelectionBody = bracedStatementBody(selectionRecords[1].text,
    "if(selectedGuardian==address(0))", "missing-selection guard");
  const missingSelectionSteps = topLevelStatements(missingSelectionBody).map((item) => compact(item.text));
  if (JSON.stringify(missingSelectionSteps) !==
      JSON.stringify(["if(cfgRequireExplicitGuardians)revertReservedProposalGuardianMissing();", "selectedGuardian=guardians[0];"])) {
    fail("explicit deployment must reject a missing reserved Guardian selection before fallback");
  }
  const rosterLoopBody = bracedStatementBody(selectionRecords[2].text,
    "for(uint256i;i<guardians.length;)", "configured-Guardian roster loop");
  const rosterSteps = topLevelStatements(rosterLoopBody).map((item) => compact(item.text));
  if (JSON.stringify(rosterSteps) !==
      JSON.stringify(["if(guardians[i]==selectedGuardian)returnselectedGuardian;", "unchecked{++i;}"])) {
    fail("configured Guardian selection must be validated against every roster member");
  }
  if (!visibleInputs.includes('vm.envOr("RESERVED_PROPOSAL_GUARDIAN", address(0))')) {
    fail("public deployment no longer reads the configured reserved Guardian input");
  }

  const explicitCheck = functionBySignature(deploySource, "_requireExplicitGuardianConfig()", binding.path);
  if (compact(explicitCheck.body) !== "_configuredProposalGuardian(_guardianAddresses(address(0)));" ) {
    fail("public explicit-guardian check no longer delegates to the roster selector");
  }
  const deployRun = sourceStatementRecords(deploySource, "run()", binding.path).map((item) => item.code);
  const deployRunOrder = [
    deployRun.indexOf("_requireAllowedDeployChain();"),
    deployRun.indexOf("_requireExpectedDeployChain();"),
    deployRun.indexOf("cfgRequireExplicitGuardians=true;"),
    deployRun.indexOf("_requireExplicitGuardianConfig();"),
    deployRun.findIndex((item) => item.includes("vm.startBroadcast(")),
    deployRun.findIndex((item) => item.startsWith("_deployWithConfig(")),
  ];
  if (deployRunOrder.some((item) => item < 0) ||
      deployRunOrder.some((item, index) => index > 0 && item <= deployRunOrder[index - 1])) {
    fail("Deploy.run must validate all seven Guardians before broadcast and deployment");
  }

  const configuredSignature = "runWithConfig(address,address,address,address,address,address,address,address)";
  for (const [source, filePath, prefix] of [
    [deploySource, binding.path, null],
    [mainnetSource, "script/DeployMainnet.s.sol", "_requireMainnetDryRunChain();"],
  ]) {
    const statements = sourceStatementRecords(source, configuredSignature, filePath).map((item) => item.code);
    const flagIndex = statements.indexOf("cfgRequireExplicitGuardians=true;");
    const validationIndex = statements.indexOf("_requireExplicitGuardianConfig();");
    const deployIndex = statements.findIndex((item) => item.startsWith("_deployWithConfig("));
    const prefixIndex = prefix === null ? -1 : statements.indexOf(prefix);
    if (flagIndex < 0 || validationIndex <= flagIndex || deployIndex <= validationIndex ||
        (prefix !== null && (prefixIndex < 0 || prefixIndex >= flagIndex))) {
      fail(`${filePath} configured entrypoint must validate the selected Guardian before setup`);
    }
  }

  const placeholderRun = sourceStatementRecords(mainnetSource, "runDryRunWithPlaceholders()",
    "script/DeployMainnet.s.sol").map((item) => item.code);
  const placeholderFlag = placeholderRun.indexOf("cfgRequireExplicitGuardians=false;");
  const placeholderDeploy = placeholderRun.findIndex((item) => item.startsWith("_deployWithConfig("));
  if (placeholderFlag < 0 || placeholderDeploy <= placeholderFlag ||
      placeholderRun.includes("_requireExplicitGuardianConfig();")) {
    fail("no-broadcast placeholder setup must retain its distinct generated-Guardian path");
  }

  const guardianFlags = [
    [binding.path, deploySource],
    ["script/DeployMainnet.s.sol", mainnetSource],
  ].flatMap(([filePath, source]) => functionDeclarations(source).flatMap((fn) => {
    if (fn.body === null) return [];
    return [...maskSolidity(fn.body).matchAll(/\bcfgRequireExplicitGuardians\s*=\s*(true|false)\s*;/g)]
      .map((match) => `${filePath}:${fn.signature}:${match[1]}`);
  }));
  const expectedFlags = [
    `${binding.path}:run():true`,
    `${binding.path}:${configuredSignature}:true`,
    `script/DeployMainnet.s.sol:${configuredSignature}:true`,
    "script/DeployMainnet.s.sol:runDryRunWithPlaceholders():false",
  ];
  if (JSON.stringify(sorted(guardianFlags)) !== JSON.stringify(sorted(expectedFlags))) {
    fail("public Guardian entrypoints changed their explicit or placeholder selection modes");
  }

  const deployFlow = sourceStatementRecords(deploySource, "_deployWithConfig(DeployConfig,address)", binding.path);
  const assignment = "_reservedProposalGuardian=_configuredProposalGuardian(_guardianAddresses(cfg.deployer));";
  const storedAssignments = [...maskSolidity(deploySource).matchAll(/\b_reservedProposalGuardian\s*=/g)];
  if (!storedAssignments.length) fail("selected proposal Guardian assignment is missing");
  if (storedAssignments.length !== 1) fail("selected proposal Guardian must have one authoritative stored assignment");
  if (deployFlow[0]?.code !== assignment) {
    fail("stored proposal Guardian assignment must use the configured roster selector");
  }
  const setupIndex = deployFlow.findIndex((item) => item.code === "_deployGovernanceAndRegistry(cfg,predicted);");
  const wiringIndex = deployFlow.findIndex((item) => item.code === "_wireTargetStack(cfg);");
  if (setupIndex <= 0 || wiringIndex <= setupIndex) {
    fail("stored proposal Guardian assignment must precede permission setup and Timelock wiring");
  }

  const guardianSetup = functionBySignature(deploySource, binding.guardianInitializer, binding.path);
  const setupStatements = topLevelStatements(guardianSetup.body).map((item) => ({
    kind: item.kind,
    text: item.text,
    code: compact(item.text),
  }));
  const setupPrefix = [
    "address[]memoryguardians=_guardianAddresses(cfg.deployer);",
    "uint256[]memorypermissions=newuint256[](guardians.length);",
    "Allowlistregistry=Allowlist(deployedAllowlist);",
    "uint256proposalPermission=GuardianModule(implGuardianModule).PERMISSION_CAN_PROPOSE();",
  ];
  if (setupPrefix.some((item, index) => setupStatements[index]?.code !== item) ||
      setupStatements[4]?.kind !== "for") {
    fail("guardian permission setup must bind the configured roster, Allowlist, and proposal bit");
  }
  const permissionLoopBody = bracedStatementBody(setupStatements[4].text,
    "for(uint256i;i<guardians.length;)", "guardian permission loop");
  const permissionStatements = topLevelStatements(permissionLoopBody).map((item) => compact(item.text));
  if (permissionStatements[0] !==
      "if(!registry.isAllowed(guardians[i]))revertInternalGuardianNotAllowed(guardians[i]);") {
    fail("every guardian must pass the configured Allowlist check before permission setup");
  }
  if (permissionStatements[1] !== "permissions[i]=GUARDIAN_PERMISSION_PAUSE;") {
    fail("every guardian must retain the ordinary pause permission before proposal selection");
  }
  if (permissionStatements[2] !==
      "if(guardians[i]==_reservedProposalGuardian)permissions[i]|=proposalPermission;") {
    fail("proposal permission bit must be assigned only to the stored selected guardian");
  }
  if (JSON.stringify(permissionStatements.slice(3)) !== JSON.stringify(["unchecked{++i;}"])) {
    fail("guardian permission loop contains an unreviewed statement");
  }
  const setupCode = compact(guardianSetup.body);
  const permissionWrites = [...maskSolidity(guardianSetup.body).matchAll(/\bpermissions\s*\[\s*([^\]]+)\s*\]\s*(\|=|=)/g)]
    .map((match) => `${match[1].trim()}:${match[2]}`);
  if (JSON.stringify(permissionWrites) !== JSON.stringify(["i:=", "i:|="]) ||
      (maskSolidity(guardianSetup.body).match(/\bproposalPermission\b/g) || []).length !== 2 ||
      (setupCode.match(/PERMISSION_CAN_PROPOSE/g) || []).length !== 1) {
    fail("proposal permission must have one selected-member write and no alternate permission path");
  }
  const permissionLoop = compact(setupStatements[4].text);
  const moduleInit = setupCode.indexOf("GuardianModule.initialize,(predicted.forageGovernor,deployedTimelock,guardians,permissions)");
  const governorDeploy = setupCode.indexOf("deployedForageGovernor=_proxy(implForageGovernor,");
  if (moduleInit <= setupCode.indexOf(permissionLoop) || governorDeploy <= moduleInit ||
      (setupCode.match(/GuardianModule\.initialize/g) || []).length !== 1) {
    fail("public deployment must initialize GuardianModule from checked permission arrays before the Governor");
  }
  if (!setupCode.slice(governorDeploy).includes("ForageGovernor.initialize") ||
      !setupCode.slice(governorDeploy).includes("deployedGuardianModule")) {
    fail("public Governor initialization is not bound to the same GuardianModule");
  }
}

function verifyManifestFiles(manifest) {
  if (!Array.isArray(manifest.inputs) || !manifest.inputCount) fail("public source manifest has no input inventory");
  const seen = new Set();
  for (const record of manifest.inputs) {
    if (!safeRelativePath(record.path) || seen.has(record.path)) fail(`duplicate or unsafe public input ${record.path}`);
    seen.add(record.path);
    const bytes = readBytes(record.path);
    const stat = fs.statSync(projectFile(record.path));
    const mode = `100${(stat.mode & 0o777).toString(8).padStart(3, "0")}`;
    if (record.bytes !== bytes.length || record.sha256 !== sha256(bytes) || record.mode !== mode) {
      fail(`public source/import/policy input changed ${record.path}`);
    }
  }
  if (manifest.inputCount !== manifest.inputs.length) fail("public source manifest count mismatch");
}

function verifyInputsMode() {
  const inputs = loadInputs();
  const sourcePaths = inputs.manifest.importGraph.nodes.map((item) => item.path);
  return {inputs, sourcePaths};
}

function normalizeKnownSemgrepRuleId(value, configuredIds) {
  if (typeof value !== "string") return null;
  const prefix = "semgrep.";
  if (!value.startsWith(prefix)) return null;
  const normalized = value.slice(prefix.length);
  return configuredIds.has(normalized) ? normalized : null;
}

function classifySourcePredicateFinding(finding, ruleId, inputs, sourceReader = readText) {
  if (!PUBLIC_SEMGREP_PREDICATE_IDS.size || ruleId !== "openforage-allowlist-gate-missing-modifier") return null;
  const candidates = PUBLIC_SOURCE_PREDICATE_SPECS.filter((item) =>
    PUBLIC_SEMGREP_PREDICATE_IDS.has(item.id) && item.ruleId === ruleId && item.path === finding.path);
  if (!candidates.length || !Number.isInteger(finding.start?.line)) return null;
  const declaration = functionDeclarations(sourceReader(finding.path)).filter((item) => item.line === finding.start.line);
  const candidate = declaration.length === 1 ? candidates.find((item) => item.signature === declaration[0].signature) : null;
  if (!candidate) {
    return {rejected: true, reason: `line ${finding.start.line} maps to ${declaration.map((item) => item.signature).join(",") || "no declaration"}`};
  }
  const record = inputs.inputs.exceptions.reviewedSourcePredicates.find((item) => item.id === candidate.id);
  if (!record || record.ruleId !== ruleId || record.path !== finding.path ||
      record.signature !== declaration[0].signature) return {rejected: true, reason: "exception signature binding differs"};
  const current = sourcePredicateBindingRows(sourceReader).find((item) => item.id === candidate.id);
  if (!current || current.sourceSha256 !== record.sourceSha256 || current.bodySha256 !== record.bodySha256 ||
      current.declarationSha256 !== record.declarationSha256 ||
      JSON.stringify(current.helperBindings) !== JSON.stringify(record.helperBindings)) {
    return {rejected: true, reason: "source, body, declaration or helper binding differs"};
  }
  return {id: candidate.id, path: finding.path, signature: declaration[0].signature, line: finding.start.line};
}

function validateSemgrepOutput(configPath, output, inputs, sourceReader = readText) {
  if (!CONFIGS.includes(configPath)) fail(`unknown public Semgrep config ${configPath}`);
  if (!output || typeof output !== "object" || Array.isArray(output)) fail("Semgrep JSON root must be an object");
  if (typeof output.version !== "string" || !output.version) fail("Semgrep version identity is missing");
  if (!Array.isArray(output.results) || !Array.isArray(output.errors)) fail("Semgrep results/errors arrays are missing or malformed");
  if (output.errors.length) fail(`Semgrep reported ${output.errors.length} scan errors`);
  if (!Array.isArray(output.skipped_rules)) fail("Semgrep JSON skipped_rules array is missing or malformed");
  if (output.skipped_rules.length) fail(`Semgrep skipped ${output.skipped_rules.length} rules`);
  const expected = inputs.inputs.manifest.ruleInventory.find((item) => item.config === configPath).scanInputs;
  if (!Array.isArray(output.paths?.scanned)) fail("Semgrep JSON paths.scanned array is missing or malformed");
  sameSet(output.paths.scanned, expected, `Semgrep scanned path set for ${configPath}`);
  const configRules = inputs.inputs.configs.get(configPath).rules;
  const sourcePaths = inputs.inputs.manifest.importGraph.nodes.map((item) => item.path);
  const ruleIds = new Set(configRules.map((rule) => rule.id));
  const recognizedSourcePredicates = [];
  const blockingFindings = [];
  const seenPredicates = new Set();
  for (const finding of output.results) {
    const ruleId = normalizeKnownSemgrepRuleId(finding?.check_id, ruleIds);
    if (!ruleId) fail(`Semgrep result names an unconfigured public rule: ${finding?.check_id}`);
    const rule = configRules.find((item) => item.id === ruleId);
    const ruleTargets = targetsForRule(rule, sourcePaths);
    if (typeof finding.path !== "string" || !ruleTargets.includes(finding.path)) fail(`Semgrep result is outside the configured ${ruleId} target set: ${finding.path}`);
    const recognized = classifySourcePredicateFinding(finding, ruleId, inputs, sourceReader);
    if (!recognized || recognized.rejected || seenPredicates.has(recognized.id)) {
      blockingFindings.push({ruleId, path: finding.path, line: finding.start?.line ?? null,
        reason: recognized?.reason || "no exact public caller predicate"});
    } else {
      seenPredicates.add(recognized.id);
      recognizedSourcePredicates.push(recognized);
    }
  }
  return {
    version: output.version || "unknown",
    scanned: expected.length,
    findings: output.results.length,
    recognizedSourcePredicates,
    blockingFindings,
    errors: 0,
    skippedRules: 0,
  };
}

function readSemgrepOutput(filePath) {
  let output;
  try {
    output = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`cannot parse Semgrep output ${filePath}: ${error.message}`);
  }
  return output;
}

function runSemgrep(configPath) {
  const inputs = verifyInputsMode();
  if (inputs.inputs.dependencyStatus.missing.length) {
    fail(`cannot run Semgrep without ${inputs.inputs.dependencyStatus.missing.length} materialized pinned dependency source files; no scan was started`);
  }
  const expected = inputs.inputs.manifest.ruleInventory.find((item) => item.config === configPath);
  const executable = process.env.SEMGREP || ".venv/bin/semgrep";
  const semgrepTool = auditToolIdentity(executable, "semgrep", configPath);
  const argv = [semgrepTool.path, "--config", configPath, "--error", "--json", ...expected.scanInputs];
  const child = spawnSync(semgrepTool.path, argv.slice(1), {
    cwd: CONTRACT_ROOT,
    env: auditCommandEnvironment(configPath),
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (child.error) fail(`cannot run configured Semgrep executable: ${child.error.message}`);
  if (auditStableJson(auditToolIdentity(semgrepTool.path, "semgrep", configPath)) !== auditStableJson(semgrepTool)) {
    fail("selected Semgrep executable identity changed during the scan");
  }
  let output;
  try {
    output = JSON.parse(child.stdout || "");
  } catch (error) {
    fail(`Semgrep did not return JSON: ${error.message}`);
  }
  const report = validateSemgrepOutput(configPath, output, inputs);
  const expectedExit = report.findings === 0 ? 0 : 1;
  if (process.env.AUDIT_CAPTURE_DIR) {
    writeSemgrepAuditReceipt(configPath, inputs, semgrepTool, argv, child, output, process.env.AUDIT_CAPTURE_DIR);
  }
  process.stderr.write(child.stderr || "");
  process.stdout.write(child.stdout);
  if (child.status !== expectedExit) {
    fail(`configured Semgrep observed child exit ${child.status}; expected ${expectedExit} for ${report.findings} raw findings`);
  }
  const wrapperExit = report.blockingFindings.length ? 1 : (child.status === 0 || child.status === 1 ? 0 : (child.status || 1));
  process.stdout.write(`${SENTINEL}_SCAN config=${configPath} version=${report.version} targets=${report.scanned} rawFindings=${report.findings} recognized=${report.recognizedSourcePredicates.length} blocking=${report.blockingFindings.length} childExit=${child.status} wrapperExit=${wrapperExit} errors=0 skipped=0\n`);
  if (wrapperExit !== 0) process.exitCode = wrapperExit;
}

function auditScratchRoot() {
  let directory = CONTRACT_ROOT;
  while (path.dirname(directory) !== directory && path.basename(directory) !== ".tmp") directory = path.dirname(directory);
  if (path.basename(directory) !== ".tmp") fail("audit capture requires an enclosing workspace .tmp directory");
  return directory;
}

function auditCaptureBase(value) {
  const absolute = path.resolve(CONTRACT_ROOT, value || process.env.AUDIT_CAPTURE_DIR || "../../.tmp/audit-static-captures");
  const scratch = auditScratchRoot();
  if (!absolute.startsWith(`${scratch}${path.sep}`)) fail("audit capture path must remain beneath the workspace .tmp directory");
  return absolute;
}

function auditSourceIdentity(inputs) {
  const manifest = inputs.inputs.manifest;
  const inputBindings = manifest.inputs.map((item) => ({path: item.path, bytes: item.bytes, mode: item.mode, sha256: item.sha256}))
    .sort((left, right) => left.path.localeCompare(right.path));
  const importBindings = manifest.importGraph.nodes.map((item) => ({path: item.path, bytes: item.bytes,
    mode: item.mode, sha256: item.sha256, owner: item.owner, dependencyPath: item.dependencyPath || null,
    dependencyPin: item.dependencyPin || null})).sort((left, right) => left.path.localeCompare(right.path));
  const manifestSha256 = sha256(readBytes(SOURCE_MANIFEST_PATH));
  const settings = ["foundry.toml", "foundry.lock", "remappings.txt", "slither.config.json", "slither_suppressions.json"]
    .map((relative) => ({path: relative, sha256: sha256(readBytes(relative))}));
  const value = {schema: manifest.schema, manifestSha256, inputs: inputBindings, importNodes: importBindings,
    importEdges: manifest.importGraph.edges, compilerProfiles: manifest.compilerProfiles, settings};
  return {digest: sha256(Buffer.from(JSON.stringify(value), "utf8")), manifestSha256,
    inputCount: inputBindings.length, importNodeCount: importBindings.length, importEdgeCount: manifest.importGraph.edgeCount};
}

function auditCommandEnvironment(profile) {
  const environment = {PATH: process.env.PATH || "", HOME: process.env.HOME || "/home/ofg"};
  if (process.env.TMPDIR) environment.TMPDIR = process.env.TMPDIR;
  if (profile === "default" || profile === "deploy") {
    environment.FOUNDRY_PROFILE = profile;
    environment.FOUNDRY_OFFLINE = "true";
  }
  return environment;
}

function auditResolveExecutable(command, searchPath = process.env.PATH || "") {
  const candidates = command.includes("/")
    ? [path.isAbsolute(command) ? command : path.resolve(CONTRACT_ROOT, command)]
    : searchPath.split(path.delimiter).filter(Boolean).map((entry) => path.join(entry, command));
  const candidate = candidates.find((item) => {
    try {
      return fs.statSync(item).isFile();
    } catch {
      return false;
    }
  });
  if (!candidate) fail(`required audit executable is absent ${command}`);
  return fs.realpathSync(candidate);
}

function auditToolVersion(name, output) {
  const lines = output.split(/\r?\n/).map((item) => item.trim()).filter(Boolean);
  if (name === "forge") return lines.find((item) => item.startsWith("forge Version:"))?.split(/\s+/)[2] || "";
  if (name === "solc") return lines.find((item) => item.startsWith("Version:"))?.split(/\s+/)[1]?.split(".").slice(0, 4).join(".") || "";
  return lines[0] || "";
}

function auditExecutableIdentity(command, name, profile = "default") {
  const environment = auditCommandEnvironment(profile);
  const executable = auditResolveExecutable(command, environment.PATH);
  const toolBytes = fs.readFileSync(executable);
  const version = spawnSync(executable, ["--version"], {cwd: CONTRACT_ROOT, env: environment,
    encoding: "utf8", timeout: 30000});
  if (version.error || version.status !== 0) fail(`cannot bind audit tool identity ${executable}`);
  return {path: executable, sha256: sha256(toolBytes), version: auditToolVersion(name, version.stdout || ""),
    versionOutputSha256: sha256(Buffer.from(version.stdout || "", "utf8"))};
}

function auditVerifyToolPin(name, identity, pin = AUDIT_TOOL_PINS[name]) {
  if (!pin || !isSha256Digest(pin.sha256) || !isSha256Digest(identity?.sha256)) {
    fail(`audit executable has a malformed ${name} SHA-256 identity or pin`);
  }
  if (identity.version !== pin.version || identity.sha256 !== pin.sha256) {
    fail(`audit executable differs from its reviewed ${name} tool pin ${pin?.version || "<missing>"}`);
  }
  return {name, version: pin.version, sha256: pin.sha256};
}

function auditToolIdentity(command, name, profile = "default") {
  const identity = auditExecutableIdentity(command, name, profile);
  auditVerifyToolPin(name, identity);
  return identity;
}

function auditConfiguredSolcVersion(profile, manifest, configuration) {
  if (profile !== "default" && profile !== "deploy") fail(`unsupported Forge compiler profile ${profile}`);
  if (manifest.compilerProfiles?.settingsSource !== "foundry.toml") fail("public compiler profile source is not foundry.toml");
  const manifestVersion = manifest.compilerProfiles?.[profile]?.solc;
  let section = "";
  let configuredVersion = "";
  for (const line of configuration.split(/\r?\n/)) {
    const header = line.match(/^\s*\[profile\.(default|deploy)\]\s*$/);
    if (header) {
      section = header[1];
      continue;
    }
    if (section !== profile) continue;
    const setting = line.match(/^\s*solc\s*=\s*["']([^"']+)["']\s*$/);
    if (setting) configuredVersion = setting[1];
  }
  if (manifestVersion !== AUDIT_TOOL_PINS.solc.configuredVersion || configuredVersion !== manifestVersion) {
    fail(`Forge ${profile} compiler config differs from its reviewed 0.8.24 profile`);
  }
  return configuredVersion;
}

function auditPinnedSolcPath(home, version) {
  if (!path.isAbsolute(home) || version !== AUDIT_TOOL_PINS.solc.configuredVersion) {
    fail("pinned Solc resolver requires the approved home and configured version");
  }
  return path.join(home, ".local", "share", "svm", version, `solc-${version}`);
}

function auditResolvePinnedSolc(home, version, fileExists = (candidate) => fs.statSync(candidate).isFile(),
  resolvePath = (candidate) => fs.realpathSync(candidate)) {
  const candidate = auditPinnedSolcPath(home, version);
  let present = false;
  try {
    present = fileExists(candidate);
  } catch {}
  if (!present) fail(`pinned Solc ${version} is absent at ${candidate}; alternate cache paths are not selected`);
  return resolvePath(candidate);
}

function auditCompilerBinding(manifest, configuration, solc, claim, selectors = {}) {
  const profileVersions = ["default", "deploy"].map((profile) =>
    auditConfiguredSolcVersion(profile, manifest, configuration));
  auditVerifyToolPin("solc", solc);
  if (new Set(profileVersions).size !== 1 || !path.isAbsolute(selectors.pinnedSolcPath || "") ||
      solc.path !== selectors.pinnedSolcPath) {
    fail("Forge default and Deploy profiles must select the exact reviewed Solc 0.8.24 binary");
  }
  if (selectors.FOUNDRY_SOLC || selectors.childEnvironment?.SOLC_BINARY || selectors.childEnvironment?.FOUNDRY_SOLC) {
    fail("Forge compiler selector is not allowlisted in the child environment");
  }
  if ((selectors.SOLC_BINARY || claim) && (!claim || claim.path !== solc.path ||
      claim.version !== solc.version || claim.sha256 !== solc.sha256)) {
    fail("SOLC_BINARY claim differs from the pinned compiler path, version, or digest");
  }
  return {configuredVersion: profileVersions[0], profiles: ["default", "deploy"], executablePath: solc.path};
}

function auditSolcIdentity(inputs) {
  const configuredVersion = auditConfiguredSolcVersion("default", inputs.inputs.manifest, readText("foundry.toml"));
  const home = process.env.HOME || "/home/ofg";
  const found = auditResolvePinnedSolc(home, configuredVersion);
  const solc = auditToolIdentity(found, "solc");
  const claim = process.env.SOLC_BINARY ? auditExecutableIdentity(process.env.SOLC_BINARY, "solc") : null;
  const binding = auditCompilerBinding(inputs.inputs.manifest, readText("foundry.toml"), solc, claim, {
    SOLC_BINARY: process.env.SOLC_BINARY,
    FOUNDRY_SOLC: process.env.FOUNDRY_SOLC,
    childEnvironment: auditCommandEnvironment("default"),
    pinnedSolcPath: found,
  });
  return {...solc, ...binding};
}

function auditForgeBuildStage(forge, profile, solc, captureDir,
  environment = auditCommandEnvironment(profile)) {
  if (profile !== "default" && profile !== "deploy") fail(`unsupported Forge build profile ${profile}`);
  if (!path.isAbsolute(forge.path || "") || !path.isAbsolute(solc.path || "")) {
    fail("Forge build plan requires absolute pinned Forge and Solc paths");
  }
  auditVerifyToolPin("solc", solc);
  const base = path.join(captureDir, "artifacts", "build", profile);
  const out = path.join(base, "out");
  const buildInfo = path.join(base, "build-info");
  const cache = path.join(base, "cache");
  const args = ["build", "--use", solc.path, "--skip", "test", "--build-info", "--extra-output", "storageLayout", "--sizes"];
  if (profile === "deploy") args.push("--evm-version", "cancun");
  args.push("--build-info-path", buildInfo, "--cache-path", cache, "--out", out);
  return {kind: profile === "default" ? "default-build" : "deploy-build",
    command: {argv: [forge.path, ...args], cwd: CONTRACT_ROOT, profile, environment},
    toolchain: {forge, solc}, outputs: [path.relative(captureDir, out).split(path.sep).join("/"),
      path.relative(captureDir, buildInfo).split(path.sep).join("/")]};
}

function auditPlan(inputs, captureDir) {
  const forge = auditToolIdentity(process.env.FORGE || "forge", "forge");
  const slither = auditToolIdentity(process.env.SLITHER || ".venv/bin/slither", "slither");
  const node = auditExecutableIdentity(process.execPath, "node");
  const solc = auditSolcIdentity(inputs);
  const semgrep = auditToolIdentity(process.env.SEMGREP || ".venv/bin/semgrep", "semgrep");
  const builds = {};
  for (const profile of ["default", "deploy"]) {
    builds[profile] = auditForgeBuildStage(forge, profile, solc, captureDir);
  }
  const rawPath = path.join(captureDir, "artifacts", "slither.raw.json");
  const build = builds.default;
  const slitherArgs = [".", "--config-file", "slither.config.json", "--json", rawPath,
    "--foundry-ignore-compile", "--foundry-out-directory", path.join(captureDir, ...build.outputs[0].split("/")),
    "--foundry-build-info-directory", path.join(captureDir, ...build.outputs[1].split("/"))];
  const stages = {
    "default-build": builds.default,
    "deploy-build": builds.deploy,
    "slither-scan": {kind: "slither-scan",
      command: {argv: [slither.path, ...slitherArgs], cwd: CONTRACT_ROOT, profile: "default",
        environment: auditCommandEnvironment("default")},
      toolchain: {slither, forge, solc},
      outputs: [path.relative(captureDir, rawPath).split(path.sep).join("/")]},
    "slither-validator": {kind: "slither-validator",
      command: {argv: [node.path, "script/check_slither_suppressions.js", rawPath, "slither_suppressions.json"],
        cwd: CONTRACT_ROOT, profile: "default", environment: auditCommandEnvironment("default")},
      toolchain: {node}, outputs: []},
  };
  for (const configPath of CONFIGS) {
    const configName = configPath.endsWith("openforage.yml") ? "semgrep-openforage" : "semgrep-disjointness";
    const record = inputs.inputs.manifest.ruleInventory.find((item) => item.config === configPath);
    stages[configName] = {kind: configName, configPath,
      command: {argv: [semgrep.path, "--config", configPath, "--error", "--json", ...record.scanInputs],
        cwd: CONTRACT_ROOT, profile: configPath, environment: auditCommandEnvironment(configPath)},
      toolchain: {semgrep}, outputs: [
        path.relative(captureDir, path.join(captureDir, "artifacts", "semgrep", `${configName}.json`)).split(path.sep).join("/"),
      ]};
  }
  return stages;
}

function auditStableJson(value) {
  if (Array.isArray(value)) return `[${value.map(auditStableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${auditStableJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function auditFileRecord(captureDir, absolute) {
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) fail(`audit capture output is not a regular file ${absolute}`);
  const bytes = fs.readFileSync(absolute);
  return {path: path.relative(captureDir, absolute).split(path.sep).join("/"), bytes: bytes.length,
    mode: `100${(stat.mode & 0o777).toString(8).padStart(3, "0")}`, sha256: sha256(bytes)};
}

function auditOutputFiles(captureDir, relative) {
  const absolute = path.join(captureDir, ...relative.split("/"));
  if (!fs.existsSync(absolute)) return [];
  const stat = fs.lstatSync(absolute);
  if (stat.isSymbolicLink()) fail(`audit capture output is a symlink ${relative}`);
  if (stat.isFile()) return [auditFileRecord(captureDir, absolute)];
  const rows = [];
  const visit = (directory) => {
    for (const name of fs.readdirSync(directory).sort((left, right) => left.localeCompare(right))) {
      const child = path.join(directory, name);
      const childStat = fs.lstatSync(child);
      if (childStat.isSymbolicLink()) fail(`audit capture output contains a symlink ${child}`);
      if (childStat.isDirectory()) visit(child);
      else if (childStat.isFile()) rows.push(auditFileRecord(captureDir, child));
      else fail(`audit capture output contains a special file ${child}`);
    }
  };
  visit(absolute);
  return rows.sort((left, right) => left.path.localeCompare(right.path));
}

function auditWriteJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), {recursive: true});
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function auditCaptureIndex(captureDir, sourceIdentity, receiptRows) {
  const indexPath = path.join(captureDir, "receipt-index.json");
  auditWriteJson(indexPath, {schema: AUDIT_CAPTURE_INDEX_SCHEMA, sourceIdentity, receipts: receiptRows});
  return indexPath;
}

function auditReadCaptureJson(filePath) {
  const scratch = auditScratchRoot();
  const absolute = path.resolve(filePath);
  if (!absolute.startsWith(`${scratch}${path.sep}`)) fail("audit receipt JSON path escapes workspace scratch");
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) fail("audit receipt JSON is absent or not a regular file");
  try {
    return JSON.parse(fs.readFileSync(absolute, "utf8"));
  } catch (error) {
    fail(`audit receipt JSON is malformed: ${error.message}`);
  }
}

function auditWriteLatest(base, runId, sourceIdentity) {
  const indexPath = path.join(base, runId, "receipt-index.json");
  auditWriteJson(path.join(base, "latest.json"), {runId, sourceIdentity,
    receiptIndexSha256: sha256(fs.readFileSync(indexPath))});
}

function auditResolveLatest(value) {
  const base = auditCaptureBase(value);
  const latestPath = path.join(base, "latest.json");
  if (!fs.existsSync(latestPath)) fail(`audit reuse receipt index is absent ${latestPath}`);
  const latest = auditReadCaptureJson(latestPath);
  if (typeof latest.runId !== "string" || !/^run-[0-9]+-[0-9a-f]{8}$/.test(latest.runId)) {
    fail("audit reuse receipt pointer is malformed");
  }
  const captureDir = path.join(base, latest.runId);
  const indexPath = path.join(captureDir, "receipt-index.json");
  if (!fs.existsSync(indexPath) || sha256(fs.readFileSync(indexPath)) !== latest.receiptIndexSha256) {
    fail("audit reuse receipt pointer does not bind an existing index");
  }
  return {base, captureDir, latest, indexPath};
}

function auditTreeBinding(receipt, prefix) {
  const rows = receipt.files.filter((item) => item.path.startsWith(prefix)).map((item) =>
    ({path: item.path, bytes: item.bytes, mode: item.mode, sha256: item.sha256}));
  return sha256(Buffer.from(auditStableJson(rows), "utf8"));
}

function auditStageInputBindings(kind, captureDir, receipts) {
  if (kind === "slither-scan") {
    const defaultReceiptPath = path.join(captureDir, "receipt-default-build.json");
    return [
      {path: "receipt-default-build.json", sha256: sha256(fs.readFileSync(defaultReceiptPath))},
      {path: "artifacts/build/default/out", sha256: auditTreeBinding(receipts["default-build"], "artifacts/build/default/out/")},
      {path: "artifacts/build/default/build-info", sha256: auditTreeBinding(receipts["default-build"], "artifacts/build/default/build-info/")},
    ];
  }
  if (kind === "slither-validator") {
    const raw = path.join(captureDir, "artifacts", "slither.raw.json");
    const rawHash = fs.existsSync(raw) ? sha256(fs.readFileSync(raw)) : null;
    return [{path: "artifacts/slither.raw.json", sha256: rawHash},
      {path: "slither_suppressions.json", sha256: sha256(readBytes("slither_suppressions.json"))}];
  }
  if (kind.startsWith("semgrep-")) return [{path: SOURCE_MANIFEST_PATH, sha256: sha256(readBytes(SOURCE_MANIFEST_PATH))}];
  return [];
}

function auditReceiptRow(captureDir, kind, rawPath) {
  const relative = `receipt-${kind}.json`;
  const receiptPath = path.join(captureDir, relative);
  const bytes = fs.readFileSync(receiptPath);
  const row = {kind, path: relative, sha256: sha256(bytes), childExit: JSON.parse(bytes.toString("utf8")).child.exitStatus};
  if (rawPath) row.rawSha256 = fs.existsSync(rawPath) ? sha256(fs.readFileSync(rawPath)) : null;
  return row;
}

function auditCaptureProcess(plan, kind, captureDir, sourceIdentity, receipts) {
  const command = plan.command;
  const stdoutPath = path.join(captureDir, "logs", `${kind}.stdout.log`);
  const stderrPath = path.join(captureDir, "logs", `${kind}.stderr.log`);
  for (const output of plan.outputs) {
    const absolute = path.join(captureDir, ...output.split("/"));
    if (output.endsWith(".json")) fs.mkdirSync(path.dirname(absolute), {recursive: true});
    else fs.mkdirSync(absolute, {recursive: true});
  }
  const child = spawnSync(command.argv[0], command.argv.slice(1), {
    cwd: command.cwd,
    env: command.environment,
    encoding: "utf8",
    timeout: 60 * 60 * 1000,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (child.error && child.error.code !== "ETIMEDOUT") fail(`could not start ${kind}: ${child.error.message}`);
  for (const [name, tool] of Object.entries(plan.toolchain)) {
    const current = name === "node"
      ? auditExecutableIdentity(tool.path, "node", command.profile)
      : auditToolIdentity(tool.path, name, command.profile);
    if (auditStableJson(current) !== auditStableJson(tool)) {
      fail(`audit executable identity changed during ${kind}: ${tool.path}`);
    }
  }
  fs.mkdirSync(path.dirname(stdoutPath), {recursive: true});
  fs.writeFileSync(stdoutPath, child.stdout || "");
  fs.writeFileSync(stderrPath, child.stderr || "");
  const artifacts = plan.outputs.flatMap((output) => auditOutputFiles(captureDir, output));
  const files = [auditFileRecord(captureDir, stdoutPath), auditFileRecord(captureDir, stderrPath), ...artifacts]
    .sort((left, right) => left.path.localeCompare(right.path));
  const receipt = {schema: AUDIT_CAPTURE_SCHEMA, kind, sourceIdentity, command, toolchain: plan.toolchain,
    child: {exitStatus: child.status, signal: child.signal, timedOut: child.error?.code === "ETIMEDOUT"},
    inputBindings: auditStageInputBindings(kind, captureDir, receipts), outputs: plan.outputs, files};
  auditWriteJson(path.join(captureDir, `receipt-${kind}.json`), receipt);
  receipts[kind] = receipt;
  const raw = kind === "slither-scan" ? path.join(captureDir, "artifacts", "slither.raw.json") : null;
  const row = auditReceiptRow(captureDir, kind, raw);
  process.stdout.write(`${JSON.stringify({kind, observedChildExit: child.status, timedOut: receipt.child.timedOut, receipt: row.path})}\n`);
  return row;
}

function captureAudit(value) {
  const inputs = verifyInputsMode();
  if (inputs.inputs.dependencyStatus.missing.length) {
    fail(`cannot capture public build/static commands without ${inputs.inputs.dependencyStatus.missing.length} pinned dependency inputs materialized`);
  }
  const identity = auditSourceIdentity(inputs);
  const base = auditCaptureBase(value || process.env.AUDIT_CAPTURE_DIR || "../../.tmp/audit-static-captures");
  fs.mkdirSync(base, {recursive: true});
  const runId = `run-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
  const captureDir = path.join(base, runId);
  fs.mkdirSync(captureDir, {recursive: true});
  const plans = auditPlan(inputs, captureDir);
  const receipts = {};
  const rows = [];
  for (const kind of AUDIT_CAPTURE_BASE_KINDS) {
    rows.push(auditCaptureProcess(plans[kind], kind, captureDir, identity, receipts));
    auditCaptureIndex(captureDir, identity, rows);
  }
  auditCaptureIndex(captureDir, identity, rows);
  auditWriteLatest(base, runId, identity);
  process.stdout.write(`${JSON.stringify({status: "CAPTURED_OBSERVED_CHILD_EXITS", runId,
    captureDirectory: path.relative(auditScratchRoot(), captureDir).split(path.sep).join("/"),
    observedChildExits: Object.fromEntries(rows.map((item) => [item.kind, item.childExit]))})}\n`);
}

function writeSemgrepAuditReceipt(configPath, inputs, tool, argv, child, output, captureBase) {
  const {captureDir} = auditResolveLatest(captureBase);
  const identity = auditSourceIdentity(inputs);
  const indexPath = path.join(captureDir, "receipt-index.json");
  const index = auditReadCaptureJson(indexPath);
  if (index.sourceIdentity?.digest !== identity.digest) fail("Semgrep capture source/import identity differs from the build/Slither run");
  const kind = configPath === CONFIGS[0] ? "semgrep-openforage" : "semgrep-disjointness";
  if (index.receipts.some((item) => item.kind === kind)) fail(`Semgrep capture already exists for ${configPath}`);
  const plan = auditPlan(inputs, captureDir)[kind];
  if (!plan || auditStableJson(plan.command.argv) !== auditStableJson(argv) ||
      auditStableJson(plan.toolchain.semgrep) !== auditStableJson(tool)) {
    fail(`Semgrep command, environment, profile or pinned tool differs from the production plan ${configPath}`);
  }
  const stdoutPath = path.join(captureDir, "logs", `${kind}.stdout.log`);
  const stderrPath = path.join(captureDir, "logs", `${kind}.stderr.log`);
  const rawPath = path.join(captureDir, ...plan.outputs[0].split("/"));
  fs.mkdirSync(path.dirname(stdoutPath), {recursive: true});
  fs.mkdirSync(path.dirname(rawPath), {recursive: true});
  fs.writeFileSync(stdoutPath, child.stdout || "");
  fs.writeFileSync(stderrPath, child.stderr || "");
  fs.writeFileSync(rawPath, child.stdout || "");
  const files = [auditFileRecord(captureDir, stdoutPath), auditFileRecord(captureDir, stderrPath),
    auditFileRecord(captureDir, rawPath)].sort((left, right) => left.path.localeCompare(right.path));
  const receipt = {schema: AUDIT_CAPTURE_SCHEMA, kind, sourceIdentity: identity, command: plan.command,
    toolchain: plan.toolchain,
    child: {exitStatus: child.status, signal: child.signal, timedOut: false},
    inputBindings: auditStageInputBindings(kind, captureDir, {}), outputs: plan.outputs, files,
    semanticSummary: {rawFindings: output.results.length, errors: output.errors.length,
      skippedRules: output.skipped_rules.length}};
  auditWriteJson(path.join(captureDir, `receipt-${kind}.json`), receipt);
  const row = auditReceiptRow(captureDir, kind, rawPath);
  index.receipts.push(row);
  auditCaptureIndex(captureDir, identity, index.receipts);
  auditWriteLatest(path.dirname(captureDir), path.basename(captureDir), identity);
}

function auditReceiptEnvelope(receipt, row, bytes) {
  if (!row || row.sha256 !== sha256(bytes) || receipt.schema !== AUDIT_CAPTURE_SCHEMA ||
      !AUDIT_CAPTURE_KINDS.includes(receipt.kind) || row.kind !== receipt.kind ||
      !Number.isInteger(receipt.child?.exitStatus) || row.childExit !== receipt.child.exitStatus ||
      receipt.child.signal !== null || receipt.child.timedOut !== false || !receipt.sourceIdentity?.digest ||
      !receipt.command || !Array.isArray(receipt.command.argv) || !receipt.command.argv.length ||
       typeof receipt.command.cwd !== "string" || typeof receipt.command.profile !== "string" ||
       !receipt.toolchain || !Array.isArray(receipt.files)) {
    fail("audit receipt is absent, malformed or inconsistent with its recorded command and child status");
  }
}

function auditReadReceiptChain(resolved, index, kind) {
  if (index.schema !== AUDIT_CAPTURE_INDEX_SCHEMA || !Array.isArray(index.receipts) ||
      index.sourceIdentity?.digest !== resolved.latest.sourceIdentity?.digest) {
    fail("audit receipt index is malformed or inconsistent with its latest pointer");
  }
  const matches = index.receipts.filter((item) => item.kind === kind);
  if (matches.length !== 1 || matches[0].path !== `receipt-${kind}.json`) {
    fail(`audit receipt index must contain one exact row for ${kind}`);
  }
  const row = matches[0];
  const bytes = fs.readFileSync(path.join(resolved.captureDir, row.path));
  const receipt = JSON.parse(bytes.toString("utf8"));
  auditReceiptEnvelope(receipt, row, bytes);
  if (receipt.sourceIdentity?.digest !== index.sourceIdentity.digest) {
    fail(`audit receipt source identity differs from its index for ${kind}`);
  }
  return {receipt, row, bytes};
}

function auditCaptureControls() {
  const runId = `run-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
  const base = path.join(auditScratchRoot(), "public-semgrep-receipt-controls", runId);
  const captureDir = path.join(base, runId);
  const identity = {digest: "non-contract-control-source"};
  const plan = {command: {argv: [process.execPath, "-e",
    "process.stdout.write('control-stdout');process.stderr.write('control-stderr');process.exit(7)"],
  cwd: CONTRACT_ROOT, profile: "default", environment: auditCommandEnvironment("default")},
  toolchain: {node: auditExecutableIdentity(process.execPath, "node")}, outputs: []};
  fs.mkdirSync(captureDir, {recursive: true});
  const row = auditCaptureProcess(plan, "default-build", captureDir, identity, {});
  auditCaptureIndex(captureDir, identity, [row]);
  auditWriteLatest(base, runId, identity);
  const resolved = auditResolveLatest(base);
  const index = auditReadCaptureJson(resolved.indexPath);
  const captured = auditReadReceiptChain(resolved, index, "default-build");
  const stdout = fs.readFileSync(path.join(captureDir, "logs", "default-build.stdout.log"), "utf8");
  const stderr = fs.readFileSync(path.join(captureDir, "logs", "default-build.stderr.log"), "utf8");
  if (captured.receipt.child.exitStatus !== 7 || stdout !== "control-stdout" || stderr !== "control-stderr") {
    fail("non-contract capture did not retain its observed nonzero exit and raw logs");
  }
  const staleBytes = Buffer.from(JSON.stringify({...captured.receipt,
    child: {...captured.receipt.child, exitStatus: 0}}), "utf8");
  const staleHash = refuse("stale-hash-child-exit-edit", () =>
    auditReceiptEnvelope(JSON.parse(staleBytes), captured.row, staleBytes));
  const commandless = {...captured.receipt, command: null};
  const commandlessBytes = Buffer.from(JSON.stringify(commandless), "utf8");
  const missingCommand = refuse("missing-command-binding", () =>
    auditReceiptEnvelope(commandless, {...captured.row, sha256: sha256(commandlessBytes)}, commandlessBytes));
  const coherentReceipt = {...captured.receipt, child: {...captured.receipt.child, exitStatus: 0}};
  auditWriteJson(path.join(captureDir, "receipt-default-build.json"), coherentReceipt);
  const coherentRow = auditReceiptRow(captureDir, "default-build", null);
  auditCaptureIndex(captureDir, identity, [coherentRow]);
  auditWriteLatest(base, runId, identity);
  const coherentResolved = auditResolveLatest(base);
  const coherentIndex = auditReadCaptureJson(coherentResolved.indexPath);
  const coherent = auditReadReceiptChain(coherentResolved, coherentIndex, "default-build");
  if (coherent.receipt.child.exitStatus !== 0) fail("coherently rehashed control was not read by the production parser");
  return {scope: "production receipt parser with a non-contract child only", observedChildExit: 7,
    rawStdoutAndStderrRetained: true, staleHashEdit: staleHash, missingCommand,
    coherentRehash: {acceptedByProductionParser: true, childExit: coherent.receipt.child.exitStatus,
      interpretation: "content consistency only; trusted runner and tool-selection precondition required"},
    positiveCount: 1, negativeCount: 2};
}

function auditReuseOutcome(childExits) {
  const redStages = AUDIT_CAPTURE_BASE_KINDS.filter((kind) => childExits[kind] !== 0);
  return {status: redStages.length ? "CAPTURED_WITH_RED_RESULTS" : "CAPTURED_ZERO_RED_STAGES_TRUSTED_RUNNER_REQUIRED",
    childExits, redStages,
    trustedRunnerPrecondition: "runner and tool selection are outside the writer's control"};
}

function auditValidateReuse(value) {
  const inputs = verifyInputsMode();
  if (inputs.inputs.dependencyStatus.missing.length) fail("cannot validate audit reuse without the materialized pinned dependency inputs");
  const currentIdentity = auditSourceIdentity(inputs);
  const resolved = auditResolveLatest(value);
  const {captureDir, latest, indexPath} = resolved;
  const index = auditReadCaptureJson(indexPath);
  if (index.schema !== AUDIT_CAPTURE_INDEX_SCHEMA || index.sourceIdentity?.digest !== currentIdentity.digest ||
      latest.sourceIdentity?.digest !== currentIdentity.digest) {
    fail("audit capture is stale for the current public source/import/settings identity");
  }
  if (!Array.isArray(index.receipts)) fail("audit capture index has no receipt list");
  const rows = new Map(index.receipts.map((item) => [item.kind, item]));
  if (index.receipts.length !== AUDIT_CAPTURE_KINDS.length || rows.size !== AUDIT_CAPTURE_KINDS.length ||
      AUDIT_CAPTURE_KINDS.some((kind) => !rows.has(kind))) {
    fail("audit capture is missing a required default, Deploy, Slither, validator or configured Semgrep receipt");
  }
  const plans = auditPlan(inputs, captureDir);
  const receipts = {};
  for (const kind of AUDIT_CAPTURE_KINDS) {
    const {receipt} = auditReadReceiptChain(resolved, index, kind);
    const plan = plans[kind];
    if (!plan || auditStableJson(receipt.command) !== auditStableJson(plan.command) ||
        auditStableJson(receipt.toolchain) !== auditStableJson(plan.toolchain) ||
        receipt.sourceIdentity.digest !== currentIdentity.digest ||
        auditStableJson(receipt.outputs) !== auditStableJson(plan.outputs)) {
      fail(`audit receipt command, profile, toolchain, source or output binding was substituted for ${kind}`);
    }
    for (const file of receipt.files) {
      if (!safeRelative(file.path)) fail(`audit receipt contains an unsafe log/artifact path ${file.path}`);
      const absolute = path.join(captureDir, ...file.path.split("/"));
      const stat = fs.lstatSync(absolute);
      if (!stat.isFile() || stat.isSymbolicLink()) fail(`captured log/artifact is absent or not regular ${file.path}`);
      const output = fs.readFileSync(absolute);
      const mode = `100${(stat.mode & 0o777).toString(8).padStart(3, "0")}`;
      if (output.length !== file.bytes || mode !== file.mode || sha256(output) !== file.sha256) {
        fail(`captured log/artifact identity differs ${file.path}`);
      }
    }
    if (!receipt.files.some((item) => item.path === `logs/${kind}.stdout.log`) ||
        !receipt.files.some((item) => item.path === `logs/${kind}.stderr.log`)) {
      fail(`audit receipt omitted raw stdout or stderr for ${kind}`);
    }
    receipts[kind] = receipt;
  }
  if (!receipts["slither-scan"].command.argv.includes("--foundry-ignore-compile")) {
    fail("Slither reuse receipt does not prove compile was disabled");
  }
  const defaultReceipt = receipts["default-build"];
  for (const prefix of ["artifacts/build/default/out/", "artifacts/build/default/build-info/"]) {
    if (!defaultReceipt.files.some((item) => item.path.startsWith(prefix))) fail(`captured default build output is missing ${prefix}`);
  }
  const deployReceipt = receipts["deploy-build"];
  for (const prefix of ["artifacts/build/deploy/out/", "artifacts/build/deploy/build-info/"]) {
    if (!deployReceipt.files.some((item) => item.path.startsWith(prefix))) fail(`captured Deploy build output is missing ${prefix}`);
  }
  const slitherRow = rows.get("slither-scan");
  if (!slitherRow.rawSha256 || !receipts["slither-scan"].files.some((item) => item.path === "artifacts/slither.raw.json")) {
    fail("captured Slither JSON artifact is absent");
  }
  const defaultTreeHash = (prefix) => sha256(Buffer.from(auditStableJson(defaultReceipt.files
    .filter((item) => item.path.startsWith(prefix)).map((item) => ({path: item.path, bytes: item.bytes,
      mode: item.mode, sha256: item.sha256}))), "utf8"));
  const expectedSlitherInputs = [
    {path: "receipt-default-build.json", sha256: rows.get("default-build").sha256},
    {path: "artifacts/build/default/out", sha256: defaultTreeHash("artifacts/build/default/out/")},
    {path: "artifacts/build/default/build-info", sha256: defaultTreeHash("artifacts/build/default/build-info/")},
  ];
  if (auditStableJson(receipts["slither-scan"].inputBindings) !== auditStableJson(expectedSlitherInputs)) {
    fail("Slither inputs do not bind to the captured default-profile compiler artifacts");
  }
  const validatorInputs = [
    {path: "artifacts/slither.raw.json", sha256: slitherRow.rawSha256},
    {path: "slither_suppressions.json", sha256: sha256(readBytes("slither_suppressions.json"))},
  ];
  if (auditStableJson(receipts["slither-validator"].inputBindings) !== auditStableJson(validatorInputs)) {
    fail("Slither validator inputs do not bind to the captured raw result and current public ledger");
  }
  const semgrepReport = {};
  for (const [configPath, kind] of [[CONFIGS[0], "semgrep-openforage"], [CONFIGS[1], "semgrep-disjointness"]]) {
    const receipt = receipts[kind];
    const rawPath = path.join(captureDir, "artifacts", "semgrep", `${kind}.json`);
    const rawBytes = fs.readFileSync(rawPath);
    const raw = JSON.parse(rawBytes.toString("utf8"));
    const report = validateSemgrepOutput(configPath, raw, inputs);
    if (report.blockingFindings.length) fail(`captured ${configPath} output has unrecognized findings`);
    const expectedExit = report.findings === 0 ? 0 : 1;
    if (receipt.child.exitStatus !== expectedExit) fail(`captured Semgrep child exit does not match raw ${configPath} results`);
    if (!receipt.files.some((item) => item.path === `artifacts/semgrep/${kind}.json`)) {
      fail(`captured Semgrep raw output is absent for ${configPath}`);
    }
    semgrepReport[kind] = {childExit: receipt.child.exitStatus, rawFindings: report.findings,
      recognized: report.recognizedSourcePredicates.length, blocking: report.blockingFindings.length,
      errors: report.errors, skippedRules: report.skippedRules};
  }
  const childExits = Object.fromEntries(AUDIT_CAPTURE_KINDS.map((kind) => [kind, receipts[kind].child.exitStatus]));
  return {...auditReuseOutcome(childExits), semgrep: semgrepReport, sourceIdentity: currentIdentity,
    receiptCount: Object.keys(receipts).length};
}

function refuse(name, predicate) {
  let refusal = null;
  try {
    predicate();
  } catch (error) {
    refusal = error.message;
  }
  if (!refusal) fail(`static control was accepted: ${name}`);
  return {name, predicateReached: true, rejected: true};
}

function runStaticControls() {
  const inputs = verifyInputsMode();
  const auditDispatch = auditDispatchControls();
  const auditToolSelection = auditToolSelectionControls();
  const config = inputs.inputs.manifest.ruleInventory[0].config;
  const expected = inputs.inputs.manifest.ruleInventory.find((item) => item.config === config).scanInputs;
  const base = {version: "control-only", results: [], errors: [], paths: {scanned: expected}, skipped_rules: []};
  const positives = [validateSemgrepOutput(config, base, inputs)];
  const negatives = [];
  for (const ruleConfig of inputs.inputs.manifest.ruleInventory) {
    const configuredPath = ruleConfig.config;
    const configuredRule = inputs.inputs.configs.get(configuredPath).rules[0];
    const sourcePath = configuredRule?.targetPaths.find((item) => item.startsWith("src/")) ||
      configuredRule?.targetPaths[0];
    if (!configuredRule || !sourcePath) fail(`configured rule has no static control target: ${configuredPath}`);
    negatives.push(refuse(`bare-configured-rule-id:${configuredPath}`, () => validateSemgrepOutput(
      configuredPath,
      {...base, paths: {scanned: ruleConfig.scanInputs}, results: [{check_id: configuredRule.id, path: sourcePath}]},
      inputs,
    )));
  }
  const bareRule = inputs.inputs.configs.get(config).rules.find((item) => item.id === "openforage-no-bare-call-with-value");
  const bareSourcePath = bareRule?.targetPaths.find((item) => item.startsWith("src/"));
  if (!bareSourcePath) fail("public bare-call positive control has no first-party source target");
  const bareCallPositive = validateSemgrepOutput(config, {...base, results: [{
    check_id: `semgrep.${bareRule.id}`, path: bareSourcePath,
  }]}, inputs);
  if (bareCallPositive.blockingFindings.length !== 1) fail("the generic configured rule must keep a bare-call result blocking");
  positives.push(bareCallPositive);

  const predicateFindings = [...PUBLIC_SEMGREP_PREDICATE_IDS].map((id) => {
    const spec = PUBLIC_SOURCE_PREDICATE_SPECS.find((item) => item.id === id);
    const declaration = functionBySignature(readText(spec.path), spec.signature, spec.path);
    return {check_id: `semgrep.${spec.ruleId}`, path: spec.path, start: {line: declaration.line},
      extra: {fingerprint: "requires login"}};
  });
  const recognized = validateSemgrepOutput(config, {...base, results: predicateFindings}, inputs);
  if (recognized.recognizedSourcePredicates.length !== PUBLIC_SEMGREP_PREDICATE_IDS.size ||
      recognized.blockingFindings.length !== 0) {
    fail(`exact public caller predicates must be recognized by source, declaration, helper and semantic bindings (expected=${PUBLIC_SEMGREP_PREDICATE_IDS.size} recognized=${recognized.recognizedSourcePredicates.map((item) => item.id).join(",")} blocking=${JSON.stringify(recognized.blockingFindings)})`);
  }
  positives.push(recognized);
  const noFingerprint = JSON.parse(JSON.stringify(predicateFindings));
  noFingerprint.forEach((item) => { delete item.extra.fingerprint; });
  const noFingerprintResult = validateSemgrepOutput(config, {...base, results: noFingerprint}, inputs);
  if (JSON.stringify(noFingerprintResult.recognizedSourcePredicates) !==
      JSON.stringify(recognized.recognizedSourcePredicates)) {
    fail("Semgrep fingerprints must not participate in public caller exception identity");
  }
  positives.push(noFingerprintResult);
  const arbitrarySource = readText("src/Allowlist.sol");
  const close = arbitrarySource.lastIndexOf("}");
  if (close < 0) fail("public source control cannot append a bounded mutator declaration");
  const withUnknownMutator = `${arbitrarySource.slice(0, close)}\nfunction unreviewedControlMutator() external {}\n${arbitrarySource.slice(close)}`;
  const unknownDeclaration = functionBySignature(withUnknownMutator, "unreviewedControlMutator()", "src/Allowlist.sol");
  const unknownMutator = validateSemgrepOutput(config, {...base, results: [{
    check_id: "semgrep.openforage-allowlist-gate-missing-modifier",
    path: "src/Allowlist.sol",
    start: {line: unknownDeclaration.line},
  }]}, inputs, (pathValue) => pathValue === "src/Allowlist.sol" ? withUnknownMutator : readText(pathValue));
  if (unknownMutator.recognizedSourcePredicates.length !== 0 || unknownMutator.blockingFindings.length !== 1) {
    fail("an unreviewed public mutator must remain blocking even in a path with reviewed predicates");
  }
  negatives.push({name: "unreviewed-mutator-at-reviewed-path", predicateReached: true, rejected: true});
  const changedExceptions = JSON.parse(JSON.stringify(inputs.inputs.exceptions));
  const changedBinding = {...inputs, inputs: {...inputs.inputs, exceptions: changedExceptions}};
  const firstPredicate = changedBinding.inputs.exceptions.reviewedSourcePredicates.find((item) =>
    item.id === [...PUBLIC_SEMGREP_PREDICATE_IDS][0]);
  firstPredicate.bodySha256 = "0".repeat(64);
  const substitutedBinding = validateSemgrepOutput(config, {...base, results: [predicateFindings[0]]}, changedBinding);
  if (substitutedBinding.recognizedSourcePredicates.length !== 0 || substitutedBinding.blockingFindings.length !== 1) {
    fail("a source-hash-only or substituted exception record must not authorize a Semgrep finding");
  }
  negatives.push({name: "substituted-body-hash-does-not-authorize", predicateReached: true, rejected: true});

  const missingErrors = {...base};
  delete missingErrors.errors;
  negatives.push(refuse("missing-errors-array", () => validateSemgrepOutput(config, missingErrors, inputs)));
  negatives.push(refuse("malformed-errors-array", () => validateSemgrepOutput(config, {...base, errors: {}}, inputs)));
  negatives.push(refuse("nonempty-errors-array", () => validateSemgrepOutput(config, {...base, errors: [{type: "control"}]}, inputs)));

  const missingSkipped = {...base};
  delete missingSkipped.skipped_rules;
  negatives.push(refuse("missing-skipped-rules-array", () => validateSemgrepOutput(config, missingSkipped, inputs)));
  negatives.push(refuse("malformed-skipped-rules-array", () => validateSemgrepOutput(config, {...base, skipped_rules: {}}, inputs)));
  negatives.push(refuse("nonempty-skipped-rules-array", () => validateSemgrepOutput(config, {...base, skipped_rules: [{rule_id: "control"}]}, inputs)));
  negatives.push(refuse("missing-scanned-path", () => validateSemgrepOutput(config, {...base, paths: {scanned: expected.slice(1)}}, inputs)));
  negatives.push(refuse("extra-scanned-path", () => validateSemgrepOutput(config, {...base, paths: {scanned: [...expected, "test/forbidden.sol"]}}, inputs)));
  negatives.push(refuse("unknown-rule-id", () => validateSemgrepOutput(config, {...base, results: [{check_id: "not-configured", path: expected[0]}]}, inputs)));
  negatives.push(refuse("unknown-semgrep-prefixed-rule-id", () => validateSemgrepOutput(config, {...base, results: [{
    check_id: "semgrep.openforage-unknown-rule", path: bareSourcePath,
  }]}, inputs)));
  negatives.push(refuse("alternate-rule-id-namespace", () => validateSemgrepOutput(config, {...base, results: [{
    check_id: `vendor.${bareRule.id}`, path: bareSourcePath,
  }]}, inputs)));
  negatives.push(refuse("repeated-semgrep-prefix", () => validateSemgrepOutput(config, {...base, results: [{
    check_id: `semgrep.semgrep.${bareRule.id}`, path: bareSourcePath,
  }]}, inputs)));
  negatives.push(refuse("suffix-only-known-rule-id", () => validateSemgrepOutput(config, {...base, results: [{
    check_id: `x-${bareRule.id}`, path: bareSourcePath,
  }]}, inputs)));
  negatives.push(refuse("bare-call-result-outside-anchored-targets", () => validateSemgrepOutput(config, {...base, results: [{
    check_id: `semgrep.${bareRule.id}`,
    path: "lib/openzeppelin-contracts-upgradeable/lib/forge-std/src/StdCheats.sol",
  }]}, inputs)));

  const binding = inputs.inputs.manifest.inputs.find((item) => item.path.endsWith("/ForageToken.sol"));
  const changed = Buffer.from(readBytes(binding.path));
  changed[0] ^= 1;
  negatives.push(refuse("changed-source-bytes", () => {
    if (sha256(changed) === binding.sha256) fail("control source byte did not change");
    verifyDigestBytes(binding, changed);
  }));
  const missingSource = {...inputs.inputs.manifest, sourceRoots: inputs.inputs.manifest.sourceRoots.slice(1)};
  negatives.push(refuse("missing-source-root", () => verifySourceRootSet(missingSource)));
  const includedRule = inputs.inputs.configs.get(config).rules[0];
  negatives.push(refuse("unlisted-public-rule-root", () => targetsForRule({...includedRule, includes: ["unlisted/**/*.sol"]}, inputs.sourcePaths)));

  const atRisk = readText("src/atRISKUSD.sol");
  const gate = "function executeWithdrawal(uint256 minAmountOut) external onlyAllowedCaller nonReentrant";
  negatives.push(refuse("removed-atRisk-exit-guard", () => verifyAtRiskGateText(atRisk.replace(gate, gate.replace(" onlyAllowedCaller", "")), inputs.inputs.exceptions)));
  const module = readText("src/modules/RISKUSDVaultModule.sol");
  negatives.push(refuse("removed-module-solvency-assertion", () => verifySolvencyModuleText(module.replace("_assertSolvency();", ""))));
  const sourcePredicateControls = verifyReviewedSourcePredicateControls();
  const sourcePolicyControls = verifyReviewedSourcePolicyControls();

  return {
    scope: "copied JSON/source controls and non-contract child capture only; no Semgrep scan, compiler, contract test, or contract execution",
    dependencyInputs: inputs.inputs.dependencyStatus,
    positiveCount: positives.length,
    negativeCount: negatives.length,
    positives,
    negatives,
    sourcePredicateControls,
    sourcePolicyControls,
    auditDispatch,
    auditToolSelection,
    auditCaptureControls: auditCaptureControls(),
  };
}

function replaceExactlyOnce(source, before, after, label) {
  const index = source.indexOf(before);
  if (index < 0 || source.indexOf(before, index + before.length) >= 0) fail(`control input cannot isolate ${label}`);
  return `${source.slice(0, index)}${after}${source.slice(index + before.length)}`;
}

function bindControlInputs(manifest, replacements) {
  const paths = new Set(Object.keys(replacements));
  const updated = new Set();
  const inputs = manifest.inputs.map((record) => {
    if (!paths.has(record.path)) return record;
    const bytes = Buffer.isBuffer(replacements[record.path]) ? replacements[record.path] : Buffer.from(replacements[record.path]);
    const replacement = {...record, bytes: bytes.length, sha256: sha256(bytes)};
    verifyDigestBytes(replacement, bytes);
    updated.add(record.path);
    return replacement;
  });
  if (updated.size !== paths.size) fail("control input path is absent from the public source manifest");
  const nodes = manifest.importGraph.nodes.map((node) => {
    const bytes = replacements[node.path];
    if (!bytes || node.owner !== "public-first-party") return node;
    const content = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
    return {...node, bytes: content.length, sha256: sha256(content)};
  });
  return {...manifest, inputs, importGraph: {...manifest.importGraph, nodes}};
}

function controlRuleConfig(inputs, ruleText, replacements) {
  const bytes = Buffer.from(ruleText, "utf8");
  const sourceManifest = JSON.parse(JSON.stringify(bindControlInputs(inputs.inputs.manifest, {
    ...replacements,
    ".semgrep/disjointness-grant-role.yml": bytes,
  })));
  const inventory = sourceManifest.ruleInventory.find((item) => item.config === ".semgrep/disjointness-grant-role.yml");
  if (!inventory) fail("control public source manifest omits the disjointness rule");
  inventory.sha256 = sha256(bytes);
  const record = sourceManifest.inputs.find((item) => item.path === ".semgrep/disjointness-grant-role.yml");
  verifyDigestBytes(record, bytes);
  if (inventory.sha256 !== record.sha256) fail("control rule hash differs between the input and rule inventories");
  return {manifest: sourceManifest, config: {rules: parseRuleBlocks(ruleText)}};
}

function disjointnessControlRecord(name, manifest, deploySource, options = {}) {
  const exceptions = options.exceptionData || inputsExceptionData(options.inputs);
  const mainnetSource = options.mainnetSource === undefined ? readText("script/DeployMainnet.s.sol") : options.mainnetSource;
  const guardianSource = options.guardianSource === undefined ? readText("src/GuardianModule.sol") : options.guardianSource;
  const guardianAbi = options.guardianAbi === undefined ? readJson("abi/GuardianModule.json") : options.guardianAbi;
  const replacements = {...(options.replacements || {})};
  const contextBytes = {
    "script/Deploy.s.sol": Buffer.from(deploySource, "utf8"),
    "script/DeployMainnet.s.sol": Buffer.from(mainnetSource, "utf8"),
    "src/GuardianModule.sol": Buffer.from(guardianSource, "utf8"),
    "abi/GuardianModule.json": replacements["abi/GuardianModule.json"] || readBytes("abi/GuardianModule.json"),
  };
  const sourceBindings = Object.fromEntries(Object.entries(contextBytes).map(([filePath, bytes]) => {
    const names = {
      "script/Deploy.s.sol": "deploy",
      "script/DeployMainnet.s.sol": "mainnet",
      "src/GuardianModule.sol": "guardianModule",
      "abi/GuardianModule.json": "guardianAbi",
    };
    return [names[filePath], {path: filePath, sha256: sha256(bytes)}];
  }));
  const binding = {...(options.binding || exceptions.disjointnessGuard), sourceBindings};
  const exceptionRecords = options.exceptionRecords || exceptions.exceptions;
  const exceptionData = {...exceptions, disjointnessGuard: binding, exceptions: exceptionRecords};
  replacements["script/Deploy.s.sol"] = contextBytes["script/Deploy.s.sol"];
  replacements["script/DeployMainnet.s.sol"] = contextBytes["script/DeployMainnet.s.sol"];
  replacements["src/GuardianModule.sol"] = contextBytes["src/GuardianModule.sol"];
  replacements["abi/GuardianModule.json"] = contextBytes["abi/GuardianModule.json"];
  replacements[".semgrep/source-exceptions.json"] = Buffer.from(`${JSON.stringify(exceptionData, null, 2)}\n`, "utf8");
  const controlManifest = bindControlInputs(manifest, replacements);
  const deployRecord = controlManifest.inputs.find((item) => item.path === "script/Deploy.s.sol");
  verifyDigestBytes(deployRecord, replacements["script/Deploy.s.sol"]);
  if (options.configText !== undefined) {
    const config = controlRuleConfig({inputs: {manifest: controlManifest}}, options.configText, replacements);
    return {
      name,
      controlManifest: config.manifest,
      config: config.config,
      deployRecord,
      inputs: options.inputs,
      replacements,
      binding,
      exceptionRecords,
      mainnetSource,
      guardianSource,
      guardianAbi,
      contextBytes,
    };
  }
  return {
    name,
    controlManifest,
    config: options.config || options.inputs.inputs.configs.get(".semgrep/disjointness-grant-role.yml"),
    deployRecord,
    inputs: options.inputs,
    replacements,
    binding,
    exceptionRecords,
    mainnetSource,
    guardianSource,
    guardianAbi,
    contextBytes,
  };
}

function inputsExceptionData(inputs) {
  if (!inputs?.inputs?.exceptions) fail("public disjointness controls have no source exception input");
  return JSON.parse(JSON.stringify(inputs.inputs.exceptions));
}

function acceptDisjointnessControl(name, inputs, source, options = {}) {
  const control = disjointnessControlRecord(name, inputs.inputs.manifest, source, {...options, inputs});
  verifyDisjointnessException(
    control.binding,
    control.config,
    control.exceptionRecords,
    {
      deploySource: source,
      mainnetSource: control.mainnetSource,
      guardianSource: control.guardianSource,
      guardianAbi: control.guardianAbi,
      contextBytes: control.contextBytes,
      sourceManifest: control.controlManifest,
    },
  );
  return {
    name,
    accepted: true,
    predicateReached: true,
    inputBindingsRecomputed: [...Object.keys(control.replacements)].sort(),
    reboundInputDigests: Object.fromEntries(Object.entries(control.replacements).map(([path, bytes]) =>
      [path, sha256(bytes)])),
    deploySha256: control.deployRecord.sha256,
    contextHashesRecomputed: Object.keys(control.contextBytes).sort(),
  };
}

function rejectDisjointnessControl(name, inputs, source, expected, options = {}) {
  const control = disjointnessControlRecord(name, inputs.inputs.manifest, source, {...options, inputs});
  let refusal = null;
  try {
    verifyDisjointnessException(
      control.binding,
      control.config,
      control.exceptionRecords,
      {
        deploySource: source,
        mainnetSource: control.mainnetSource,
        guardianSource: control.guardianSource,
        guardianAbi: control.guardianAbi,
        contextBytes: control.contextBytes,
        sourceManifest: control.controlManifest,
      },
    );
  } catch (error) {
    refusal = error.message;
  }
  if (!refusal || !refusal.includes(expected)) fail(`disjointness semantic control did not reach the expected refusal: ${name}`);
  return {
    name,
    accepted: false,
    predicateReached: true,
    inputBindingsRecomputed: [...Object.keys(control.replacements)].sort(),
    reboundInputDigests: Object.fromEntries(Object.entries(control.replacements).map(([path, bytes]) =>
      [path, sha256(bytes)])),
    deploySha256: control.deployRecord.sha256,
    contextHashesRecomputed: Object.keys(control.contextBytes).sort(),
    refusal,
  };
}

function runDisjointnessControls() {
  const inputs = verifyInputsMode();
  const source = readText("script/Deploy.s.sol");
  const mainnetSource = readText("script/DeployMainnet.s.sol");
  const exceptions = inputs.inputs.exceptions;
  const binding = exceptions.disjointnessGuard;
  const configText = readText(".semgrep/disjointness-grant-role.yml");
  const guardBlock = [
    "        if (GuardianModule(deployedGuardianModule).isGuardian(deployedForageGovernor)) {",
    "            revert GovernanceProposerIsGuardian(deployedForageGovernor);",
    "        }",
  ].join("\n");
  const grantLine = `        ${DISJOINTNESS_GRANT_SOURCE}`;
  const guardGrantPair = `${guardBlock}\n${grantLine}`;
  const withoutGuard = replaceExactlyOnce(source, guardBlock, "", "guard removal");
  const wrongFunction = replaceExactlyOnce(
    withoutGuard,
    "        deployedBlocklist = _proxy(implBlocklist, abi.encodeCall(Blocklist.initialize, (guardians[0], cfg.deployer)));",
    `${guardBlock}\n\n        deployedBlocklist = _proxy(implBlocklist, abi.encodeCall(Blocklist.initialize, (guardians[0], cfg.deployer)));`,
    "wrong-function guard",
  );
  const wrongAddress = replaceExactlyOnce(
    source,
    guardBlock,
    guardBlock.split("deployedForageGovernor").join("deployedTimelock"),
    "wrong-address guard",
  );
  const wrongModule = replaceExactlyOnce(
    source,
    guardBlock,
    guardBlock.replace("deployedGuardianModule", "deployedTimelock"),
    "wrong GuardianModule binding",
  );
  const afterGrant = replaceExactlyOnce(
    withoutGuard,
    grantLine,
    `${grantLine}\n${guardBlock}`,
    "guard-after-grant control",
  );
  const commentOnly = replaceExactlyOnce(
    withoutGuard,
    grantLine,
    `        ${String.fromCharCode(47, 47)} ${guardBlock.replace(/\n\s*/g, " ")}\n${grantLine}`,
    "comment-only guard",
  );
  const impossibleUsdcBranch = replaceExactlyOnce(
    source,
    guardBlock,
    `        if (cfg.usdc == address(0)) {\n${guardBlock}\n        }`,
    "impossible USDC outer branch",
  );
  const enclosingBranch = replaceExactlyOnce(
    source,
    guardGrantPair,
    `        if (cfg.usdc != address(0)) {\n${guardBlock}\n${grantLine}\n        }`,
    "enclosing branch",
  );
  const enclosingLoop = replaceExactlyOnce(
    source,
    guardGrantPair,
    `        for (uint256 i; i < 1; ++i) {\n${guardBlock}\n${grantLine}\n        }`,
    "enclosing loop",
  );
  const enclosingTry = replaceExactlyOnce(
    source,
    guardGrantPair,
    `        try this.membershipProbe() {\n${guardBlock}\n${grantLine}\n        } catch {\n            revert GovernanceProposerIsGuardian(deployedForageGovernor);\n        }`,
    "enclosing try",
  );
  const earlyExit = replaceExactlyOnce(
    source,
    guardGrantPair,
    `${guardBlock}\n        return;\n${grantLine}`,
    "early exit between refusal and grant",
  );
  const interveningStatement = replaceExactlyOnce(
    source,
    guardGrantPair,
    `${guardBlock}\n        _wireModules();\n${grantLine}`,
    "intervening statement",
  );
  const stringDecoy = replaceExactlyOnce(
    withoutGuard,
    grantLine,
    `        string memory decoy = ${JSON.stringify(guardBlock)};\n${grantLine}`,
    "string-only guard decoy",
  );
  const aliasRebinding = replaceExactlyOnce(
    source,
    guardBlock,
    `        address governorAlias = deployedForageGovernor;\n        if (GuardianModule(deployedGuardianModule).isGuardian(governorAlias)) {\n            revert GovernanceProposerIsGuardian(governorAlias);\n        }`,
    "Governor alias and rebinding",
  );
  const unknownGuardSyntax = replaceExactlyOnce(
    source,
    guardBlock,
    `        if (GuardianModule(deployedGuardianModule).isGuardian(deployedForageGovernor) == true) {\n            revert GovernanceProposerIsGuardian(deployedForageGovernor);\n        }`,
    "unsupported guard expression",
  );
  const duplicateProposerGrant = replaceExactlyOnce(
    source,
    grantLine,
    `${grantLine}\n${grantLine}`,
    "duplicate proposer grant",
  );
  const executorGrantLine = "        TimelockController(payable(deployedTimelock)).grantRole(EXECUTOR_ROLE, deployedForageGovernor);";
  const extraAdminGrant = replaceExactlyOnce(
    source,
    executorGrantLine,
    `${executorGrantLine}\n        TimelockController(payable(deployedTimelock)).grantRole(bytes32(0), cfg.deployer);`,
    "extra default-admin grant",
  );
  const missingDeployAdminCleanup = replaceExactlyOnce(
    source,
    "        timelock.revokeRole(bytes32(0), deployer);\n",
    "",
    "broadcast admin-cleanup removal",
  );
  const missingMainnetAdminCleanup = replaceExactlyOnce(
    mainnetSource,
    "        timelock.revokeRole(bytes32(0), address(this));\n",
    "",
    "mainnet admin-cleanup removal",
  );
  const reorderedAdminCleanup = replaceExactlyOnce(
    source,
    "        timelock.revokeRole(EXECUTOR_ROLE, deployer);\n        timelock.revokeRole(bytes32(0), deployer);",
    "        timelock.revokeRole(bytes32(0), deployer);\n        timelock.revokeRole(EXECUTOR_ROLE, deployer);",
    "default-admin cleanup ordering",
  );
  const zeroAdminConstructor = replaceExactlyOnce(
    source,
    "new TimelockController(_minDelay(), proposers, executors, deployer)",
    "new TimelockController(_minDelay(), proposers, executors, address(0))",
    "zero constructor admin shortcut",
  );
  const mainnetBroadcast = replaceExactlyOnce(
    mainnetSource,
    "    function run() public override {\n        runDryRunWithPlaceholders();",
    "    function run() public override {\n        vm.startBroadcast();\n        runDryRunWithPlaceholders();",
    "unexpected mainnet broadcast",
  );
  const missingTypedError = replaceExactlyOnce(
    source,
    "    error GovernanceProposerIsGuardian(address proposer);\n",
    "",
    "typed membership-refusal error removal",
  );
  const guardianSource = readText("src/GuardianModule.sol");
  const wrongMembershipSource = replaceExactlyOnce(
    guardianSource,
    "return guardianPermissions[account] != 0;",
    "return guardianPermissions[account] == 0;",
    "GuardianModule membership semantics",
  );
  const whitespaceUpdate = replaceExactlyOnce(
    source,
    "GuardianModule(deployedGuardianModule).isGuardian(deployedForageGovernor)",
    "GuardianModule ( deployedGuardianModule ) . isGuardian ( deployedForageGovernor )",
    "updated valid source bytes",
  );
  const alternateSafePrelude = replaceExactlyOnce(
    source,
    "        _wireSharedAllowlist(cfg);\n        _wireModules();",
    "        _wireModules();\n        _wireSharedAllowlist(cfg);",
    "alternate safe deployment prelude order",
  );
  const missingSelectionAssignment = replaceExactlyOnce(
    source,
    "        _reservedProposalGuardian = _configuredProposalGuardian(_guardianAddresses(cfg.deployer));",
    "",
    "missing reserved Guardian assignment",
  );
  const redirectedSelectionAssignment = replaceExactlyOnce(
    source,
    "        _reservedProposalGuardian = _configuredProposalGuardian(_guardianAddresses(cfg.deployer));",
    "        _reservedProposalGuardian = cfg.deployer;",
    "redirected reserved Guardian assignment",
  );
  const skippedGuardianMembership = replaceExactlyOnce(
    source,
    "            if (!registry.isAllowed(guardians[i])) revert InternalGuardianNotAllowed(guardians[i]);",
    "",
    "skipped guardian Allowlist membership",
  );
  const zeroGuardianAccepted = replaceExactlyOnce(
    source,
    '                require(guardians[i] != address(0), "guardian required");',
    "",
    "unguarded zero guardian input",
  );
  const redirectedProposalPermission = replaceExactlyOnce(
    source,
    "            if (guardians[i] == _reservedProposalGuardian) permissions[i] |= proposalPermission;",
    "            if (guardians[i] != _reservedProposalGuardian) permissions[i] |= proposalPermission;",
    "redirected reserved proposal permission",
  );
  const positives = [
    acceptDisjointnessControl("valid-guarded-grant-admin-handoff-self-admin", inputs, source),
    acceptDisjointnessControl("valid-alternate-safe-deploy-prelude-order", inputs, alternateSafePrelude),
    acceptDisjointnessControl("updated-bytes-valid-grant", inputs, whitespaceUpdate),
  ];
  const semanticRefusal = "public proposer grant lacks a dominating same-address GuardianModule membership refusal";
  const negatives = [
    rejectDisjointnessControl("removed-guard", inputs, withoutGuard, semanticRefusal),
    rejectDisjointnessControl("wrong-function-guard", inputs, wrongFunction, semanticRefusal),
    rejectDisjointnessControl("wrong-address-guard", inputs, wrongAddress, semanticRefusal),
    rejectDisjointnessControl("wrong-module-guard", inputs, wrongModule, semanticRefusal),
    rejectDisjointnessControl("guard-after-grant", inputs, afterGrant, semanticRefusal),
    rejectDisjointnessControl("comment-only-guard", inputs, commentOnly, semanticRefusal),
    rejectDisjointnessControl("impossible-usdc-outer-branch", inputs, impossibleUsdcBranch, semanticRefusal),
    rejectDisjointnessControl("enclosing-conditional", inputs, enclosingBranch, semanticRefusal),
    rejectDisjointnessControl("enclosing-loop", inputs, enclosingLoop, semanticRefusal),
    rejectDisjointnessControl("enclosing-try-catch", inputs, enclosingTry, semanticRefusal),
    rejectDisjointnessControl("early-exit-before-grant", inputs, earlyExit, semanticRefusal),
    rejectDisjointnessControl("intervening-statement", inputs, interveningStatement, semanticRefusal),
    rejectDisjointnessControl("string-only-guard-decoy", inputs, stringDecoy, semanticRefusal),
    rejectDisjointnessControl("alias-and-rebinding", inputs, aliasRebinding, semanticRefusal),
    rejectDisjointnessControl("unknown-guard-syntax", inputs, unknownGuardSyntax, semanticRefusal),
    rejectDisjointnessControl("duplicate-proposer-grant", inputs, duplicateProposerGrant,
      semanticRefusal),
    rejectDisjointnessControl("extra-default-admin-grant", inputs, extraAdminGrant,
      "public deployment grants an extra or aliased proposer/admin role"),
    rejectDisjointnessControl("missing-broadcast-admin-cleanup", inputs, missingDeployAdminCleanup,
      "DEFAULT_ADMIN_ROLE last"),
    rejectDisjointnessControl("mainnet-placeholder-admin-cleanup-removed", inputs, source,
      "DEFAULT_ADMIN_ROLE last", {mainnetSource: missingMainnetAdminCleanup}),
    rejectDisjointnessControl("admin-cleanup-not-last", inputs, reorderedAdminCleanup,
      "DEFAULT_ADMIN_ROLE last"),
    rejectDisjointnessControl("zero-admin-constructor-shortcut", inputs, zeroAdminConstructor,
      "bootstrap admin must remain the deployer"),
    rejectDisjointnessControl("mainnet-placeholder-starts-broadcast", inputs, source,
      "mainnet placeholder variant must remain no-broadcast", {mainnetSource: mainnetBroadcast}),
    rejectDisjointnessControl("typed-refusal-error-removed", inputs, missingTypedError,
      "exact typed script error"),
    rejectDisjointnessControl("missing-reserved-guardian-assignment", inputs, missingSelectionAssignment,
      "selected proposal Guardian assignment is missing"),
    rejectDisjointnessControl("redirected-reserved-guardian-assignment", inputs, redirectedSelectionAssignment,
      "stored proposal Guardian assignment must use the configured roster selector"),
    rejectDisjointnessControl("skipped-guardian-allowlist-membership", inputs, skippedGuardianMembership,
      "every guardian must pass the configured Allowlist check before permission setup"),
    rejectDisjointnessControl("zero-guardian-input-accepted", inputs, zeroGuardianAccepted,
      "each explicit guardian input must be read from its numbered key and reject zero"),
    rejectDisjointnessControl("proposal-permission-redirected", inputs, redirectedProposalPermission,
      "proposal permission bit must be assigned only to the stored selected guardian"),
  ];

  const guardianAbi = readJson("abi/GuardianModule.json");
  const noMembershipAbi = guardianAbi.filter((item) => item.name !== "isGuardian");
  const noMembershipAbiBytes = Buffer.from(`${JSON.stringify(noMembershipAbi, null, 2)}\n`, "utf8");
  negatives.push(rejectDisjointnessControl(
    "missing-guardian-abi-method",
    inputs,
    source,
    "candidate GuardianModule ABI does not expose exactly isGuardian(address)",
    {guardianAbi: noMembershipAbi, replacements: {"abi/GuardianModule.json": noMembershipAbiBytes}},
  ));
  const malformedAbi = guardianAbi.map((item) => item.name === "isGuardian"
    ? {...item, inputs: [{...item.inputs[0], type: "uint256"}]}
    : item);
  const malformedAbiBytes = Buffer.from(`${JSON.stringify(malformedAbi, null, 2)}\n`, "utf8");
  negatives.push(rejectDisjointnessControl(
    "malformed-guardian-abi-method",
    inputs,
    source,
    "candidate GuardianModule ABI does not expose exactly isGuardian(address)",
    {guardianAbi: malformedAbi, replacements: {"abi/GuardianModule.json": malformedAbiBytes}},
  ));
  const missingBoolAbi = guardianAbi.map((item) => item.name === "isGuardian"
    ? {...item, outputs: [{...item.outputs[0], type: "uint256"}]}
    : item);
  const missingBoolAbiBytes = Buffer.from(`${JSON.stringify(missingBoolAbi, null, 2)}\n`, "utf8");
  negatives.push(rejectDisjointnessControl(
    "wrong-guardian-abi-return-type",
    inputs,
    source,
    "candidate GuardianModule ABI does not expose exactly isGuardian(address)",
    {guardianAbi: missingBoolAbi, replacements: {"abi/GuardianModule.json": missingBoolAbiBytes}},
  ));
  negatives.push(rejectDisjointnessControl(
    "wrong-guardian-membership-source",
    inputs,
    source,
    "candidate GuardianModule isGuardian does not read current guardian membership",
    {guardianSource: wrongMembershipSource, replacements: {"src/GuardianModule.sol": Buffer.from(wrongMembershipSource, "utf8")}},
  ));

  const wrongRecords = exceptions.exceptions.map((item) => item.id === DISJOINTNESS_EXCEPTION_ID
    ? {...item, signature: DISJOINTNESS_INITIALIZER_FUNCTION}
    : item);
  const wrongExceptionData = {...exceptions, exceptions: wrongRecords};
  const wrongExceptionBytes = Buffer.from(`${JSON.stringify(wrongExceptionData, null, 2)}\n`, "utf8");
  negatives.push(rejectDisjointnessControl(
    "wrong-exception-record-binding",
    inputs,
    source,
    "public disjointness exception record does not match its exact grant binding",
    {exceptionRecords: wrongRecords, replacements: {".semgrep/source-exceptions.json": wrongExceptionBytes}},
  ));

  const wrongBinding = {...binding, grantAddress: "deployedTimelock"};
  const wrongBindingData = {...exceptions, disjointnessGuard: wrongBinding};
  const wrongBindingBytes = Buffer.from(`${JSON.stringify(wrongBindingData, null, 2)}\n`, "utf8");
  negatives.push(rejectDisjointnessControl(
    "wrong-exception-address-binding",
    inputs,
    source,
    "public disjointness exception does not bind the actual Timelock grant",
    {binding: wrongBinding, replacements: {".semgrep/source-exceptions.json": wrongBindingBytes}},
  ));

  const wrongFunctionRule = replaceExactlyOnce(
    configText,
    "function _wireTargetStack(DeployConfig memory cfg) internal {",
    "function _deployGovernanceAndRegistry(DeployConfig memory cfg, PredictedAddresses memory predicted) internal {",
    "wrong-function Semgrep guard",
  );
  const wrongAddressRule = replaceExactlyOnce(
    configText,
    "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, $ADDR);",
    "TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, $OTHER);",
    "wrong-address Semgrep guard",
  );
  const ruleGuard = "            if (GuardianModule($GM).isGuardian($ADDR)) {\n              ...\n            }\n            ...\n            TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, $ADDR);";
  const grantBeforeGuard = "            TimelockController(payable(deployedTimelock)).grantRole(PROPOSER_ROLE, $ADDR);\n            ...\n            if (GuardianModule($GM).isGuardian($ADDR)) {\n              ...\n            }";
  const afterGrantRule = replaceExactlyOnce(configText, ruleGuard, grantBeforeGuard, "after-grant Semgrep rule");
  for (const [name, ruleText] of [
    ["wrong-function-rule-binding", wrongFunctionRule],
    ["wrong-address-rule-binding", wrongAddressRule],
    ["guard-after-grant-rule-binding", afterGrantRule],
  ]) {
    const ruleControl = controlRuleConfig({inputs: inputs.inputs}, ruleText, {"script/Deploy.s.sol": Buffer.from(source, "utf8")});
    negatives.push(rejectDisjointnessControl(
      name,
      inputs,
      source,
      "public disjointness Semgrep pattern does not bind the same address",
      {config: ruleControl.config, replacements: {".semgrep/disjointness-grant-role.yml": Buffer.from(ruleText, "utf8")}},
    ));
  }

  return {
    scope: "copied public source, ABI, exception, and rule text with each changed input hash rebound; no Semgrep, compiler, contract test, or execution",
    dependencyInputs: inputs.inputs.dependencyStatus,
    positiveCount: positives.length,
    negativeCount: negatives.length,
    positives,
    negatives,
  };
}

function verifyDigestBytes(record, bytes) {
  if (sha256(bytes) !== record.sha256 || bytes.length !== record.bytes) fail(`public source digest mismatch ${record.path}`);
}

function verifySourceRootSet(manifest) {
  const actual = collectFiles("src", (relativePath) => relativePath.endsWith(".sol"));
  sameSet(actual, manifest.sourceRoots, "dynamic production source-root inventory");
}

function verifyAtRiskGateText(source, exceptions) {
  for (const signature of REQUIRED_ATRISK_EXITS) {
    const fn = functionBySignature(source, signature, "src/atRISKUSD.sol");
    if (!fn.header.includes("onlyAllowedCaller")) fail(`atRISKUSD caller gate missing ${signature}`);
    if (exceptions.exceptions.some((item) => item.path === "src/atRISKUSD.sol" && item.signature === signature)) fail(`atRISKUSD exception added ${signature}`);
  }
}

function verifySolvencyModuleText(source) {
  const fn = functionBySignature(source, "deployCapital(uint256)", "src/modules/RISKUSDVaultModule.sol");
  const body = compact(fn.body);
  const transfer = body.indexOf("_usdc.safeTransfer(_custodian,usdcAmount);");
  const assertion = body.indexOf("_assertSolvency();");
  if (!fn.header.includes("onlyDelegateCall") || transfer < 0 || assertion <= transfer) fail("module solvency predicate does not prove transfer-before-assertion");
}

function main() {
  const args = process.argv.slice(2);
  try {
    if (args.length === 1 && args[0] === "--source-predicate-bindings") {
      process.stdout.write(`${JSON.stringify(sourcePredicateBindingRows())}\n`);
      return;
    }
    if (args.length === 1 && args[0] === "--source-policy-binding") {
      process.stdout.write(`${JSON.stringify(sourcePolicyBindingRow())}\n`);
      return;
    }
    if (args.length === 1 && args[0] === "--source-policy-predicate-bindings") {
      process.stdout.write(`${JSON.stringify(sourcePolicyPredicateBindingRows())}\n`);
      return;
    }
    if ((args.length === 1 || args.length === 2) && args[0] === "--capture-audit") {
      captureAudit(args[1]);
      return;
    }
    if ((args.length === 1 || args.length === 2) && args[0] === "--reuse-audit") {
      const result = auditValidateReuse(args[1]);
      process.stdout.write(`${JSON.stringify(result)}\n`);
      if (result.redStages.length) process.exitCode = 1;
      return;
    }
    if (args.length === 1 && args[0] === "--preflight") {
      const inputs = verifyInputsMode();
      if (inputs.inputs.dependencyStatus.missing.length) {
        process.stdout.write(`${SENTINEL}_PREFLIGHT_PARTIAL roots=${inputs.inputs.manifest.sourceRoots.length} scripts=${inputs.inputs.manifest.publicScriptFiles.length} dependencyFiles=${inputs.inputs.dependencyStatus.expected} materialized=${inputs.inputs.dependencyStatus.materialized} semgrepConfigs=${CONFIGS.length}\n`);
        process.exitCode = 2;
        return;
      }
      process.stdout.write(`${SENTINEL}_PREFLIGHT_PASS roots=${inputs.inputs.manifest.sourceRoots.length} scripts=${inputs.inputs.manifest.publicScriptFiles.length} dependencyFiles=${inputs.inputs.dependencyStatus.expected} semgrepConfigs=${CONFIGS.length}\n`);
      return;
    }
    if (args.length === 1 && args[0] === "--static-controls") {
      process.stdout.write(`${JSON.stringify(runStaticControls())}\n`);
      return;
    }
    if (args.length === 1 && args[0] === "--compiler-selection-controls") {
      process.stdout.write(`${JSON.stringify(auditToolSelectionControls())}\n`);
      return;
    }
    if (args.length === 1 && args[0] === "--disjointness-controls") {
      process.stdout.write(`${JSON.stringify(runDisjointnessControls())}\n`);
      return;
    }
    if (args.length === 2 && args[0] === "--run" && CONFIGS.includes(args[1])) {
      runSemgrep(args[1]);
      return;
    }
    if (args.length === 3 && args[0] === "--validate-output" && CONFIGS.includes(args[1])) {
      const inputs = verifyInputsMode();
      if (inputs.inputs.dependencyStatus.missing.length) fail("cannot bind Semgrep output without the pinned dependency inputs materialized");
      const report = validateSemgrepOutput(args[1], readSemgrepOutput(args[2]), inputs);
      if (report.blockingFindings.length) fail(`Semgrep output contains ${report.blockingFindings.length} unrecognized public finding(s)`);
      process.stdout.write(`${SENTINEL}_OUTPUT_BOUND config=${args[1]} version=${report.version} targets=${report.scanned} rawFindings=${report.findings} recognized=${report.recognizedSourcePredicates.length} blocking=0 errors=0 skipped=0\n`);
      return;
    }
    fail("usage: check_semgrep_rule_coverage.js --preflight | --static-controls | --compiler-selection-controls | --disjointness-controls | --source-predicate-bindings | --source-policy-predicate-bindings | --source-policy-binding | --capture-audit [capture-dir] | --reuse-audit [capture-dir] | --run <config> | --validate-output <config> <json>");
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

main();
