#!/usr/bin/env node
// Generate the tracked CHANGELOG.md from the app's own source of truth,
// WhatsNewService.swift's `bundled` array — so the repository record and the
// in-app "What's New" panel never drift apart.
//
//   node scripts/gen-releases.mjs          # rewrite CHANGELOG.md in place
//   node scripts/gen-releases.mjs --check  # exit 1 if CHANGELOG.md is stale

import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SWIFT = join(ROOT, 'NotchFlow/Sources/WhatsNewService.swift');
const CHANGELOG = join(ROOT, 'CHANGELOG.md');

// --- parse Swift -----------------------------------------------------------

// Pull the `bundled` literal: from `let bundled: [Entry] = [` to its matching `]`.
function extractBundled(src) {
  const m = src.match(/bundled\s*:\s*\[Entry\]\s*=\s*\[/);
  if (!m) throw new Error('could not find `bundled: [Entry] = [` in WhatsNewService.swift');
  let i = src.indexOf('[', m.index + m[0].length - 1);
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if (c === '[') depth++;
    else if (c === ']') { depth--; if (depth === 0) return src.slice(i + 1, j); }
  }
  throw new Error('unbalanced brackets in bundled array');
}

// Decode a Swift string literal body (between the quotes): \" \\ \n \t etc.
function decodeSwiftString(body) {
  let out = '';
  for (let i = 0; i < body.length; i++) {
    if (body[i] === '\\' && i + 1 < body.length) {
      const n = body[++i];
      out += n === 'n' ? '\n' : n === 't' ? '\t' : n; // \" \\ \( etc → the char itself
    } else {
      out += body[i];
    }
  }
  return out;
}

// All "..."-delimited string literals inside a chunk, in order, Swift-escaping aware.
function stringsIn(chunk) {
  const res = [];
  const re = /"((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(chunk))) res.push(decodeSwiftString(m[1]));
  return res;
}

// The labelled array after `features:` / `fixes:` up to the next label or end.
function listField(entryBody, label) {
  const re = new RegExp(label + '\\s*:\\s*\\[');
  const m = entryBody.match(re);
  if (!m) return [];
  let i = entryBody.indexOf('[', m.index + m[0].length - 1);
  let depth = 0;
  for (let j = i; j < entryBody.length; j++) {
    if (entryBody[j] === '[') depth++;
    else if (entryBody[j] === ']') { depth--; if (depth === 0) return stringsIn(entryBody.slice(i + 1, j)); }
  }
  return [];
}

// Split the bundled body into per-Entry(...) chunks (handles nested brackets).
function entryChunks(body) {
  const chunks = [];
  const re = /Entry\s*\(/g;
  let m;
  while ((m = re.exec(body))) {
    let i = body.indexOf('(', m.index + m[0].length - 1);
    let depth = 0;
    for (let j = i; j < body.length; j++) {
      if (body[j] === '(') depth++;
      else if (body[j] === ')') { depth--; if (depth === 0) { chunks.push(body.slice(i + 1, j)); re.lastIndex = j; break; } }
    }
  }
  return chunks;
}

function scalar(entryBody, key) {
  const m = entryBody.match(new RegExp(key + '\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"'));
  return m ? decodeSwiftString(m[1]) : null;
}

function parseEntries(src) {
  return entryChunks(extractBundled(src)).map((body) => ({
    version: scalar(body, 'version'),
    date: scalar(body, 'date'),
    features: listField(body, 'features'),
    improvements: listField(body, 'improvements'),
    fixes: listField(body, 'fixes'),
    others: listField(body, 'others'),
  })).filter((e) => e.version);
}

// --- render Markdown -------------------------------------------------------

// Compare version strings descending (newest first), numeric-segment aware.
function cmpVer(a, b) {
  const pa = a.split('.').map(Number), pb = b.split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pb[i] || 0) - (pa[i] || 0);
    if (d) return d;
  }
  return 0;
}

function renderGroup(label, items) {
  if (!items.length) return '';
  return `### ${label}\n\n${items.map((item) => `- ${item}`).join('\n')}\n\n`;
}

function renderEntries(entries) {
  return entries.map((e) => {
    let markdown = `## [${e.version}]${e.date ? ` - ${e.date}` : ''}\n\n`;
    markdown += renderGroup('Added', e.features);
    markdown += renderGroup('Changed', e.improvements);
    markdown += renderGroup('Fixed', e.fixes);
    markdown += renderGroup('Other', e.others);
    return markdown.trimEnd();
  }).join('\n\n');
}

// --- generate CHANGELOG.md -------------------------------------------------

function build() {
  const entries = parseEntries(readFileSync(SWIFT, 'utf8')).sort((a, b) => cmpVer(a.version, b.version));
  if (!entries.length) throw new Error('parsed zero releases — refusing to write CHANGELOG.md');
  const changelog = [
    '# Changelog',
    '',
    'All notable user-facing changes to NotchFlow are documented here.',
    '',
    '> Generated from `NotchFlow/Sources/WhatsNewService.swift`. Run `node scripts/gen-releases.mjs`; do not edit this file by hand.',
    '',
    renderEntries(entries),
    '',
  ].join('\n');
  return { changelog, entries };
}

const check = process.argv.includes('--check');
const { changelog, entries } = build();
const current = (() => {
  try { return readFileSync(CHANGELOG, 'utf8'); }
  catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
})();

if (changelog === current) {
  console.log(`CHANGELOG.md is up to date (${entries.length} releases, newest ${entries[0].version}).`);
  process.exit(0);
}

if (check) {
  console.error('CHANGELOG.md is STALE — run: node scripts/gen-releases.mjs');
  process.exit(1);
}

writeFileSync(CHANGELOG, changelog);
console.log(`Wrote CHANGELOG.md: ${entries.length} releases, newest ${entries[0].version}.`);
