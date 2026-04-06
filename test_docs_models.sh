#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/tools/docs-eval/out"

CLAUDE_MODELS=()
OPENCODE_MODELS=()
TIMEOUT_SECS="${DOCS_EVAL_TIMEOUT_SECS:-120}"
SUMMARY_BASENAME="matrix-$(date +%Y%m%d-%H%M%S)"
SUMMARY_TSV=""
SUMMARY_TXT=""

record_result() {
    local runner="$1"
    local model="$2"
    local exit_code="$3"
    local out_file="$4"
    local status_file="${out_file%.json}.status"
    local run_status="missing"
    if [ -f "$status_file" ]; then
        run_status="$(cat "$status_file")"
    fi
    local score_status="fail"
    if [ "$exit_code" -eq 0 ]; then
        score_status="pass"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$runner" "$model" "$run_status" "$score_status" "$out_file" >> "$SUMMARY_TSV"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --claude)
            CLAUDE_MODELS+=("$2")
            shift 2
            ;;
        --opencode)
            OPENCODE_MODELS+=("$2")
            shift 2
            ;;
        --timeout)
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        *)
            echo "usage: $0 [--timeout SECONDS] [--claude MODEL]... [--opencode MODEL]..." >&2
            exit 2
            ;;
    esac
done

if [ "${#CLAUDE_MODELS[@]}" -eq 0 ] && [ "${#OPENCODE_MODELS[@]}" -eq 0 ]; then
    CLAUDE_MODELS=(sonnet haiku)
    OPENCODE_MODELS=(github-copilot/gpt-5-mini)
fi

mkdir -p "$OUT_DIR"
SUMMARY_TSV="$OUT_DIR/$SUMMARY_BASENAME.tsv"
SUMMARY_TXT="$OUT_DIR/$SUMMARY_BASENAME.txt"
printf 'runner\tmodel\trun_status\tscore_status\toutput_file\n' > "$SUMMARY_TSV"

status=0

for model in "${CLAUDE_MODELS[@]}"; do
    echo "== Claude: $model =="
    set +e
    "$ROOT_DIR/test_docs_claude.sh" --timeout "$TIMEOUT_SECS" "$model"
    cmd_status=$?
    set -e
    out_file="$OUT_DIR/claude-$(echo "$model" | tr '/:' '__').json"
    record_result "claude" "$model" "$cmd_status" "$out_file"
    if [ "$cmd_status" -ne 0 ]; then
        status=1
    fi
    echo ""
done

for model in "${OPENCODE_MODELS[@]}"; do
    echo "== OpenCode: $model =="
    set +e
    "$ROOT_DIR/test_docs_opencode.sh" --timeout "$TIMEOUT_SECS" "$model"
    cmd_status=$?
    set -e
    out_file="$OUT_DIR/opencode-$(echo "$model" | tr '/:' '__').json"
    record_result "opencode" "$model" "$cmd_status" "$out_file"
    if [ "$cmd_status" -ne 0 ]; then
        status=1
    fi
    echo ""
done

{
    echo "Docs eval summary"
    echo "Timeout: ${TIMEOUT_SECS}s"
    echo "TSV: $SUMMARY_TSV"
    echo ""
    column -t -s $'\t' "$SUMMARY_TSV"
} | tee "$SUMMARY_TXT"

exit "$status"
