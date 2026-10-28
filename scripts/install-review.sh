#!/usr/bin/env bash
# Install the AI review caller workflow in repositories.
#
# Usage: scripts/install-review.sh [--config-ref REF] [--ci-ref REF] [--update] owner/repo...
#
# Writes .github/workflows/ai-review.yml on a branch and opens a pull request.
# Both references are pinned to commits: --ci-ref names the commit in this
# repository that the caller runs, and --config-ref the commit in
# joaomj/pi-agent-config that supplies the review guidelines.
#
# This script never writes repository secrets. Credentials are yours to add.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

config_ref=v0.7.2
ci_ref=
update=0
repos=()

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config-ref) config_ref=${2:?--config-ref needs a value}; shift 2 ;;
    --ci-ref) ci_ref=${2:?--ci-ref needs a value}; shift 2 ;;
    --update) update=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) repos+=("$1"); shift ;;
  esac
done

[ ${#repos[@]} -gt 0 ] || { usage >&2; die "name at least one repository as owner/name"; }
command -v gh >/dev/null || die "gh is not installed"
command -v git >/dev/null || die "git is not installed"
command -v jq >/dev/null || die "jq is not installed"

config_sha=$(resolve_commit joaomj/pi-agent-config "$config_ref")
if [ -z "$ci_ref" ]; then
  ci_ref=$(git -C "$here/.." rev-parse HEAD)
fi
ci_sha=$(resolve_commit joaomj/github-ci "$ci_ref")

printf '== github-ci      %s\n== pi-agent-config %s\n' "$ci_sha" "$config_sha"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
body=$work/body.md
cat > "$body" <<'MD'
Adds a pre-merge AI review for pull requests into the default branch.

The workflow calls the shared review in `joaomj/github-ci`. It reviews the pull
request with the `code-review` guidelines from `joaomj/pi-agent-config`, posts
the report as a review comment, and fails when the report contains a P0 or P1
finding.

The job runs only for pull requests whose head branch is in this repository, so
a fork pull request is skipped. It needs the `LLM_API_KEY` repository secret;
without it the job fails before reviewing. Until a branch rule requires the
`ai-review / review` check, the review reports without blocking a merge.
MD

for repo in "${repos[@]}"; do
  printf '\n== %s\n' "$repo"
  base=$(default_branch "$repo")
  if [ "$update" -eq 0 ] && gh api "repos/$repo/branches/ai-review" >/dev/null 2>&1; then
    printf 'skip: branch ai-review already exists; pass --update to rewrite it\n'
    continue
  fi
  caller=$work/caller-${repo##*/}.yml
  sed -e "s|@@BASE_BRANCH@@|$base|g" \
    -e "s|@@CI_SHA@@|@$ci_sha|g" \
    -e "s|@@CONFIG_SHA@@|$config_sha|g" \
    "$here/../caller/ai-review.yml" > "$caller"
  printf '%s\n' "$(open_pr "$repo" ai-review "Add the AI review workflow" "$body" \
    "Add the AI review workflow" \
    "$caller:.github/workflows/ai-review.yml")"
done
