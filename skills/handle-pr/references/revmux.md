# revmux rounds from an orchestrating skill

revmux runs a supervised multi-agent review (parallel claude and codex agents, then synthesis and verification) and returns the findings as JSON. This file is how an orchestrating skill runs one round without pulling review text into the conversation. It serves `handle-pr` (a re-review before each fix round is pushed) and any caller with its own checkpoints. The caller picks the checkpoint and the profile; everything below is the same for every round.

The mechanics belong to the `revmux` skill from the `revmux@revmux` plugin and its scripts. This file points at them instead of restating them, and lists where an orchestrator departs from that skill.

## Locate the revmux skill

```bash
RVX="$(jq -r '.plugins["revmux@revmux"][0].installPath // empty' ~/.claude/plugins/installed_plugins.json)/.claude-plugin/skills/revmux"
```

`$RVX/SKILL.md` holds the round-preparation brief (Step 2), `$RVX/scripts/preflight.sh` and `task-state.sh` the checks, `$RVX/references/output.md` the JSON shape and the run archive. Resolve the path into every brief as an absolute path: a subagent has no skill loaded and no variable to expand.

If the plugin is missing (no `$RVX/SKILL.md`) or preflight fails (`$RVX/scripts/preflight.sh <profile>` exits 1 naming a missing `revmux` or model CLI), push the user and continue without that round only on their word, recorded in the state file. A checkpoint that silently did not run reads as one that came back clean.

## Where this departs from the revmux skill

- **No question after each round, no `present.md` turn, no progress Monitor.** The orchestrator owns the flow: confirmed findings get fixed, everything not being fixed goes to the user. The user is not asked to pick what to fix from a list.
- **The checkpoint picks the profile; nobody is asked.** `expert` is the one exception: it runs only when the user asked for it in words, because it costs several times `comprehensive` and the revmux skill forbids inferring it from the subject.
- **Always headless, never `launch-revmux.sh`.** The overlay launcher needs a supported terminal. In a background session with no tty it exits 3 (`no overlay terminal available`), and inside tmux it opens a popup nobody is watching. Pass `--no-tui` explicitly: revmux also falls back to plain stderr progress when it cannot open a tty, but the flag makes the run independent of where the session happens to be.
- **Keep revmux's own codex models** (`gpt-6.1-sol` in most profiles, `gpt-6-astra` in `expert`). Do not override a profile to pin another model: a global rule that every codex call uses one model deliberately does not apply to revmux.
- **No archive housekeeping.** Never run `revmux cleanup` from a workflow. That is the user's call.

## Storage in the repo

revmux keeps rounds in `./.revmux/tasks` relative to where it runs, so run it from the checkout root of the branch under review, the worktree if there is one. The run archive (`.revmux/tasks/`) is git-ignored. Everything else under `.revmux/` (a `profile.md`, custom profiles and lenses, a config) is committed as the project's review standard.

**The first time revmux runs in a repository**, check that the archive is ignored by the repo itself, not just by a global excludes file on this machine:

```bash
git -c core.excludesFile=/dev/null check-ignore -q .revmux/tasks/x || echo '.revmux/tasks/' >> .gitignore
```

If the entry was added, commit it, with any other `.revmux/` file, on the current branch (`chore(<scope>): ignore revmux run archives` in the repo's convention). It rides along in this PR rather than getting a task or PR of its own. Never run `revmux init` on your own: it copies every prompt file into the repo and freezes them at this version. Mention it only when the project wants its own lenses or profiles. A project `profile.md` follows the revmux skill's Step 0.5: offer it once, write it only on the user's yes.

## One round

1. **Task and label.** One task per unit of work so every round sees the earlier ones: the caller's task id if it handed one over, otherwise `pr-<num>`. The label is the checkpoint's (`plan`, `impl`, `pre-flip`, `fix-r<N>`). The preparing agent puts the `NN-` prefix on it.
2. **Preflight** once per profile per session: `$RVX/scripts/preflight.sh <profile>`.
3. **Prepare the round in a subagent.** Measure the scale here (`git diff <range> --shortstat`), then spawn one `general-purpose` agent:

   > Read `<RVX>/SKILL.md`, section "Step 2: Prepare the round", and follow the brief quoted there exactly. Its values: scope `<range and what it is>`, scale `<shortstat>`, exclusions `<list or none>`, task id `<id>` (use it verbatim), round label `<label>` (prefix it `NN-` per the brief's step 4), task-state script `<RVX>/scripts/task-state.sh`. Goal: `<the checkpoint's goal line>`. Return the JSON the brief asks for.

   Check that `round_dir` is set and `wrote` is not empty before launching.
4. **Launch in the background**, from the checkout root, with Bash `run_in_background: true`:

   ```bash
   revmux --task <task> --run <run> --profile <profile> --no-tui \
     > <round_dir>/revmux.json 2> <round_dir>/revmux.log
   ```

   Never `2>&1`: stderr is progress and breaks the JSON. Say one line (task, round, profile, roughly 5 to 20 minutes, `tail -f <round_dir>/revmux.log` for live progress) and set `nextGate` to reading this round. Then carry on with independent work or yield; the completion notification wakes the session. On a status request, read the log's tail. Never poll.
5. **Read the outcome, counts only.** The exit code and this summary are all that enter the conversation:

   ```bash
   jq '{expected: .sources.expected, reported: .sources.reported, degraded: .sources.degraded,
        silent: [.sources.agents[] | select(.raised == 0 and (.degraded | not)) | .name],
        severities: [.findings[].severity], open_questions: (.open_questions | length)}' <round_dir>/revmux.json
   ```

   - **Exit 2, or `reported` 0: a tool failure, never a clean round.** The log's tail names the cause. If `<round_dir>/findings.json` exists, the review finished and only stdout failed: read that instead. Otherwise fix the cause and retry once as a new round with this round's `input/` copied across (the two output files make revmux refuse the old name). A second failure goes to the user.
   - **`degraded` not empty: a partial round.** Use what it found, and name the missing source in the report and the state file. "No findings" from a partial round is not "clean". A name in `silent` reported nothing at all; mention that too.
   - **Exit 0, nothing degraded, no open questions:** clean. Record it and move on.
   - **Exit 1, or open questions:** step 6. Exit 1 is the normal outcome, not a failure.
6. **Verify and fix in one subagent** (session model, this needs judgment). Brief it self-contained: repo, checkout path, `round_dir`, what the change is for, decisions already made that findings must not re-litigate, and the project's validation commands.

   > Read `<round_dir>/findings.json` (shape: `<RVX>/references/output.md`); skip `immaterial` and `pre_existing`. A review is a hypothesis: verify each entry of `findings` against the code as written (quote the line, check every premise) and classify it VALID, PARTIALLY-VALID (real, but the remedy is wrong; give the right one) or INVALID (with the evidence). Fix every VALID and PARTIALLY-VALID finding at its root cause. Before calling a fix done, grep for the same construct elsewhere and fix every occurrence, and add a regression test where the project's conventions call for one. Run the validation and leave it green. Do not commit or push. Turn each open question into a one-line decision for the user. Report per finding in at most four lines: `[id] severity | file:line | VERDICT | fixed or not`, then the evidence. No raw review text.

7. **Close the round.** Verify the fixes the way the caller verifies any fix (trace the claim, confirm a test drives each touched call site), then commit them where the caller's flow commits. INVALID findings, deferrals and open questions go to the user via `AskUserQuestion` with the evidence. No finding is dropped without the user's word. Append to the state file's `revmux.rounds`: `{"run","profile","exit","degraded","confirmed","fixed","disputed"}`, and clear the `nextGate` that pointed at this round.

Fixes to one round's findings are not re-reviewed by another round at the same checkpoint. The next checkpoint (or the next reviewer round on the PR) covers them, which keeps a checkpoint from turning into an open-ended loop.
