---
name: write-pr
description: Writes a GitHub pull request's title, body, labels, assignee and reviewers, and flips it out of draft through finalize_pr.sh so no reviewer is dropped and the review cycle (shipshape:handle-pr) starts right after. Load BEFORE running `gh pr create`, `gh pr edit` or `gh pr ready`, and before drafting or rewriting any PR title or description. Triggers: "create a PR", "open a pull request", "write the PR description", "update the PR body", "fix the PR title", "flip the PR out of draft", "mark the PR ready", "add reviewers", "создай PR", "открой пулреквест", "обнови описание PR", "выведи из драфта". Do NOT use for reviewing someone else's PR or for the review rounds (shipshape:handle-pr).
---

# write-pr: a pull request's text, and the flip out of draft

Load this when a PR is created or its text is edited, not earlier. It owns the PR's title, body, labels, assignee and the flip out of draft. The review rounds that follow belong to `shipshape:handle-pr`.

**Project rules come first.** The repository's own conventions win where they differ from the defaults below: a PR template, CONTRIBUTING.md, CLAUDE.md or AGENTS.md, a label policy, or an add-on skill your instructions name for this repo. An add-on that sets the body shape, the reviewers or the flip command replaces the matching section here. Everything else here still applies.

Apply `shipshape:writing-rules`, plus any add-on your instructions name, to the title and body before posting either.

## Title

Follow the repo's convention, which you can read from recent merged PR titles (`gh pr list --state merged --limit 10`). With none, use Conventional Commits: `<type>(<scope>): <summary>`, where the scope is one lowercase subsystem and the summary is imperative, starts lowercase, has no trailing period and stays under 70 characters.

## Body

Default shape, when the repo has no template:

```
## Summary
- <what changed and why>
- <what changed and why>
```

- Lead with what changed and why. A reviewer reads the diff for how.
- Residual risk a reviewer cannot see in the diff belongs in the bullets: a migration, a behavior change, a known gap. Do not drop it to keep the body short.
- Link the issue or task the PR resolves (`Closes #N`, or the tracker URL) when there is one.
- No "Files changed" list, no restated diff, no test plan or screenshots section unless the repo or the user asks for one. Extra sections are the most common defect in a first draft.

## Creating the PR

```bash
gh pr create --draft --assignee @me --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

- **Open as a draft** when anything still has to happen before review (CI, a visual check, a self-review), so no reviewer is pulled in early. Open it ready only when the user asks for that, or the repo does it that way.
- **`--assignee @me`**, draft or not. `finalize_pr.sh` checks it and adds it if it is missing.
- **Labels** come from the repo's own policy. Read it rather than guessing from the diff.

## Cross-repository links

- Write a PR or issue in another repo as `owner/repo#N` or as the full URL. A bare `#N` links to the current repo's own #N.
- When a change spans repos, link both directions: the dependent PR says `Depends on <url>`, the other says `Required by <url>`.

## The flip: `finalize_pr.sh`, never by hand

```bash
<this skill's base dir>/scripts/finalize_pr.sh <num> --repo <owner>/<repo> [--team <org/team>] [--reviewers a,b] [--exclude a,b]
```

It flips the PR with `gh pr ready`, adds you as assignee if missing, and requests review in one call:

- `--team <org/team>`: the team's members, minus you, bots and `--exclude`.
- `--reviewers a,b`: these logins, for example a review bot that is not on the team.
- With neither, nothing is requested, and GitHub's CODEOWNERS and auto-assignment rules pick the reviewers.

It asks for confirmation first. Pass `--no-confirm` once the user has approved the flip.

Never hand-roll the flip. A manual `gh pr ready` followed by a hand-made reviewer list is how a reviewer gets dropped. Never pass a team handle as a reviewer either: once one member reviews for the team, GitHub hides the other members.

**Start the review cycle in the same turn.** Load `shipshape:handle-pr` for the PR right after the flip, whether or not a larger workflow is driving. The script's last line says so (`NEXT: load shipshape:handle-pr ...`). A PR without it has no watch, so reviews and CI failures reach no one.

## Check what you posted

After `gh pr create` or `gh pr edit`, read the PR back and confirm the shape before moving on:

```bash
gh pr view <num> --repo <owner>/<repo> --json title,body,labels,assignees,isDraft \
  --jq '{title, isDraft, labels: [.labels[].name], assignees: [.assignees[].login], body}'
```

Fix and check again, rather than reporting what you meant to post.