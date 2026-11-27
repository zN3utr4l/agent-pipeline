# Pipeline

The main session defines the scope, writes a brief, launches an isolated executor, reads `meta.json` and `report.md`, reviews the changes, and completes the authorized work. The skill handles model routing, quota limits, locks, deadlines, fix loops, gates, and usage accounting. An executor can run the steps listed under `Long steps:` as detached processes and monitor them. The launcher uses the PIDs in `jobs.pid` to stop those processes when the executor exits and records them in `meta.json`.

## Installation

In Claude Code:

```text
/plugin marketplace add zN3utr4l/agent-pipeline
/plugin install pipeline@agent-pipeline
```

The skill is `/pipeline:pipeline`, and the agent is `pipeline:implementer`. Repositories using the plugin can add `"pipeline@agent-pipeline": true` to `enabledPlugins` in `.claude/settings.json`.

You need Windows, PowerShell 7, Git, and an authenticated Claude Code subscription. The main session uses `gh` for GitHub operations. Codex CLI is optional. If it is unavailable, a new brief uses Claude. `codex-run.ps1` forwards new runs to Sonnet medium or Opus high/xhigh. Resuming an existing Codex session requires Codex.

Node.js runs the JavaScript tools, metrics, and test suite. A metrics capture failure warns and keeps the launcher result. `codeburn` is optional. If it is missing from `PATH`, the quota gate skips the check and shows a warning. If it is installed but fails to respond, Claude refuses the launch (exit 4), and Codex treats the reading as advisory. The workflow requires a current provider reading before using `-SkipQuotaCheck`. Python is optional for TOML validation during Codex setup.

## First-time setup and updates

Claude shows the skill directory when it loads the skill. All executable code lives under `skills/pipeline/`. Set `$PipelineSkill` to that directory, including when its cache path changes after an update.

```powershell
$PipelineSkill = '<plugin directory>\skills\pipeline'
pwsh -NoProfile -File "$PipelineSkill\bin\setup-claude-home.ps1"
pwsh -NoProfile -File "$PipelineSkill\bin\setup-codex-home.ps1"
```

The setup scripts preserve existing settings, back up files before changing them, and can be run repeatedly. The plugin provides the Claude skill and agent. Claude setup removes legacy links at `skills/pipeline` and `agents/implementer.md` while preserving their targets and any regular files or directories. It sets the delegation limits to 1 and 2 and adds `autoCompactWindow: 400000` only when absent. Codex setup links the skill and local instructions, adds top-level `project_doc_max_bytes = 131072` only when absent, and shares enabled Claude skills except those excluded by the workflow. Codex replaces empty files and refuses to overwrite nonempty files or regular directories. Move those entries before setup. For Windows symlinks, enable Developer Mode or use a shell with the necessary privileges.

After updating the plugin, repeat Codex setup from the new path to update the links. `-DryRun` shows the planned operations. For alternate homes, use `-ClaudeHome` and `-CodexHome` or `CLAUDE_CONFIG_DIR` and `CODEX_HOME`. Launchers find their files from `$PSScriptRoot` even when invoked through the Codex skill link. `claude-run.ps1` loads the plugin with `--plugin-dir`, selects `pipeline:implementer`, and configures the Git guard as a `PreToolUse` hook with a quoted absolute path.

## State and registry

`PIPELINE_HOME` is the user state root. It defaults to `$HOME\.pipeline`, outside Claude's sensitive directories, and is created on first use. Set it before starting a session, for example with `[Environment]::SetEnvironmentVariable('PIPELINE_HOME', '<state directory>', 'User')`. Open a fresh shell to pick up the value.

```text
PIPELINE_HOME/
  config/executors.json       optional user registry
  runs/<alias>/<run>/         brief, progress, meta, report, gate, usage
  runs/.locks/                repository and heavy gate locks
  logs/quota/last-good.json   shared quota cache
```

To keep existing state, set `PIPELINE_HOME` to its root. The layout and your configured aliases stay in place. The launchers read code from the plugin directory, which they treat as read-only.

The [bundled example registry](skills/pipeline/config/executors.json) defines defaults and three invented projects under `C:\Example\Checkouts`. `acme-api` is a .NET API with a two-command integration gate, `acme-web` is an npm app, and `acme-docs` builds a docs site. Use the example shape to define your own aliases, checkout paths, GitHub slugs, and commands in the user registry.

The optional user registry merges over the bundled registry recursively. User properties win, arrays are replaced, and missing properties inherit defaults. Keep the `schemaVersion`, `defaults`, and `executors` structure. Store credentials in your CLI authentication settings.

```json
{
  "schemaVersion": 1,
  "defaults": {
    "githubAccounts": { "C:\\Example\\Checkouts": "acme-user" }
  },
  "executors": {
    "acme-api": {
      "repo": "C:\\Example\\Checkouts\\acme-api",
      "github": "acme-example/acme-api"
    },
    "my-project": {
      "repo": "C:\\Example\\Checkouts\\my-project",
      "github": "acme-example/my-project",
      "logDir": ".pipeline-logs",
      "commands": {
        "targetedTest": "npm test -- <target>", "analyze": "npm run lint", "regenerate": "none",
        "fullGate": "npm test", "e2e": "none"
      }
    }
  }
}
```

`repo` is an absolute checkout path. `github` is the GitHub `owner/repository` slug. `commands` declares targeted checks, analysis, regeneration, the full gate, and E2E for the brief. Use `none` to mark an unavailable check. A `fullGate` array runs in order. `gateOwner`, `gateRetries`, `gateTimeoutMinutes`, and `heavyGate` control full gate ownership, retries, deadlines, and the shared heavy gate lock. `logDir` is relative to the checkout, and `briefNotes` add repository instructions to a brief. Repositories that need extra writable directories or a Flutter SDK can set `writableRoots` and `flutterSdk` in their user entry.

An explicit alias uses its configured `repo`. If `repo` is omitted or set to `null`, the origin of the current checkout must match the alias's GitHub slug. When passed a path, the launcher first checks registered checkout paths, including a worktree's main checkout, then matches the GitHub origin slug, and finally uses the lowercase main checkout name as the alias. Registry aliases start with an ASCII letter or digit and can contain lowercase letters, digits, dots, hyphens, and underscores. Non-Git targets work without an inferred GitHub identity. The state directory's legacy `config/projects.json` is also supported.

`defaults.githubAccounts` comes from the user registry. The longest absolute directory prefix of the main checkout determines the account. The skill checks `gh api user --jq .login` against the configured account before writing to GitHub. Without a matching rule it uses the current authentication. `new-brief` selects a token only for the issue read and always restores `GH_TOKEN`.

## Usage and verification

### Repeatable Codex skill sync

`bin/setup-codex-home.ps1 -SyncSkillsOnly` uses the existing sync code in `AgentLinks.ps1`. `-DryRun -PlanPath <file>` shows provenance and portability. `-ApplyPlan <file>` rechecks the observations before editing. `-ActivePluginDirectory <dirs>` adds only explicitly active directories. Enabled plugins follow their current `installPath`. Regular directories and unknown links are conflicts. The 21 video mirrors named by the policy can be adopted only with `-AdoptSkill <names>`, with backups of both roots outside skill discovery. `-VerifiedMcpServer <names>` records the reviewer's attestation after verification. Refresh and `-Rollback` preserve concurrent changes. Use fixture home parameters in tests. The legacy setup keeps its existing callers. [Migration commands and limits](../cockpit/codex/README.md#skill-refresh-and-portability).

Classification distinguishes runtime instructions, frontmatter, usage comments, and development examples. Projections resolve only existing resources of the skill and its installed siblings, preserving relative imports and concurrent edit checks. Optional MCP tools and missing illustrative commands remain explicitly unverified. Missing runtime dependencies are excluded. Regenerate plans from the previous adapter before applying them. Portability checks leave credentials, providers, and external toolchains unverified.

### Fixes from October 15, 2026

The quota gate refreshes its cache when a provider window has passed its reset time, even within the TTL. Dry runs ignore expired cache entries without starting a live read.

```powershell
pwsh -NoProfile -File "$PipelineSkill\bin\new-brief.ps1" -Repo '<path or alias>' -Topic '<task>' -Risk HIGH -DryRun
pwsh -NoProfile -File "$PipelineSkill\bin\codex-run.ps1" -Repo '<path or alias>' -Brief '<brief.md>' -Effort high -FullAccess -DryRun
pwsh -NoProfile -File "$PipelineSkill\bin\claude-run.ps1" -Repo '<path or alias>' -Brief '<brief.md>' -Effort high -DryRun
```

The skill and its references contain the full workflow rules. The suite uses temporary homes and repositories, CLI fixtures, and simulated APIs:

```powershell
pwsh -NoProfile -File plugins/pipeline/tests/run-all.ps1
claude plugin validate .
claude plugin validate ./plugins/pipeline
```
