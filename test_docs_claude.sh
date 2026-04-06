#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="sonnet"
TIMEOUT_SECS="${DOCS_EVAL_TIMEOUT_SECS:-120}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout)
            TIMEOUT_SECS="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "usage: $0 [--timeout SECONDS] [MODEL]" >&2
            exit 2
            ;;
        *)
            MODEL="$1"
            shift
            ;;
    esac
done

OUT_FILE="$(DOCS_EVAL_TIMEOUT_SECS="$TIMEOUT_SECS" "$ROOT_DIR/tools/docs-eval/claude_eval.sh" "$MODEL")"
STATUS_FILE="${OUT_FILE%.json}.status"
echo "Output: $OUT_FILE"
echo "Timeout: ${TIMEOUT_SECS}s"

if [ -f "$STATUS_FILE" ]; then
    echo "Run status: $(cat "$STATUS_FILE")"
fi

if [ "$(cat "$STATUS_FILE" 2>/dev/null || printf 'missing')" != "ok" ]; then
    echo "Skipping score: run did not finish cleanly"
    exit 1
fi

"$ROOT_DIR/tools/docs-eval/score.sh" "$OUT_FILE"
