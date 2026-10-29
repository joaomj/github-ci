#!/usr/bin/env bash
# Run the review model once and write its report.
#
#   PROMPT=prompt.md OUT=review.md MODEL=... THINKING=... \
#     LLM_API_KEY=... scripts/review.sh
#
# Exits non-zero when the model cannot be reached or writes nothing, so a broken
# run never looks like an approving review. The verdict is not enforced here:
# callers post the report first, then fail on it.

set -euo pipefail

: "${PROMPT:?PROMPT must name the prompt file}"
: "${OUT:?OUT must name the report file}"
: "${MODEL:?MODEL must name a model}"
: "${THINKING:?THINKING must name a thinking level}"

if [ -z "${LLM_API_KEY:-}" ]; then
  printf '::error::LLM_API_KEY is empty. Set the repository secret.\n' >&2
  exit 1
fi

err=$(mktemp)
trap 'rm -f "$err"' EXIT

if ! pi --print --no-session --no-approve --tools read,bash \
    --model "$MODEL" --api-key "$LLM_API_KEY" --thinking "$THINKING" \
    "$(cat "$PROMPT")" > "$OUT" 2> "$err"; then
  printf '::error::Pi exited with a failure status.\n' >&2
  tail -20 "$err" >&2
  exit 1
fi

if [ ! -s "$OUT" ]; then
  printf '::error::Pi wrote an empty review.\n' >&2
  tail -20 "$err" >&2
  exit 1
fi

cat "$OUT"
