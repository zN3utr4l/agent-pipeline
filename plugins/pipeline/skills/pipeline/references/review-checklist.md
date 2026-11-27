# Review checklist

The main session reviews the complete diff once, without extra reviewer agents. Report Spec/Standards findings without re-ranking axes. Read `meta.json`, `report.md`, and linked evidence once.

1. Confirm target and authorized/changed files. `git diff` omits untracked files: open every new file `git status` lists. Inspect status, branch, task commits and diff scope, or orchestrator's before-copies for non-Git targets.
2. Read diff stat, hunks, changed functions/dependencies once. Reopen only changed/missing ranges, stating why. Review fix-loop scope.
3. Apply **Done when**. Match `gate.json` command, cwd, log, exit and source state to the reviewed diff; reuse matching gates. `reused: true` with a `fingerprint` matching reviewed source counts as gate evidence; `failures` names red lines. A flaky green is not a fix-loop trigger; record the flaky test as a follow-up (tracker where enabled). Match other commands to reported command, log, exit, count and scope; reuse only matching green evidence. Exit 0 alone is not success.
4. Check risk and coverage. HIGH executable work needs a relevant full gate when CI cannot own it. Documentation needs a parser or validator; one owner runs each expensive gate. Diagnose a failing slice before rerunning. Check device-only behaviour (car host, surface, timings) before the first fix brief; each defect needs a shot/log and measured target.
5. Check widened scope, weakened guards, unsupported claims, unrequested tests/abstractions, security, data risks and forbidden actions. Narrative added to `CLAUDE.md`/`AGENTS.md`, or either exceeding 200 lines, is a finding: move it to `docs/ai/`. Lean findings: duplicate code/styles/components (name existing paths), dead/speculative code, one-implementation abstractions, unused config, dependencies for a few lines. New non-trivial logic warrants one small test.
6. Number findings by axis: `file:line`, checked scope, evidence, next action. Collect findings before one correction cycle. Track unrelated follow-ups separately (`tracker.md` where enabled).

Check time budgets between batches; never cancel in-flight database writes.

## Spec

Check missing, partial, wrong or unrequested behaviour against the request, approved artifacts and Done when. Keep red bug reproductions as regressions; verify vertical slices independently. Preserve features unless removal was requested. Changed tests must assert the acceptance criteria or a valid regression, not whatever the implementation returns.

## Device surfaces

For app repositories, check lock screens and images mirrored by watches or the shade. Record live-notification animations: a loop bursting once per period cannot be sampled at its period. The in-app notification twin shows identical content. Grep every notification sender; list its file in the brief's Files.

## Standards

Apply repository `docs/ai/` pointers and contributing rules, then the Fowler smell baseline: mysterious name, duplicated code, speculative generality, shotgun surgery, feature envy, primitive obsession. Check quality, security, and data risks within changed scope.

For UI, check duplicated information and overflow: no heading restates its parent; one navigation per level, one style per role. Reused components answer the same tap the same way on every screen; primary actions never hide behind a "more" icon. Inspect reference screenshots at 360 px width, 100% text, dark and light where available; check larger text only for overflow at 130%, by test, without screenshots. After visible text changes, search affected tests for stale copy and i18n assertions.

Tag findings catchable by a deterministic check `→ check` for the retro.
