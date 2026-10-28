#!/usr/bin/env bash
# Apply the baseline repository policy to repositories.
#
# Usage: scripts/apply-baseline.sh [--dry-run] [--skip-ruleset] owner/repo...
#
# Per repository:
#   1. Settings: pull requests on, outside pull requests closed to
#      non-collaborators, default merge commit message, secret scanning and
#      push protection.
#   2. CodeQL default setup.
#   3. Pull request and issue templates.
#   4. A "default-branch" ruleset: no deletion, no force push, signed commits,
#      required pull request, and a CodeQL gate wherever CodeQL reports.
#
# Code scanning must produce results before a CodeQL rule can gate a merge, so
# the rule is added only where an analysis exists. The first run enables
# scanning; re-run later to add the rule.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/lib.sh"

dry_run=0
skip_ruleset=0
repos=()

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --skip-ruleset) skip_ruleset=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) repos+=("$1"); shift ;;
  esac
done

[ ${#repos[@]} -gt 0 ] || { usage >&2; die "name at least one repository as owner/name"; }
command -v gh >/dev/null || die "gh is not installed"
command -v jq >/dev/null || die "jq is not installed"

settings=$(jq -n '{
  has_pull_requests: true,
  pull_request_creation_policy: "collaborators_only",
  merge_commit_title: "PR_TITLE",
  merge_commit_message: "PR_BODY",
  squash_merge_commit_title: "PR_TITLE",
  squash_merge_commit_message: "PR_BODY",
  security_and_analysis: {
    secret_scanning: { status: "enabled" },
    secret_scanning_push_protection: { status: "enabled" },
    secret_scanning_non_provider_patterns: { status: "enabled" }
  }
}')

base_ruleset=$(jq -n '{
  name: "default-branch",
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  bypass_actors: [
    { actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" }
  ],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "required_signatures" },
    {
      type: "pull_request",
      parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: false,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: true,
        allowed_merge_methods: ["merge", "squash", "rebase"]
      }
    }
  ]
}')

codeql_rule=$(jq -n '{
  type: "code_scanning",
  parameters: {
    code_scanning_tools: [
      { tool: "CodeQL", alerts_threshold: "errors", security_alerts_threshold: "high_or_higher" }
    ]
  }
}')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/body.md" <<'MD'
Adds the standard pull request and issue templates.

The pull request template asks for the change, the reason, and the verification.
The issue templates separate a defect from a feature request and ask for the
smallest reproduction.
MD

for repo in "${repos[@]}"; do
  printf '\n== %s\n' "$repo"
  if [ "$dry_run" -eq 1 ]; then
    printf 'would set pull requests, merge message, secret scanning, CodeQL, templates, and the default-branch ruleset\n'
    continue
  fi

  if printf '%s\n' "$settings" | gh api --method PATCH "repos/$repo" --input - >/dev/null; then
    printf 'settings: pull requests on, collaborators-only, merge message, secret scanning\n'
  else
    die "cannot change the settings of $repo"
  fi

  if printf '{"state":"configured"}' \
      | gh api --method PATCH "repos/$repo/code-scanning/default-setup" --input - >/dev/null 2>&1; then
    printf 'codeql: default setup configured\n'
  else
    printf 'codeql: cannot configure default setup, the CodeQL rule will be skipped\n'
  fi

  template_result=$(open_pr "$repo" repo-baseline "Add the standard templates" "$work/body.md" \
    "Add the standard pull request and issue templates" \
    "$here/../templates/pull_request_template.md:.github/pull_request_template.md" \
    "$here/../templates/ISSUE_TEMPLATE/bug.yml:.github/ISSUE_TEMPLATE/bug.yml" \
    "$here/../templates/ISSUE_TEMPLATE/feature.yml:.github/ISSUE_TEMPLATE/feature.yml")
  printf 'templates: %s\n' "$template_result"

  if [ "$skip_ruleset" -eq 1 ]; then
    printf 'ruleset: skipped\n'
    continue
  fi

  payload=$base_ruleset
  if [ "$(gh api "repos/$repo/code-scanning/analyses?per_page=1" 2>/dev/null | jq 'length' || printf 0)" -gt 0 ]; then
    payload=$(printf '%s\n%s\n' "$base_ruleset" "$codeql_rule" \
      | jq -s '.[0] * {rules: (.[0].rules + [.[1]])}')
    note="with the CodeQL gate"
  else
    note="without the CodeQL gate, re-run once code scanning has results"
  fi

  existing=$(gh api "repos/$repo/rulesets" 2>/dev/null | jq -r '.[] | select(.name == "default-branch") | .id' || true)
  if [ -n "$existing" ]; then
    printf '%s\n' "$payload" | gh api --method PUT "repos/$repo/rulesets/$existing" --input - >/dev/null
    printf 'ruleset: updated %s\n' "$note"
  else
    printf '%s\n' "$payload" | gh api --method POST "repos/$repo/rulesets" --input - >/dev/null
    printf 'ruleset: created %s\n' "$note"
  fi
done
