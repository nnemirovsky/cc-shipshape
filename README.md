# Shipshape

Skills for keeping GitHub work in good order: repositories set up to a sound baseline, pull requests taken from draft to merged without babysitting, and the text you send to other people kept plain and human.

## Skills

| Skill | What it does |
|---|---|
| `write-pr` | Writes the PR's title, body, labels and assignee, opens it as a draft, and flips it out of draft with `finalize_pr.sh`, which requests every reviewer in one call. Then hands over to `handle-pr`. |
| `handle-pr` | Watches the PR through its review cycle and drives it to clean. It reacts to every review, inline comment, CI result and state change: verifies each finding, fixes the valid ones in a subagent, re-reviews the fixes, pushes, resolves threads, dismisses an addressed `CHANGES_REQUESTED`, and re-requests review on green CI. It tidies superseded bot reports at the end. |
| `writing-rules` | Style rules for text that leaves Claude Code for another human: PR text, review replies, commit messages, chat posts, emails. Plain ASCII, no filler, no AI voice. |
| `gh-notif-cleanup` | Clears stale GitHub notifications: merged and closed PRs and failed CI runs. Open work is kept. |
| `repo-setup` | Sets up a new repository, or audits and fixes an existing one, to a vetted baseline per kind (Claude Code plugin, MCP server, library, private repo). It covers squash-only merges, rulesets protecting main and release tags, secret scanning, private vulnerability reporting, Dependabot, CodeQL and immutable releases, plus the community files and CI and release workflows. Scripts show a diff before they change anything. |

## handle-pr in more detail

The main conversation stays a pure orchestrator. Each review round is triaged, fixed and re-reviewed in subagents, so a twenty-round PR costs the conversation a few hundred words per round instead of every review's full text.

- **Every finding is verified before it is acted on.** Reviews are hypotheses: the triage agent checks each one against the code as written and classifies it valid, partially valid or invalid, with evidence.
- **Nothing is disputed without you.** A finding that will not be fixed goes to you, with the evidence, before anything is posted.
- **Re-review only on green CI, first attempt.** A reviewer is never pulled back to a PR whose checks are pending, red, or green only on a re-run.
- **Push before touching threads**, and never resolve a thread silently unless its finding was fixed in full.
- **A state file in `/tmp`** keeps the round, the gates and the next step. A hook brings them back on every prompt, so a long run does not drift.

The watch is `watch_pr.sh`. It polls the PR every 60 seconds and prints one line per change: new reviews, inline comments, issue comments, checks, and state or draft or review-decision changes. It keeps a snapshot, so a restart prints only what changed in between. It exits when the PR is merged or closed.

- **In a terminal session** it runs as a Claude Code `Monitor`. Install [monitor-rearm](https://github.com/nnemirovsky/cc-monitor-rearm) so the 30-minute Monitor cap does not wake Claude.
- **In a [T3 Code](https://github.com/pingdotgg/t3code) thread** it runs as a job of [t3-jobs](https://github.com/nnemirovsky/cc-t3-jobs). The job survives the thread's Claude session and needs no re-arm.

Before each fix round is pushed, `handle-pr` runs a [revmux](https://github.com/umputun/revmux) multi-agent review over the fixes. That needs the `revmux` binary and the `revmux@revmux` plugin. Without them it asks you once whether to go on without that check.

## Company and project rules

The skills are company-agnostic. A repository's own conventions take precedence: a PR template, CONTRIBUTING.md, CLAUDE.md or AGENTS.md, a label policy. For house rules that go further, write a small add-on skill in your own plugin and tell Claude in your CLAUDE.md to load it together with the shipshape skill. For example:

> For PRs in work repos load `acme:write-pr` together with `shipshape:write-pr`. It sets the body shape and the flip command.

`write-pr` and `writing-rules` say outright that a named add-on is applied too and wins where it is more specific. `finalize_pr.sh` takes `--team`, `--reviewers` and `--exclude`, so an add-on only has to pass its own reviewer set.

## Install

```
/plugin marketplace add nnemirovsky/cc-shipshape
/plugin install shipshape@shipshape
```

Needs `gh` (logged in), `jq` and `bash`. Recommended: [monitor-rearm](https://github.com/nnemirovsky/cc-monitor-rearm), and [t3-jobs](https://github.com/nnemirovsky/cc-t3-jobs) if you use T3 Code. Optional: [revmux](https://github.com/umputun/revmux).

## License

MIT