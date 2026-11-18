# Security policy

## Reporting a vulnerability

Report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/nnemirovsky/cc-shipshape/security/advisories/new)**

The report is visible only to the maintainer ([@nnemirovsky](https://github.com/nnemirovsky)) until an advisory is published, so nothing sensitive is exposed while a fix is prepared. Expect an acknowledgement within a week.

If the form is unavailable, open a normal issue that says only "I would like a private channel for a security report", with no details, and a private advisory will be opened for you.

Never attach real credentials, tokens, personal data or private files to a report. Describe the shape of the problem instead.

## Supported versions

Only the latest release gets security fixes.

## Scope

shipshape's scripts act on GitHub as you, through your `gh` login, and its hook adds text to every prompt. A vulnerability here would be, for example:

- A script acting on a repository, PR, review thread or comment other than the one it was given, for example `cleanup_pr.sh` minimizing a comment it should keep.
- A dry run that changes something: `repo_baseline.sh audit`, `cleanup_pr.sh` without `--apply`, `repo_files.sh --dry-run`. Or `repo_files.sh` overwriting a file that already exists.
- Text that comes from GitHub, such as a PR title, branch name, review body or comment, reaching the shell or a `jq` filter as code.
- Your `gh` token or another secret ending up in a script's output, a state file or anything posted to GitHub.
- Another local user on a shared machine putting text into your conversation through the hook, or steering a review run, through the state files. They live in `~/.local/state/shipshape/` (mode 700), and the hook ignores legacy `/tmp` files that you do not own.
- The hook blocking a prompt, or adding anything other than the active handle-pr run lines.

Out of scope: bugs in `gh` or in GitHub itself, how Claude responds to the text of a review it reads, and anything that needs an attacker who can already run commands as your user.
