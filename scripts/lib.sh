#!/usr/bin/env bash
# Helpers shared by the install and baseline scripts. Source this file.

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# resolve_commit <owner/repo> <ref> — echo the commit a tag or branch points to.
resolve_commit() {
  local url=https://github.com/$1 ref=$2 sha=
  sha=$(git ls-remote "$url" "refs/tags/$ref^{}" | cut -f1)
  [ -n "$sha" ] || sha=$(git ls-remote "$url" "refs/tags/$ref" | cut -f1)
  [ -n "$sha" ] || sha=$(git ls-remote "$url" "refs/heads/$ref" | cut -f1)
  [ -n "$sha" ] || die "cannot resolve $ref in $url"
  printf '%s\n' "$sha"
}

# default_branch <owner/repo>
default_branch() {
  local info base
  info=$(gh api "repos/$1" 2>&1) || die "cannot read $1: $info"
  base=$(printf '%s' "$info" | jq -r .default_branch)
  [ -n "$base" ] && [ "$base" != null ] || die "cannot read the default branch of $1"
  printf '%s\n' "$base"
}

# open_pr <owner/repo> <branch> <title> <body-file> <commit-message> <src:dest>...
# Commits the given files on a new branch, opens a pull request, and merges it.
# Prints "merged", "up to date", or "open" so the caller can report the outcome.
open_pr() {
  local repo=$1 branch=$2 title=$3 body=$4 message=$5
  shift 5
  local dir base pair src dest
  base=$(default_branch "$repo")
  dir="$(mktemp -d)/${repo##*/}"
  git clone --quiet "git@github.com:$repo.git" "$dir" || die "cannot clone $repo"
  git -C "$dir" switch --quiet -c "$branch"
  for pair in "$@"; do
    src=${pair%%:*}
    dest=${pair#*:}
    mkdir -p "$dir/$(dirname "$dest")"
    cp "$src" "$dir/$dest"
  done
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    printf 'up to date\n'
    return 0
  fi
  git -C "$dir" commit --quiet -m "$message"
  git -C "$dir" push --quiet -u origin "$branch" || die "cannot push to $repo"
  gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title "$title" --body-file "$body" >/dev/null || die "cannot open a pull request on $repo"
  if gh pr merge --repo "$repo" "$branch" --merge --delete-branch >/dev/null 2>&1; then
    printf 'merged\n'
  elif gh pr merge --repo "$repo" "$branch" --merge --delete-branch --admin >/dev/null 2>&1; then
    printf 'merged with admin bypass\n'
  else
    printf 'open, merge it when checks pass\n'
  fi
}
