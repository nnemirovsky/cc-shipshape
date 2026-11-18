#!/usr/bin/env bash
# finalize_pr.sh <pr-num> --repo <owner/repo> [--team <org/team>] [--reviewers a,b]
#                [--exclude a,b] [--no-confirm]
#
# Flips the PR out of draft, makes sure its author is an assignee, and requests
# review in one call from:
#   --team <org/team>   the team's members, minus you, minus bots (any login
#                       containing "bot"), minus --exclude
#   --reviewers a,b     these logins
# Both may be given. With neither, no review is requested here, and GitHub's own
# rules (CODEOWNERS, auto-assignment) are left to pick reviewers.
#
# Notes (do not regress):
#   - A team handle is never passed as a reviewer. When one member of a
#     requested team submits a review for the team, GitHub drops the other
#     members from the reviewer list. Individuals are requested instead.
#   - GitHub rejects the PR author as a reviewer (HTTP 422), so you are left
#     out of every list.
#   - The last line names the next step: the review cycle (handle-pr).
set -euo pipefail

usage="Usage: $0 <pr-num> --repo <owner/repo> [--team <org/team>] [--reviewers a,b] [--exclude a,b] [--no-confirm]"
PR=""; REPO=""; TEAM=""; EXTRA=""; EXCLUDE=""; CONFIRM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --team) TEAM="$2"; shift 2;;
    --reviewers) EXTRA="$2"; shift 2;;
    --exclude) EXCLUDE="$2"; shift 2;;
    --no-confirm) CONFIRM=0; shift;;
    -h|--help) echo "$usage"; exit 0;;
    *) PR="$1"; shift;;
  esac
done
if [ -z "$PR" ] || [ -z "$REPO" ]; then echo "$usage" >&2; exit 2; fi

ME=$(gh api user --jq '.login')
csv() { jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))' <<<"$1"; }

TEAM_JSON='[]'
if [ -n "$TEAM" ]; then
  TEAM_JSON=$(gh api "orgs/${TEAM%/*}/teams/${TEAM#*/}/members" --paginate --jq '[.[].login]' | jq -sc 'add // []')
fi
REVIEWERS_JSON=$(jq -nc --argjson team "$TEAM_JSON" --argjson extra "$(csv "$EXTRA")" \
  --argjson ex "$(csv "$EXCLUDE")" --arg me "$ME" '
  ([$team[] | select(test("bot"; "i") | not)] - $ex) + $extra
  | map(select(. != $me)) | unique')
PRETTY=$(jq -r 'if length == 0 then "none (GitHub rules apply)" else join(", ") end' <<<"$REVIEWERS_JSON")

echo "About to finalize $REPO#$PR:"
echo "  - gh pr ready  (flip out of draft)"
echo "  - verify assignee == $ME (add if missing)"
echo "  - request review from: $PRETTY"
if [ "$CONFIRM" = 1 ]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1;; esac
fi

gh pr ready "$PR" --repo "$REPO"

ASSIGNEES=$(gh pr view "$PR" --repo "$REPO" --json assignees --jq '[.assignees[].login]')
if ! jq -e --arg me "$ME" 'index($me)' >/dev/null <<<"$ASSIGNEES"; then
  echo "PR has no $ME assignee, adding"
  gh pr edit "$PR" --repo "$REPO" --add-assignee "$ME"
fi

if [ "$(jq length <<<"$REVIEWERS_JSON")" -gt 0 ]; then
  gh api "repos/$REPO/pulls/$PR/requested_reviewers" -X POST --input - \
    <<<"{\"reviewers\":$REVIEWERS_JSON}" >/dev/null
fi

echo "ok: $REPO#$PR is ready for review, assignee=$ME, reviewers=$PRETTY"
# Printed here because a session that ran this hours after loading write-pr (or
# after a context compaction) may no longer have the hand-off rule in view.
echo "NEXT: load shipshape:handle-pr for https://github.com/$REPO/pull/$PR now. It arms the review watch; nothing watches the PR until it runs."