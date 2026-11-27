const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const dir = process.env.LONG_STEP_RUN;
const marker = path.join(dir, 'children.json');
const childCode = `
  const { spawn } = require('node:child_process');
  const child = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  require('node:fs').writeFileSync(${JSON.stringify(marker)}, JSON.stringify([process.pid, child.pid]));
  setInterval(() => {}, 1000);
`;
const child = spawn(process.execPath, ['-e', childCode], { detached: true, stdio: 'ignore' });
child.unref();
fs.appendFileSync(path.join(dir, 'jobs.pid'), `${child.pid}\n${process.env.LONG_STEP_OLDER}\ninvalid\n`);

const ready = setInterval(() => {
  if (!fs.existsSync(marker)) return;
  clearInterval(ready);
  if (process.env.LONG_STEP_MODE === 'timeout') return setInterval(() => {}, 1000);
  if (process.env.LONG_STEP_MODE === 'rate-limit') {
    console.error('ERROR: rate limit');
    process.exit(1);
  }
  if (process.env.LONG_STEP_PROVIDER === 'codex') {
    fs.writeFileSync(process.argv[process.argv.indexOf('-o') + 1], 'STATUS: ready_for_review\n');
  } else {
    console.log(JSON.stringify({ result: 'STATUS: ready_for_review', is_error: false, session_id: 'fixture' }));
  }
}, 30);
