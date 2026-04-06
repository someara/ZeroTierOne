#!/bin/bash
set -euo pipefail

MODEL="${1:-github-copilot/gpt-5-mini}"
TIMEOUT_SECS="${DOCS_EVAL_TIMEOUT_SECS:-120}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/tools/docs-eval/out"
SCHEMA_FILE="$ROOT_DIR/tools/docs-eval/schema.json"
BASE="opencode-$(echo "$MODEL" | tr '/:' '__')"
OUT_FILE="$OUT_DIR/$BASE.json"
STATUS_FILE="$OUT_DIR/$BASE.status"
ERR_FILE="$OUT_DIR/$BASE.stderr.txt"
PARTIAL_FILE="$OUT_DIR/$BASE.partial.txt"
TMP_BUNDLE="$(mktemp)"

mkdir -p "$OUT_DIR"
rm -f "$OUT_FILE" "$STATUS_FILE" "$ERR_FILE" "$PARTIAL_FILE"
trap 'rm -f "$TMP_BUNDLE"' EXIT

{
    printf '===== CLAUDE.md =====\n'
    cat "$ROOT_DIR/CLAUDE.md"
    printf '\n\n===== ZIG.md =====\n'
    cat "$ROOT_DIR/ZIG.md"
    printf '\n\n===== DEVELOPMENT.md =====\n'
    cat "$ROOT_DIR/DEVELOPMENT.md"
    printf '\n\n===== TESTING.md =====\n'
    cat "$ROOT_DIR/TESTING.md"
    printf '\n\n===== README.md =====\n'
    cat "$ROOT_DIR/README.md"
    printf '\n\n===== JSON SCHEMA =====\n'
    cat "$SCHEMA_FILE"
} > "$TMP_BUNDLE"

PROMPT=$(cat <<EOF
Read this bundled repo documentation and answer from it only.

$(cat "$TMP_BUNDLE")

Return one JSON object matching the schema above.

Rules:

- Do not infer status from file presence, type names, TODOs, or support levels.
- Separate verified, untested, blocked, and broken.
- If a fact is not documented, put it in unknowns.
- Cite the files you used.
EOF
)

set +e
perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT_SECS" \
  opencode run \
    -m "$MODEL" \
    --format json \
    "$PROMPT" > "$OUT_FILE.raw" 2> "$ERR_FILE"
cmd_status=$?
set -e

if [ -f "$OUT_FILE.raw" ]; then
    jq -rs '[ .[] | select(.type == "text") | .part.text ] | last // empty' "$OUT_FILE.raw" > "$OUT_FILE" 2>/dev/null || true
fi

if [ "$cmd_status" -eq 0 ]; then
    printf 'ok\n' > "$STATUS_FILE"
elif [ "$cmd_status" -eq 142 ] || [ "$cmd_status" -eq 124 ]; then
    printf 'timeout\n' > "$STATUS_FILE"
    cp "$OUT_FILE" "$PARTIAL_FILE" 2>/dev/null || true
else
    printf 'error\n' > "$STATUS_FILE"
    cp "$OUT_FILE" "$PARTIAL_FILE" 2>/dev/null || true
fi

echo "$OUT_FILE"
