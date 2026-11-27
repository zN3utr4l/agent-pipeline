import { readFileSync, statSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
export const identity = value => createHash('sha256').update(String(value)).digest('hex').slice(0, 24);
export function readJson(path, max = 262144) {
  try { if (statSync(path).size > max) return undefined; return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, '')); } catch { return undefined; }
}
export function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temp = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temp, JSON.stringify(value), { mode: 0o600 }); renameSync(temp, path);
}
export const pipelineHome = () => process.env.PIPELINE_HOME || `${process.env.USERPROFILE || process.env.HOME}/.pipeline`;
