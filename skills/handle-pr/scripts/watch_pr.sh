#!/usr/bin/env bash
# watch_pr.sh <pr-num> --repo <owner/repo> [--interval <sec>] [--once [--heartbeat <sec>]] [--state <file>]
#
# Poll loop for a PR. Emits one stdout line per delta:
#   - new reviews (id list, excluding self-authored)
#   - new inline review comments (id list, excluding self-authored)
#   - new issue comments on the PR (id list, excluding self-authored)
#   - check-runs on the PR head (name/status/conclusion) — surfaces CI failures
#   - state / isDraft / mergeable / reviewDecision changes
#   - CLEANUP_SUGGESTED after a non-first green CI pass on a new head, when the
#     prior commit's bot reports and dismissed review overviews are superseded
#     clutter — the cue to run cleanup_pr.sh
# Exits when state flips to MERGED or CLOSED.
#
# Two modes, one snapshot. handle-pr Phase 1 runs stream mode by default.
#   - default (stream): keeps polling and printing until MERGED/CLOSED. For
#     Claude Code's Monitor tool, which wakes the session on every stdout line
#     but stops the script after at most 30 minutes. The monitor-rearm plugin
#     then starts it again with the same arguments, so a restart must print
#     only what changed.
#   - --once: exits after the first poll that printed a delta. The fallback
#     when Monitor is unavailable: a Bash `run_in_background` command, which
#     has no time cap and wakes the session once, when it exits.
# The caller relaunches it after every exit that reaches it. The snapshot lives
# in <state dir>/watch_pr-<owner>-<repo>-<pr>.json (override with --state),
# where the state dir is $HANDLE_PR_STATE_DIR, by default
# ${XDG_STATE_HOME:-~/.local/state}/shipshape (mode 700), and both
# modes read and write it, so a relaunch in either mode neither re-prints the
# baseline nor misses what landed while no watch ran. Only a run with no
# snapshot yet prints a baseline, and the baseline alone never ends --once.
#
# --once also exits after --heartbeat seconds (default 4 h) with no delta,
# printing `HEARTBEAT`. The background supervisor retires a session that has
# sat idle for about 8 hours, and a retired session takes its watch down with
# it; the heartbeat wake-up and relaunch keep the session from ever getting
# there. A HEARTBEAT line needs a relaunch and nothing else.
#
# One watch per PR. A <state>.pid file records the running watch; a second
# launch while it is alive prints `ALREADY_RUNNING` and exits 3 without
# polling. The run-state hook reads the same file to tell the session whether
# its PR is being watched.
#
# Two hard rules baked in (regressions cost real time):
#   1. The jq projections deliberately drop comment/review BODIES.
#      Bodies can contain control characters that crash a second-pass
#      jq used for diffing. Fetch full bodies via a separate
#      `gh api .../reviews/$id` or `gh api .../comments/$id` call when
#      a notification fires.
#   2. The projection excludes the polling user's own login. Replying
#      to a thread or pushing a fix you authored creates a comment row,
#      which would trip the "new IDs" detection on the next poll and
#      surface as if a reviewer wrote something. Pre-fetch the self login
#      once and filter at the jq level.

set -euo pipefail

PR=""
REPO=""
INTERVAL=60
ONCE=0
HEARTBEAT=14400
STATE_FILE=""
USAGE="Usage: $0 <pr-num> --repo <owner/repo> [--interval <sec>] [--once [--heartbeat <sec>]] [--state <file>]"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    --once) ONCE=1; shift;;
    --heartbeat) HEARTBEAT="$2"; shift 2;;
    --state) STATE_FILE="$2"; shift 2;;
    -h|--help)
      echo "$USAGE"
      exit 0;;
    *) PR="$1"; shift;;
  esac
done

if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "$USAGE" >&2
  exit 2
fi
LEGACY_PID_FILE=""
if [ -z "$STATE_FILE" ]; then
  STATE_DIR="${HANDLE_PR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shipshape}"
  mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
  STATE_FILE="$STATE_DIR/watch_pr-${REPO//\//-}-$PR.json"
  # Older versions kept the snapshot in /tmp. Carry one over (only if it is
  # ours), so the first run here prints no baseline, and treat a watch started
  # by an older version as this PR's watch.
  legacy="/tmp/watch_pr-${REPO//\//-}-$PR.json"
  if [ ! -e "$STATE_FILE" ] && [ -O "$legacy" ]; then cp "$legacy" "$STATE_FILE"; fi
  [ -O "$legacy.pid" ] && LEGACY_PID_FILE="$legacy.pid"
fi
PID_FILE="$STATE_FILE.pid"
MODE=stream
[ "$ONCE" = 1 ] && MODE=once
[ "$ONCE" = 0 ] && [ -n "${T3_JOB:-}" ] && MODE=job  # a t3-jobs unit (T3), not a Monitor

# A pid file only counts when that pid is still a watch_pr.sh process, so a
# watch killed without running its trap, or a recycled pid, never blocks a
# relaunch. monitor-rearm starts the next run as soon as an expired Monitor is
# stopped, and the stopped run can need a few seconds to exit. So a live pid
# gets 20 s to go away before this run calls it a second watch.
other_alive() { ps -p "$other_pid" -o args= 2>/dev/null | grep -q 'watch_pr\.sh'; }
for pf in "$PID_FILE" $LEGACY_PID_FILE; do
  [ -f "$pf" ] || continue
  other_pid=""; other_mode=""
  read -r other_pid other_mode < "$pf" || true
  if [ -n "${other_pid:-}" ] && [ "$other_pid" != "$$" ]; then
    waited=0
    while other_alive && [ "$waited" -lt 20 ]; do sleep 1; waited=$(( waited + 1 )); done
    if other_alive; then
      echo "$REPO#$PR ALREADY_RUNNING pid=$other_pid mode=${other_mode:-?}"
      exit 3
    fi
  fi
done
echo "$$ $MODE" > "$PID_FILE"
release_pid_file() {
  if [ -f "$PID_FILE" ] && [ "$(cut -d' ' -f1 "$PID_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$PID_FILE"
  fi
}
trap release_pid_file EXIT
trap 'exit 143' TERM INT HUP

prev_review=""
prev_inline=""
prev_state=""
prev_checks=""
prev_issue_comments=""
passes_seen=0
last_green_head=""
baseline_poll=1
emitted=0
started_at=$(date +%s)

if jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
  prev_review=$(jq -r '.review' "$STATE_FILE")
  prev_inline=$(jq -r '.inline' "$STATE_FILE")
  prev_issue_comments=$(jq -r '.issueComments' "$STATE_FILE")
  prev_checks=$(jq -r '.checks' "$STATE_FILE")
  prev_state=$(jq -r '.state' "$STATE_FILE")
  passes_seen=$(jq -r '.passesSeen' "$STATE_FILE")
  last_green_head=$(jq -r '.lastGreenHead' "$STATE_FILE")
  baseline_poll=0
fi

# Every event line goes through out(), so --once knows whether a poll printed
# anything without each call site tracking it.
out() {
  echo "$*"
  emitted=1
}

# Backgrounded so a TERM while waiting reaches the trap at once instead of
# after the sleep ends.
pause() {
  sleep "$INTERVAL" &
  wait $! || true
}

# The self login is retried until it arrives. A failed lookup used to end the
# run under set -e before its first poll, and a Monitor watch then ends and
# wakes the session. With monitor-rearm a watch restarts every 30 minutes, so a
# network blip at one of those restarts must not end it. An empty login would
# also let the user's own comments through as new ones.
until SELF_LOGIN=$(gh api user --jq '.login' 2>/dev/null) && [ -n "$SELF_LOGIN" ]; do pause; done

# Written after every successful poll, through a temp file so a kill mid-write
# cannot leave a truncated snapshot behind.
save_state() {
  jq -n --arg review "$prev_review" --arg inline "$prev_inline" \
    --arg issueComments "$prev_issue_comments" --arg checks "$prev_checks" \
    --arg state "$prev_state" --argjson passesSeen "$passes_seen" \
    --arg lastGreenHead "$last_green_head" \
    '{review: $review, inline: $inline, issueComments: $issueComments, checks: $checks,
      state: $state, passesSeen: $passesSeen, lastGreenHead: $lastGreenHead}' \
    > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Emit only the DELTA (newly-added ids), not the whole list. On a busy PR the full
# list is long, the chat notification truncates it, and a NEW review/comment (sorted
# last by id) gets truncated away — so a new reviewer is invisible. Emitting just the
# new entries keeps them visible no matter how many total reviews/comments exist.
emit_delta() {
  local label="$1" cur="$2" prev="$3"
  [ -z "$cur" ] && return 0
  [ "$cur" = "$prev" ] && return 0
  if [ -z "$prev" ] || [ "$prev" = "[]" ]; then
    local n latest
    n=$(echo "$cur" | jq 'length' 2>/dev/null)
    latest=$(echo "$cur" | jq -c 'sort_by(.id) | last // {}' 2>/dev/null)
    out "$REPO#$PR $ts $label baseline=$n latest=$latest"
    return 0
  fi
  local new cnt edited ecnt line
  new=$(jq -cn --argjson cur "$cur" --argjson prev "$prev" \
    '($prev|map(.id)) as $p | $cur | map(select(.id as $i | ($p|index($i))|not))' 2>/dev/null)
  cnt=$(echo "$new" | jq 'length' 2>/dev/null)
  # An entry whose updated_at moved was edited. A snapshot written before the
  # projection carried updated_at has none, and such an entry is not an edit.
  edited=$(jq -cn --argjson cur "$cur" --argjson prev "$prev" \
    '($prev|map({key: (.id|tostring), value: .updated_at})|from_entries) as $p
     | $cur | map(select(.updated_at != null and ($p[.id|tostring] // null) != null
                         and $p[.id|tostring] != .updated_at)) | map({id, user})' 2>/dev/null)
  ecnt=$(echo "$edited" | jq 'length' 2>/dev/null)
  line=""
  [ "${cnt:-0}" -gt 0 ] && line="new=$new"
  [ "${ecnt:-0}" -gt 0 ] && line="${line:+$line }edited=$edited"
  if [ -n "$line" ]; then
    out "$REPO#$PR $ts $label $line"
  elif [ "$(jq -cn --argjson cur "$cur" --argjson prev "$prev" \
      'all($prev[]; has("updated_at") | not) and ($prev|map(.id)) == ($cur|map(.id))' 2>/dev/null)" = true ]; then
    # Only the projection gained updated_at since the snapshot: nothing happened.
    return 0
  else
    out "$REPO#$PR $ts $label changed (no new or edited ids; resolved/removed)"
  fi
}

while true; do
  # A transient gh/network failure must SKIP the poll and keep the last known
  # state, never fall back to "[]"/"" — an empty fallback resets prev_* and makes
  # the next good poll re-baseline, which both spams and can mask a real new
  # review that landed during the blip. `if !` is set -e safe; sleep-then-continue
  # avoids a tight spin on a persistent outage. A legitimately empty list still
  # arrives as "[]" with exit 0 and is processed normally.
  if ! rids=$(
    gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
      --jq ".[] | select(.user.login != \"$SELF_LOGIN\") | {id, user: .user.login, state}" 2>/dev/null \
      | jq -sc 'sort_by(.id)' 2>/dev/null
  ); then
    pause; continue
  fi

  if ! iids=$(
    gh api --paginate "repos/$REPO/pulls/$PR/comments" \
      --jq ".[] | select(.user.login != \"$SELF_LOGIN\") | {id, user: .user.login, line, path, updated_at}" 2>/dev/null \
      | jq -sc 'sort_by(.id)' 2>/dev/null
  ); then
    pause; continue
  fi

  if ! cids=$(
    gh api --paginate "repos/$REPO/issues/$PR/comments" \
      --jq ".[] | select(.user.login != \"$SELF_LOGIN\") | {id, user: .user.login, updated_at}" 2>/dev/null \
      | jq -sc 'sort_by(.id)' 2>/dev/null
  ); then
    pause; continue
  fi

  if ! sj=$(
    gh pr view "$PR" --repo "$REPO" \
      --json state,isDraft,mergeable,reviewDecision,headRefOid \
      --jq '{state, isDraft, mergeable, reviewDecision, head: .headRefOid}' 2>/dev/null
  ); then
    pause; continue
  fi

  head_sha=$(echo "$sj" | jq -r '.head // ""' 2>/dev/null)
  if [ -n "$head_sha" ]; then
    if ! checks=$(
      gh api --paginate "repos/$REPO/commits/$head_sha/check-runs" \
        --jq '.check_runs[] | {name, status, conclusion}' 2>/dev/null \
        | jq -sc 'sort_by(.name)' 2>/dev/null
    ); then
      pause; continue
    fi
  else
    checks="[]"
  fi

  ts=$(date -u +%H:%MZ)
  emitted=0

  if [ -n "$rids" ] && [ "$rids" != "$prev_review" ]; then
    emit_delta REVIEWS "$rids" "$prev_review"
    prev_review="$rids"
  fi
  if [ -n "$iids" ] && [ "$iids" != "$prev_inline" ]; then
    emit_delta INLINE "$iids" "$prev_inline"
    prev_inline="$iids"
  fi
  if [ -n "$cids" ] && [ "$cids" != "$prev_issue_comments" ]; then
    emit_delta ISSUE_COMMENTS "$cids" "$prev_issue_comments"
    prev_issue_comments="$cids"
  fi
  if [ -n "$checks" ] && [ "$checks" != "$prev_checks" ]; then
    checks_summary=$(echo "$checks" | jq -rc '.[] | "\(.name) \(.status)/\(.conclusion // "")"' 2>/dev/null | paste -sd' | ' -)
    out "$REPO#$PR $ts CHECKS ${checks_summary:-empty}"
    prev_checks="$checks"
  fi

  # Periodic cleanup nudge: after a non-first green CI pass on a NEW head, the prior
  # commit's bot reports (Code Quality / Test Summary) and any dismissed review overviews
  # are superseded clutter. Emit one reminder per green head so cleanup_pr.sh gets run.
  if [ -n "$head_sha" ] && [ "$head_sha" != "$last_green_head" ] \
     && echo "$checks" | jq -e 'length > 0 and (map(.status == "completed") | all) and (map((.conclusion // "") | . == "success" or . == "skipped" or . == "neutral") | all)' >/dev/null 2>&1; then
    last_green_head="$head_sha"
    passes_seen=$((passes_seen + 1))
    if [ "$passes_seen" -ge 2 ]; then
      out "$REPO#$PR $ts CLEANUP_SUGGESTED head=$head_sha pass#$passes_seen. run cleanup_pr.sh if superseded bot reports or dismissed review overviews have accumulated"
    fi
  fi

  if [ -n "$sj" ] && [ "$sj" != "$prev_state" ]; then
    out "$REPO#$PR $ts STATE $sj"
    prev_state="$sj"
  fi

  save_state

  s=$(echo "$sj" | jq -r '.state // ""' 2>/dev/null)
  if [ "$s" = "MERGED" ] || [ "$s" = "CLOSED" ]; then
    echo "$REPO#$PR STOP state=$s"
    break
  fi

  # --once ends on the first poll that printed something, unless that poll was
  # only recording the baseline of a run with no earlier snapshot.
  if [ "$ONCE" = 1 ] && [ "$emitted" = 1 ] && [ "$baseline_poll" = 0 ]; then
    break
  fi
  if [ "$ONCE" = 1 ] && [ $(( $(date +%s) - started_at )) -ge "$HEARTBEAT" ]; then
    echo "$REPO#$PR $(date -u +%H:%MZ) HEARTBEAT no change in $(( HEARTBEAT / 60 )) min; relaunch the watch"
    break
  fi
  baseline_poll=0

  pause
done
