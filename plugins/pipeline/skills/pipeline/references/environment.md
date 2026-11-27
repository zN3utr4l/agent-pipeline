# Environment

All configured roots; remote actions belong to the orchestrator.

- Use absolute paths and `git -C`; never `cd`.
- Git Bash: `-p:` instead of `/p:` for MSBuild (MSB1008); `MSYS_NO_PATHCONV=1` for Windows-style arguments. Set path variables on their own line before `&&`.
- Use no `jq`; use `gh --jq`. PowerShell skips the profile; check the gh account before GitHub writes.
- Stop processes by PID from `-PassThru` or `TaskStop`, never command-line regex, never `$PID`.
- New worktrees install dependencies (`npm ci` or `yarn install --immutable`), no node_modules junction. Before `git worktree remove`, delete a legacy junction alone with `[IO.Directory]::Delete('<wt>\node_modules', $false)`.
- Never `git worktree move` with installed dependencies: junctions keep old paths; plain install does not relink. Create a worktree, or delete `node_modules/.yarn-state.yml` and reinstall.
- Branches may track `origin/develop`; push with an explicit refspec, e.g. `HEAD:refs/heads/<branch>`.
- Remove worktrees after every citing brief finishes; after merge, cite artefacts by main-checkout path or GitHub URL.
- Never schedule launches with CronCreate.
- Node tools behind proxies need `NODE_USE_ENV_PROXY=1`.
- Quota reading: reset time has passed means stale; reread `codeburn quota`.
- Codex PR review does not rerun on push; comment `@codex review`.
- Never pipe a launcher into `tail` or `head`: the pipe hides its exit code; redirect to a file, then print its tail and the exit.
