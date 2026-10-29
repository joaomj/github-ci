#!/usr/bin/env bash
# Cut a release: tag the current commit, push the tag, and publish a release.
#
#   scripts/release.sh v1.0.0
#
# The tag is what callers pin, so a release is the unit of change: until you cut
# one, no repository moves. Tags cannot be moved once protected by the `release`
# ruleset, so a published version always means the same files.

set -euo pipefail

usage() { printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2; exit 2; }
tag="${1:-}"
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

root="$(git rev-parse --show-toplevel)"
cd "${root}"

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "commit or stash your changes first"
git show-ref --tags --verify --quiet "refs/tags/${tag}" && die "tag ${tag} already exists"
git fetch --quiet origin

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "${branch}" == main ]] || die "you are on ${branch}; release from main"
git merge-base --is-ancestor origin/main HEAD \
  || die "origin/main has commits you do not have; pull first"

note "Checking the workflow parses"
command -v yq >/dev/null && yq eval '.jobs.review.steps | length' .github/workflows/ai-review.yml >/dev/null

note "Tagging ${tag} (signed)"
git tag -s --annotate "${tag}" --message "${tag}"

note "Pushing the tag"
git push --quiet origin "${tag}"

note "Publishing the release"
gh release create "${tag}" --title "${tag}" --generate-notes

note "Released ${tag}. Re-pin callers with:"
printf '  scripts/install-review.sh --ci-ref %s owner/repo...\n' "${tag}"
