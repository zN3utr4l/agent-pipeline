#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

function fail(message, code = 2) {
  console.error(`run-logged: ${message}`);
  process.exit(code);
}

function parse(argv) {
  const separator = argv.indexOf('--');
  if (separator < 0 || separator === argv.length - 1) fail('usage: --log PATH [--cwd PATH] -- EXECUTABLE ARG...');
  const options = {};
  for (let i = 0; i < separator; i += 2) {
    const name = argv[i], value = argv[i + 1];
    if (!['--log', '--cwd'].includes(name) || !value || value === '--') fail('usage: --log PATH [--cwd PATH] -- EXECUTABLE ARG...');
    if (options[name]) fail(`${name} may be specified only once`);
    options[name] = value;
  }
  if (!options['--log']) fail('--log is required');
  return { log: path.resolve(options['--log']), cwd: options['--cwd'] ? path.resolve(options['--cwd']) : process.cwd(), command: argv[separator + 1], args: argv.slice(separator + 2) };
}

function safeTail(buffer) {
  let start = 0;
  while (start < buffer.length && (buffer[start] & 0xc0) === 0x80) start++;
  let text = buffer.subarray(start).toString('utf8');
  let lines = text.split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  lines = lines.slice(-80);
  text = lines.join('\n');
  if (text.length > 6000) text = text.slice(-6000);
  if (text.length && /[\uDC00-\uDFFF]/.test(text[0])) text = text.slice(1);
  return text;
}

const options = parse(process.argv.slice(2));
let fd;
try { fd = fs.openSync(options.log, 'wx'); }
catch (error) { fail(error.code === 'EEXIST' ? `refusing to overwrite ${options.log}` : `cannot create log: ${error.message}`); }

let bytes = 0;
let tail = Buffer.alloc(0);
const tailLimit = 16 * 1024;
function record(chunk) {
  fs.writeSync(fd, chunk);
  bytes += chunk.length;
  tail = chunk.length >= tailLimit ? chunk.subarray(chunk.length - tailLimit) : Buffer.concat([tail, chunk]);
  if (tail.length > tailLimit) tail = tail.subarray(tail.length - tailLimit);
}

let child;
try {
  child = spawn(options.command, options.args, { cwd: options.cwd, shell: false, windowsHide: true, stdio: ['inherit', 'pipe', 'pipe'] });
} catch (error) {
  fs.closeSync(fd);
  fail(`launch failed: ${error.message}`, 1);
}

let launchFailed = false;
child.stdout.on('data', record);
child.stderr.on('data', record);
child.on('error', error => {
  launchFailed = true;
  fs.closeSync(fd);
  console.error(`run-logged: launch failed: ${error.message}`);
  console.log(`exit=1 bytes=${bytes} log=${options.log}`);
  process.exitCode = 1;
});
child.on('close', (code, signal) => {
  if (launchFailed) return;
  fs.closeSync(fd);
  const exitCode = Number.isInteger(code) ? code : 1;
  console.log(`exit=${exitCode} bytes=${bytes} log=${options.log}${signal ? ` signal=${signal}` : ''}`);
  const text = safeTail(tail);
  if (text) console.log(text);
  process.exitCode = exitCode;
});
