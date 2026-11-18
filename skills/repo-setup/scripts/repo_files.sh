#!/usr/bin/env bash
# repo_files.sh <checkout dir> --repo <owner/repo> --kind plugin|mcp|lib|private
#               [--license <spdx id>|none] [--author "<name>"] [--dry-run]
#
# Adds the baseline files a repository is missing, in a local checkout. Never
# overwrites an existing file. Prints one line per file:
#   ADDED   <path>            written from the template (or "WOULD ADD" with --dry-run)
#   EXISTS  <path>            already there, left alone
#   TODO    <path>            added with <!-- TODO --> markers to fill in by hand
#   MISSING <path>: <why>     wanted but not written (decide by hand)
#   WARN    <text>            something in the repo that breaks the baseline
#
# Public kinds (plugin, mcp, lib) get: LICENSE (--license, from GitHub's license
# API), SECURITY.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md (Contributor Covenant,
# from GitHub's API), PRIVACY.md (plugin and mcp), .github/CODEOWNERS, issue
# forms and their config.yml, a PR template, .github/dependabot.yml, and for
# plugins .github/workflows/tests.yml. Every versioned repo gets a tag-triggered
# .github/workflows/release.yml unless a workflow already triggers on tags.
# Private repos get only .github/dependabot.yml.
#
# Template placeholders: {{REPO}} {{OWNER}} {{NAME}} {{DEFAULT_BRANCH}}.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TPL="$HERE/../templates"
usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
DIR="${1:-}"; [ -d "$DIR" ] || usage; shift
REPO=""; KIND=""; LICENSE=""; AUTHOR=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --kind) KIND="$2"; shift 2;;
    --license) LICENSE="$2"; shift 2;;
    --author) AUTHOR="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) usage;;
  esac
done
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || usage
case "$KIND" in plugin|mcp|lib|private) ;; *) usage;; esac
cd "$DIR" || exit 2
OWNER=${REPO%/*}; NAME=${REPO#*/}
DEFAULT=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "$DEFAULT" ] || DEFAULT=$(gh api "repos/$REPO" --jq .default_branch 2>/dev/null)
[[ "$DEFAULT" =~ ^[A-Za-z0-9._/-]+$ ]] || DEFAULT=main
[ -n "$AUTHOR" ] || AUTHOR=$(gh api user --jq '.name // .login' 2>/dev/null)

fill() { sed -e "s#{{REPO}}#$REPO#g" -e "s#{{OWNER}}#$OWNER#g" -e "s#{{NAME}}#$NAME#g" -e "s#{{DEFAULT_BRANCH}}#$DEFAULT#g"; }
# put <path> <content on stdin>: write it unless it exists
put() {
  local path=$1 body
  body=$(cat)
  if [ -e "$path" ]; then echo "EXISTS  $path"; return; fi
  if [ -z "$body" ]; then echo "MISSING $path: its template produced nothing"; return; fi
  if [ "$DRY" = 1 ]; then echo "WOULD ADD $path"; return; fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
  if grep -q 'TODO' "$path"; then echo "TODO    $path"; else echo "ADDED   $path"; fi
}
tpl() { fill < "$TPL/$1" | put "$2"; }

public=1; [ "$KIND" = private ] && public=0

if [ "$public" = 1 ]; then
  # LICENSE
  if ls LICENSE LICENSE.md LICENSE.txt COPYING >/dev/null 2>&1; then echo "EXISTS  LICENSE"
  elif [ -z "$LICENSE" ]; then echo "MISSING LICENSE: ask the user which license, then pass --license <spdx id>"
  elif [ "$LICENSE" = none ]; then echo "MISSING LICENSE: none wanted"
  else
    body=$(gh api "licenses/$(tr '[:upper:]' '[:lower:]' <<<"$LICENSE")" --jq .body 2>/dev/null)
    if [ -z "$body" ]; then echo "MISSING LICENSE: GitHub has no license '$LICENSE'"
    else sed -e "s/\[year\]/$(date +%Y)/g" -e "s/\[yyyy\]/$(date +%Y)/g" -e "s/\[fullname\]/$AUTHOR/g" \
           -e "s/\[name of copyright owner\]/$AUTHOR/g" <<<"$body" | put LICENSE; fi
  fi
  [ -e README.md ] || echo "MISSING README.md: write it by hand (what it does, install, usage)"
  tpl SECURITY.md SECURITY.md
  if [ "$KIND" = plugin ]; then tpl CONTRIBUTING.plugin.md CONTRIBUTING.md; else tpl CONTRIBUTING.md CONTRIBUTING.md; fi
  if [ -e CODE_OF_CONDUCT.md ]; then echo "EXISTS  CODE_OF_CONDUCT.md"
  else
    coc=$(gh api codes_of_conduct/contributor_covenant --jq .body 2>/dev/null)
    if [ -n "$coc" ]; then
      sed "s#\[INSERT CONTACT METHOD\]#a private report at https://github.com/$REPO/security/advisories/new#" <<<"$coc" | put CODE_OF_CONDUCT.md
    else echo "MISSING CODE_OF_CONDUCT.md: could not fetch the Contributor Covenant"; fi
  fi
  case "$KIND" in plugin|mcp) tpl PRIVACY.md PRIVACY.md;; esac
  tpl .github/CODEOWNERS .github/CODEOWNERS
  tpl .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/bug_report.yml
  tpl .github/ISSUE_TEMPLATE/feature_request.yml .github/ISSUE_TEMPLATE/feature_request.yml
  tpl .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/config.yml
  [ -e .github/pull_request_template.md ] && echo "EXISTS  .github/pull_request_template.md" \
    || tpl .github/PULL_REQUEST_TEMPLATE.md .github/PULL_REQUEST_TEMPLATE.md
fi

# dependabot.yml: GitHub Actions plus every ecosystem found in the checkout.
if [ -e .github/dependabot.yml ] || [ -e .github/dependabot.yaml ]; then echo "EXISTS  .github/dependabot.yml"
else
  {
    echo "version: 2"
    echo "updates:"
    eco() {  # eco <ecosystem> <directory>
      printf '  - package-ecosystem: %s\n    directory: "%s"\n    schedule:\n      interval: weekly\n    groups:\n      %s:\n        patterns: ["*"]\n' "$1" "$2" "$1"
    }
    eco github-actions /
    [ -f go.mod ] && eco gomod /
    if [ -f uv.lock ]; then eco uv /
    elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then eco pip /; fi
    [ -f package.json ] && eco npm /
    [ -f Cargo.toml ] && eco cargo /
    { [ -f Dockerfile ] || ls Dockerfile.* >/dev/null 2>&1; } && eco docker /
  } | put .github/dependabot.yml
fi

if [ "$public" = 1 ]; then
  # CI: plugins get the standard plugin test workflow; other kinds need one
  # written for their language, so it is only reported.
  workflows=$(ls .github/workflows/*.y*ml 2>/dev/null)
  # grep with no file arguments would read stdin, so /dev/null is always one of them.
  wf_grep() { [ -n "$workflows" ] && grep "$@" $workflows /dev/null; }
  if [ "$KIND" = plugin ]; then
    if wf_grep -lqs 'claude plugin validate'; then echo "EXISTS  plugin test workflow"
    else tpl .github/workflows/plugin-tests.yml .github/workflows/tests.yml; fi
  elif [ -z "$workflows" ]; then
    echo "MISSING .github/workflows/ci.yml: write CI for this language (see SKILL.md, CI rules)"
  fi
  # Release on v* tags, unless something already releases on tags.
  if wf_grep -lqsE '^\s*tags:'; then echo "EXISTS  release workflow (a workflow triggers on tags)"
  else tpl .github/workflows/release.yml .github/workflows/release.yml; fi
  # Claude's plugin directory refuses repos whose .gitattributes rewrites archives.
  if [ "$KIND" = plugin ] && grep -qsE 'export-ignore|export-subst|filter=' .gitattributes; then
    echo "WARN    .gitattributes uses export-ignore, export-subst or a filter: the Claude plugin directory refuses to validate such a repo"
  fi
fi
exit 0