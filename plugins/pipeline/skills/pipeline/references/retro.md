# Retrospective

Scan weekly; follow `delivery-economy.md`'s one-tuning-lot-per-week rule.

Run `node bin\retro-scan.js --since <YYYY-MM-DD>` from the skill base; use `--until`, `--repo <alias>`, `--runs`, `--registry <file>`, `--json`, or `--out`. It reads `meta.json` (every resumed attempt), `gate.json`, `*fix*.md`, brief size, and `task-usage.json` cost deltas. Outcome uses `wrapperExitCode`, falling back to `exitCode` only when absent. Missing metrics stay unknown; malformed artifacts are skipped.

Grouping: a root matching an executor registry path uses its alias (case-insensitive, trailing separators ignored); otherwise use the lowercase `meta.repoRoot` leaf, Git main checkout of `meta.repoPath`, longest normalized `--roots` prefix, or run folder. Registry defaults to `PIPELINE_HOME\config\executors.json`; override with `--registry <file>`. Pass `--roots <root>,<root>` for checkout discovery (dot folders included). Markdown sorts by runs; groups under three fold into `other`, but `--all`, `--repo`, and `--json` keep complete results. The executor table feeds routing: choose the cheapest model and effort meeting fix-loop and deadline rates. Briefs carry ponytail since 2026-10-09: compare diff size and executor cost before and after; drop the section if about ten code lots show no gain.

Read the run's `report.md`, fix briefs, `gate.json`, review findings, and scan numbers, never transcripts. Classify causes as navigation, automated check, standards, steering size and no-ops, tool economy, information access, or launcher bug. Use evidence to distinguish regressions, flakes, and environment failures.

Write `retro.md` in the run directory. Before ranking, read `PIPELINE_HOME\retro-rejected.md`; never re-propose a listed candidate without new evidence. Rank candidates by frequency × cost; each names evidence paths, observed impact, and one prevention action. Mechanical mistakes get a deterministic check (lint rule, test, CI job), not more prose. Navigation or standards guidance belongs in `docs/ai/` pointers or the review checklist. Review findings tagged `→ check` supply check candidates.

Accepted candidates become tracker issues through `tracker.md`, or bounded lots without tracking. Append each candidate the user rejects to `retro-rejected.md` with date, reason, and evidence path. Record acceptance and issue/lot links; implement repository-specific prevention separately.
