# Contributing

Thanks for looking at `cc-shipshape`. This covers the dev loop, the tests and how changes land.

## Dev loop

Load the plugin from a working tree instead of through the marketplace:

```
claude --plugin-dir /path/to/cc-shipshape
```

Every Claude Code restart re-reads the plugin from disk, with no `/plugin install` and no marketplace cache to flush. A change to `hooks/hooks.json` needs a restart before it takes effect. `hooks/run-state.sh` and the skills' scripts run from disk on every call, so an edit to one applies at once.

## Tests

```
claude plugin validate .
git ls-files -z '*.sh' | xargs -0 -n1 bash -n
git ls-files -z '*.sh' | xargs -0 shellcheck --severity=error
```

There is no test suite yet. `claude plugin test` runs a hooks module's tests, and this plugin's hook is a bash script. The scripts call the real GitHub API, so try a change on a repository or PR of your own, starting with the read-only modes:

```
skills/repo-setup/scripts/repo_baseline.sh audit <owner/repo> --kind plugin
skills/repo-setup/scripts/repo_files.sh <checkout> --repo <owner/repo> --kind plugin --dry-run
skills/handle-pr/scripts/cleanup_pr.sh <pr> --repo <owner/repo>
```

`cleanup_pr.sh` only prints its plan until you pass `--apply`. `audit` and `--dry-run` change nothing.

The hook reads `~/.local/state/shipshape/handle-pr-*.json` (and, from older versions, `/tmp/handle-pr-*.json` files you own). Run it by hand from a checkout to see what it would add to a prompt:

```
bash hooks/run-state.sh
```

CI runs the validation and the shell checks on every PR.

## Pull requests

- Open a PR against `main`. Direct pushes are blocked.
- CI must be green and every review thread resolved before a PR can merge.
- PRs are squash-merged, and the PR title becomes the commit subject, so write it as a commit message.
- Bump `version` in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` in the PR that should ship as a release.

## Commits

Scoped conventional commits with a lowercase description:

```
feat(scope): add the thing
fix(scope): stop doing the wrong thing
```
