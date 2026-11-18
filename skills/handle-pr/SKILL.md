---
name: handle-pr
description: Watches a GitHub PR through its review cycle and drives it to clean — keeps a watch on reviews, inline comments, CI and state flips, then runs one triage-fix-push-rerequest round per review until no reviewer has open findings, and tidies the conversation at the end. The main agent stays a pure orchestrator: every review round runs in a subagent, so a 20-round PR costs the conversation a few hundred words instead of tens of thousands. Use when the user says "handle PR N", "watch PR N", "watch the PR", "babysit PR N", "monitor the PR", "iterate on the review", "close the review comments", "отреагируй на ревью", "своди ревью", "последи за PR", when a workflow hands off a PR that has reviewers requested, and right after any flip out of draft (`shipshape:write-pr`'s `finalize_pr.sh` ends with a `NEXT: load shipshape:handle-pr` line), with or without a workflow. Do NOT use for reviewing someone else's PR, creating a PR, or merging one.
---

# handle-pr — watch and iterate a PR until the review cycle is clean

Company-agnostic. Owns the watch, the per-round iteration loop, and the end-of-run cleanup. Out of scope and caller-specific: flipping out of draft and choosing reviewers (`shipshape:write-pr`), merging.

## Runtime

Check `echo "${T3CODE_THREAD_ID:-}"` in Phase 0. A value means this session is a T3 Code thread, empty a terminal session. Everything here applies to both. In T3 three things change:

- **The watch.** It is the same `watch_pr.sh`, run as a job of the [t3-jobs](https://github.com/nnemirovsky/cc-t3-jobs) plugin that posts its lines to this thread's webhook (Phase 1, In T3), not a Monitor. The job survives the thread's Claude session and needs no re-arm. Without that plugin installed, use the Monitor as in a terminal session.
- **The state file** also records `"t3ThreadId"` (Phase 0 step 3).
- **Pushes.** Rule 9's push becomes the turn's last line starting with 📣, because T3 pushes the phone when the turn ends. Do not call `PushNotification` there.

That unit is the PR's only watch, and it overrides T3's own PR instructions (call `watch_pull_request` to monitor a PR, no Monitor for PR waits). A second watch wakes this thread twice on every event, so each review gets reported twice. Link the PR with `link_pull_request` as T3 asks, but never call `watch_pull_request`. If `list_thread_pull_requests` shows the PR with `watching: true`, call `unwatch_pull_request` on it.

## Hard rules

These are what the loop breaks without. A long run drifts far from this text, so Phase 0 copies them into a state file and the goal task — re-read that file at the top of every round.

1. **The main agent is a PURE ORCHESTRATOR.** It never reads review bodies, never greps the repo, never edits code. It runs `gh` / `git` / test commands, parses their output, spawns agents, talks to the user, maintains the state file. A review round's content belongs in a subagent's context, not this conversation — that is the whole point of this skill, and the reason a 20-round PR stays workable.
2. **Every finding is verified before it is actioned.** A review is a hypothesis. Confirm the defect exists in the code as written before changing anything, and confirm a cited rule or API actually says what the finding claims.
3. **No dispute without the user.** Any finding not being fixed — invalid, out of scope, deferred — goes to the user before any reply or resolution is posted. No autonomous push-back.
4. **Re-request only on green CI, first attempt.** Never pull a reviewer back to a PR whose checks are pending, failing, or passed only on a re-run. A `run_attempt > 1` green is itself a finding to fix first. Two exemptions, both on the same reasoning — there is no pending result the reviewer could be pulled ahead of. A repo with no CI at all: confirm zero check-runs AND zero workflow runs, re-query once, then proceed. A diff no check can act on, such as a docs-only or comment-only change: confirm the diff touches nothing any workflow builds or tests, then proceed without waiting. Neither exemption applies the moment the diff reaches a built or tested path.
5. **Push before touching threads.** Commit and push first, then resolve or reply. Resolving at an unchanged head reads as a dispute signal to review bots and can burn a round.
6. **Never resolve a thread silently unless the finding was fixed in full.** Fixed completely → resolve. Disputed → post the user-approved rationale, then resolve. **Partially fixed → say which part was done and which was not, and why, before resolving** — a finding naming two files whose fix adds one of them is an incomplete fix, and resolving it without a word reads as exactly that. Reviewers re-derive findings from the code rather than trusting the resolved flag, so an undocumented decision to decline half a finding is indistinguishable from having missed it, and it returns next round. When declining any part of a finding, the reason goes on the thread, not only into this conversation.
7. **An addressed `CHANGES_REQUESTED` must be dismissed.** It pins `reviewDecision` and blocks the merge bar until the reviewer returns or you dismiss it. Re-requesting alone does not clear it. Dismiss only after the fix is pushed and CI is green.
8. **No foreground sleeps.** All waiting goes through the Phase 1 watch.
9. **Push on what the user would act on.** A `PushNotification` (one line, under 200 characters; in T3 a 📣 last line instead, see Runtime) when a review arrives and whether it blocks, when a round is pushed and re-requested, when CI goes red, when the PR reaches `APPROVED`, and when a finding needs the user's decision. Not for a relaunch, a heartbeat or a CI status change on its way to green.
10. **The watch stays up until the PR merges or closes, or the user says stop.** The Monitor watch from Phase 1 is re-armed by monitor-rearm at every 30-minute expiry without waking you. Every exit that does reach you (an expiry after a day of re-arms, a background command finishing, a kill) is followed by a relaunch in the same turn. A quiet reviewer, a night or a weekend never stops the watch. Stopping it is the user's call, not yours. When they do stop it, run `TaskStop` with the watch's first task id (in T3: `$J stop <job>`) and set `"watch": "stopped"` in the state file so the run-state hook stops asking for a relaunch. Remove the field when they ask for the watch back. In T3 the job restarts itself after a crash, so only `WATCH: NOT RUNNING` from the run-state hook needs a `$J start`.

## Scripts (`./scripts/`)

- `watch_pr.sh <num> --repo <o>/<r> [--once]`: polls the PR every 60 s and prints one line per delta. The default stream mode is for a Monitor. `--once` exits after the first delta and is the background Bash fallback. The snapshot persists across runs and modes, so a restart prints only what changed since the last run. Prints `STOP` on MERGED/CLOSED and `ALREADY_RUNNING` if this PR is already watched
- `list_unresolved_threads.sh` / `list_review_bodies.sh` — inline threads / full review bodies (both paginate)
- `resolve_threads.sh <thread-id>...` — close threads
- `request_reviewers.sh <num> --repo <o>/<r> --reviewers a,b` — re-request
- `cleanup_pr.sh <num> --repo <o>/<r> [--apply] [--claude]` — minimize superseded bot reports and stale review overviews; dry-run by default

`references/revmux.md` — how a revmux round runs from this skill: storage, launch, reading the outcome, the verify-and-fix agent. Read it before the first Phase 3.5.

## Phase 0 — Preflight

1. Resolve the PR: `gh pr view <num> --repo <o>/<r> --json number,url,state,isDraft,headRefOid,reviewDecision,reviewRequests`. On a colleague's PR the user took over, add the user as assignee and keep the original: `gh pr edit <num> --repo <o>/<r> --add-assignee @me`.
2. **Set the session goal** via `TaskCreate`: `Drive PR #<num> review cycle to clean`, marked `in_progress` immediately. This survives context compaction and stays open until Phase 5. A pushed round or a green CI is progress, not the goal.
3. **Write the state file** `~/.local/state/shipshape/handle-pr-<owner>-<repo>-<num>.json` (`$XDG_STATE_HOME/shipshape/` when that is set; create the directory with mode 700). Never put it inside the repo: it must survive compaction.
   ```json
   {"repo":"<o>/<r>","pr":<num>,"round":0,"lastReviewId":0,"nextGate":"launch the PR watch","status":"active",
    "fixed":[],"disputed":[],"deferred":[],"awaitingUser":[],
    "revmux":{"task":"pr-<num>","rounds":[]},
    "gates":["verify before actioning","no dispute without the user",
             "revmux final round on the committed fixes before the push",
             "re-request only on first-attempt green CI","push before threads",
             "dismiss an addressed CHANGES_REQUESTED"]}
   ```
   In a T3 thread add `"t3ThreadId":"<$T3CODE_THREAD_ID>"`, so an orchestrating session can find this thread.
   `revmux.task` is the caller's revmux task id when it handed one over (so this PR's rounds stack on the ones that ran before it opened), otherwise `pr-<num>`.
   Re-read it at the top of every round and update it at the end of every phase that changes it. When this conversation has drifted and the hard rules above feel hazy, this file is the source of truth.

   Set `status` to `done` once the PR is merged or closed (the watch prints `STOP`). The hook stops injecting a run at that point, so a finished PR does not keep appearing in unrelated sessions.

   **Keep `nextGate` pointed at the one thing this round has not done yet** — `launch the PR watch`, `run the revmux final round on the round 3 fixes, then push`, `push the fixes for round 3`, `dismiss the addressed CHANGES_REQUESTED`, `re-request reviewers once CI is green first-attempt`. Clear it the moment it is done and set the next. The hook re-injects it on every prompt, so it is the part of this skill that survives a twenty-round PR; the prose here does not.
4. Create one task per hard-rule gate that has a decision point, with the rule **in the task title** — task text is re-surfaced by the harness, this skill's prose is not. For example: `Dismiss CHANGES_REQUESTED only after fix pushed AND CI green first-attempt`.

## Phase 1 — Launch the watch (MANDATORY)

Start the watch as a `Monitor` from the main conversation, for the whole life of the PR:

`Monitor`, command `./scripts/watch_pr.sh <num> --repo <o>/<r>`, `timeout_ms: 1800000`

It wakes the session on every delta and runs until `STOP`. The monitor-rearm plugin keeps it up. When a Monitor started with `timeout_ms` 1800000 expires, the plugin starts it again with the same input and drops the expiry notice, so no turn is spent on it. Three things follow:

- Ask for exactly `timeout_ms: 1800000`. A shorter Monitor expires as usual and is not re-armed.
- Launch it from the main conversation. A Monitor started inside a subagent is not re-armed.
- A re-armed watch gets a new task id and its events carry that id. `TaskStop` with the id of the first launch still stops it.

**When an exit reaches you, relaunch in the same turn.** After 24 hours of re-arms the expiry reaches you as usual: launch the same Monitor again. A 30-minute expiry that reaches you means monitor-rearm is not loaded in this session. It loads at session start, so relaunch the Monitor yourself and ask the user for `/reload-plugins` or a restart. If the Monitor tool is unavailable, fall back to `Bash` with `run_in_background: true` and the command `./scripts/watch_pr.sh <num> --repo <o>/<r> --once`. That run wakes the session once on the first delta and exits. It also exits every 4 hours with a `HEARTBEAT` line and no delta. That wake-up exists only to stop the supervisor retiring an idle session: relaunch and say nothing.

A watch the system killed for low memory is the exception: the harness will not let you relaunch it on your own, so push the user and relaunch when they say so. The run-state hook shows `WATCH: NOT RUNNING` on every wake-up until a watch is back up. Only a `STOP state=MERGED` or `STOP state=CLOSED` line ends the watch for good. `ALREADY_RUNNING` means another watch on this PR is alive: launch nothing. To restart a running watch, stop it with `TaskStop` first.

Both modes share one snapshot file per PR, so every restart (a re-arm included) continues where the last run stopped. It prints only what changed since then and misses nothing that landed in between. Only the very first run on a PR prints a baseline, and in background mode the baseline alone does not end the run.

### In T3: a t3-jobs job instead of the Monitor

In a T3 thread, with the t3-jobs plugin installed, none of the Monitor text above applies (re-arm, relaunch, `--once`, `TaskStop`). Load the `t3-jobs:t3-jobs` skill. It owns the mechanics. `$J` below is its `t3_job.sh`, at that skill's base directory plus `/../../scripts/t3_job.sh`.

1. **Once per thread, a webhook.** Follow the t3-jobs skill's step 1, unless `$J status` already lists a job for this thread. Record the task id as `"t3WebhookTask"` in the state file.
2. **Start the watch:** `$J start pr-<owner>-<repo>-<num> -- <this skill's base dir>/scripts/watch_pr.sh <num> --repo <o>/<r>`. Lowercase the job name, and replace any character outside letters, digits and dashes with a dash. Each batch of lines arrives as a new turn whose text holds the lines, and is handled exactly like Monitor events. `ALREADY_RUNNING`, from `$J` or as a posted line, means a watch on this PR is up already, for example a Monitor from before: start nothing.
3. **While it runs.** The job restarts itself 30 s after a crash and ends with `STOP`, so there is nothing to re-arm or relaunch. `$J status pr-…` shows its state, and the run-state hook shows `WATCH: running (t3-jobs job, pid …)`.
4. **At the end (Phase 6).** When none of this thread's jobs is still running (`$J status`), delete the webhook task with `mcp__t3-code__delete_scheduled_task` and drop `t3WebhookTask` from the state file.

The script drops bodies from its projection (control characters crash diffing) and filters self-authored events. It emits `REVIEWS`, `INLINE`, `ISSUE_COMMENTS`, `CHECKS`, `STATE`, and a synthetic `CLEANUP_SUGGESTED` after a non-first green CI on a new head. A background run's lines are in its output file; read that file when its notification arrives. Report the delta in one sentence. Do **not** fetch review bodies here — that is Phase 2's subagent's job.

## Phase 2 — Triage the round (subagent)

On a new review or new inline comments, spawn ONE triage agent (`Agent`, session model — this needs judgment). It is a verifier: it does not edit, commit, push, reply, or resolve. Brief it self-contained (it cannot see this conversation): the repo, PR number, worktree path, head SHA, what the PR does, any decisions already made that findings must not re-litigate, and the verification bar below.

```
Fetch the review and every unresolved thread (gh api --paginate; a non-paginated
reviews query silently misses the latest review on a busy PR). Read the review BODY
as well as the inline threads — the body routinely carries asks that are in no thread.

Verify EACH finding against the code at HEAD: is the defect actually present as
written (quote the line); is every premise true (open the cited rule / run the cited
call); what is the blast radius of the suggested fix; which tests pin the area.

Classify: VALID | PARTIALLY-VALID (real, but the suggested remedy is wrong — say what
the right one is) | INVALID (with the evidence that disproves it).

Report per finding, max 6 lines each:
[n] SEVERITY | path:line | thread_id=<id> | VERDICT
Claim / Evidence / Fix (exact minimal change, or "none — disproved because ...")
Then: verdict-body asks not covered above, shared root causes, anything the reviewer missed.
Do not include raw review text.
```

Its report is what enters this conversation — a few hundred words per round instead of the full review. Record the classification in the state file.

If the agent goes idle without its report arriving, ask for it explicitly rather than waiting or re-running the triage. The completion signal and the final message do not always arrive together, and the agent's context survives, so a resend costs nothing and a re-run costs a full round. If the resend does not produce it either, do that round's work yourself in the same turn. Never wait a second time, and never announce a fallback ("I'll do it myself if it does not answer") without executing it right then — a stated intention with no tool call beside it is how a stalled agent turns into a stalled session.

When a finding names several files or several changes, treat the whole list as the unit of work. Adding some and dropping the rest is the most common way a round repeats itself. If part of it should be declined, that is a decision to record on the thread, not to leave implicit.

Then split the list: VALID and PARTIALLY-VALID go to Phase 3. Everything INVALID or deferred goes to the user via `AskUserQuestion` (batch up to 4) with the evidence summary — hard rule 3. The user's decision is final and gets recorded in the state file.

## Phase 3 — Fix (subagent)

Spawn ONE developer agent per round with the full fix list — findings often share files, and parallel agents conflict. Give it the triage evidence, the governing convention files, and the project's build/test commands. Require: root-cause fixes, a regression test where the project's conventions call for one, and a per-finding report of what changed.

**Verify the fix itself, not only the finding.** A fix that reads well is not evidence. Trace its specific claim through the code, or run the command it prescribes, exactly as you would for a finding. This matters most when the fix authors PRESCRIPTIVE text a future reader will act on (a direction, an ordering, a command, a threshold): plausible reasoning around a correct diagnosis routinely carries an inverted or unrunnable remedy, and reviewing the diff for coherence will not catch it. When a fix corrects one side of a symmetry, check the other side was not left contradicting it, and check the symmetry is real before writing the fix as a mirror of it. **When a fix touches several call sites, confirm the test exercises EACH of them.** A red-proof on one site is evidence about that site and nothing else: a fix can be correct at three call sites and dead on arrival at the fourth, and the suite will still go green. Ask which site each test drives before accepting the coverage as proof. Two mechanisms that look parallel often are not, and narrating the asymmetric one in the symmetric one's shape produces confident claims that were never true of it.

Then run the project's validation (format, build, full test suite) and confirm it green. Any failure is in scope for this round, including in tests the round did not touch — hand the output back to the developer agent. The orchestrator does not fix code itself.

Commit the round's fixes locally. Do not push yet.

## Phase 3.5 — Re-review the fixes before the push (revmux)

Before a reviewer is pulled back, run one revmux round on the same task over this round's fixes, profile `final`: two agents, nothing below major reported. It catches a fix that does not answer its finding or breaks something next to it, before a human or a bot spends a round on it. Scope: the range from the last pushed head to `HEAD`, with the branch diff against the base named as context. Label `fix-r<round>`. Run it in the background per `references/revmux.md`, which also covers reading the outcome and the verify-and-fix agent.

- Confirmed findings get fixed by that agent, verified as in Phase 3, validated green and committed before the push. They ride this round's push; no second revmux round runs on them.
- A finding not being fixed goes to the user, as in Phase 2 (hard rule 3).
- Exit 2, or every source degraded, is a tool failure: surface it and do not treat the round as clean. One degraded source is a partial round: say so in the round report.
- A round with no code change (every finding disputed) has nothing to re-review: skip it.

Record the run in the state file's `revmux.rounds`.

## Phase 4 — Push, then close the round

In this order — hard rule 5:

1. Push (the fixes and the Phase 3.5 fixes are already committed).
2. Resolve each fixed thread (`resolve_threads.sh`). For threads from humans, post a short "fixed in `<sha>`" first — a human does not re-derive the fix from code the way a bot does.
3. Post the user-approved rationale on each disputed thread, then resolve it. Self-contained and quotable; a deferral names its follow-up.
4. Wait for CI green on the new head, first attempt (hard rule 4).
5. Dismiss any addressed `CHANGES_REQUESTED` (hard rule 7):
   ```bash
   gh api -X PUT "repos/$REPO/pulls/$PR/reviews/$ID/dismissals" -f message="fixed in <sha>" -f event=DISMISS
   ```
   Short message — a pointer, not a re-explanation. The endpoint only acts on `CHANGES_REQUESTED` / `APPROVED`; a plain `COMMENTED` review cannot be dismissed, so reply and leave it or minimize it in Phase 5. If a permission gate blocks the call, surface it to the user — never silently fall back to re-request-only, which leaves the merge bar blocked.
6. Re-request the reviewer (`request_reviewers.sh`), including reviewers who already approved — a fresh push makes an old approval stale. Skip when the user has a standing instruction not to re-request that person.
7. Bump `round`, set `lastReviewId`, update the state file. The push and re-request above start a burst of CI and review events, and the Monitor watch reports each one. If the run-state hook shows the watch is not running, relaunch it now (Phase 1).

Apply `shipshape:writing-rules` to every reply, dismissal message, and commit message, together with any add-on your instructions name for that destination.

## Phase 5 — Clean up the conversation

Once no reviewer has open findings, or when the watch reports `CLEANUP_SUGGESTED`, run `cleanup_pr.sh <num> --repo <o>/<r>` (dry run) then `--apply`. It minimizes superseded bot report comments, keeping the newest of each kind when it is still relevant to the head, and superseded review overviews, keeping each reviewer's latest live one. Delegate anything ambiguous to a subagent that reads the actual bodies — never match on heading text. When unsure whether a comment is signal, keep it.

Minimize (reversible) rather than delete:
```bash
gh api graphql -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' -F id="<node_id>"
```

## Phase 6 — Return control

Mark the goal task complete. In T3, delete the thread's webhook task once none of its jobs runs (Phase 1, In T3, step 4). Report in one line: PR, `reviewDecision`, CI state, rounds run, findings fixed / disputed / deferred, what cleanup did.

## Anti-patterns

1. **DO NOT** read review bodies, diffs, or source files from the orchestrator — that is what fills the conversation and makes round 10 worse than round 1.
2. **DO NOT** action a finding without verifying it. Reviewers invent API shapes, cite rules that say something else, and raise edge cases that cannot occur at the project's real volume. Verified push-back is a correct outcome.
3. **DO NOT** dispute, defer, or skip a finding without the user's decision.
4. **DO NOT** resolve a thread whose defect is not fixed and carries no rationale.
5. **DO NOT** reply or resolve before pushing.
6. **DO NOT** re-request on pending, red, or re-run-green CI.
7. **DO NOT** leave an addressed `CHANGES_REQUESTED` standing — it blocks the merge bar for hours while looking handled.
8. **DO NOT** push a fix round before its revmux round has come back and its confirmed findings are fixed.
9. **DO NOT** add defensive layers, retries, or fallbacks a finding suggests "just in case" without a concrete failure case that has happened or is likely.
10. **DO NOT** wait with foreground sleeps or tight polls.
