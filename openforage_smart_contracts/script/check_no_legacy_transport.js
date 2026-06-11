#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function findRoots() {
  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, "foundry.toml")) && fs.existsSync(path.join(cwd, "src"))) {
    return { contractRoot: cwd, repoRoot: path.resolve(cwd, "..") };
  }
  const nested = path.join(cwd, "openforage_smart_contracts");
  if (fs.existsSync(path.join(nested, "foundry.toml")) && fs.existsSync(path.join(nested, "src"))) {
    return { contractRoot: nested, repoRoot: cwd };
  }
  throw new Error("run from repo root or openforage_smart_contracts");
}

const { contractRoot, repoRoot } = findRoots();

const SCAN_TARGETS = [
  { base: contractRoot, rel: "src" },
  { base: contractRoot, rel: "test/hyperliquid" },
  { base: contractRoot, rel: "script" },
  { base: contractRoot, rel: "remappings.txt" },
  { base: contractRoot, rel: "foundry.toml" },
  { base: repoRoot, rel: "documentation/ccip" },
  { base: repoRoot, rel: "documentation/deployment" },
  { base: repoRoot, rel: "plans/smart_contracts" },
  { base: repoRoot, rel: "web/src/contracts" },
  { base: repoRoot, rel: "src/contract_keeper_service" },
  { base: repoRoot, rel: "scripts/keeper" },
];

const TEXT_EXTENSIONS = new Set([
  ".js",
  ".json",
  ".md",
  ".sol",
  ".toml",
  ".txt",
  ".ts",
  ".tsx",
  ".yaml",
  ".yml",
]);

const SKIP_DIRS = new Set([".git", "broadcast", "cache", "node_modules", "out"]);
const SKIP_FILES = new Set([
  "openforage_smart_contracts/script/check_no_legacy_transport.js",
  "openforage_smart_contracts/test/hyperliquid/HLLegacyTransportStatic.t.sol",
]);

const FORBIDDEN = [
  { id: "LayerZero", re: /LayerZero/g },
  { id: "layerzero", re: /layerzero/g },
  { id: "@layerzerolabs", re: /@layerzerolabs/g },
  { id: "LayerZero-v2", re: /LayerZero-v2/g },
  { id: "lzReceive", re: /\blzReceive\b/g },
  { id: "ILayerZero", re: /\bILayerZero[A-Za-z0-9_]*/g },
  { id: "MessagingParams", re: /\bMessagingParams\b/g },
  { id: "MessagingFee", re: /\bMessagingFee\b/g },
  { id: "lzEndpoint", re: /\blzEndpoint\b/g },
  { id: "endpointV2", re: /\bendpointV2\b/g },
  { id: "srcEid", re: /\bsrcEid\b/g },
  { id: "dstEid", re: /\bdstEid\b/g },
  { id: "hyperEvmEid", re: /\bhyperEvmEid\b/g },
];

function isTextFile(filePath) {
  return TEXT_EXTENSIONS.has(path.extname(filePath));
}

function collectFiles(absPath, files) {
  if (!fs.existsSync(absPath)) return;
  const stat = fs.statSync(absPath);
  if (stat.isFile()) {
    if (isTextFile(absPath)) files.push(absPath);
    return;
  }
  if (!stat.isDirectory()) return;

  const entries = fs.readdirSync(absPath, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory() && SKIP_DIRS.has(entry.name)) continue;
    collectFiles(path.join(absPath, entry.name), files);
  }
}

function lineAndColumn(source, index) {
  let line = 1;
  let column = 1;
  for (let i = 0; i < index; i += 1) {
    if (source.charCodeAt(i) === 10) {
      line += 1;
      column = 1;
    } else {
      column += 1;
    }
  }
  return { line, column };
}

const files = [];
for (const target of SCAN_TARGETS) {
  collectFiles(path.join(target.base, target.rel), files);
}
const scannedFiles = files.filter((file) => !SKIP_FILES.has(path.relative(repoRoot, file)));

const matches = [];
for (const file of scannedFiles.sort()) {
  const text = fs.readFileSync(file, "utf8");
  for (const pattern of FORBIDDEN) {
    pattern.re.lastIndex = 0;
    let match;
    while ((match = pattern.re.exec(text)) !== null) {
      const loc = lineAndColumn(text, match.index);
      matches.push({
        file: path.relative(repoRoot, file),
        line: loc.line,
        column: loc.column,
        pattern: pattern.id,
        value: match[0],
      });
    }
  }
}

const layerZeroLibPath = path.join(contractRoot, "lib", "LayerZero-v2");
if (fs.existsSync(layerZeroLibPath)) {
  matches.push({
    file: path.relative(repoRoot, layerZeroLibPath),
    line: 1,
    column: 1,
    pattern: "LayerZero-v2",
    value: "dependency directory present",
  });
}

const result = {
  sentinel: matches.length === 0 ? "NO_LEGACY_TRANSPORT_PASS" : "NO_LEGACY_TRANSPORT_FAIL",
  filesScanned: scannedFiles.length,
  targetsScanned: SCAN_TARGETS.length,
  forbiddenPatterns: FORBIDDEN.length,
  matches: matches.length,
  details: matches.slice(0, 50),
};

const output = JSON.stringify(result);
if (matches.length > 0) {
  console.error(output);
  process.exit(1);
}

console.log(output);
