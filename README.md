# github-ci

Shared GitHub automation for my repositories:

- an AI code review on every pull request opened against the default branch;
- a baseline branch policy applied to each repository.

A repository holds one small caller file naming a workflow here, pinned to a
release tag. The logic lives in this repository, so a change ships once, as a
tag, and every caller can move to it with one command.

## Layout

| Path | What it is |
|---|---|
| `.github/workflows/ai-review.yml` | Reusable review workflow called by every repository |
| `review/prelude.md` | CI-only constraints prepended to the guidelines |
| `review/verdict.md` | The `REVIEW-VERDICT` protocol appended to the guidelines |
| `caller/ai-review.yml` | Template for the caller file installed per repository |
| `templates/` | Pull request and issue templates installed per repository |
| `scripts/lib.sh` | Shared helpers: ref resolution, pull-request helper |
| `scripts/install-review.sh` | Writes the caller file into repositories |
| `scripts/apply-baseline.sh` | Repository settings, CodeQL, templates, ruleset |
| `scripts/release.sh` | Cuts a release tag |

## How a review runs

1. A pull request opens against the default branch, and the caller workflow
   starts the reusable workflow at the tag the caller pins.
2. The job installs [Pi](https://pi.dev) and Node on a fresh `ubuntu-latest`
   runner, then fetches this repository at `ci-ref` and
   [pi-agent-config](https://github.com/joaomj/pi-agent-config) at `config-ref`.
3. It assembles one prompt: a scope header, `review/prelude.md`, the
   `code-review` guidelines, then `review/verdict.md`.
4. Pi reviews the checkout with two tools, `read` and `bash`, and writes the
   report to stdout.
5. The report is posted as a pull-request review comment by the job's own token.
6. The final `REVIEW-VERDICT` line decides the job status. A `BLOCK` verdict
   fails the job; a missing verdict fails it too, because an inconclusive review
   must not read as approval.

Nothing is hosted. Each review is one job in the repository being reviewed, so
there is no server, no queue, and no long-lived agent process.

### Inputs

| Input | Default | Meaning |
|---|---|---|
| `ci-ref` | required | Tag in this repository supplying the workflow, prelude, and verdict text |
| `config-ref` | `v0.7.2` | Tag in `pi-agent-config` supplying the guidelines and skills |
| `guidelines` | `prompts/code-review.md` | Guideline file inside `config-ref` |
| `model` | `openrouter/openai/gpt-6.1-sol` | Reviewer model |
| `thinking` | `medium` | Thinking level, clamped to what the model supports |

### Credentials

The job reads exactly one secret, `LLM_API_KEY`, and passes it to Pi with
`--api-key`. The name is provider-neutral: swap `model` to a different provider
and the same secret name still works.

The write-scoped `GITHUB_TOKEN` reaches only the step that posts the comment.
The review step, where the agent runs commands, has no token in its environment.

## Install a review in a repository

```bash
# 1. install the caller on a branch and open a pull request
scripts/install-review.sh --config-ref v0.7.2 joaomj/example-repo

# 2. give the job its credential
gh secret set LLM_API_KEY --repo joaomj/example-repo

# 3. after the caller merges, require the check (see Baseline policy)
```

`install-review.sh` validates both tags before touching anything, so a typo
fails once, not in nine workflows. It never writes repository secrets — that
stays an explicit step. Re-running it with `--update` rewrites the branch it
created earlier.

Verify the check name on a real pull request before requiring it: a required
check that never reports blocks every merge. The context is
`ai-review / review`, and the first run on any repository confirms it.

## Releases and pinning

Callers pin `v1`, a floating major tag. A release produces two tags:

| Tag | Behavior |
|---|---|
| `v1.1.0` | Permanent. Protected by the `release` ruleset, signed, never moves |
| `v1` | Moves to the newest release. What every caller pins |

```bash
scripts/release.sh v1.1.0
```

That one command tags the commit, pushes it, runs the canary against the exact
tag, and only then moves `v1`. Nothing to re-pin, no pull requests in nine
repositories, nothing to merge.

The protection pattern is `refs/tags/v*.*.*`, so version tags are immutable
while the major tag stays movable on purpose. A version tag is evidence; the
major tag is a pointer.

### How a release reaches the repositories

Nothing is pushed into the repositories. Each one holds a caller naming
`@v1`, and GitHub resolves that name when a run starts:

1. A pull request opens, and GitHub resolves `v1` to its current commit and runs
   that workflow version.
2. The job fetches `github-ci` at `ci-ref` (`v1`) for the prelude and verdict
   text.

Updates are therefore lazy and per-event: a release takes effect on each
repository's next pull request, a run already in flight keeps the code it
started with, and nothing retroactively re-runs. A repository with no pull
request activity keeps running older code until its next one.

Rolling back is the same motion: move `v1` back to the previous release tag.

```bash
git tag --force --sign --annotate v1 --message "v1: back to v1.0.0" v1.0.0
git push --force origin refs/tags/v1
```

### The canary

`scripts/release.sh` refuses to move `v1` unless a real review succeeds against
the exact tag being released: `.github/workflows/canary.yml` installs Pi,
assembles the same prompt, calls the same `scripts/review.sh`, and requires a
`REVIEW-VERDICT` line.

It catches a broken Pi install, a bad model id, a broken prompt chain, and a
missing verdict. It does not catch a broken caller workflow file, because only a
real pull request exercises that path. If the canary fails, the version tag
stays (it is immutable) and `v1` stays where it was: fix forward with the next
patch release.

The canary needs `LLM_API_KEY` on this repository, like any repository that runs
a review.

### Trust boundary

A floating tag means whoever can push here can run code in every repository that
holds `LLM_API_KEY`. That is why this repository carries the same baseline
policy as the others: no deletion, no force push, signed commits, and merges
through a pull request. Admin bypass still applies, as everywhere.

## Baseline policy

`scripts/apply-baseline.sh` applies, per repository:

| Item | Mechanism |
|---|---|
| Deletion and force-push protection | ruleset rules |
| Required signed commits | ruleset rule |
| Required pull request, thread resolution | ruleset rule |
| CodeQL gate at high-risk severity | ruleset rule, added once CodeQL reports |
| Required AI review | ruleset rule with `--require-review` |
| Admin escape hatch | ruleset bypass, mode `always` |
| Secret scanning and push protection | repository settings |
| Pull requests closed to non-collaborators | repository setting |
| Default merge commit message | repository settings |
| Pull request and issue templates | files from `templates/` |

This repository carries the same baseline, without the required AI review:
nothing reviews `github-ci`'s own pull requests yet, so requiring the check there
would block every merge.

```bash
scripts/apply-baseline.sh --dry-run joaomj/example-repo
scripts/apply-baseline.sh --require-review joaomj/example-repo
```

Two limits are worth knowing:

- The CodeQL rule needs scan results, so the first run configures scanning and
  adds the rule only where an analysis exists. Re-run later to add it.
- Bypass mode `always` means a repository admin skips every rule, including
  required reviews. On a single-admin account the policy constrains future
  collaborators, not its owner.

## Operations

| Task | Command |
|---|---|
| Change the reviewer model or thinking level | edit `.github/workflows/ai-review.yml`, run `scripts/release.sh vX.Y.Z` |
| Change the review guidelines | edit `prompts/code-review.md` in `pi-agent-config`, release it, then pass `--config-ref` to the next release here |
| Run the canary by hand | `gh workflow run canary.yml --ref v1` |
| Move `v1` back to an older release | the rollback commands above |
| Pause reviews in one repository | `gh workflow disable "AI review" --repo joaomj/<repo>` |
| Resume reviews | `gh workflow enable "AI review" --repo joaomj/<repo>` |
| Rotate the key | `gh secret set LLM_API_KEY --repo joaomj/<repo>` |
| Check a run | `gh run list --repo joaomj/<repo> --workflow "AI review" --limit 5` |

## Troubleshooting

**The check never appears.** The caller must exist on the pull request head or
the base branch, and the repository must have pull requests enabled. Check
`gh run list --repo joaomj/<repo> --event pull_request`.

**The job fails with "LLM_API_KEY is empty".** The secret is missing on that
repository. This failure is deliberate: a review that cannot authenticate must
not report success.

**The job fails with "Cannot fetch ...".** The pinned tag does not exist on the
remote. Check `git ls-remote https://github.com/joaomj/github-ci refs/tags/v1`.

**The canary failed during a release.** The version tag exists and `v1` did not
move, so no repository changed. Read `gh run view <id> --log-failed`, fix, then
release the next patch version.

**Every repository broke at once.** `v1` moved to a bad release. Roll it back to
the previous version tag; the next pull request in each repository uses it.

**The job fails with "The review did not end with a REVIEW-VERDICT line".**
The model omitted the protocol line. Re-run the job; if it repeats, tighten
`review/verdict.md` rather than letting an inconclusive report pass.

**A merge is blocked with "base branch policy prohibits the merge".** A required
check is pending or failing. `gh pr checks` shows which. A repository admin can
merge anyway with `gh pr merge --admin`.

**Fork pull requests never run.** The job skips them: GitHub does not give fork
pull requests the secret, and running without it would fail the required check
for an outside contributor.

## Limits

- Private repositories are out of scope: a free plan cannot require a status
  check there, so a review would report without blocking.
- Each review costs a model call of unknown size until measured, and consumes
  Actions minutes on private repositories (public repositories are free).
- The reviewer sees the diff and the repository at the pull request head, not
  the runtime behavior of the change.
- This repository is scanned with CodeQL default setup for the `actions`
  language. Its own ruleset gains the CodeQL gate once a first analysis exists.

## Development

```bash
bash -n scripts/lib.sh scripts/install-review.sh scripts/apply-baseline.sh scripts/release.sh
scripts/apply-baseline.sh --dry-run joaomj/<repo>
```
