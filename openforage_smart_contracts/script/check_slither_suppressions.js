#!/usr/bin/env node

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

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
      component: "check_slither_suppressions",
      function: "writeDiagnosticError",
      file: "openforage_smart_contracts/script/check_slither_suppressions.js",
      line: 27,
      information,
    })}\n`,
  );
}

const RESULT_PATH = process.argv[2] || "/tmp/openforage-slither-results.json";
const SUPPRESSION_PATH = process.argv[3] || "slither_suppressions.json";
const SENTINEL = "OPENFORAGE_SLITHER_SUPPRESSION_GATE_R37";
const MS_PER_DAY = 24 * 60 * 60 * 1000;
const ID_REGEX = /^[0-9a-f]{16,}$/;
const PROHIBITED_WAIVER_TEXT = [/placeholder/i, /pending\s+re-triage/i, /CI stays green/i];

function fail(message) {
  writeDiagnosticError(`${SENTINEL}_FAIL ${message}`);
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
  for (const field of ["detector", "file", "name", "created", "expires", "rationale", "owner"]) {
    if (entry[field] === undefined || entry[field] === null || entry[field] === "") {
      fail(`suppression ${index} is missing required field ${field}`);
    }
  }
  const hasIdDigest = entry.idDigest !== undefined && entry.idDigest !== null && entry.idDigest !== "";
  const hasStableIdentity = entry.stableIdentity !== undefined && entry.stableIdentity !== null;
  if (hasIdDigest === hasStableIdentity) {
    fail(`suppression ${index} must have exactly one selector: idDigest or stableIdentity`);
  }
  if (hasIdDigest && !ID_REGEX.test(entry.idDigest)) {
    fail(`suppression ${index} has malformed id ${entry.idDigest} (expect hex, ≥16 chars)`);
  }
  if (hasStableIdentity) {
    validateStableIdentity(entry, index);
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

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function safeSourcePath(file) {
  if (typeof file !== "string" || file.length === 0 || path.isAbsolute(file) ||
    file.split(/[\\/]/).includes("..")) {
    fail(`stable identity has unsafe source file ${file}`);
  }
  const root = path.resolve(__dirname, "..");
  const source = path.resolve(root, file);
  if (!source.startsWith(`${root}${path.sep}`)) {
    fail(`stable identity source escapes contracts root: ${file}`);
  }
  return source;
}

function validateStableIdentity(entry, index) {
  const identity = entry.stableIdentity;
  const fields = ["detector", "contract", "function", "file", "rootStart", "rootLength", "functionSha256", "elementIdentitySha256"];
  for (const field of fields) {
    if (identity[field] === undefined || identity[field] === null || identity[field] === "") {
      fail(`suppression ${index} stableIdentity is missing ${field}`);
    }
  }
  if (identity.detector !== entry.detector || identity.file !== entry.file) {
    fail(`suppression ${index} stableIdentity detector/file differs from its entry scope`);
  }
  if (!Number.isSafeInteger(identity.rootStart) || identity.rootStart < 0 ||
    !Number.isSafeInteger(identity.rootLength) || identity.rootLength <= 0) {
    fail(`suppression ${index} stableIdentity has malformed root source span`);
  }
  for (const field of ["functionSha256", "elementIdentitySha256"]) {
    if (!/^[0-9a-f]{64}$/.test(identity[field])) {
      fail(`suppression ${index} stableIdentity has malformed ${field}`);
    }
  }
  const source = fs.readFileSync(safeSourcePath(identity.file));
  const end = identity.rootStart + identity.rootLength;
  if (end > source.length || sha256(source.subarray(identity.rootStart, end)) !== identity.functionSha256) {
    fail(`suppression ${index} stableIdentity function bytes do not match ${identity.file}:${identity.rootStart}+${identity.rootLength}`);
  }
}

function elementIdentity(element) {
  const mapping = element.source_mapping || {};
  const filename = mapping.filename_relative || mapping.filename || "";
  return {
    type: String(element.type || ""),
    expressionOrName: String(element.name || mapping.content || ""),
    file: String(filename).replaceAll("\\", "/"),
    sourceMapping: {
      start: Number.isSafeInteger(Number(mapping.start)) ? Number(mapping.start) : null,
      length: Number.isSafeInteger(Number(mapping.length)) ? Number(mapping.length) : null,
      lines: Array.isArray(mapping.lines) ? mapping.lines.map(Number) : [],
      startingColumn: Number.isSafeInteger(Number(mapping.starting_column)) ? Number(mapping.starting_column) : null,
      endingColumn: Number.isSafeInteger(Number(mapping.ending_column)) ? Number(mapping.ending_column) : null,
    },
  };
}

function elementIdentityDigest(finding) {
  const identities = (finding.elements || []).map(elementIdentity);
  identities.sort((left, right) => {
    const leftText = JSON.stringify(left);
    const rightText = JSON.stringify(right);
    return leftText < rightText ? -1 : leftText > rightText ? 1 : 0;
  });
  return sha256(Buffer.from(JSON.stringify(identities), "utf8"));
}

function rootFunctionIdentity(finding) {
  const root = finding.elements?.[0];
  const mapping = root?.source_mapping || {};
  const parent = root?.type_specific_fields?.parent || {};
  const canonical = /^Reentrancy in ([^.()]+)\.([A-Za-z_$][\w$]*\([^)]*\))\s+\(/.exec(String(finding.description || ""));
  return {
    contract: String(parent.name || ""),
    function: canonical && canonical[1] === parent.name && canonical[2].startsWith(`${root?.name}(`) ? canonical[2] : "",
    file: String(mapping.filename_relative || mapping.filename || "").replaceAll("\\", "/"),
    rootStart: Number(mapping.start),
    rootLength: Number(mapping.length),
  };
}

function matchesStableIdentity(finding, identity) {
  if (finding.check !== identity.detector) return false;
  const root = rootFunctionIdentity(finding);
  return root.contract === identity.contract && root.function === identity.function &&
    root.file === identity.file && root.rootStart === identity.rootStart &&
    root.rootLength === identity.rootLength && elementIdentityDigest(finding) === identity.elementIdentitySha256;
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
  if (entry.idDigest === undefined || entry.idDigest === null || entry.idDigest === "") continue;
  if (suppressionById.has(entry.idDigest)) {
    fail(`suppression ${index} duplicates id ${entry.idDigest} (already used at index ${suppressionById.get(entry.idDigest)})`);
  }
  suppressionById.set(entry.idDigest, index);
}

const detectors = result.results.detectors;
const findingIds = new Set(detectors.map((d) => d.id));
const stableClaims = new Set();
const idClaims = new Set(detectors.filter((finding) => suppressionById.has(finding.id)));
for (const [index, entry] of suppressions.entries()) {
  if (!entry.stableIdentity) continue;
  const matches = detectors.filter((finding) => matchesStableIdentity(finding, entry.stableIdentity));
  if (matches.length !== 1) {
    fail(`suppression ${index} stableIdentity matched ${matches.length} findings (expect exactly one)`);
  }
  if (idClaims.has(matches[0]) || stableClaims.has(matches[0])) {
    fail(`suppression ${index} stableIdentity duplicates another suppression claim`);
  }
  stableClaims.add(matches[0]);
}

const unsuppressed = detectors.filter((finding) => !suppressionById.has(finding.id) && !stableClaims.has(finding));
const stale = [...suppressionById.entries()]
  .filter(([id]) => !findingIds.has(id))
  .map(([id, index]) => ({ id, index, entry: suppressions[index] }));

if (unsuppressed.length > 0) {
  for (const detector of unsuppressed) {
    writeDiagnosticError(`unsuppressed: ${summarize(detector)}`);
  }
}
if (stale.length > 0) {
  for (const { id, index, entry } of stale) {
    writeDiagnosticError(`stale: suppression[${index}] ${entry.detector}|${entry.file}|${entry.name} id=${id.slice(0, 16)} no longer matches any finding`);
  }
}

if (unsuppressed.length > 0 || stale.length > 0) {
  fail(`unsuppressed=${unsuppressed.length} stale=${stale.length} total_findings=${detectors.length} total_suppressions=${suppressions.length}`);
}

console.log(`${SENTINEL}_PASS detectors=${detectors.length} suppressions=${suppressions.length}`);
