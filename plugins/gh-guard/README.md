# GitHub CLI account guard

gh-guard checks the active GitHub CLI account before Claude Code runs a `gh` command in Bash or PowerShell. It blocks a known account mismatch for a configured checkout folder.

Install with `/plugin install gh-guard@agent-pipeline` after adding the marketplace. Use Claude Code with mod support on Windows.

## Configuration

Create or edit `config/executors.json` in `PIPELINE_HOME`, or in `~/.pipeline` when `PIPELINE_HOME` is unset. The file can be shared with Pipeline and Cockpit. A standalone configuration can contain just the map below.

```json
{
  "schemaVersion": 1,
  "defaults": {
    "githubAccounts": {
      "C:\\Example\\Checkouts\\Acme": "acme-user",
      "C:\\Example\\Checkouts\\Personal": "personal-user"
    }
  }
}
```

Use absolute Windows folder paths and GitHub login names. Restart the Claude Code session after editing the file. The longest directory prefix wins, so nested folders can use a different account. Missing or invalid configuration leaves the guard without folder rules.

The guard reads the active login from `hosts.yml` in `GH_CONFIG_DIR`, or `%APPDATA%/GitHub CLI` by default. It checks the last recognized absolute directory change before `gh`, and uses the session folder's rule when that destination has none. Unmapped folders, an unavailable login, `gh auth`, and explicit `GH_TOKEN` use pass through.

If you already use a Bash wrapper that selects the account for every mapped folder, set `defaults.githubBashWrapper` to `true` to trust that wrapper inside those folders. Bash checks the active login by default. The mod does not install a wrapper.

Run the fixture suite with `claude plugin test ./plugins/gh-guard` from the repository root. It uses the Claude Code mod test runner with mocked shell and filesystem calls.
