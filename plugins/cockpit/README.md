# Cockpit

Cockpit is a Claude Code mod that shows pipeline executors, GitHub Actions runners, PRs, the prompt cache, context, and quotas above the prompt.

**Codex on Windows** can use a Windows Terminal companion with documented hooks, per-session notifications, and a read-only dashboard. The native status line and computer-use notifications keep their existing behavior. [Installation, parity, verification, and rollback](codex/README.md).

## Installation and requirements

```text
/plugin marketplace add zN3utr4l/agent-pipeline
/plugin install cockpit@agent-pipeline
```

You need Windows, PowerShell 7 (`pwsh`), Windows PowerShell (`powershell.exe`), and Claude Code with mod support. Windows Terminal shows an indicator on the tab and taskbar. Notifications use native Windows APIs. The plugin includes its assets and uses built-in PowerShell modules. The dashboard bands and notifications appear during interactive sessions.

Authenticated `gh` provides PR and GitHub Actions runner data. Git identifies repositories and worktrees. `codeburn.cmd` on `PATH` is optional. Without it, the Codex chip stays hidden. When available, it reads quota and keeps the last reading if the provider fails to respond.

Executor monitoring and launch features require **Pipeline** (`/plugin install pipeline@agent-pipeline`) and its launchers and registry. Cockpit finds them in a marketplace cache, in a plugin loaded with `--plugin-dir`, or through a link.

## What it shows

- **Executors** show session runs, model and effort, elapsed time, progress, gate, cost, and outcome. Cockpit sends a notification when a run ends. `/runs` opens the runs from the last 14 days with report, log, progress, gate, and brief tabs. It reads the run artifacts and excludes transcripts.
- **Runners** show offline or busy runners and queued or running workflows for registered repositories. The panel updates after pushes, PR operations, and CI commands, and polls while visible.
- **PRs** show open PRs and requested reviews for the folder account, conflicts, CI, requested changes, and whether Codex review is pending or stale. `/prs` refreshes the feed and opens details. The `@codex review` button requires two presses to post the comment.
- **Cache and context** show the countdown, hit rate, context bar, and a cold cache after a model change or compaction. Large contexts can trigger a suggestion to start a fresh chat or run `/compact`. `/cache` explains the reading. The context denominator uses `autoCompactWindow` if configured and the model window otherwise.
- **Quotas** show Claude/Codex percentages and resets, distinguish stale readings, and warn at thresholds. Cockpit and Pipeline share the Codex quota cache.
- **Waiting and completion** trigger Windows notifications for permissions, questions, plans, completion, and errors. A yellow tab means Claude is waiting, green means work finished, and red means an error. The next prompt clears it. Repeated waits are deduplicated.

## State and user registry

Cockpit reads `PIPELINE_HOME` without starting a process. Use an absolute path. Cockpit strips trailing separators and falls back to `USERPROFILE` or `HOME` plus `.pipeline` when the variable is empty or absent. If all are unset, Cockpit skips pipeline file access while keeping notifications, prompt cache, and the quota available from Codeburn. Set the variable before launching Claude Code and open a fresh shell. To keep existing state, point it at that root. Cockpit reads `runs/<alias>/<run>/`, locks in `runs/.locks/`, the registry at `config/executors.json`, and quota at `logs/quota/last-good.json`.

Cockpit finds the bundled registry from the launcher path in a guarded command, including through links. User entries take precedence when it predicts the alias. It matches the registered main checkout path first, then the GitHub origin slug, and finally uses the lowercase main checkout name. A resume follows the previous metadata directory. A new run uses the first free suffix.

Account rules come from `defaults.githubAccounts` in the user registry. The longest matching directory prefix wins. With missing or invalid rules, `gh` uses the current authentication. Keep credentials and tokens in your CLI authentication settings.

Set `defaults.cockpitRunnerRoot` in the same registry to limit monitoring to checkouts under a local root. Without the key, the panel considers every user executor that declares `repo` and `github`. It accepts GitHub `owner/repository` slugs and deduplicates them. For example:

```json
{
  "schemaVersion": 1,
  "defaults": {
    "githubAccounts": { "C:\\Example\\Checkouts": "acme-user" },
    "cockpitRunnerRoot": "C:\\Example\\Checkouts\\apps"
  },
  "executors": {
    "my-app": { "repo": "C:\\Example\\Checkouts\\apps\\my-app", "github": "acme-example/my-app" }
  }
}
```

## Mod settings

Configure these plugin options with `claude plugin configure cockpit`.

| Key | Default | Effect |
| --- | --- | --- |
| `ttl` | `auto` | Cache TTL: `auto`, `1h`, or `5m`. Auto starts at 1h and uses signals from model changes and exhausted quota windows. |
| `warnMinutes` | `5` | Warns before cache expiry. `0` disables the warning. |
| `bigContextK` | `150` | Large context threshold in thousands of tokens. |
| `codexQuotaMinutes` | `10` | Codeburn polling interval. `0` disables periodic reads. |
| `launchGuard` | `true` | Guards launcher calls. |
| `minMinutes` | `2` | Minimum turn duration for the completion notification. The tab indicator also appears for short turns. |
| `windowsNotification` | `true` | Windows notifications, including executor completion. |
| `tabBadge` | `true` | Windows Terminal tab indicator. |
| `sound` | `true` | Windows notification sound. |

The guard recognizes executable `codex-run.ps1` and `claude-run.ps1` calls, including PowerShell and Bash wrappers, and ignores simple mentions in files or strings. It requires `-FullAccess` for Codex and an explicit `-TimeoutMinutes` of at most 115. It rejects pipes that hide the exit code, shell variables in `-Repo`, `-Brief`, or `-RunDir`, resumes without `-FixLoop`, and a second executor in the same worktree. `codex-run.ps1 -ReadOnly` can omit `-FullAccess` and `-FixLoop`, runs even when the worktree is busy, and leaves it available to other executors. The timeout, pipe, and shell variable checks still apply. Dry runs pass. Launches move to the background with a tool timeout of at least `7200000` ms, preserving higher values. Turn off these rules with `launchGuard: false`.

## Local verification

### Fixes from October 15, 2026

Cockpit also recognizes launcher refusals in redirected output and in the run's `launcher.out`. A nonzero `exit=` without `meta.json` ends the attempt immediately and frees the worktree for another launch.

```powershell
claude plugin test ./plugins/cockpit
pwsh -NoProfile -File plugins/cockpit/tests/pipeline-paths.test.ps1
claude plugin validate .
claude plugin validate ./plugins/cockpit
```

The TypeScript fixtures simulate clocks, filesystems, processes, and APIs. The PowerShell path fixture compares resolution with the Pipeline contract and creates temporary directories and links under `build/pipeline/cockpit-plugin`. These fixtures use simulated executors and GitHub responses and temporary setup.
