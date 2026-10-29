#!/usr/bin/env bash
# Cut a release: tag the current commit, prove it with a canary review, then move
# the floating major tag that callers follow.
#
#   scripts/release.sh v1.1.0
#
# Two tags come out of one release:
#   v1.1.0  the permanent, protected record of this code
#   v1      a pointer that moves here, and what every caller pins
#
# The canary runs before the pointer moves, so a broken release never reaches a
# repository. If the canary fails, the version tag stays (tags are immutable) and
# the pointer does not move: fix forward with the next patch release.

set -euo pipefail

die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

repo=joaomj/github-ci
config_ref=v0.7.2
tag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config-ref) config_ref=$2; shift 2 ;;
    -*) die "unknown option $1" ;;
    *) tag=$1; shift ;;
  esac
done

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh [--config-ref REF] vMAJOR.MINOR.PATCH"
major="${tag%%.*}"

root="$(git rev-parse --show-toplevel)"
cd "$root"

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit or stash your changes first"
git show-ref --tags --verify --quiet "refs/tags/$tag" && die "tag $tag already exists"
git fetch --quiet origin

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == main ]] || die "you are on $branch; release from main"
git merge-base --is-ancestor origin/main HEAD || die "origin/main has commits you do not have; pull first"
command -v yq >/dev/null || die "yq is required to check the workflow files"
for f in .github/workflows/ai-review.yml .github/workflows/canary.yml; do
  yq -e '.jobs | length' "$f" >/dev/null || die "$f does not parse"
done

note "Tagging $tag (signed)"
git tag -s --annotate "$tag" --message "$tag"

note "Pushing $tag"
git push --quiet origin "$tag"

note "Running the canary against $tag"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run canary.yml --repo "$repo" --ref "$tag" --field "config-ref=$config_ref" >/dev/null

run_id=""
for _ in $(seq 1 30); do
  run_id=$(gh run list --repo "$repo" --workflow canary.yml --limit 1 \
    --json databaseId,createdAt --jq ".[0] | select(.createdAt >= \"$started\") | .databaseId" 2>/dev/null || true)
  [ -n "$run_id" ] && break
  sleep 2
done
[ -n "$run_id" ] || die "the canary did not start; $tag is tagged, $major did not move"

if ! gh run watch "$run_id" --repo "$repo" --exit-status >/dev/null 2>&1; then
  die "the canary failed; $tag is tagged, $major did not move. Inspect: gh run view $run_id --log-failed"
fi
note "Canary passed"

note "Moving $major to $tag"
git tag --force --sign --annotate "$major" --message "$major: currently $tag"
git push --quiet --force origin "refs/tags/$major"

note "Publishing the release"
gh release create "$tag" --repo "$repo" --title "$tag" --generate-notes
gh release create "$major" --repo "$repo" --title "$major (floating)" \
  --notes "Tracks the newest $major release. Currently $tag. Callers pin this tag." >/dev/null 2>&1 || true

note "Released $tag. $major now points here; callers pick it up on their next pull request."
