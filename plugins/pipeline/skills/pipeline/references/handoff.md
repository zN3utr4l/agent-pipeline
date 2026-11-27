# Handoff

## Choose the executor

| Risk | Work | Codex (preferred) | Claude |
|---|---|---|---|
| LOW | Narrow leaf code, docs, or nonsensitive configuration. | `gpt-6.1-terra` medium | `claude-haiku-5-5` medium |
| MEDIUM | Cross-component, public, UI, dependency, or build work. | `gpt-6.2-sol` medium | `claude-sonnet-5-5` medium |
| HIGH | Security, privacy, auth, migration, deletion, release, infrastructure, concurrency, or broad toolchain work. | `gpt-6.2-sol` high | `claude-opus-5-5` high |

Defaults and overrides:
- Terra: screenshots, images, browser/app control, visual UI checks, up to MEDIUM.
- Sol: multi-file code and debugging.
- Astra (`gpt-6.2-astra`): only on user request or after stalled fix loops or days of work (whole-system independent review, root-cause analysis, hard redesign).
  Use `high` or explain `xhigh`. Justify Astra in Known state. Weekly Codex quota cost far exceeds Sol's.
- Haiku: mechanical edits, renames, docs.
- Sonnet: UI and cross-component code.
- Opus: HIGH and after a failed fix loop.
- Effort: `medium` minimum; `high` for subtle logic or unclear causes; `xhigh` (explain) for hard debugging or concurrency.

Use Claude when requested or Codex unavailable/quota-capped. Resolve uncertain risk upward. User choice wins; retain session models. Retired-model resumes need fresh executors with `fix-<n>.md` in the same run directory. Network failures never prove exhaustion.

## Brief and launch

Cite post-launch files only from the run directory or repository.

Proven device or API facts name their observed effect; otherwise mark them unverified.

Codex lots forbid commits/pushes; Claude lots allow one commit, never pushes.

Domain choices (preference kinds, categories, verdicts): quote spec line/path; never paraphrase.

Read-only audit lot: table and findings, then fix lots. UI lot: at most about ten roles or screens.

Shared-function or screen-default changes: Done when lists and runs caller tests and route e2e tests (grep).

Narrow checks or list exceptions for legitimate flags while preserving behaviour.

Each HIGH brief gets the read-only review (`cross-review.md`) before launch.

When a decision replaces a behaviour, change every brief, plan, and fix-brief passage that states it, Done when included; an addendum leaves it standing.

A lot that replaces code compares old and new output on the same real inputs from the producing program, not only hand-written samples.

Dependency-adoption/namespace briefs list companions: PublicAPI files, test-project usings, doc examples/generators, version-pinned test expectations.

Create `brief.md` with `new-brief.ps1`. Task caps: HIGH three, otherwise five. `briefWarnChars`: 6000. Include acceptance, allowed files, proven state, checks/logs, gate owner, `Depends on:` (`none`), approved-plan links, `Long steps:` (>9 minutes, with commands), `## Code economy` (ponytail v5.3.3, `7801d06`, re-pin `vendor\ponytail\SOURCE.md`). Launch only through:

```powershell
pwsh -NoProfile -File "<skill-base>\bin\new-brief.ps1" -Repo <alias|path> -Topic <topic> -Risk <LOW|MEDIUM|HIGH> [-Executor <codex|claude>] [-Model <m>] [-Plan <path> -Tasks <range> | -Spec <path>] [-Issue <n> [-IssueJson <path>]] [-GateCommand <cmd>] [-GateOwner <executor|launcher>]
pwsh -NoProfile -File "<skill-base>\bin\codex-run.ps1" -Repo <alias|path> -Brief <brief> [-Model <gpt-6.1-terra|gpt-6.2-sol|gpt-6.2-astra>] [-ReasoningEffort|-Effort <medium|high|xhigh>] -TimeoutMinutes <n> -FullAccess
pwsh -NoProfile -File "<skill-base>\bin\codex-run.ps1" -Repo <alias|path> -Brief <request> -RunDir <dir> -ReadOnly [-Model <gpt-6.2-sol|gpt-6.2-astra>] [-ReasoningEffort <high|xhigh>] [-Resume <id>] -TimeoutMinutes 30
pwsh -NoProfile -File "<skill-base>\bin\claude-run.ps1" -Repo <alias|path> -Brief <brief> [-Model <claude-haiku-5-5|claude-sonnet-5-5|claude-opus-5-5>] -Effort <medium|high|xhigh> -TimeoutMinutes <n> [-MaxBudgetUsd <n>]
```

Plan independently verifiable vertical slices across needed layers. Wide mechanical refactors: expand → batch-migrate → contract. Start bug Done when with a red reproduction kept as a regression test. Before dispatch, ensure allowed files reach every file the behaviour passes through. Measure before setting numeric targets. Find changed-output assertions in tests. Timeouts in minutes: LOW 30, MEDIUM 60, HIGH 90, executor plus gate under 115 minutes (Claude Code's Bash kills background commands at two hours). Launch from Bash with `run_in_background`, `timeout: 7200000`. Shorter parent timeouts kill launchers mid-run. Split longer work using `progress.md` and resume. UI reference screenshots: 360 px, 100% text, dark and light where available. Check larger-text overflow only at 130% by test without screenshots. Issue checklists prefill acceptance. `-DryRun` never calls `gh` (`-IssueJson` offline).

Codex executors need `-FullAccess` for launches/resumes (Windows sandbox blocks NuGet, worktree Git, Docker). `-DryRun` shows arguments and lock without taking it. Launchers grant run-directory access for `progress.md`. Multi-task briefs maintain it as assigned, mirrored in `Checkpoint:`. Gate order: `-GateCommand`, `brief.gate.json`, before registry `fullGate`. `-GateCommand none` skips even on resume. `-GateTimeoutMinutes`: registry `gateTimeoutMinutes` or 20. `-SkipQuotaCheck` needs an explicit provider reading. `-Resume <id>` inherits recorded model/effort. Legacy metadata needs explicit originals. `-FixLoop <n>` requires resume. One loop, two max with stated high-assurance reasons (security, data, migration, release, concurrency). Prefer fresh small briefs when old context outweighs files.

For `gateOwner: "executor"` or `-GateOwner executor -GateCommand <cmd>` (p90 under 10 minutes), run `run-gate.ps1` once after edits and fix red. The launcher reads `brief.gate.json`, reuses untimed green/red `gate.json` matching command, cwd, `fingerprint` (`reused: true`), or reruns, retaining `gate.executor.json`. The launcher runs `fullGate` unless brief-assigned. Missing reports yield `STATUS: failed`, `reportSynthesized: true`. A target under `~/.claude` goes to a Codex executor because headless Claude refuses edits there as sensitive files. Skip Git for non-Git targets.

Retries select extracted failing files only; pathless failures, multi-command arrays and non-runner commands retain first results.

`fullGate` arrays run in order; `heavyGate: true` serializes heavy runs, hand-run `run-gate.ps1` too. Launch with literal paths; the cockpit guard matches command text.

Follow SKILL.md's parallel rule; a busy path returns exit 3.

## Guard facts

Claude autocompact 400k tokens, resume guard 150k. Codex autocompact 200k (effective window ~258k). Both providers/windows use `quotaCapPercent`/`quotaCapPercentResume` at 85. Claude counts own-model and unscoped windows. Fable never blocks Claude models. Codex counts all windows. Missing codeburn warns and skips. Failing installs count as unreadable. Claude refuses (4). Codex continues with an advisory. Exits: 0 success, 1 execution/report failure, 2 Claude authentication, 3 busy repository or mechanical/resume refusal, 4 quota refusal, 5 post-run gate failure/timeout, 75 Codex preflight/sandbox refusal, 124 executor deadline.
