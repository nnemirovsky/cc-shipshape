#!/usr/bin/env bash
# Lists each review's author, state, time and FULL top-level body — i.e. the review
# SUMMARY, which is separate from inline code-thread comments. Summary reviewers
# (review bots and humans alike) routinely put substantive, actionable
# points in the review body that `list_unresolved_threads.sh` does NOT surface
# (that script only lists inline threads). Read this whenever a review event fires so
# top-level asks are not missed before resolving/dismissing.
#
# Notes:
# - Uses --paginate: the reviews list is paginated, and a recent review is often beyond
#   page 1, so a non-paginated query silently misses it.
# - Prints the body in FULL (no truncation) — heading-only truncation hides the point.
# - Excludes your own reviews by default; pass --include-self to include them.
set -euo pipefail

PR=""
REPO=""
INCLUDE_SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --include-self) INCLUDE_SELF=1; shift;;
    -h|--help)
      echo "Usage: $0 <pr-num> --repo <owner/repo> [--include-self]"
      exit 0;;
    *) PR="$1"; shift;;
  esac
done

if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "Usage: $0 <pr-num> --repo <owner/repo> [--include-self]" >&2
  exit 2
fi

ME=$(gh api user --jq '.login')

gh api --paginate "repos/$REPO/pulls/$PR/reviews" --jq '
  .[]
  | select((.body // "") != "")
  | select('"$INCLUDE_SELF"' == 1 or .user.login != "'"$ME"'")
  | "=== \(.user.login) [\(.state)] \(.submitted_at) (review \(.id)) ===\n\(.body)\n"
'
