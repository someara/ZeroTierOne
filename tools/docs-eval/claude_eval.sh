#!/bin/bash
set -euo pipefail

MODEL="${1:-sonnet}"
TIMEOUT_SECS="${DOCS_EVAL_TIMEOUT_SECS:-120}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/tools/docs-eval/out"
PROMPT_FILE="$ROOT_DIR/tools/docs-eval/prompt.txt"
SCHEMA_FILE="$ROOT_DIR/tools/docs-eval/schema.json"
BASE="claude-$(echo "$MODEL" | tr '/:' '__')"
OUT_FILE="$OUT_DIR/$BASE.json"
STATUS_FILE="$OUT_DIR/$BASE.status"
ERR_FILE="$OUT_DIR/$BASE.stderr.txt"
PARTIAL_FILE="$OUT_DIR/$BASE.partial.txt"

mkdir -p "$OUT_DIR"
rm -f "$OUT_FILE" "$STATUS_FILE" "$ERR_FILE" "$PARTIAL_FILE"

PROMPT="$(cat "$PROMPT_FILE")"

set +e
perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT_SECS" \
  claude -p \
    --model "$MODEL" \
    --permission-mode plan \
    --output-format json \
    --json-schema "$(cat "$SCHEMA_FILE")" \
    --append-system-prompt "Before answering, read CLAUDE.md, then the docs it routes you to. Treat ZIG.md as roadmap, DEVELOPMENT.md and TESTING.md as command docs, and build.zig as final command truth. Do not infer implementation status from file presence, type names, TODO counts, or support levels. Support levels are not completion percentages. Do not run builds or tests." \
    "$PROMPT" > "$OUT_FILE" 2> "$ERR_FILE"
cmd_status=$?
set -e

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
