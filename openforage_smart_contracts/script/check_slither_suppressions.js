#!/usr/bin/env node

// Slither suppression gate.
//
// Keys suppressions by slither's `id` field — a SHA-256 content hash of the
// finding's detector + elements. The id stays stable when only line numbers
// shift (cosmetic code changes); it changes when the finding's semantic
// content changes. This is what makes the suppression mechanism robust:
// line-keyed suppressions silently drift every time a file grows.
//
// Each suppression must:
//   1. carry a stable `id` (40+ hex chars) plus a human `name` (for review),
//   2. carry the audit metadata: created, expires, rationale, owner,
//   3. not be expired,
//   4. not exceed max_suppression_days from creation,
//   5. match exactly one current slither finding by id.
//
// Each current finding must be claimed by exactly one suppression entry.

const fs = require("fs");

const RESULT_PATH = process.argv[2] || "/tmp/openforage-slither-results.json";
const SUPPRESSION_PATH = process.argv[3] || "slither_suppressions.json";
const SENTINEL = "OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37";
const MS_PER_DAY = 24 * 60 * 60 * 1000;
const ID_REGEX = /^[0-9a-f]{16,}$/;
const PROHIBITED_WAIVER_TEXT = [/placeholder/i, /pending\s+re-triage/i, /CI stays green/i];

function fail(message) {
  console.error(`${SENTINEL}_FAIL ${message}`);
  process.exit(1);
}

function readJson(path) {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    fail(`could not read JSON at ${path}: ${error.message}`);
  }
}

function summarize(detector) {
  const source = detector.elements?.[0]?.source_mapping || {};
  const file = source.filename_relative || source.filename || "?";
  const line = (source.lines || ["?"])[0];
  const name = detector.elements?.[0]?.name || "?";
  return `${detector.check}|${file}:${line}|${name}|id=${detector.id?.slice(0, 16) || "?"}`;
}

function validateSuppression(entry, index, maxSuppressionDays) {
  for (const field of ["detector", "file", "id", "name", "created", "expires", "rationale", "owner"]) {
    if (entry[field] === undefined || entry[field] === null || entry[field] === "") {
      fail(`suppression ${index} is missing required field ${field}`);
    }
  }
  if (!ID_REGEX.test(entry.id)) {
    fail(`suppression ${index} has malformed id ${entry.id} (expect hex, ≥16 chars)`);
  }
  const created = Date.parse(`${entry.created}T00:00:00Z`);
  const expires = Date.parse(`${entry.expires}T00:00:00Z`);
  if (Number.isNaN(created) || Number.isNaN(expires)) {
    fail(`suppression ${index} has invalid created/expires dates`);
  }
  if (expires < Date.now()) {
    fail(`suppression ${index} expired on ${entry.expires}`);
  }
  const maxExpiry = created + maxSuppressionDays * MS_PER_DAY;
  if (expires > maxExpiry) {
    fail(`suppression ${index} exceeds ${maxSuppressionDays} day maximum`);
  }
  const waiverText = `${entry.rationale} ${entry.owner}`;
  for (const pattern of PROHIBITED_WAIVER_TEXT) {
    if (pattern.test(waiverText)) {
      fail(`suppression ${index} contains prohibited non-final waiver text matching ${pattern}`);
    }
  }
}

const result = readJson(RESULT_PATH);
const suppressionFile = readJson(SUPPRESSION_PATH);

if (result.success !== true) {
  fail("slither JSON did not report success=true");
}
if (!Array.isArray(result.results?.detectors)) {
  fail("slither JSON is missing results.detectors array");
}

if (suppressionFile.openforage_sentinel !== "OPENFORAGE_SLITHER_SUPPRESSIONS_R37") {
  fail("slither_suppressions.json sentinel mismatch");
}

const maxSuppressionDays = suppressionFile.max_suppression_days || 180;
const suppressions = suppressionFile.suppressions || [];
const suppressionById = new Map();
for (const [index, entry] of suppressions.entries()) {
  validateSuppression(entry, index, maxSuppressionDays);
  if (suppressionById.has(entry.id)) {
    fail(`suppression ${index} duplicates id ${entry.id} (already used at index ${suppressionById.get(entry.id)})`);
  }
  suppressionById.set(entry.id, index);
}

const detectors = result.results.detectors;
const findingIds = new Set(detectors.map((d) => d.id));

// Real audit gaps: findings present in the current scan that no suppression
// claims by id. Line shifts do NOT trigger this — id is content-stable.
const unsuppressed = detectors.filter((d) => !suppressionById.has(d.id));

// Stale suppressions: suppressions that point at a finding id no longer
// produced by the scan. The code may have been deleted, reformatted into a
// new finding shape, or the detector may have been disabled. Either way the
// suppression no longer suppresses anything and should be removed or
// re-keyed by the audit team.
const stale = [...suppressionById.entries()]
  .filter(([id]) => !findingIds.has(id))
  .map(([id, index]) => ({ id, index, entry: suppressions[index] }));

if (unsuppressed.length > 0) {
  for (const detector of unsuppressed) {
    console.error(`unsuppressed: ${summarize(detector)}`);
  }
}
if (stale.length > 0) {
  for (const { id, index, entry } of stale) {
    console.error(`stale: suppression[${index}] ${entry.detector}|${entry.file}|${entry.name} id=${id.slice(0, 16)} no longer matches any finding`);
  }
}

if (unsuppressed.length > 0 || stale.length > 0) {
  fail(`unsuppressed=${unsuppressed.length} stale=${stale.length} total_findings=${detectors.length} total_suppressions=${suppressions.length}`);
}

console.log(`${SENTINEL}_PASS detectors=${detectors.length} suppressions=${suppressions.length}`);
