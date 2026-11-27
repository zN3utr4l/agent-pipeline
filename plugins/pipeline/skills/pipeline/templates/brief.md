# Brief — {{alias}} — {{topic}} — {{date}}

## Goal and non-goals

Goal: <fill: bounded outcome>. Non-goals: <fill: excluded behavior>. Approved plan: {{plan}} tasks {{tasks}}. Approved spec: {{spec}}. Issue: {{issue}}.

## Done when

- <fill: observable acceptance result or command and expected count; for a bug, start with the red reproduction retained as a regression test>.
- <fill: reviewer check for scope and behavior>.

## Files

Target: `{{repo}}` ({{alias}}), branch `{{branch}}`. Instructions: {{instructions}}. Risk: {{risk}}. Executor: {{executor}}; effort `{{effort}}`.
Depends on: {{dependsOn}}.

May change: <fill: exact paths>.
Must not change: <fill: exact paths>. Unless named above, never edit secrets, `.env`, production configuration, lockfiles, dependencies, CI workflows, migrations, `.git` or instruction files (your edits, not product behavior).

## Known state

<fill: completed work and matching evidence, or none>. UI work names the existing style, theme, and component files the change must reuse: <fill: paths, or none>. Remote CI: {{remoteCi}}. Read only needed ranges once per content version. Search hints: <fill: paths, symbols, or error text; no pasted source>. The executor owns exploration, reproduction, and debugging. For multiple tasks, overwrite `<run dir>\progress.md` (at most 600 characters) after each completed task with completed work, stopping point, and next step.
{{repoNotes}}
## Verify

Targeted: `{{targetedTest}}`. Analyze: `{{analyze}}`. Full gate: {{fullGate}}. E2E: `{{e2e}}`. Regenerate: `{{regenerate}}`. Gate owner: {{gateOwner}}.
Long steps: {{longSteps}}.

Logs: `{{logDir}}`. Report each command with exit, count, and log. Do not rerun matching green evidence.

## Code economy

{{codeEconomy}}

## Return

Use `{{reportTemplate}}`. Your final message is saved as `report.md` and must be the whole report. Report checked scope, actual commands and counts, risks, and next action. Finish independent work before reporting a blocker. {{commitPolicy}}
