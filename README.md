# github-ci

Shared GitHub workflows for my repositories: one AI code review each time a
pull request opens against the default branch, and one baseline branch policy.

A repository here means a small caller file that names a workflow in this
repository. The logic lives here, so a change reaches every repository without
editing any of them.

## AI review

`.github/workflows/ai-review.yml` runs on every pull request opened against the
default branch. It reviews the change with the `code-review` guidelines from
[pi-agent-config](https://github.com/joaomj/pi-agent-config), posts the report as
a review comment, and fails when the report holds a P0 or P1 finding. A required
branch check turns that failure into a blocked merge.

The review runs as a GitHub Actions job. Nothing is hosted: the job installs
[Pi](https://pi.dev) on a fresh runner, points it at the pinned guidelines, and
lets it read the diff with `read` and `bash`.

### Install it

```bash
scripts/install-review.sh --config-ref v0.7.2 joaomj/example-repo
```

The script writes `.github/workflows/ai-review.yml` on the `ai-review` branch
and opens a pull request. It pins two commits: the workflow it runs, and the
guidelines it follows. Pass `--update` to rewrite a branch it already created.

Then add the credential the job needs:

```bash
gh secret set LLM_API_KEY --repo joaomj/example-repo
```

The script never writes secrets. `LLM_API_KEY` is provider-neutral: the model
input decides which provider is called, and the key reaches Pi through
`--api-key`.

### Make a finding block the merge

```bash
gh api --method POST repos/joaomj/example-repo/rulesets --input - <<'JSON'
{"name":"ai-review","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},
 "rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ai-review / review"}]}}]}
JSON
```

Check the context name on a real pull request before adding the rule: a
required check that never reports blocks every merge.

### Limits

- Private repositories are skipped: a free plan cannot require a status check
  there, so a review would report without blocking.
- Fork pull requests are skipped: they receive no secret.
- The job fails when it cannot produce a verdict, rather than passing silently.

## Baseline policy

`scripts/apply-baseline.sh` applies, per repository:

| Item | Mechanism |
|---|---|
| Deletion and force-push protection | ruleset rules |
| Required signed commits | ruleset rule |
| Required pull request, thread resolution | ruleset rule |
| CodeQL gate at high-risk severity | ruleset rule, added once CodeQL reports |
| Admin escape hatch | ruleset bypass, mode `always` |
| Secret scanning and push protection | repository settings |
| Pull requests closed to non-collaborators | repository setting |
| Default merge commit message | repository settings |
| Pull request and issue templates | files from `templates/` |

```bash
scripts/apply-baseline.sh --dry-run joaomj/example-repo
scripts/apply-baseline.sh joaomj/example-repo
```

The CodeQL rule needs code scanning results, so the first run configures
scanning and adds the rule only where an analysis already exists. Re-run to add
it elsewhere.

## Development

Paths resolve from this directory; the scripts are plain `bash` with `gh` and
`jq`.

```bash
bash -n scripts/lib.sh scripts/install-review.sh scripts/apply-baseline.sh
```
