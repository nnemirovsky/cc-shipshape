#!/usr/bin/env bash
# list_unresolved_threads.sh <pr-num> --repo <owner/repo>
#
# Outputs unresolved review threads on the PR authored by someone OTHER
# than the PR author (filters out self-resolved / self-authored noise).
# Each line:
#   <thread-id>\t<author>\t<path>:<line>\t<comment-snippet>
#
# Use the GraphQL `reviewThreads` query so we get the thread node id
# needed by `resolveReviewThread` later. The comment body is truncated
# to 100 chars to keep the listing scannable; full body is one
# `gh api` call away if needed.

set -euo pipefail

PR=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 <pr-num> --repo <owner/repo>"
      exit 0;;
    *) PR="$1"; shift;;
  esac
done

if [ -z "$PR" ] || [ -z "$REPO" ]; then
  echo "Usage: $0 <pr-num> --repo <owner/repo>" >&2
  exit 2
fi

OWNER=${REPO%/*}
NAME=${REPO#*/}
ME=$(gh api user --jq '.login')

gh api graphql -f query='
  query($owner:String!, $name:String!, $num:Int!) {
    repository(owner:$owner, name:$name) {
      pullRequest(number:$num) {
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            comments(first:1) {
              nodes {
                author { login }
                path
                originalLine
                body
              }
            }
          }
        }
      }
    }
  }
' -F owner="$OWNER" -F name="$NAME" -F num="$PR" \
  --jq '
    .data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)
    | .comments.nodes[0] as $c
    | select($c.author.login != "'"$ME"'")
    | "\(.id)\t\($c.author.login)\t\($c.path):\($c.originalLine)\t\($c.body | gsub("\\s+";" ") | .[0:100])"
  '
