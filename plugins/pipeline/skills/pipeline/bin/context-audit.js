#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function option(name, fallback) {
  const index = process.argv.indexOf(name);
  return index < 0 ? fallback : process.argv[index + 1];
}
const profile = process.env.USERPROFILE || process.env.HOME || '';
const projects = path.join(profile, '.claude', 'projects');
const roots = (option('--roots', process.cwd()) || '').split(',').filter(Boolean);
const memoryOption = option('--memory', null);
const transcriptRoot = option('--transcripts', projects);
const days = Number(option('--days', '7'));
if (!Number.isFinite(days) || days <= 0) {
  console.error('--days must be positive');
  process.exit(2);
}

function walk(root, visit, excluded, maxDepth = Infinity) {
  if (!fs.existsSync(root)) return;
  const pending = [[root, 0]];
  while (pending.length) {
    const [directory, depth] = pending.pop();
    let entries;
    try { entries = fs.readdirSync(directory, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (depth < maxDepth && !excluded.has(entry.name.toLowerCase())) pending.push([full, depth + 1]);
      } else if (entry.isFile()) visit(full, entry.name);
    }
  }
}

const instructions = [];
for (const root of roots) {
  walk(root, (file, name) => {
    if (!['CLAUDE.md', 'AGENTS.md'].includes(name)) return;
    const data = fs.readFileSync(file);
    const content = data.toString('utf8');
    const lines = content ? content.split(/\r?\n/).length - (content.endsWith('\n') ? 1 : 0) : 0;
    if (lines > 200 || data.length > 16384) instructions.push({ file, lines, bytes: data.length });
  }, new Set(['node_modules', '.git', 'dist', 'bin', 'obj', 'runs']), 5);
}

let memories = [];
if (memoryOption !== null) memories = memoryOption.split(',').filter(Boolean);
else if (fs.existsSync(projects)) {
  memories = fs.readdirSync(projects, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(projects, entry.name, 'memory'));
}
const largeMemory = [];
for (const root of memories) {
  walk(root, (file, name) => {
    const bytes = fs.statSync(file).size;
    const limit = name.toLowerCase() === 'memory.md' ? 8192 : 20480;
    if (bytes > limit) largeMemory.push({ file, bytes });
  }, new Set(['archive']));
}

const since = Date.now() - days * 86400000;
const startup = new Map();
let sessions = 0;
walk(transcriptRoot, (file, name) => {
  if (!name.endsWith('.jsonl') || fs.statSync(file).mtimeMs < since) return;
  let first = null;
  let cwd = null;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line) continue;
    let item;
    try { item = JSON.parse(line); } catch { continue; }
    cwd = item.cwd || cwd;
    if (item.type !== 'assistant' || !item.message || !item.message.usage || item.message.model === '<synthetic>') continue;
    const time = Date.parse(item.timestamp || '');
    if (!Number.isFinite(time)) continue;
    first = item;
    break;
  }
  if (!first || Date.parse(first.timestamp) < since) return;
  sessions++;
  const usage = first.message.usage;
  const tokens = (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0);
  const key = first.cwd || cwd || path.basename(path.dirname(file));
  if (!startup.has(key)) startup.set(key, []);
  startup.get(key).push(tokens);
}, new Set());

instructions.sort((a, b) => a.file.localeCompare(b.file));
largeMemory.sort((a, b) => a.file.localeCompare(b.file));
console.log(`Instruction files over limit: ${instructions.length}`);
for (const item of instructions) console.log(`  ${item.file}: ${item.lines} lines, ${item.bytes} bytes`);
console.log(`Memory files over limit: ${largeMemory.length}`);
for (const item of largeMemory) console.log(`  ${item.file}: ${item.bytes} bytes`);
console.log(`Startup context: ${sessions} sessions in ${startup.size} cwd groups (${days} days)`);
for (const [cwd, values] of [...startup].sort((a, b) => a[0].localeCompare(b[0]))) {
  values.sort((a, b) => a - b);
  const middle = Math.floor(values.length / 2);
  const median = values.length % 2 ? values[middle] : (values[middle - 1] + values[middle]) / 2;
  const max = values[values.length - 1];
  console.log(`  ${median > 60000 ? 'FLAG ' : ''}${cwd}: n ${values.length}, median ${median}, max ${max}`);
}
