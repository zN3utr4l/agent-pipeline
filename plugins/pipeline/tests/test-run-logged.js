'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const root = path.resolve(__dirname, '../skills/pipeline');
const cli = path.join(root, 'bin', 'run-logged.js');

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'run-logged-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function run(args) {
  return spawnSync(process.execPath, [cli, ...args], { cwd: root, encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 });
}

test('passes exact argument array and honors cwd', t => {
  const dir = tempDir(t);
  const log = path.join(dir, 'args.log');
  const script = "console.log(JSON.stringify({args:process.argv.slice(1),cwd:process.cwd()}))";
  const args = ['plain', 'with space', '$(not-executed)', '"quoted"', 'café'];
  const result = run(['--log', log, '--cwd', dir, '--', process.execPath, '-e', script, ...args]);
  assert.equal(result.status, 0, result.stderr);
  const payload = JSON.parse(fs.readFileSync(log, 'utf8').trim());
  assert.deepEqual(payload.args, args);
  assert.equal(payload.cwd, dir);
  assert.match(result.stdout, /exit=0/);
});

test('preserves nonzero child exit and refuses log overwrite', t => {
  const dir = tempDir(t);
  const log = path.join(dir, 'failure.log');
  let result = run(['--log', log, '--', process.execPath, '-e', "process.stderr.write('failed\\n');process.exit(7)"]);
  assert.equal(result.status, 7);
  assert.equal(fs.readFileSync(log, 'utf8'), 'failed\n');
  result = run(['--log', log, '--', process.execPath, '-e', "console.log('overwrite')"]);
  assert.notEqual(result.status, 0);
  assert.equal(fs.readFileSync(log, 'utf8'), 'failed\n');
});

test('retains full large UTF-8 log while output tail is bounded and valid', t => {
  const dir = tempDir(t);
  const log = path.join(dir, 'large.log');
  const script = "for(let i=0;i<500;i++)console.log(String(i).padStart(3,'0')+' 😀 '+ 'x'.repeat(40))";
  const result = run(['--log', log, '--', process.execPath, '-e', script]);
  assert.equal(result.status, 0, result.stderr);
  const full = fs.readFileSync(log, 'utf8');
  assert.match(full, /^000 😀/);
  assert.match(full, /499 😀/);
  assert.ok(Buffer.byteLength(full) > 20000);
  assert.ok(result.stdout.length <= 6500, `stdout length ${result.stdout.length}`);
  assert.equal(result.stdout.includes('\uFFFD'), false, 'UTF-8 tail is not split mid-character');
  const tailLines = result.stdout.split(/\r?\n/).filter(line => /^\d{3} /.test(line));
  assert.ok(tailLines.length <= 80, `tail line count ${tailLines.length}`);
  assert.match(result.stdout, /bytes=\d+/);
});

test('launch errors are nonzero and still produce an empty log', t => {
  const dir = tempDir(t);
  const log = path.join(dir, 'launch.log');
  const result = run(['--log', log, '--', path.join(dir, 'does-not-exist')]);
  assert.notEqual(result.status, 0);
  assert.equal(fs.existsSync(log), true);
  assert.equal(fs.statSync(log).size, 0);
  assert.match(result.stderr, /launch/i);
});
