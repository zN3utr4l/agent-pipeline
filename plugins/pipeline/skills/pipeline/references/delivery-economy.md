# Delivery economy

## Publication

Reconcile target and dependency branches once before the final gate. Identify a reviewed gate by its 40-character head SHA and workflow IDs; recheck before merge. The main session performs authorized Git, metadata, and API finish from reviewed evidence. State the PR URL once; a watch authorizes no merge or deploy.

For branches changing UI across many screens, the last lot runs full e2e once locally before the single push. Otherwise CI owns verification.

```powershell
pwsh -NoProfile -File "<skill-base>\scripts\watch-pr.ps1" -Repo <owner/name> -PR <number> -ExpectedHeadSha <40-hex> -RunId '<id>[,<id>]' -IntervalSeconds 60 -TimeoutMinutes <n> [-LogPath <file>]
```

A successful watch needs every selected run green on that head and a nonempty successful rollup. Exit 0 proves the gate, 1 means failure or identity error, 2 missing identity, 124 observation ended. Verify writes before retrying; preserve release artifacts, signing and privacy requirements.

After a runner change, check drive paths outside Windows guards, gitignored job inputs and `paths` filters skipping CD; rerun a green PR.

The PR body has a summary, before/after evidence, and merge danger (one-way or two-way door, blast radius), plus `Closes #n` per delivered lot issue. This gives the user evidence for an explicit merge OK; publication does not grant it.

At request finish after a fix loop, red gate, or non-zero exit, follow `references/retro.md`.

## Session and checkpoint

Stay in one session while the work is coherent; start fresh only when compaction keeps losing needed state or the context holds finished, unrelated work. Then write `checkpoint.md` in the run directory (at most 4000 characters: state, next action, authorization, IDs, links) and give the user a paste-ready prompt naming the folder, checkpoint path, and next action. Do not poll; await the executor's completion notification.

## Accounting and tuning

The launchers run `task-usage.js --phase start --run-dir <run dir>` before the executor and `--phase finish` after the post-run gate; failure warns without changing the exit. By hand, finish reads the run directory `meta.json` absent `--session` or `--meta`. The executor links the artifact, never recapturing it. Use `usage.js --hours 5`, or `--since` and `--until` for an interval. Before tuning, run `node bin/context-audit.js --days 7` to measure instruction, memory, and Claude startup context. Codeburn shows provider windows. Coverage is partial; costs are API-equivalent estimates, not invoices. Never attribute tasks from a shared window.

Change the pipeline only when `usage.js` or Codeburn numbers in the run directory support it. Make at most one tuning lot per week unless a launcher is broken. Do not add pricing tables or claim unmeasured savings.
