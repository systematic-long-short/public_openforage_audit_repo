#!/usr/bin/env node

/*
 * OPENFORAGE_SEMGREP_RULE_COVERAGE
 *
 * Fails when a Semgrep include glob resolves to zero tracked files or when
 * the renamed RISKUSDVault audit rules drift back to retired RISKUSDC names.
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

const SENTINEL = "OPENFORAGE_SEMGREP_RULE_COVERAGE";
const PROJECT_ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.resolve(PROJECT_ROOT, process.argv[2] || ".semgrep/openforage.yml");
const MODULES_DIR = path.join(PROJECT_ROOT, "src", "modules");

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
      component: "check_semgrep_rule_coverage",
      function: "writeDiagnosticError",
      file: "openforage_smart_contracts/script/check_semgrep_rule_coverage.js",
      line: 23,
      information,
    })}\n`,
  );
}

function fail(message) {
  writeDiagnosticError(`${SENTINEL}_FAIL ${message}`);
  process.exit(1);
}

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch (error) {
    fail(`could not read ${filePath}: ${error.message}`);
  }
}

function escapeRegExpChar(char) {
  return /[\\^$+?.()|[\]{}]/.test(char) ? `\\${char}` : char;
}

function globToRegExp(glob) {
  let pattern = "^";

  for (let i = 0; i < glob.length;) {
    if (glob.startsWith("**/", i)) {
      pattern += "(?:.*/)?";
      i += 3;
    } else if (glob.startsWith("**", i)) {
      pattern += ".*";
      i += 2;
    } else if (glob[i] === "*") {
      pattern += "[^/]*";
      i += 1;
    } else if (glob[i] === "?") {
      pattern += "[^/]";
      i += 1;
    } else {
      pattern += escapeRegExpChar(glob[i]);
      i += 1;
    }
  }

  pattern += "$";
  return new RegExp(pattern);
}

const SKIPPED_DIRECTORIES = new Set([
  "lib",
  "out",
  "cache",
  ".venv",
  "node_modules",
  "broadcast",
  ".tmp",
  ".git",
]);

function collectFiles(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      if (!SKIPPED_DIRECTORIES.has(entry.name)) {
        files.push(...collectFiles(entryPath));
      }
    } else if (entry.isFile()) {
      files.push(path.relative(PROJECT_ROOT, entryPath));
    }
  }
  return files;
}

function projectFiles() {
  try {
    return collectFiles(PROJECT_ROOT);
  } catch (error) {
    fail(`could not list project files: ${error.message}`);
  }
}

function functionBody(source, functionName) {
  const signature = new RegExp(`function\\s+${functionName}\\s*\\(`, "g");
  const match = signature.exec(source);
  if (!match) return null;

  const open = source.indexOf("{", match.index);
  if (open === -1) return null;

  let depth = 0;
  for (let i = open; i < source.length; i += 1) {
    if (source[i] === "{") depth += 1;
    if (source[i] === "}") depth -= 1;
    if (depth === 0) return source.slice(match.index, i + 1);
  }
  return null;
}

function moduleFunctionBody(functionName) {
  if (!fs.existsSync(MODULES_DIR)) return null;
  for (const filePath of collectFiles(MODULES_DIR)) {
    if (!filePath.endsWith(".sol")) continue;
    const body = functionBody(readText(path.join(PROJECT_ROOT, filePath)), functionName);
    if (body) return body;
  }
  return null;
}

function resolveDelegatedSource(source, functionName) {
  const body = functionBody(source, functionName);
  if (!body || !body.includes("_delegateToModule()")) return source;

  const moduleBody = moduleFunctionBody(functionName);
  if (!moduleBody) {
    fail(`${functionName} delegates to a module body that was not found under src/modules`);
  }

  const flattened = `${body.slice(0, body.indexOf("{"))}{${moduleBody.slice(
    moduleBody.indexOf("{") + 1,
    moduleBody.lastIndexOf("}"),
  )}}`;
  return source.replace(body, flattened);
}

function extractRule(config, id) {
  const lines = config.split(/\r?\n/);
  const start = lines.findIndex((line) => line === `  - id: ${id}`);
  if (start === -1) {
    fail(`missing semgrep rule ${id}`);
  }

  let end = lines.length;
  for (let i = start + 1; i < lines.length; i += 1) {
    if (lines[i].startsWith("  - id: ")) {
      end = i;
      break;
    }
  }

  return lines.slice(start, end).join("\n");
}

function extractIncludeGlobs(config) {
  const lines = config.split(/\r?\n/);
  const globs = [];
  let inInclude = false;

  for (const line of lines) {
    if (/^\s+include:\s*$/.test(line)) {
      inInclude = true;
      continue;
    }

    if (!inInclude) {
      continue;
    }

    const match = line.match(/^\s*-\s*["']([^"']+)["']\s*$/);
    if (match) {
      globs.push(match[1]);
      continue;
    }

    if (line.trim() === "") {
      continue;
    }

    inInclude = false;
  }

  return globs;
}

function extractPatternRegex(rule, id) {
  const match = rule.match(/pattern-regex:\s*'([^']+)'/);
  if (!match) {
    fail(`missing pattern-regex for ${id}`);
  }
  return match[1];
}

function toJavaScriptRegExp(semgrepRegex) {
  const dotAll = semgrepRegex.startsWith("(?s)");
  const pattern = dotAll ? semgrepRegex.slice("(?s)".length) : semgrepRegex;
  try {
    return new RegExp(pattern, dotAll ? "s" : "");
  } catch (error) {
    fail(`could not compile semgrep regex as JavaScript RegExp: ${error.message}`);
  }
}

function assertNoRetiredRiskusdc(rule, id) {
  for (const retired of ["RISKUSDCVault", "riskusdcVault"]) {
    if (rule.includes(retired)) {
      fail(`${id} still contains retired token ${retired}`);
    }
  }
}

function assertSolvencyRuleTargetsLiveGlob(config) {
  const id = "openforage-no-skip-of-assert-solvency";
  const rule = extractRule(config, id);
  if (!rule.includes('        - "**/src/RISKUSDVault.sol"')) {
    fail(`${id} must include the live **/src/RISKUSDVault.sol glob`);
  }
  if (rule.includes("RISKUSDCVault.sol")) {
    fail(`${id} still targets retired RISKUSDCVault.sol`);
  }
}

function assertTrustSetterRegexMatchesLivePendingSetterMutation(config) {
  const id = "openforage-no-onlyOwner-on-trust-sensitive-setter";
  const rule = extractRule(config, id);
  assertNoRetiredRiskusdc(rule, id);

  for (const token of ["RISKUSDVault", "riskusdVault"]) {
    if (!rule.includes(token)) {
      fail(`${id} is missing live token ${token}`);
    }
  }

  const source = resolveDelegatedSource(
    readText(path.join(PROJECT_ROOT, "src", "RISKUSDVault.sol")),
    "setCustodian",
  );
  const liveLine = "_pendingCustodian = custodian_;";
  if (!source.includes("function setCustodian(address custodian_)")) {
    fail("RISKUSDVault live setCustodian signature not found");
  }
  if (!source.includes(liveLine)) {
    fail("RISKUSDVault live custodian pending assignment not found");
  }

  const mutatedSource = source.replace(liveLine, "_custodian = custodian_;");
  const regex = toJavaScriptRegExp(extractPatternRegex(rule, id));
  if (!regex.test(mutatedSource)) {
    fail(`${id} regex does not match a direct-assignment mutation of live setCustodian`);
  }
}

function assertAllowlistGateRuleTargetsLiveGlob(config) {
  const id = "openforage-allowlist-gate-missing-modifier";
  const rule = extractRule(config, id);
  if (!rule.includes('        - "**/src/**/*.sol"')) {
    fail(`${id} must include the **/src/**/*.sol glob`);
  }
  const selectors = [
    "transfer(address,uint256)",
    "approve(address,uint256)",
    "transferFrom(address,address,uint256)",
  ];
  for (const contract of ["RISKUSD", "atRISKUSD", "ForageToken"]) {
    for (const selector of selectors) {
      if (!rule.includes(`${contract}.${selector}`)) {
        fail(`${id} exempt allowlist is missing ${contract}.${selector}`);
      }
    }
  }
}

function assertGlobsResolve(config) {
  const files = projectFiles();
  const globs = extractIncludeGlobs(config);
  if (globs.length === 0) {
    fail("semgrep config has no paths.include globs to verify");
  }

  for (const glob of globs) {
    const regex = globToRegExp(glob);
    const matches = files.filter((file) => regex.test(file));
    if (matches.length === 0) {
      fail(`include glob ${glob} resolves to zero project files`);
    }
    console.log(`${SENTINEL}_GLOB glob=${glob} matches=${matches.length}`);
  }
}

const config = readText(CONFIG_PATH);
assertSolvencyRuleTargetsLiveGlob(config);
assertTrustSetterRegexMatchesLivePendingSetterMutation(config);
assertAllowlistGateRuleTargetsLiveGlob(config);
assertGlobsResolve(config);

console.log(`${SENTINEL}_PASS config=${path.relative(PROJECT_ROOT, CONFIG_PATH)}`);
