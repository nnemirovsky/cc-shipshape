#!/usr/bin/env bash
# repo_baseline.sh audit|apply <owner/repo> --kind plugin|mcp|lib|private
#                  [--checks "ctx,ctx"] [--discussions] [--no-signed] [--codeql on|off]
#
# Compares a GitHub repository's settings with the shipshape baseline for its
# kind, and with `apply` changes what differs. Prints one line per item:
#   OK      <item>                       already as the baseline wants
#   DRIFT   <item>: <have> -> <want>     differs (audit) / about to change
#   APPLIED <item>                       changed (apply)
#   SKIP    <item>: <why>                not possible here (plan, visibility…)
#   NOTE    <text>                       something to look at by hand
#   SUGGEST checks: <ctx,ctx>            check names seen on the default branch
# Exit 0 when nothing drifts (audit) or everything applied, 1 when audit found
# drift or apply hit an error, 2 on usage errors.
#
# Baseline (all kinds):
#   squash merge only, PR title + PR body as the squash commit, delete branch
#   on merge, allow update branch, wiki and projects off; workflow token
#   read-only and unable to approve PRs; Dependabot alerts + security updates.
# Public repos add:
#   allow auto-merge; secret scanning + push protection; private vulnerability
#   reporting; immutable releases; topics for the kind; CodeQL default setup
#   for mcp and lib (--codeql to override); Discussions with --discussions;
#   ruleset "Protect main" on the default branch: no deletion, no force push,
#   PRs with 0 approvals, review threads resolved, squash only, required
#   status checks (--checks, or the ones the ruleset already has), signed
#   commits (--no-signed drops it), and the repository admin role may bypass
#   only through a pull request; ruleset "Protect release tags" on refs/tags/v*:
#   no deletion, update or force push. Classic branch protection on the default
#   branch is removed once the ruleset is in place.
# Private repos on a free plan cannot have rulesets, branch protection, secret
# scanning or private vulnerability reporting: those are reported as SKIP.
set -uo pipefail

usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
MODE="${1:-}"; REPO="${2:-}"
case "$MODE" in audit|apply) ;; -h|--help) sed -n '2,33p' "$0"; exit 0;; *) usage;; esac
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
shift 2
KIND=""; CHECKS=""; DISCUSSIONS=0; SIGNED=1; CODEQL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="$2"; shift 2;;
    --checks) CHECKS="$2"; shift 2;;
    --discussions) DISCUSSIONS=1; shift;;
    --no-signed) SIGNED=0; shift;;
    --codeql) CODEQL="$2"; shift 2;;
    *) usage;;
  esac
done
case "$KIND" in plugin|mcp|lib|private) ;; *) usage;; esac
[ -n "$CODEQL" ] || { case "$KIND" in mcp|lib) CODEQL=on;; *) CODEQL=off;; esac; }

drift=0; failed=0
say() { echo "$*"; }
ok() { say "OK      $1"; }
skip() { say "SKIP    $1: $2"; }
note() { say "NOTE    $*"; }
# change <item> <have> <want> <command...>: report, and run the command in apply mode
change() {
  local item=$1 have=$2 want=$3; shift 3
  if [ "$MODE" = audit ]; then say "DRIFT   $item: $have -> $want"; drift=1; return; fi
  if "$@" >/dev/null 2>"${TMPDIR:-/tmp}/repo_baseline.err"; then say "APPLIED $item ($have -> $want)"
  else say "FAILED  $item: $(head -c 300 "${TMPDIR:-/tmp}/repo_baseline.err" | tr '\n' ' ')"; failed=1; fi
}
api() { gh api "$@" 2>/dev/null; }
status_of() { gh api -i "$1" 2>/dev/null | head -n 1 | awk '{print $2}'; }

repo=$(api "repos/$REPO") || { echo "cannot read $REPO" >&2; exit 2; }
private=$(jq -r .private <<<"$repo")
default=$(jq -r .default_branch <<<"$repo")
if [ "$KIND" = private ] && [ "$private" != true ]; then note "--kind private on a public repo: using the private baseline only"; fi
if [ "$KIND" != private ] && [ "$private" = true ]; then note "$REPO is private: the public-only items will be skipped"; fi
public=0; [ "$private" = true ] || public=1

# ---- repository settings ---------------------------------------------------
want_settings=$(jq -n --argjson pub "$public" --argjson disc "$DISCUSSIONS" '{
  allow_squash_merge: true, allow_merge_commit: false, allow_rebase_merge: false,
  squash_merge_commit_title: "PR_TITLE", squash_merge_commit_message: "PR_BODY",
  delete_branch_on_merge: true, allow_update_branch: true,
  has_wiki: false, has_projects: false}
  + (if $pub == 1 then {allow_auto_merge: true} else {} end)
  + (if $disc == 1 then {has_discussions: true} else {} end)')
diff_settings=$(jq -c --argjson want "$want_settings" '. as $have
  | [$want | to_entries[] | select($have[.key] != .value) | {key, have: $have[.key], want: .value}]' <<<"$repo")
if [ "$(jq length <<<"$diff_settings")" = 0 ]; then ok "repo settings"
else
  patch=$(jq -c 'map({(.key): .want}) | add' <<<"$diff_settings")
  change "repo settings" "$(jq -r 'map("\(.key)=\(.have)") | join(" ")' <<<"$diff_settings")" \
    "$(jq -r 'map("\(.key)=\(.want)") | join(" ")' <<<"$diff_settings")" \
    gh api -X PATCH "repos/$REPO" --input - <<<"$patch"
fi

# ---- Actions token ---------------------------------------------------------
wf=$(api "repos/$REPO/actions/permissions/workflow")
if [ -z "$wf" ]; then skip "actions token" "cannot read actions/permissions/workflow"
elif [ "$(jq -r '"\(.default_workflow_permissions) \(.can_approve_pull_request_reviews)"' <<<"$wf")" = "read false" ]; then ok "actions token (read-only, cannot approve PRs)"
else change "actions token" "$(jq -r '"\(.default_workflow_permissions), approve=\(.can_approve_pull_request_reviews)"' <<<"$wf")" "read, approve=false" \
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
fi

# ---- Dependabot ------------------------------------------------------------
if [ "$(status_of "repos/$REPO/vulnerability-alerts")" = 204 ]; then ok "dependabot alerts"
else change "dependabot alerts" off on gh api -X PUT "repos/$REPO/vulnerability-alerts"; fi
asf=$(api "repos/$REPO/automated-security-fixes" | jq -r '.enabled // false')
if [ "$asf" = true ]; then ok "dependabot security updates"
else change "dependabot security updates" off on gh api -X PUT "repos/$REPO/automated-security-fixes"; fi

if [ "$public" = 0 ]; then
  skip "secret scanning, private vulnerability reporting, immutable releases, rulesets, CodeQL" "private repo (needs a paid plan or a public repo)"
else
  # ---- secret scanning -----------------------------------------------------
  ss=$(jq -r '"\(.security_and_analysis.secret_scanning.status // "?") \(.security_and_analysis.secret_scanning_push_protection.status // "?")"' <<<"$repo")
  if [ "$ss" = "enabled enabled" ]; then ok "secret scanning + push protection"
  else change "secret scanning + push protection" "$ss" "enabled enabled" \
    gh api -X PATCH "repos/$REPO" --input - <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
  fi
  # ---- private vulnerability reporting ---------------------------------------
  pvr=$(api "repos/$REPO/private-vulnerability-reporting" | jq -r '.enabled // false')
  if [ "$pvr" = true ]; then ok "private vulnerability reporting"
  else change "private vulnerability reporting" off on gh api -X PUT "repos/$REPO/private-vulnerability-reporting"; fi
  # ---- immutable releases ----------------------------------------------------
  imm=$(api "repos/$REPO/immutable-releases" | jq -r '.enabled // false')
  if [ "$imm" = true ]; then ok "immutable releases"
  else change "immutable releases" off on gh api -X PUT "repos/$REPO/immutable-releases"; fi
  # ---- CodeQL ----------------------------------------------------------------
  cq=$(api "repos/$REPO/code-scanning/default-setup" | jq -r '.state // "unknown"')
  if [ "$CODEQL" = off ]; then
    [ "$cq" = configured ] && note "CodeQL default setup is on, though --codeql off (left as is)" || ok "CodeQL (not wanted for $KIND)"
  elif [ "$cq" = configured ]; then ok "CodeQL default setup"
  elif [ "$cq" = unknown ]; then skip "CodeQL default setup" "cannot read code-scanning/default-setup"
  else change "CodeQL default setup" "$cq" configured gh api -X PATCH "repos/$REPO/code-scanning/default-setup" -f state=configured; fi
  # ---- topics ----------------------------------------------------------------
  case "$KIND" in
    plugin) want_topics='["claude-code","claude-code-plugin"]';;
    mcp) want_topics='["mcp","model-context-protocol"]';;
    *) want_topics='[]';;
  esac
  have_topics=$(jq -c '.topics // []' <<<"$repo")
  missing=$(jq -c --argjson h "$have_topics" '. - $h' <<<"$want_topics")
  if [ "$missing" = '[]' ]; then ok "topics"
  else change "topics" "$(jq -r 'join(",")' <<<"$have_topics")" "+$(jq -r 'join(",")' <<<"$missing")" \
    gh api -X PUT "repos/$REPO/topics" --input - <<<"$(jq -nc --argjson h "$have_topics" --argjson m "$missing" '{names: ($h + $m)}')"
  fi
  [ "$have_topics" = '[]' ] && note "no topics at all: add a few that describe the repo"

  # ---- rulesets ----------------------------------------------------------------
  list=$(gh api "repos/$REPO/rulesets?includes_parents=false" 2>&1)
  if grep -q 'Upgrade to GitHub Pro' <<<"$list"; then
    skip "rulesets" "not available for this repo on the current plan"
  else
    get_ruleset() { local id; id=$(jq -r --arg n "$1" '.[] | select(.name == $n) | .id' <<<"$list" | head -n 1); [ -n "$id" ] && api "repos/$REPO/rulesets/$id"; }
    main_rs=$(get_ruleset "Protect main")
    # The check names: --checks, else the ones the ruleset already requires.
    if [ -n "$CHECKS" ]; then checks_json=$(jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) | map({context: .})' <<<"$CHECKS")
    else checks_json=$(jq -c '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[] | {context}]' <<<"${main_rs:-null}")
    fi
    if [ "$checks_json" = '[]' ]; then
      sha=$(jq -r '.commit.sha // empty' <<<"$(api "repos/$REPO/branches/$default")")
      seen=$([ -n "$sha" ] && api "repos/$REPO/commits/$sha/check-runs?per_page=100" | jq -r '[.check_runs[].name] | unique | join(",")')
      [ -n "${seen:-}" ] && say "SUGGEST checks: $seen"
      note "no required status checks: pass --checks with the CI job names to require them"
    fi
    want_main=$(jq -n --argjson checks "$checks_json" --argjson signed "$SIGNED" '{
      name: "Protect main", target: "branch", enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}],
      rules: ([{type: "deletion"}, {type: "non_fast_forward"},
        {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false, require_last_push_approval: false,
          required_review_thread_resolution: true, allowed_merge_methods: ["squash"]}}]
        + (if ($checks | length) > 0 then [{type: "required_status_checks", parameters: {
            strict_required_status_checks_policy: true, required_status_checks: $checks}}] else [] end)
        + (if $signed == 1 then [{type: "required_signatures"}] else [] end))}')
    want_tags='{"name":"Protect release tags","target":"tag","enforcement":"active",
      "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"bypass_actors":[],
      "rules":[{"type":"deletion"},{"type":"update"},{"type":"non_fast_forward"}]}'
    # A ruleset matches when every wanted rule is there with the wanted
    # parameters, and the bypass list and conditions are the same.
    rs_diff() {  # rs_diff <have json> <want json> -> what differs, empty when it matches
      jq -nr --argjson have "$1" --argjson want "$2" --arg def "refs/heads/$default" '
        def norm_bypass: [.bypass_actors[]? | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_id);
        def norm_checks: if type != "array" then .
          elif all(.[]; type == "object") then [.[] | {context}] | sort_by(.context)
          else sort end;
        [ (if $have.enforcement != $want.enforcement then "enforcement=\($have.enforcement)" else empty end),
          (def tgt: [.conditions.ref_name.include[]? | if . == $def then "~DEFAULT_BRANCH" else . end] | sort;
           if ($have | tgt) != ($want | tgt) then "targets" else empty end),
          (if ($have | norm_bypass) != ($want | norm_bypass) then "bypass" else empty end),
          ($want.rules[] as $w
            | ([$have.rules[]? | select(.type == $w.type)][0]) as $h
            | if $h == null then "missing \($w.type)"
              else ($w.parameters // {} | to_entries[]
                | select((.value | norm_checks) != ($h.parameters[.key] | norm_checks))
                | "\($w.type).\(.key)") end) ] | join(", ")'
    }
    for which in main tags; do
      if [ "$which" = main ]; then want=$want_main; have=$main_rs; else want=$want_tags; have=$(get_ruleset "Protect release tags"); fi
      name=$(jq -r .name <<<"$want")
      if [ -z "$have" ]; then
        change "ruleset \"$name\"" none created gh api -X POST "repos/$REPO/rulesets" --input - <<<"$want"
      else
        if ! d=$(rs_diff "$have" "$want"); then say "FAILED  ruleset \"$name\": could not compare"; failed=1; drift=1; continue; fi
        if [ -z "$d" ]; then ok "ruleset \"$name\""
        else change "ruleset \"$name\"" "$d" baseline gh api -X PUT "repos/$REPO/rulesets/$(jq -r .id <<<"$have")" --input - <<<"$want"; fi
      fi
    done
    others=$(jq -r '[.[] | select(.name != "Protect main" and .name != "Protect release tags") | .name] | join(", ")' <<<"$list")
    [ -n "$others" ] && note "other rulesets left as they are: $others"
    # Classic protection is replaced by the ruleset.
    if [ "$(status_of "repos/$REPO/branches/$default/protection")" = 200 ]; then
      change "classic branch protection on $default" present "removed (the ruleset replaces it)" \
        gh api -X DELETE "repos/$REPO/branches/$default/protection"
    else ok "no classic branch protection"; fi
  fi
fi

if [ "$MODE" = audit ]; then exit "$drift"; else exit "$failed"; fi