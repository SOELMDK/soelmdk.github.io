#!/usr/bin/env node
/**
 * Builds a slim patchmypc-catalog.json from Patch My PC's full PatchMyPC.xml
 * SCUP/WSUS catalog export, for the Intune compliance report page to load
 * instead of parsing the full ~16 MB XML file in the browser.
 *
 * Node.js port of build-patchmypc-catalog.ps1 — PowerShell's array-return
 * semantics (functions silently unwrap nested single-element arrays when
 * returned via `return`/`+=`) made the recursive And/Or/Not distribution
 * logic unreliable. Plain JS arrays don't have that footgun, so this
 * mirrors the exact same algorithm faithfully.
 *
 * Mirrors the parsing/grouping logic in intune-signin.html's client-side
 * JS (parseTitle, extractArch, matcherReferencesArch, extractDisplayName
 * Groups, parsePatchMyPcCatalog) so the two stay in sync. If you change how
 * products are parsed/grouped in intune-signin.html, make the equivalent
 * change here too.
 *
 * Usage: node build-patchmypc-catalog.js [InputPath] [OutputPath]
 *   Defaults: PatchMyPC.xml -> patchmypc-catalog.json (same folder as script)
 *
 * Output: patchmypc-catalog.json — an array of
 *   { id, name, vendor, latestVersion, matchers: [ [ { comparison, data } ] ] }
 * where each entry in `matchers` is an AND-combined group of DisplayName
 * conditions (all conditions in a group must match); different groups are
 * OR alternatives.
 */

const fs = require("fs");
const path = require("path");
const { XMLParser } = require("fast-xml-parser");

const inputPath = process.argv[2] || path.join(__dirname, "PatchMyPC.xml");
const outputPath = process.argv[3] || path.join(__dirname, "patchmypc-catalog.json");

if (!fs.existsSync(inputPath)) {
  throw new Error(`Could not find ${inputPath}`);
}

console.log(`Loading ${inputPath} ...`);
const xmlText = fs.readFileSync(inputPath, "utf8");

// preserveOrder keeps every element as { tagName: [...children] } wrapped
// in an array-of-one-key objects, which also preserves duplicate sibling
// tags (e.g. multiple RegSz under the same parent) — critical for the
// recursive And/Or/Not walk below.
const parser = new XMLParser({
  removeNSPrefix: true,
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  preserveOrder: true,
  allowBooleanAttributes: true,
  // Patch My PC's matchers rely on exact whitespace in Data attributes
  // (e.g. `BeginsWith "7-Zip "` requires a trailing space to avoid
  // matching "7-ZipPro"-style names) — don't let the parser trim it.
  trimValues: false,
});
const doc = parser.parse(xmlText);

// --- preserveOrder tree helpers -------------------------------------------
// With preserveOrder:true, each node is an object like:
//   { "TagName": [ ...children ], ":@": { "@_Attr": "value", ... } }
// wrapped in an array. Text-only leaves have a "#text" key instead.
function tagName(node) {
  if (typeof node !== "object" || node === null) return null;
  for (const k of Object.keys(node)) {
    if (k !== ":@" && k !== "#text") return k;
  }
  return null;
}
function children(node) {
  const t = tagName(node);
  return t ? node[t] : [];
}
function attrs(node) {
  return node[":@"] || {};
}
function attr(node, name) {
  return attrs(node)[`@_${name}`];
}
function innerText(node) {
  let text = "";
  for (const child of children(node)) {
    if (Object.prototype.hasOwnProperty.call(child, "#text")) {
      text += String(child["#text"]);
    }
  }
  return text;
}

// Depth-first search for all elements with the given local tag name,
// anywhere under root (root itself excluded from the search start).
function findAllByLocalName(root, localName, results = []) {
  for (const child of children(root)) {
    if (tagName(child) === localName) results.push(child);
    findAllByLocalName(child, localName, results);
  }
  return results;
}
function findFirstByLocalName(root, localName) {
  for (const child of children(root)) {
    if (tagName(child) === localName) return child;
    const found = findFirstByLocalName(child, localName);
    if (found) return found;
  }
  return null;
}

// --- version helpers --------------------------------------------------
function toCompareParts(version) {
  if (!version) return [];
  return version.split(".").map((v) => parseInt(v, 10) || 0);
}
function compareVersions(a, b) {
  if (!a) return b ? -1 : 0;
  if (!b) return 1;
  const pa = toCompareParts(a);
  const pb = toCompareParts(b);
  const max = Math.max(pa.length, pb.length);
  for (let i = 0; i < max; i++) {
    const va = i < pa.length ? pa[i] : 0;
    const vb = i < pb.length ? pb[i] : 0;
    if (va !== vb) return va - vb;
  }
  return 0;
}

// Splits a title like "Microsoft OneDrive 26.113.0614.0004 (x64)" into
// name/version/suffix. Mirrors parseTitle() in intune-signin.html.
function parseTitle(title) {
  let suffix = null;
  const suffixMatch = title.match(/\(([^)]*)\)\s*$/);
  if (suffixMatch) suffix = suffixMatch[1];
  let s = title.replace(/\s*\([^)]*\)\s*$/, "");
  s = s.replace(/\s+Rev\d+$/i, "");
  const tokens = s.split(/\s+/);
  let versionIdx = -1;
  for (let i = tokens.length - 1; i >= 0; i--) {
    if (/^\d+(\.\d+){1,4}$/.test(tokens[i])) {
      versionIdx = i;
      break;
    }
  }
  if (versionIdx === -1) {
    return { name: s.trim(), version: null, suffix };
  }
  let nameTokens = tokens.slice(0, versionIdx);
  if (nameTokens.length > 0 && /^latest$/i.test(nameTokens[nameTokens.length - 1])) {
    nameTokens = nameTokens.slice(0, -1);
  }
  return { name: nameTokens.join(" ").trim(), version: tokens[versionIdx], suffix };
}

// Mirrors extractArch(): pulls an x86/x64/x32/arm64 token out of the
// title's trailing installer-type suffix (e.g. "EXE-x64" -> "x64").
function getArch(suffix) {
  if (!suffix) return null;
  for (const token of suffix.split(/[^A-Za-z0-9]+/)) {
    if (/^(x86|x64|x32|arm64)$/i.test(token)) return token.toLowerCase();
  }
  return null;
}

// Recursively evaluates a subtree for its DisplayName-matching semantics,
// returning a list of "alternative" condition groups: each group is a
// list of {comparison, data} conditions that must ALL be true (AND); the
// groups themselves are OR alternatives (any one group matching is
// enough). This correctly distributes AND over OR (e.g. an <lar:And>
// containing an <lar:Or> produces one alternative group per Or branch,
// each still combined with the And's other conditions) instead of
// flattening everything into a single AND group regardless of nesting.
//
// - RegSz (Value=DisplayName): one alternative, a single-condition group.
// - Any other leaf element (RegSzToVersion, RegDword, WindowsVersion,
//   etc.): contributes no DisplayName info, i.e. the identity element
//   (one alternative with an empty condition list) so it doesn't affect
//   AND-combination with its siblings.
// - Not: dropped entirely (see rationale below) — also the identity
//   element.
// - Or: the union of its children's alternatives (OR).
// - And / RegKeyLoop: the cross-product of its children's alternatives,
//   concatenating conditions within each combination (AND).
function getDisplayNameAlternatives(node) {
  const tag = tagName(node);
  switch (tag) {
    case "RegSz": {
      if (attr(node, "Value") === "DisplayName" && attr(node, "Data")) {
        return [[{ comparison: attr(node, "Comparison"), data: attr(node, "Data") }]];
      }
      return [[]];
    }
    case "Not": {
      // DisplayName conditions nested inside <lar:Not> are exclusions
      // (e.g. "Bria" AND NOT "Bria Enterprise", to keep the Enterprise
      // SKU's own product from also matching plain "Bria"). Since
      // EqualTo/BeginsWith/etc. conditions can never simultaneously equal
      // two different strings, a negated DisplayName check never actually
      // changes whether an unrelated positive check matches — so these
      // are dropped entirely (identity) rather than folded in as
      // impossible positive requirements.
      return [[]];
    }
    case "Or": {
      let alternatives = [];
      for (const child of children(node)) {
        if (!tagName(child)) continue;
        alternatives = alternatives.concat(getDisplayNameAlternatives(child));
      }
      if (alternatives.length === 0) return [[]];
      return alternatives;
    }
    default: {
      // And, RegKeyLoop, or anything else with children: AND-combine via
      // cross-product so nested Or branches are distributed correctly
      // instead of flattened away.
      let accumulated = [[]];
      for (const child of children(node)) {
        if (!tagName(child)) continue;
        const childAlternatives = getDisplayNameAlternatives(child);
        const combined = [];
        for (const existing of accumulated) {
          for (const alt of childAlternatives) {
            combined.push(existing.concat(alt));
          }
        }
        accumulated = combined;
      }
      return accumulated;
    }
  }
}

// Mirrors extractDisplayNameGroups(): builds matcher groups per
// RegKeyLoop by evaluating its And/Or/Not structure (via
// getDisplayNameAlternatives) instead of flattening every DisplayName
// condition in the loop into one AND group.
function getDisplayNameGroups(pkg) {
  const groups = [];
  for (const loop of findAllByLocalName(pkg, "RegKeyLoop")) {
    for (const alternative of getDisplayNameAlternatives(loop)) {
      if (alternative.length > 0) groups.push(alternative);
    }
  }
  return groups;
}

// Mirrors matcherReferencesArch(): true if any DisplayName condition
// explicitly mentions the given architecture as a whole word.
function matcherReferencesArch(groups, arch) {
  const pattern = new RegExp(`\\b${arch}\\b`, "i");
  for (const group of groups) {
    for (const condition of group) {
      if (condition.data && pattern.test(condition.data)) return true;
    }
  }
  return false;
}

// Mirrors guessVendor(): best-effort vendor label from the support/info URL.
function guessVendor(url) {
  if (!url) return "";
  try {
    const host = new URL(url).host.replace(/^www\./, "");
    const parts = host.split(".");
    const label = parts.length >= 2 ? parts[parts.length - 2] : parts[0];
    return label.charAt(0).toUpperCase() + label.slice(1);
  } catch {
    return "";
  }
}

const root = doc.find((n) => tagName(n) === "SystemsManagementCatalog");
if (!root) throw new Error("Could not find SystemsManagementCatalog root element");

const packages = findAllByLocalName(root, "SoftwareDistributionPackage");
console.log(`Found ${packages.length} packages. Parsing...`);

const productsByKey = new Map();

for (const pkg of packages) {
  const titleEl = findFirstByLocalName(pkg, "Title");
  const titleText = titleEl ? innerText(titleEl).trim() : "";
  if (!titleText) continue;

  const parsed = parseTitle(titleText);
  if (!parsed.name) continue;

  const groups = getDisplayNameGroups(pkg);
  if (groups.length === 0) continue; // no way to match installed apps to this package

  const arch = getArch(parsed.suffix);
  const splitByArch = arch && matcherReferencesArch(groups, arch);
  const displayName = splitByArch ? `${parsed.name} (${arch})` : parsed.name;
  const key = displayName.toLowerCase();

  if (!productsByKey.has(key)) {
    const infoUrlEl = findFirstByLocalName(pkg, "SupportUrl") || findFirstByLocalName(pkg, "MoreInfoUrl");
    productsByKey.set(key, {
      id: key,
      name: displayName,
      vendor: guessVendor(infoUrlEl ? innerText(infoUrlEl).trim() : ""),
      latestVersion: null,
      matchers: [],
      _sigs: new Set(),
    });
  }
  const product = productsByKey.get(key);

  for (const group of groups) {
    const sig = group
      .map((c) => `${c.comparison}:${(c.data || "").toLowerCase()}`)
      .sort()
      .join("|");
    if (!product._sigs.has(sig)) {
      product._sigs.add(sig);
      product.matchers.push(group);
    }
  }

  if (compareVersions(parsed.version, product.latestVersion) > 0) {
    product.latestVersion = parsed.version;
  }
}

const catalog = Array.from(productsByKey.values()).map((p) => ({
  id: p.id,
  name: p.name,
  vendor: p.vendor,
  latestVersion: p.latestVersion,
  matchers: p.matchers,
}));

console.log(`Writing ${catalog.length} products to ${outputPath} ...`);
fs.writeFileSync(outputPath, JSON.stringify(catalog), "utf8");

const rawSize = fs.statSync(inputPath).size;
const outSize = fs.statSync(outputPath).size;
console.log(
  `Done. ${(rawSize / 1024 / 1024).toFixed(1)} MB -> ${(outSize / 1024).toFixed(1)} KB (${((100 * outSize) / rawSize).toFixed(1)}% of original).`
);
