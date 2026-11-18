---
name: gh-notif-cleanup
description: This skill should be used when the user asks to "cleanup github notifications", "clean up gh notifications", "clear merged PR notifications", "delete failed CI notifications", "tidy github inbox", or otherwise wants stale GitHub notifications removed. Deletes notifications for merged PRs and failed CI runs via the GitHub REST API; preserves open/active items.
allowed-tools: Bash(gh api *), Bash(gh api -X DELETE *), Bash(bash -c *)
---

# gh-notif-cleanup — delete stale GitHub notifications

Trigger when the user asks to clean up / tidy / clear their GitHub notifications, especially when they mention deleting merged PR or failed CI notifications.

## Policy

- **DELETE** notifications about:
  - PRs that are merged (also merged-then-closed)
  - PRs that are closed without being merged (treat as resolved)
  - CheckSuite notifications whose title contains "failed" / "failure" (CI already finished — the failure is recorded in the PR)
- **KEEP** notifications about:
  - Open PRs (review_requested, assign, mention, author with open PR)
  - Issues that are still open
  - Discussions, Releases, and other types unless the user says otherwise

When in doubt, ask before deleting; never delete open-PR notifications without confirmation.

## Workflow

### 1. List the inbox — always with `all=true`, on the first pass

```bash
gh api "notifications?all=true&participating=false&per_page=100" --paginate \
  | jq -r '.[] | "\(.id)\t\(.unread)\t\(.reason)\t\(.subject.type)\t\(.repository.full_name)\t\(.subject.title)\t\(.subject.url)"'
```

**Do not start with plain `gh api notifications`.** That returns *unread only*, which is a small
slice of what the user actually sees in their inbox. Most stale merged-PR notifications are already
read but not done, so an unread-only pass looks clean while the user is still staring at 20+ merged
PRs. Sweeping with `all=true` from the start is the whole point — one pass, everything.

`per_page=100` matters: the default page size makes `--paginate` far slower on a large backlog.

### 2. Classify each notification

For each `PullRequest`-typed notification, fetch state from `.subject.url` (already a `repos/OWNER/REPO/pulls/N` API URL):

```bash
gh api "$subject_url" --jq '"state=\(.state) merged=\(.merged)"'
```

Batch with bash to keep it fast — one call per PR, all in a single tool invocation:

```bash
bash -c '
for pr in "OWNER/REPO N" "OWNER/REPO N"; do
  set -- $pr
  echo -n "$1#$2 "
  gh api "repos/$1/pulls/$2" --jq "\"state=\(.state) merged=\(.merged)\""
done
'
```

For `CheckSuite` notifications, the subject URL is null. Use the title — anything with "failed" or "failure" qualifies for deletion under this skill's policy.

### 3. Show the user the plan

Print the to-delete list (id + reason + title) and the to-keep list.

Proceed without confirmation when every item in the delete set is unambiguous under the Policy
above — a PR verified `merged=true` or `state=closed` via the API, or a CheckSuite titled
failed/failure. **Set size alone is not a reason to ask**: a first full-backlog sweep is routinely
20–40 items and prompting on that is pure friction.

Ask first only when: an item does not fit the policy cleanly, the user's phrasing implies a narrower
scope than a full sweep, or the set would touch an open PR/issue.

### 4. Delete

```bash
bash -c '
for id in ID1 ID2 ID3; do
  gh api -X DELETE "notifications/threads/$id" && echo "deleted $id"
done
'
```

There is no bulk-delete endpoint — loop one by one. The call returns 204 on success.

### 5. Verify and report

Verify with the unread inbox, which is the only view that reliably shrinks:

```bash
gh api notifications --paginate | jq -s 'add | length'
```

For read items, verify against the set you just deleted — do **not** re-run the `all=true` listing
and expect it to shrink (see Gotchas).

End with a summary: "Deleted N (X merged PRs + Y failed CI). Kept M open items: …".

## Gotchas

- **DELETE marks a thread *done*; it does not erase it.** A done thread keeps coming back in
  `notifications?all=true` forever, and **no response field distinguishes done from not-done** —
  `unread`, `last_read_at`, and `updated_at` look identical on both. So:
  - A thread still appearing in the `all=true` listing is *not* evidence the delete failed.
  - Re-running this skill will re-list everything ever deleted. Re-`DELETE`ing is idempotent and
    harmless (still 204), so on a repeat run just re-delete rather than trying to detect what is
    already done.
  - Track what you deleted within the session; that list, not the API, is the record.
- The user's shell may not be bash (fish does not parse `for ... do ... done`). Always wrap multi-step loops in `bash -c '...'`.
- The `.subject.url` for PullRequest notifications is the API URL, perfect for piping straight into `gh api`. For CheckSuite it is null — don't try to dereference it.
- Mark-as-read (`PATCH /notifications/threads/{id}`) is *not* what the user wants here. Always use DELETE.
- A PR can stay open after approvals, for example behind a code-owner gate. Don't mistake "approved" for "merged". Only `.merged == true` qualifies.