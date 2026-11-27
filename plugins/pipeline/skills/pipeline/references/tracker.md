# GitHub tracker

Enable for any GitHub origin (registry `github` overrides origin); opt out with `tracker: none`. Azure DevOps and local repos keep the run directory and PR as record. Executors never call `gh`; the main session writes after the identity check.

Read a raw issue once:

`new-brief` scopes the account token in `GH_TOKEN` for its read, then restores the previous process value. Choose the account by root folder using `defaults.githubAccounts`: configured root → account; the longest main-checkout prefix wins for worktrees. When unset, use current gh authentication.

```powershell
gh issue view <n> --repo {o}/{r} --json number,title,body,url
```

Two or more lots get a parent issue (problem, spec/plan links, out-of-scope work) plus sub-issues (delivery, unchecked acceptance, blocked-by dependencies). In a repository others use, an issue the user names is the parent. Single lots need no issue; the PR is the record.

Create missing labels, then parent and children:

```powershell
gh label list --repo {o}/{r} --json name
gh label create ready-for-agent --repo {o}/{r} --color 0E8A16
gh label create follow-up --repo {o}/{r} --color D4C5F9
gh label create retro --repo {o}/{r} --color FBCA04
gh issue create --repo {o}/{r} --title '<request>' --body-file <parent.md>
gh issue create --repo {o}/{r} --title '<lot>' --body-file <lot.md> --label ready-for-agent
gh api repos/{o}/{r}/issues/<child-n> --jq .id
gh api -X POST repos/{o}/{r}/issues/{n}/sub_issues -F sub_issue_id=<id>
gh api repos/{o}/{r}/issues/<blocking-n> --jq .id
gh api -X POST repos/{o}/{r}/issues/{n}/dependencies/blocked_by -F issue_id=<id>
```

Use numeric REST issue IDs. If relationship APIs fail, put `Parent: #n` / `Sub-issues: #n` and `Blocked by #n` in the body with `gh issue edit <n> --repo {o}/{r} --body-file <updated.md>`.

Accepted retro candidates and unrelated review follow-ups become issues labelled `retro` or `follow-up`, plus `ready-for-agent` when bounded. Execute with `new-brief.ps1 -Issue <n>`; the PR body closes each delivered lot with `Closes #n`.
