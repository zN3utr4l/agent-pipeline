# Agent Pipeline

Agent Pipeline is a Claude Code marketplace for handing implementation to a fresh executor while the main session retains scope, review, and delivery.

- **Pipeline** turns approved work into briefs and runs Codex or Claude executors. It records progress, verifies gates, and gives the reviewer a report and run metadata.
- **Cockpit** shows executor runs, pull requests, GitHub Actions runners, prompt cache, quota, and Windows notifications in Claude Code. Its optional Codex companion shows pipeline state and live GitHub readings alongside the native status line.
- **gh-guard** checks whether a Claude Code Bash or PowerShell command would use the GitHub CLI account configured for its folder.

## How a run flows

Request → plan → brief → fresh executor → review → fix loop if needed → pull request.

The main session starts at the latest approved stage, prepares the brief, and launches a fresh executor for that assignment. The executor implements and checks the change. The main session reviews the diff against `meta.json`, `report.md`, and gate evidence, sends back any findings, and opens the pull request when authorized.

## Requirements

- **Claude Code** with mod support for Cockpit and gh-guard. The fixtures use Claude Code 2.1.332. Claude executor runs use an authenticated Claude Code CLI.
- **PowerShell 7, Git, and Node.js 24** for the Windows workflow and tests. **GitHub CLI (`gh`)** with authentication is required for live GitHub operations. **Codex CLI** is optional for day-to-day use and required for the Codex native protocol test.
- The full launcher and setup workflow targets **Windows**. The Codex launcher uses `cmd.exe`, and the Windows launchers use native process and lock handling. Cockpit's Windows notifications use `powershell.exe` and native APIs. Windows Terminal provides the tab indicator and automatic Codex companion opening. The gh-guard mod targets Windows folder paths and the Windows GitHub CLI configuration.
- **Codeburn** is optional for quota and usage readings. GitHub, quota, and notification fixtures simulate their external dependencies.

## Install

Run these commands in Claude Code.

```text
/plugin marketplace add zN3utr4l/agent-pipeline
/plugin install pipeline@agent-pipeline
/plugin install cockpit@agent-pipeline
/plugin install gh-guard@agent-pipeline
```

## First-time setup

1. Set `PIPELINE_HOME` to an absolute path for run state. The default is `~/.pipeline`. Launchers create the state directories on first use.
2. Add your own `config/executors.json` under that directory. The [bundled example registry](plugins/pipeline/skills/pipeline/config/executors.json) uses invented aliases and commands. Set `executors.<alias>.repo` to the local checkout, `github` to its `owner/repository`, and `commands` to the checks for that repository. User settings overlay the bundled registry. The [Pipeline setup guide](plugins/pipeline/README.md#state-and-registry) explains the keys and gives a runnable configuration shape.
3. To map folders to GitHub accounts, add `defaults.githubAccounts` to the same file. The [gh-guard setup guide](plugins/gh-guard/README.md) explains how the hook reads this map. For Cockpit's runner panel, list repositories with both `repo` and `github`. Set `defaults.cockpitRunnerRoot` to filter them by checkout root.
4. For Claude and optional Codex setup scripts, use the paths in the [Pipeline setup guide](plugins/pipeline/README.md#first-time-setup-and-updates). Follow the [Cockpit Codex companion setup](plugins/cockpit/codex/README.md) to install the companion and review its hooks.

## Main commands

| Command | What it does |
| --- | --- |
| `/pipeline:pipeline` | Run the orchestration skill in Claude Code. |
| `bin/new-brief.ps1` | Prepare a brief for a configured alias or checkout. |
| `bin/codex-run.ps1`, `bin/claude-run.ps1` | Launch an executor from a brief or resume an existing one. |
| `bin/run-gate.ps1` | Run the assigned gate and record its result. |
| `/runs`, `/prs`, `/cache` | Open executor details, refresh the PR panel, or show the prompt cache reading. |

The `bin/` scripts are under the installed Pipeline plugin's `skills/pipeline/` directory. gh-guard runs automatically on matching tool calls after session start.

## Tests

From the repository root on Windows, with `pwsh`, `node`, `git`, `claude`, and `codex.exe` on `PATH`, run:

```powershell
pwsh -NoProfile -File plugins/pipeline/tests/run-all.ps1
pwsh -NoProfile -File plugins/pipeline/skills/pipeline/scripts/test-new-brief-utf8.ps1
pwsh -NoProfile -File plugins/cockpit/tests/test-codex-parity.ps1 -LogDirectory .pipeline-logs/cockpit
claude plugin test ./plugins/gh-guard
```

The Cockpit gate runs the PowerShell and Node fixtures, the Claude mod fixtures, and marketplace validation. The native Codex fixture uses only the local app-server listing protocol and accepts `CODEX_NATIVE_EXE` for the actual executable. Both mod suites use Claude Code's `claude-code/testing` runner offline. CI runs these checks on GitHub-hosted Windows.

## License

[MIT](LICENSE) © 2026 Giuseppe Chirico. Pipeline vendors Dietrich Gebert's [Ponytail v5.3.3](plugins/pipeline/skills/pipeline/vendor/ponytail/SOURCE.md) under its own [MIT license](plugins/pipeline/skills/pipeline/vendor/ponytail/LICENSE).
