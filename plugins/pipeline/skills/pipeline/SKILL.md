---
name: pipeline
description: >-
  Use when orchestrating work in a repository. Orchestrator-only: it does not apply when an executor brief is already assigned.
---

# Pipeline

The main session owns scope, authorization, review, and finish; requests and approved artifacts authorize work until material ambiguity changes scope. Executors implement one brief.

## Routes

Choose the furthest proven state. Do not repeat approved work.

| Route | Action |
|---|---|
| raw | Classify a spike, bounded task, or architectural task; plan only what is missing. An issue number or URL counts as the request. |
| approved-design-spec | Brief bounded work; plan architectural work. |
| approved-plan | Prepare the brief and launch. |
| review-only | Reconstruct scope and review completed work. |
| fix-loop-finish | Continue the correction or authorized finish. |
| second-opinion | After a second failed fix loop, or a blocker no executor could explain, run one read-only review (`references/cross-review.md`), then brief the fix. Fresh session, never the failing executor's. |
| retro | Read `references/retro.md`; turn run evidence into prevention. |

## References

| Need | Read |
|---|---|
| Brief, model, launcher, guards, and evidence | `references/handoff.md` |
| Read-only brief review and second opinion | `references/cross-review.md` |
| Complete diff and review findings | `references/review-checklist.md` |
| Publication, checkpoints, and accounting | `references/delivery-economy.md` |
| Worktree setup or removal and when a shell command misbehaves | `references/environment.md` |
| Performance work | `references/performance.md` |
| Retrospective and cross-run scan | `references/retro.md` |
| GitHub issues | `references/tracker.md` |
| Manual Claude launcher fallback | `templates/manual-opus-handoff.md` |

## Orchestrator discipline

Commands: skill directory. State: `PIPELINE_HOME` (default `~/.pipeline`). Setup: README.

Use absolute paths and `git -C`; never `cd`, which reloads instruction files.

Name each brief's repository. Run at most two executors at once, unasked, only for `Depends on: none` lots with disjoint files in different repositories or orchestrator-created Git worktrees. Prefer different providers (separate quotas). Keep short lots, shared files (version props, changelog, lockfiles), and competing heavy gates sequential. A launcher refuses a second executor on the same path with exit 3. Launch via `new-brief.ps1`, `codex-run.ps1`, or `claude-run.ps1`. Do not poll; read `meta.json` and `report.md`, never transcripts.

Before dispatch, read only the request, approved plan or spec, repository status and log, and targeted searches needed for **Done when** and **Files**. Never read source to pre-solve. Put paths, symbols, and errors in the brief as search hints; the executor owns exploration, reproduction, and debugging.

Use preferred Claude `claude-opus-5-5` or `claude-fable-5-2`, or rare Codex `gpt-6-astra`, at `high` for the orchestrator. Use `xhigh` only on request or after `high` planning failed.

Finish with a pull request. Group each request's lots on one branch and PR per repository; push later reviewed lots there. Separate PRs only for unrelated scope or on request. Watch CI only when asked or the terminal goal requires it. Run a retro at finish after a fix loop, red gate, or non-zero exit.

Before GitHub writes, read `defaults.githubAccounts` from `PIPELINE_HOME\config\executors.json`: the longest root prefix of the repository's main checkout names the account. Skip when unset; else match `gh api user --jq .login`. Preserve Git/CLI authentication; switch only on mismatch; never fetch tokens manually. `-FixLoop` follows handoff.
