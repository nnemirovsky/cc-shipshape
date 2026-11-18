#!/usr/bin/env bash
# resolve_threads.sh <thread-id> [<thread-id>...]
#
# Resolves one or more PR review threads via the GraphQL
# `resolveReviewThread` mutation. Use `list_unresolved_threads.sh`
# first to fetch the thread IDs.
#
# Per ~/.claude/CLAUDE.md "GitHub PR Reviews", the rule is to resolve
# every thread you address — fixed in code, replied with a justified
# pushback, or otherwise closed out. Silent inaction reads as "still
# discussing".
#
# This script ONLY resolves. Replies are composed separately (apply
# the writing-rules skill before posting) and posted with
# `gh api repos/$REPO/pulls/$PR/comments/$COMMENT_ID/replies` or
# `gh pr review --comment`.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <thread-id> [<thread-id>...]" >&2
  exit 2
fi

for tid in "$@"; do
  out=$(gh api graphql -f query='
    mutation($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { isResolved }
      }
    }
  ' -F id="$tid" --jq '.data.resolveReviewThread.thread.isResolved')

  if [ "$out" = "true" ]; then
    echo "resolved $tid"
  else
    echo "ERROR: $tid did not resolve (response: $out)" >&2
    exit 1
  fi
done
