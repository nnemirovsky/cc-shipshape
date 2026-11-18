#!/bin/bash
# UserPromptSubmit: re-inject a pointer to any active handle-pr run in this repo.
# A skill body is injected once and gets summarized away as the conversation
# grows; this line comes back on every turn, so the run's round, its NEXT gate
# and whether its PR watch is alive survive a long review cycle. Silent, and exit
# 0, when nothing applies: it must never disrupt an ordinary session.
#
# A BASH script (arrays, shopt): hooks.json runs it with `bash` and appends
# `|| true`, because a UserPromptSubmit hook that exits non-zero blocks the
# prompt.
set -u
shopt -s nullglob

files=(/tmp/handle-pr-*.json)
[ ${#files[@]} -eq 0 ] && exit 0

# The state files live in /tmp and are visible from every project, so a run is
# scoped to its repo. A worktree lives under its repo, so trimming the worktree
# suffix maps both to one root: a run stays visible from the main checkout and
# from any of its worktrees.
dir="${CLAUDE_PROJECT_DIR:-$PWD}"
here="${dir%%/.claude/worktrees/*}"

# watch_pr.sh records how it runs in its pid file.
watch_mode() {
  case "${1:-}" in
    stream) echo "Monitor" ;;
    once) echo "background --once" ;;
    job) echo "t3-jobs job" ;;
    *) echo "${1:-?}" ;;
  esac
}

out=""
others=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  # Ignore stale state from a run older than 7 days, and finished runs.
  [ -n "$(find "$f" -mtime +7 -print 2>/dev/null)" ] && continue
  [ "$(jq -r '.status // ""' "$f" 2>/dev/null)" = "done" ] && continue

  # Rows from another repo are counted, not printed. Only an absolute path can
  # be placed: a row without one is shown, because hiding a session's own live
  # run is far worse than showing one extra row.
  rowdir=$(jq -r '.cwd // .worktree // ""' "$f" 2>/dev/null)
  case "$rowdir" in
    /*) rowdir="${rowdir%%/.claude/worktrees/*}" ;;
    *) rowdir="" ;;
  esac
  if [ -n "$rowdir" ] && [ "$rowdir" != "$here" ]; then others=$((others+1)); continue; fi

  line=$(jq -r '
    (if (.nextGate // "") != "" then " | NEXT: \(.nextGate)" else "" end) as $next
    | "handle-pr \(.repo // "?")#\(.pr) | round \(.round // 0) | fixed=\((.fixed // []) | length) disputed=\((.disputed // []) | length) awaiting-user=\((.awaitingUser // []) | length)\(if .worktree then " | worktree: \(.worktree)" else "" end)\($next)"' "$f" 2>/dev/null) || continue
  [ -z "$line" ] && continue

  # The run only moves while its PR watch is alive. watch_pr.sh records itself
  # in /tmp/watch_pr-<owner>-<repo>-<pr>.json.pid, and the pid counts only while
  # it is still a watch_pr.sh process.
  slug=$(jq -r '"\(.repo // "")|\(.pr // "")" | gsub("/"; "-")' "$f" 2>/dev/null)
  pidf="/tmp/watch_pr-${slug%%|*}-${slug##*|}.json.pid"
  watch="NOT RUNNING - relaunch it now as a Monitor from this conversation with timeout_ms 1800000, per handle-pr Phase 1"
  [ -n "${T3CODE_THREAD_ID:-}" ] \
    && watch="NOT RUNNING - start it again per handle-pr Phase 1 (In T3)"
  # The user can stop the watch; handle-pr then records "watch": "stopped".
  [ "$(jq -r '.watch // ""' "$f" 2>/dev/null)" = "stopped" ] \
    && watch="stopped by the user - relaunch only when they ask"
  if [ -f "$pidf" ]; then
    read -r wpid wmode < "$pidf" || true
    if [ -n "${wpid:-}" ] && ps -p "$wpid" -o args= 2>/dev/null | grep -q 'watch_pr\.sh'; then
      watch="running ($(watch_mode "${wmode:-}"), pid ${wpid})"
    fi
  fi
  out="${out}  ${line} | WATCH: ${watch}  (state: ${f})"$'\n'
done
# Silent when none of the runs belongs to this repo.
[ -z "$out" ] && exit 0
[ "$others" -gt 0 ] && out="${out}  (${others} active handle-pr run(s) in other repositories, not shown)"$'\n'
printf 'ACTIVE HANDLE-PR RUNS. These files are shared across sessions, so a row is YOURS only if its worktree or PR matches what you are working on. For your own run, re-read the state file before the next step and treat its gates as authoritative over anything this conversation has drifted into. A NEXT field names the gate not satisfied yet: do it before anything else. Ignore rows belonging to another session.\n%s' "$out"
exit 0