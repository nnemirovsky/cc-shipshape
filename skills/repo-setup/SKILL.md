---
name: repo-setup
description: Sets up a GitHub repository to a vetted baseline, or audits and fixes an existing one. Covers repo settings (squash-only merges, branch cleanup, auto-merge), security (secret scanning, push protection, private vulnerability reporting, Dependabot, CodeQL, immutable releases), rulesets protecting the default branch and release tags, and the community files (LICENSE, SECURITY, CONTRIBUTING, PRIVACY, CODE_OF_CONDUCT, CODEOWNERS, issue forms, PR template, dependabot.yml, CI and release workflows). Baselines per kind: Claude Code plugin, MCP server, library or CLI, private repo. Triggers: "set up the repo", "create a new repo for", "make this repo OSS-ready", "apply repo settings", "protect main", "add branch rules", "add a SECURITY.md", "audit my repos", "fix repo settings", "настрой репозиторий". Do NOT use for writing a PR (shipshape:write-pr) or for the review cycle (shipshape:handle-pr).
---

# repo-setup: a repository in good order

Two scripts do the work. Both are idempotent: run them as often as you like.

- `scripts/repo_baseline.sh audit|apply <owner/repo> --kind <kind>`: the settings, security features and rulesets, through the GitHub API.
- `scripts/repo_files.sh <checkout> --repo <owner/repo> --kind <kind>`: the files a checkout is missing, from `templates/`. Never overwrites a file.

Paths are relative to this skill's base directory.

## 1. Pick the kind

| Kind | For | Adds on top of the common base |
|---|---|---|
| `plugin` | Claude Code plugins and marketplaces | the `claude plugin validate` + `test` CI, PRIVACY.md, topics `claude-code`, `claude-code-plugin` |
| `mcp` | MCP servers (local or remote) | CodeQL, PRIVACY.md, topics `mcp`, `model-context-protocol`, language CI |
| `lib` | libraries, CLIs, apps | CodeQL, language CI |
| `private` | private repos | only what a free plan allows (see Limits) |

A repo that is both, for example an MCP server shipped as a plugin, takes `mcp`. Add the plugin CI job and the plugin topics by hand.

**License: ask the user every time** for a new public repo (MIT, Apache-2.0, or something else), and pass it as `--license <spdx id>`. Never pick one silently.

## 2. New repository

1. Create it: `gh repo create <owner>/<name> --public|--private --description "<one line>" --clone`. Add 3 to 6 topics that describe it.
2. Write the code and README, then in the checkout run `repo_files.sh . --repo <owner/repo> --kind <kind> --license <spdx>`.
3. Fill in every file the script printed as `TODO`. They hold `<!-- TODO -->` markers for what only this project knows, such as the security scope, the dev loop and what the privacy policy covers. Remove the markers. Write CI for `mcp` and `lib` repos by the CI rules below.
4. Commit and push this first commit straight to the default branch. Protection is not on yet.
5. Run `repo_baseline.sh audit`, show the user the DRIFT lines, then `repo_baseline.sh apply` with `--checks "<CI job names>"`. Use `--discussions` only for a bigger project that wants a Q&A space.
6. Run the audit again. It should print only OK, SKIP and NOTE lines.

From now on every change goes through a PR (`shipshape:write-pr`), including your own.

## 3. Existing repository (audit and fix)

1. Run `repo_baseline.sh audit <owner/repo> --kind <kind>`. If it prints `SUGGEST checks:`, pick the jobs that should gate a merge, usually test and lint, never a release job. Run the audit again with `--checks`.
2. In a checkout, run `repo_files.sh . --repo <owner/repo> --kind <kind> --dry-run`.
3. **Show the user both lists and get their approval for this repo** before changing anything. An `AskUserQuestion` per repo works well: apply everything, settings only, files only, or skip. The settings change the repo for everyone who uses it, for example by blocking direct pushes, so never apply them without that yes.
4. Apply the settings with `repo_baseline.sh apply`, using the same flags as the audit.
5. Add the missing files on a branch with `repo_files.sh`, fill in the TODOs, and open a PR through `shipshape:write-pr`. Protected repos only take changes through a PR.
6. Report per repo what changed, and anything left as SKIP or NOTE.

## The baseline

**All kinds:**
- Squash merges only, with the PR title and PR body as the commit.
- Delete branches after merge, and allow updating a PR branch from the base.
- Wiki and projects off.
- The workflow token is read-only by default and cannot approve PRs.
- Dependabot alerts and security updates are on, and `.github/dependabot.yml` updates GitHub Actions plus every ecosystem it finds, weekly and grouped.

**Public kinds add:**
- Auto-merge allowed.
- Secret scanning with push protection, private vulnerability reporting and immutable releases.
- CodeQL default setup for `mcp` and `lib`.
- **The "Protect main" ruleset on the default branch:**
  - no deletion and no force push
  - PRs required, with 0 approvals but every review thread resolved, and squash only
  - required status checks, with strict up-to-date branches
  - signed commits (`--no-signed` drops the rule)
  - The repository admin role, the owner, may bypass the rules only through a pull request: you can merge your own PR, but never push straight to main.
- **The "Protect release tags" ruleset on `refs/tags/v*`:** no deletion, no update, no force push.
- Classic branch protection is removed once the ruleset is in place.
- **Files:**
  - LICENSE, SECURITY.md (reports go to the private advisory form), CONTRIBUTING.md, CODE_OF_CONDUCT.md (Contributor Covenant), CODEOWNERS (`* @owner`)
  - PRIVACY.md for `plugin` and `mcp`
  - bug and feature issue forms, plus a `config.yml` that turns off blank issues and links the advisory form
  - a short PR template
  - a release workflow on `v*` tags, which checks the tag against `plugin.json`, `package.json` or `pyproject.toml` and creates the GitHub release with generated notes

## CI rules (for any workflow you write)

- Put `permissions: contents: read` at the top. Grant more per job only where the job needs it, such as `contents: write` for a release or `packages: write` for GHCR.
- Add `concurrency: {group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true}`, and `workflow_dispatch:` next to `push` and `pull_request`.
- Each job's `name:` is what a required status check matches. Keep the names stable, and pass exactly those names in `--checks`.
- Never put a required job behind `paths:` filters. A PR that skips it waits forever for a check that never reports.
- Reference actions by their current major tag, for example `actions/checkout@v7`. Dependabot keeps them current.
- Go: `golangci-lint`, `gofumpt` and `go test ./...`. Python: `ruff check`, `ruff format --check`, `mypy`, `pytest`, with uv. Node: lint, typecheck and test scripts. Add a matrix over operating systems when the code is platform-specific.
- Release binaries with goreleaser (Go), or publish to PyPI through trusted publishing in a `pypi` environment. A release workflow that already exists stays as it is.

## Limits

- **Private repos on a free GitHub plan** cannot have rulesets or branch protection (403 "Upgrade to GitHub Pro"), private vulnerability reporting or secret scanning. The script reports these as SKIP. A local `pre-push` hook that refuses pushes to `main` is the cheap stand-in for branch protection.
- **Claude plugin repos must not have a `.gitattributes` with `export-ignore`, `export-subst` or a `filter`.** Claude's plugin directory refuses to validate such a repo. `repo_files.sh` warns about it. The directory also wants a LICENSE, a README of at least 40 words and a `version` in `plugin.json` that goes up with every release.
- Signed commits are required on public repos. Set up SSH commit signing on every machine you push from before applying it (`references/signing.md`). Merges made on GitHub are signed by GitHub, so they always pass.