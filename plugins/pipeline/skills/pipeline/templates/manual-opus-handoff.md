# Manual Claude launcher handoff — <repo>

Use only for an approved brief when the Codex host cannot invoke the launcher. Replace every placeholder first.

## COPY TO POWERSHELL

```powershell
pwsh -NoProfile -File "<skill-base>\bin\claude-run.ps1" `
  -Repo '<absolute-repo-path>' `
  -Brief '<absolute-brief-path>' `
  -RunDir '<absolute-run-directory>' `
  -Model '<claude-haiku-5-5|claude-sonnet-5-5|claude-opus-5-5>' `
  -Effort '<medium|high>' `
  -TimeoutMinutes <n> `
  -MaxBudgetUsd <n>
```

The launcher keeps its guards. Wait for it to finish and run no second executor meanwhile. Never open its transcript.

## RETURN TO CODEX

Paste into the same Codex session:

```text
CLAUDE LAUNCH COMPLETE — <repo>
Run directory: <absolute-run-directory>
Read meta.json and report.md, review the complete change, and continue the authorized finish.
```

Codex reads only `meta.json` and `report.md` and owns any correction cycle or finish.

## FIX LOOP

If review returns findings and the recorded session is compact and relevant, resume:

```powershell
-Resume '<session-id>' -FixLoop <1|2> -Model '<recorded-model>' -Effort '<recorded-effort>'
```

Otherwise write a fresh concise fix brief. A resume keeps the original model. Fix-loop limits follow `references/handoff.md`; more than two loops need explicit user authorization.
