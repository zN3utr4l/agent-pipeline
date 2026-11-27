# Cross review

`codex-run.ps1 -ReadOnly` runs one turn in a read-only sandbox with apps, plugins, and MCP servers disabled. It takes no repository lock and runs no post-run gate. It refuses `-FullAccess` and `-FixLoop` (exit 3) and unreadable MCP listings (exit 75). Read the launcher exit first. Exit 0 is a valid review whatever the verdict; 1 is failed or malformed. Outputs: 0 gives `review.json` plus `report.md` starting `VERDICT:` (`VERDICT: APPROVED|REVISE|BLOCKED`, findings); 1 gives `report.md` starting `STATUS: failed` and no `review.json`; 3, 4 or 75 is refused before launch, possibly with no artifacts. `-Resume <id> -ReadOnly` continues only a read-only session.

## Brief review

Review HIGH before launch. LOW and MEDIUM briefs skip it unless the user asks.

1. Write `<lot run dir>\review-<n>\brief.md` with target brief path, plan/spec link, and checks.
2. Run `codex-run.ps1 -Repo <repo> -Brief <request> -RunDir <lot run dir>\review-<n> -ReadOnly -Model <gpt-6.2-sol|gpt-6.2-astra> -ReasoningEffort high -TimeoutMinutes 30`. Default to Sol.
3. Arbitrate every finding: accepted edits the brief; rejected records its reason in the next request.
4. Allow at most two rounds. Round 2 uses `-Resume <session> -ReadOnly` only after material brief changes. Write `review-<n+1>\brief.md` with dispositions and changed brief. Run `-RunDir <lot run dir>\review-<n+1> -Resume <session> -ReadOnly`. The launcher finds round 1's `meta.json` only under `PIPELINE_HOME\runs\<alias>\*\` or `*\*\`, so review folders stay inside the lot run directory.

Exit 0 is a valid review, not approval; BLOCKED, failed, or malformed never counts as approval.

At the Codex quota cap or on the user's request, skip and record `Brief review: skipped (<reason>)` in Known state.

## Second opinion

SKILL.md's `second-opinion` route: give the review the reproduction, evidence, and failed approaches; ask for a testable alternative explanation. Use a fresh session, never the failing executor's.
