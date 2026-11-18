#!/usr/bin/env bash
# request_reviewers.sh <pr-num> --repo <owner/repo> --reviewers <login>[,<login>...]
#
# Requests review from one or more reviewers. Works for both humans
# and bot reviewers.
#
# For a bot reviewer, pass its exact login including any `[bot]` suffix.
# which already handles the verify-it-actually-landed step.
#
# Same endpoint covers both initial requests AND re-requests after a
# fix push. Re-requesting a human who already approved is intentional
# when new commits land — it flips the GitHub UI back to "review
# requested" and pings the reviewer so they confirm against the new
# state.

set -euo pipefail

PR=""
REPO=""
REVIEWERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --reviewers) REVIEWERS="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 <pr-num> --repo <owner/repo> --reviewers <login>[,<login>...]"
      exit 0;;
    *) PR="$1"; shift;;
  esac
done

if [ -z "$PR" ] || [ -z "$REPO" ] || [ -z "$REVIEWERS" ]; then
  echo "Usage: $0 <pr-num> --repo <owner/repo> --reviewers <login>[,<login>...]" >&2
  exit 2
fi

# Convert comma-separated logins to a JSON array.
json=$(jq -nc --arg s "$REVIEWERS" '$s | split(",") | map(gsub("^\\s+|\\s+$"; ""))')

gh api "repos/$REPO/pulls/$PR/requested_reviewers" -X POST --input - \
  <<<"{\"reviewers\":$json}" \
  --jq '[.requested_reviewers[].login] | "ok: requested " + (. | join(", "))'
