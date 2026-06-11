#!/usr/bin/env node

/*
 * OPENFORAGE_SEMGREP_RULE_COVERAGE
 *
 * Fails when a Semgrep include glob resolves to zero tracked files or when
 * the renamed RISKUSDVault audit rules drift back to retired RISKUSDC names.
 */

const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

const SENTINEL = "OPENFORAGE_SEMGREP_RULE_COVERAGE";
const PROJECT_ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.resolve(PROJECT_ROOT, process.argv[2] || ".semgrep/openforage.yml");

function fail(message) {
  console.error(`${SENTINEL}_FAIL ${message}`);
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

function trackedFiles() {
  try {
    return childProcess
      .execFileSync("git", ["ls-files"], { cwd: PROJECT_ROOT, encoding: "utf8" })
      .split(/\r?\n/)
      .filter(Boolean);
  } catch (error) {
    fail(`could not list tracked files: ${error.message}`);
  }
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

  const source = readText(path.join(PROJECT_ROOT, "src", "RISKUSDVault.sol"));
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

function assertGlobsResolve(config) {
  const files = trackedFiles();
  const globs = extractIncludeGlobs(config);
  if (globs.length === 0) {
    fail("semgrep config has no paths.include globs to verify");
  }

  for (const glob of globs) {
    const regex = globToRegExp(glob);
    const matches = files.filter((file) => regex.test(file));
    if (matches.length === 0) {
      fail(`include glob ${glob} resolves to zero tracked files`);
    }
    console.log(`${SENTINEL}_GLOB glob=${glob} matches=${matches.length}`);
  }
}

const config = readText(CONFIG_PATH);
assertSolvencyRuleTargetsLiveGlob(config);
assertTrustSetterRegexMatchesLivePendingSetterMutation(config);
assertGlobsResolve(config);

console.log(`${SENTINEL}_PASS config=${path.relative(PROJECT_ROOT, CONFIG_PATH)}`);
