#!/usr/bin/env node
/*
 * OPENFORAGE_SIMPLIFY_REGRESSION_GUARD_R37
 *
 * Fails if a simplify pass removes/changes a public selector, increases deployed
 * bytecode size, or drops `_assertSolvency` / `revert` sentinels without an
 * explicit entry in simplify_waivers.json.
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const BASELINE_PATH = path.join(ROOT, "test", "audit", "simplify_baseline.json");
const WAIVER_PATH = path.join(ROOT, "simplify_waivers.json");

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function artifactPath(entry) {
  return path.join(ROOT, "out", path.basename(entry.file), `${entry.contract}.json`);
}

function selectorSummary(entry) {
  const artifact = readJson(artifactPath(entry));
  const lines = Object.entries(artifact.methodIdentifiers || {})
    .map(([signature, selector]) => `${signature}:${selector}`)
    .sort();
  return {
    count: lines.length,
    hash: crypto.createHash("sha256").update(lines.join("\n")).digest("hex"),
    lines,
    bytecodeBytes: (artifact.deployedBytecode.object || "").length / 2,
  };
}

function sentinelCount(entry) {
  const source = fs.readFileSync(path.join(ROOT, entry.file), "utf8");
  return (source.match(/_assertSolvency|revert\s/g) || []).length;
}

function waiverMap(waivers) {
  const map = new Map();
  for (const waiver of waivers.waivers || []) {
    map.set(`${waiver.file}:${waiver.contract}`, waiver);
  }
  return map;
}

function allowed(waiver, key) {
  return Number((waiver && waiver[key]) || 0);
}

function allowedSelectorChange(waiver, selectors) {
  if (!waiver) return {allowed: false, reason: "missing waiver"};

  const expectedCount = waiver.allowSelectorCount;
  const expectedHash = waiver.allowSelectorSetHash;
  const expectedAdditions = waiver.allowSelectorAdditions || [];

  if (expectedCount === undefined || expectedHash === undefined) {
    return {allowed: false, reason: "missing allowSelectorCount/allowSelectorSetHash"};
  }
  if (Number(expectedCount) !== selectors.count || String(expectedHash) !== selectors.hash) {
    return {
      allowed: false,
      reason:
        `selector waiver expected current ${expectedCount}/${expectedHash}, ` +
        `got ${selectors.count}/${selectors.hash}`,
    };
  }
  if (!Array.isArray(expectedAdditions) || expectedAdditions.length === 0) {
    return {allowed: false, reason: "missing allowSelectorAdditions"};
  }

  const current = new Set(selectors.lines);
  const missing = expectedAdditions.filter((selector) => !current.has(selector));
  if (missing.length > 0) {
    return {allowed: false, reason: `declared selector additions missing: ${missing.join(", ")}`};
  }

  return {allowed: true, reason: "exact selector waiver matched"};
}

function main() {
  const baseline = readJson(BASELINE_PATH);
  const waivers = readJson(WAIVER_PATH);
  const byContract = waiverMap(waivers);
  const failures = [];
  const results = [];

  if (baseline.openforage_sentinel !== "OPENFORAGE_SIMPLIFY_REGRESSION_BASELINE_R37") {
    failures.push("baseline sentinel missing or changed");
  }
  if (waivers.openforage_sentinel !== "OPENFORAGE_SIMPLIFY_WAIVERS_R37") {
    failures.push("waiver sentinel missing or changed");
  }

  for (const entry of baseline.contracts) {
    const key = `${entry.file}:${entry.contract}`;
    const waiver = byContract.get(key);
    const selectors = selectorSummary(entry);
    const currentSentinels = sentinelCount(entry);

    if (selectors.count !== entry.selectorCount || selectors.hash !== entry.selectorSetHash) {
      const selectorWaiver = allowedSelectorChange(waiver, selectors);
      if (!selectorWaiver.allowed) {
        failures.push(
          `${key}: public selector set changed. baseline count/hash ${entry.selectorCount}/${entry.selectorSetHash}; ` +
            `current ${selectors.count}/${selectors.hash}. No selector changes are allowed during simplify ` +
            `without an exact waiver (${selectorWaiver.reason}).`
        );
      }
    }

    const bytecodeGrowth = selectors.bytecodeBytes - entry.bytecodeBytes;
    if (bytecodeGrowth > allowed(waiver, "allowBytecodeGrowthBytes")) {
      failures.push(
        `${key}: deployed bytecode grew by ${bytecodeGrowth} bytes without waiver ` +
          `(baseline ${entry.bytecodeBytes}, current ${selectors.bytecodeBytes}).`
      );
    }

    const sentinelDrop = entry.assertSolvencyOrRevertCount - currentSentinels;
    if (sentinelDrop > allowed(waiver, "allowAssertSolvencyOrRevertDrop")) {
      failures.push(
        `${key}: _assertSolvency/revert sentinel count dropped by ${sentinelDrop} without waiver ` +
          `(baseline ${entry.assertSolvencyOrRevertCount}, current ${currentSentinels}).`
      );
    }

    results.push({
      file: entry.file,
      contract: entry.contract,
      selectorCount: selectors.count,
      selectorSetHash: selectors.hash,
      bytecodeBytes: selectors.bytecodeBytes,
      assertSolvencyOrRevertCount: currentSentinels,
    });
  }

  if (failures.length > 0) {
    console.error("SIMPLIFY_REGRESSION_GUARD_FAIL");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }

  if (process.argv.includes("--json")) {
    console.log(JSON.stringify({status: "pass", contracts: results.length, results}));
  } else {
    console.log(`SIMPLIFY_REGRESSION_GUARD_PASS contracts=${results.length}`);
  }
}

main();
