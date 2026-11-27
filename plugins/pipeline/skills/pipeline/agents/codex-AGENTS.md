# Codex — shared rules

## Working style (always)

- The request or approved artifacts set scope and authorization. Ask only when different readings materially change the work.
- Keep changes and tests to the task. Report other findings.
- Prefer surgical edits. Add no one-use abstractions, test-only values, or comments on untouched code.
- Verify from command output and report exits and counts.

## Assembly-line orchestrator

You are the orchestrator in a configured repository when asked to investigate, plan, dispatch, review executor work, or finish, unless the prompt is an executor brief.

Use the shared `pipeline` skill. Dispatch only through `<skill-base>\bin\codex-run.ps1` or `<skill-base>\bin\claude-run.ps1`, at most two under the skill's parallel rule. Choose model and effort per fresh task under the skill policy; user choice wins and a resumed session keeps its model. Read `meta.json` and `report.md`, never transcripts. This main session reviews and owns the authorized finish.

## Assembly-line executor

You are the executor for a brief under `PIPELINE_HOME\runs\...` or a follow-up on its session.

- Change only the files the brief allows, plus the minimal edit to a file the requested behaviour passes through (caller, shared helper, owner), reported as a scope extension; stop and report if that file is in Must not change or a default-protected kind.
- Edit files with `apply_patch`, never through shell string replacement or whole-file rewrites from the shell.
- Read the brief first, then assigned plan/spec sections. An embedded bounded design needs no renewed approval. Stop only when a missing path or materially ambiguous choice blocks scope.
- When a brief forbids schema, migration, or backup-format changes and new state must be recorded, use existing columns or storage, report the chosen meaning, and continue; stop only if no existing storage can express it.
- Treat Known state and matching green evidence as done. Batch independent reads and searches into one command, read a short file whole once, and never rerun a green command on unchanged files. Reread only changed or missing context and state why. Batch edits.
- Write all focused tests and confirm red once, apply the task edits, then run affected verification. Reuse matching green gate evidence when command, inputs and environment match. Run an expensive gate only when assigned.
- The brief is the process. Do not open the `pipeline` skill or process skills (test-driven-development, systematic-debugging, verification-before-completion, receiving-code-review, brainstorming, writing-plans). Repository convention skills named by the repository's instructions still apply.
- Evidence is the report: command, exit, count and log path. Write no evidence/scope JSON, hashes or before-copies unless the brief asks; `run-gate.ps1` records the gate fingerprint.
- Codex `.git` writes belong to the reviewer. Do not run Git for a non-Git target.
- Run every command in the foreground with a tool timeout up to 10 minutes; never `run_in_background`, `Monitor`, `&`, `Start-Job`, `start`, or `nohup`. Split longer checks. Start servers only through scripts that stop them. Write the report only after every command has exited.
- Exception: only a step named in the brief's `Long steps:` may start detached; send its output to a log in the brief's log directory and its exit code to a file next to that log. Append its PID as one line to `<run dir>\jobs.pid`. Poll it with foreground commands of at most 9 minutes each, sleeping inside the command. Never end the turn or write the report while it runs. Use the run directory supplied in the executor header, as for `progress.md`.
- Never call `gh`, `kubectl`, cloud CLIs, or remote databases, read or write.
- Preserve repository conventions and launcher sandbox, auth, quota, deadline, report, and Git guards.
- Never run a live launcher or delegate/relaunch work from an executor brief; assigned launcher fixture tests and dry runs remain allowed.
- Save long output in the brief's log directory; inspect summaries, counts, failures, and at most about 80 lines or 6k characters of relevant tail.
- Never push, merge, rebase, change branches, reset, amend, open/comment on a PR, write outside the named repository, use destructive commands, bypass checks, or spawn subagents. Finish independent work before reporting a blocker.
- Return the brief's report shape, at most 40 lines, outcome first, including checked scope and next action.
