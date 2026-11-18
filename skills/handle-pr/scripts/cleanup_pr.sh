#!/usr/bin/env bash
# cleanup_pr.sh <pr-number> --repo <owner>/<repo> [--apply] [--claude] [--bots login1,login2]
#
# Minimizes SUPERSEDED bot report comments on a PR (keeping the newest comment of each
# report KIND) AND superseded review OVERVIEWS. For every reviewer (bots AND humans, except
# the PR author) it keeps their LATEST non-dismissed review overview -- the live gate signal
# (APPROVED / open CHANGES_REQUESTED / COMMENTED) -- and minimizes every older or DISMISSED
# overview from that author. So a multi-round review leaves one live review visible instead
# of a stack of stale "since last review" summaries. Never touches the PR author's own
# comments, or any reviewer's latest live review.
#
# Kind detection (for the bot REPORT issue comments) is deliberately NOT exact-header
# matching (bots re-title reports between
# pushes, e.g. "Test Summary" -> "Test Summary - build 42"). Layered strategy, first hit wins:
#   1. Hidden HTML marker  (<!-- ... --> upsert markers many CI bots embed) - exact key.
#   2. Link-anchor fingerprint (URL fragments like #user-content-test-summary) - stable key.
#   3. Normalized first-heading tokens (emoji/shortcodes/counts/punctuation stripped,
#      lowercased) grouped by Jaccard token overlap >= 0.5 (union-find) - drift-tolerant.
#   4. Ambiguous leftovers: KEPT in scripted mode (conservative); grouped by Claude in
#      --claude mode (headless `claude -p`, strict JSON contract, mechanically re-validated:
#      output ids must be a subset of the inventory and every group keeps its newest).
#
# Default is a DRY RUN printing the plan; --apply executes the GraphQL minimize calls.
set -euo pipefail

PR="${1:?usage: cleanup_pr.sh <pr> --repo <owner>/<repo> [--apply] [--claude] [--bots a,b]}"
shift
REPO="" APPLY=0 USE_CLAUDE=0 BOTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --claude) USE_CLAUDE=1; shift ;;
    --bots) BOTS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REPO" ]] || { echo "--repo is required" >&2; exit 2; }

OWNER="${REPO%%/*}" NAME="${REPO##*/}"
SELF="$(gh api user --jq .login)"
HEAD_SHA="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)"
HEAD_DATE="$(gh api "repos/$REPO/commits/$HEAD_SHA" --jq .commit.committer.date)"

# One GraphQL query: issue comments with node ids, minimized state, author, body.
INVENTORY="$(gh api graphql --paginate \
  -f query='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$name){pullRequest(number:$pr){
      comments(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{id databaseId createdAt isMinimized author{login} body}
      }}}}' \
  -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  --jq '.data.repository.pullRequest.comments.nodes[]' | jq -s '.')"

# Bot-authored COMMENTED reviews (review overviews and the like). APPROVED /
# CHANGES_REQUESTED reviews are review-gate signal handled by dismissal, never cleanup.
REVIEWS="$(gh api graphql --paginate \
  -f query='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$name){pullRequest(number:$pr){
      reviews(first:100,after:$endCursor){
        pageInfo{hasNextPage endCursor}
        nodes{id databaseId submittedAt state isMinimized author{login} body}
      }}}}' \
  -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  --jq '.data.repository.pullRequest.reviews.nodes[]' | jq -s '.')"

INV_FILE="$(mktemp)" REV_FILE="$(mktemp)"
trap 'rm -f "$INV_FILE" "$REV_FILE"' EXIT
printf '%s' "$INVENTORY" > "$INV_FILE"
printf '%s' "$REVIEWS" > "$REV_FILE"

PLAN="$(python3 - "$SELF" "$BOTS" "$USE_CLAUDE" "$INV_FILE" "$REV_FILE" "$HEAD_SHA" "$HEAD_DATE" <<'PYEOF'
import json, re, subprocess, sys

self_login, bots_arg, use_claude = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
comments = json.load(open(sys.argv[4]))
reviews = json.load(open(sys.argv[5]))
head_sha, head_date = sys.argv[6], sys.argv[7]
explicit_bots = {b.strip().lower() for b in bots_arg.split(",") if b.strip()}

def is_bot(login: str) -> bool:
    l = login.lower()
    return l in explicit_bots or l.endswith("bot") or l.endswith("[bot]")

candidates = [
    c for c in comments
    if c.get("author") and is_bot(c["author"]["login"]) and c["author"]["login"] != self_login
]

MARKER_RE = re.compile(r"<!--\s*(.*?)\s*-->", re.S)
ANCHOR_RE = re.compile(r"#user-content-([a-z0-9-]+)")
SHORTCODE_RE = re.compile(r":[a-z0-9_+-]+:")
NON_WORD_RE = re.compile(r"[^a-z0-9 ]+")
NUM_RE = re.compile(r"\b\d[\d.,%]*\b")

def first_heading(body: str) -> str:
    for line in body.splitlines():
        line = line.strip()
        if line:
            return line
    return ""

def norm_tokens(text: str) -> frozenset:
    text = SHORTCODE_RE.sub(" ", text.lower())
    text = NUM_RE.sub(" ", text)
    text = NON_WORD_RE.sub(" ", text)
    stop = {"the", "a", "an", "for", "of", "on", "in", "and", "issue", "issues", "s"}
    return frozenset(t for t in text.split() if t and t not in stop)

def kind_key(c):
    body = c["body"]
    m = MARKER_RE.search(body)
    if m:
        # Strip volatile parts (shas, run ids) out of the marker.
        marker = NUM_RE.sub("", m.group(1).split("\n")[0]).strip().lower()
        marker = re.sub(r"\b[0-9a-f]{7,40}\b", "", marker).strip()
        if marker:
            return ("marker", marker)
    a = ANCHOR_RE.search(body)
    if a:
        return ("anchor", a.group(1))
    return None  # falls through to token grouping

exact, fuzzy = {}, []
for c in candidates:
    k = kind_key(c)
    (exact.setdefault(k, []).append(c)) if k else fuzzy.append(c)

# Union-find over normalized first-heading tokens (Jaccard >= 0.5).
groups: list[list] = []
tokensets: list[frozenset] = []
ambiguous = []
for c in fuzzy:
    toks = norm_tokens(first_heading(c["body"]))
    if not toks:
        ambiguous.append(c)
        continue
    best_i, best_j = -1, 0.0
    for i, ts in enumerate(tokensets):
        j = len(toks & ts) / len(toks | ts)
        if j > best_j:
            best_i, best_j = i, j
    if best_j >= 0.5:
        groups[best_i].append(c)
        tokensets[best_i] = tokensets[best_i] | toks
    else:
        groups.append([c])
        tokensets.append(toks)

if ambiguous and use_claude:
    brief = [{"id": c["id"], "first_line": first_heading(c["body"])[:120],
              "excerpt": c["body"][:200]} for c in ambiguous]
    prompt = (
        "Group these bot PR comments by report KIND (same recurring report re-posted per push "
        "= one kind). Reply with ONLY JSON: {\"groups\": [[\"id\", ...], ...]} using every id "
        "exactly once.\n" + json.dumps(brief)
    )
    out = subprocess.run(["claude", "-p", prompt], capture_output=True, text=True, timeout=300)
    parsed = json.loads(re.search(r"\{.*\}", out.stdout, re.S).group(0))
    by_id = {c["id"]: c for c in ambiguous}
    claimed = [i for g in parsed["groups"] for i in g]
    if sorted(claimed) == sorted(by_id):  # subset+exactly-once rail
        for g in parsed["groups"]:
            groups.append([by_id[i] for i in g])
        ambiguous = []

# Underscore-tolerant boundaries (markdown italics glue to shas: _f612af3_) and at least
# one a-f letter so purely numeric tokens (CI run ids) are not mistaken for shas.
SHA_RE = re.compile(r"(?<![0-9A-Za-z])(?=[0-9a-f]*[a-f])([0-9a-f]{7,40})(?![0-9A-Za-z])")

def newest_is_stale(c) -> bool:
    shas = SHA_RE.findall(c["body"])
    if shas:
        return not any(head_sha.startswith(m) or m.startswith(head_sha[:7]) for m in shas)
    return c["createdAt"] < head_date

plan = {"minimize": [], "keep": [], "ambiguous_kept": []}
for kind, members in list(exact.items()) + [(("tokens", i), g) for i, g in enumerate(groups)]:
    members.sort(key=lambda c: c["createdAt"])
    newest = members[-1]
    stale_newest = newest_is_stale(newest)
    for c in members[:-1]:
        (plan["keep"] if c["isMinimized"] else plan["minimize"]).append(
            {"id": c["id"], "why": f"superseded {kind[0]}:{kind[1]}",
             "line": first_heading(c["body"])[:80],
             "already_minimized": c["isMinimized"]})
    if stale_newest:
        (plan["keep"] if newest["isMinimized"] else plan["minimize"]).append(
            {"id": newest["id"], "why": f"stale newest (predates head {head_sha[:7]}) {kind[0]}:{kind[1]}",
             "line": first_heading(newest["body"])[:80],
             "already_minimized": newest["isMinimized"]})
    else:
        plan["keep"].append({"id": newest["id"], "why": f"newest {kind[0]}:{kind[1]}",
                             "line": first_heading(newest["body"])[:80],
                             "already_minimized": newest["isMinimized"]})
for c in ambiguous:
    plan["ambiguous_kept"].append({"id": c["id"], "line": first_heading(c["body"])[:80]})

# --- Review OVERVIEWS (separate from the report kind-grouping above) ---
# A review is stale by SUPERSESSION (a newer review from the SAME author exists), not by
# head sha. Per author, keep their LATEST non-dismissed review overview (the live gate
# signal) and minimize every older or DISMISSED one. Bots AND humans, minus the PR author
# (self). Reviews with no body carry no overview and are skipped. If an author has only
# dismissed reviews (no live one), all are minimized -- we keep only an approval-or-open
# last word, per the caller's choice.
review_overviews = [
    r for r in reviews
    if (r.get("body") or "").strip()
    and r.get("author") and r["author"]["login"] != self_login
]
by_author = {}
for r in review_overviews:
    by_author.setdefault(r["author"]["login"], []).append(r)
for login, revs in by_author.items():
    revs.sort(key=lambda r: r["submittedAt"])
    live = [r for r in revs if r.get("state") != "DISMISSED"]
    keeper_id = live[-1]["id"] if live else None
    for r in revs:
        entry = {"id": r["id"], "line": first_heading(r["body"])[:80],
                 "already_minimized": r["isMinimized"]}
        if r["id"] == keeper_id:
            plan["keep"].append({**entry, "why": f"latest {r['state']} review by {login}"})
        elif r["isMinimized"]:
            plan["keep"].append({**entry, "why": f"already minimized {r['state']} review by {login}"})
        else:
            plan["minimize"].append({**entry, "why": f"superseded {r['state']} review by {login}"})

print(json.dumps(plan, indent=2))
PYEOF
)"

echo "$PLAN"

if [[ "$APPLY" == "1" ]]; then
  echo "$PLAN" | jq -r '.minimize[].id' | while read -r nid; do
    [[ -n "$nid" ]] || continue
    gh api graphql \
      -f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
      -F id="$nid" --jq '.data.minimizeComment.minimizedComment.isMinimized' >/dev/null
    echo "minimized $nid"
  done
  echo "done: $(echo "$PLAN" | jq '.minimize | length') minimized, $(echo "$PLAN" | jq '.keep | length') kept, $(echo "$PLAN" | jq '.ambiguous_kept | length') ambiguous kept"
else
  echo "DRY RUN — pass --apply to execute ($(echo "$PLAN" | jq '.minimize | length') would be minimized)"
fi
