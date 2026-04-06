#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <output-file>" >&2
    exit 2
fi

OUT_FILE="$1"

require_jq() {
    local expr="$1"
    local label="$2"
    if jq -e "$expr" "$OUT_FILE" >/dev/null 2>&1; then
        echo "PASS: $label"
    else
        echo "FAIL: missing $label"
        return 1
    fi
}

forbid_jq() {
    local expr="$1"
    local label="$2"
    if jq -e "$expr" "$OUT_FILE" >/dev/null 2>&1; then
        echo "FAIL: forbidden $label"
        return 1
    else
        echo "PASS: no $label"
    fi
}

status=0

if ! jq -e . "$OUT_FILE" >/dev/null 2>&1; then
    echo "FAIL: output is not valid JSON"
    exit 1
fi

require_jq '.goals | type == "array" and length > 0' 'goals array' || status=1
require_jq '.verified | type == "array"' 'verified array' || status=1
require_jq '.untested | type == "array"' 'untested array' || status=1
require_jq '.blocked | type == "array"' 'blocked array' || status=1
require_jq '.broken | type == "array"' 'broken array' || status=1
require_jq '.next | type == "array" and length > 0' 'next array' || status=1
require_jq '.unknowns | type == "array"' 'unknowns array' || status=1
require_jq '.roadmap_file == "ZIG.md"' 'roadmap file' || status=1
require_jq '.command_truth_file == "build.zig"' 'command truth file' || status=1
require_jq '.service_binary == "zerotea"' 'service binary' || status=1
require_jq '.service_readme_parity | test("(?i)no|cannot|not.*infer|does not")' 'service README caveat' || status=1
require_jq '.support_levels_completion | test("(?i)no|not|priority|confidence")' 'support-level caveat' || status=1
require_jq '.docs_used | type == "array" and (index("ZIG.md") != null)' 'docs used include ZIG.md' || status=1
require_jq '.docs_used | type == "array" and ((index("CLAUDE.md") != null) or (index("DEVELOPMENT.md") != null) or (index("TESTING.md") != null))' 'docs used include routing docs' || status=1
require_jq '([.goals[], .verified[], .untested[], .blocked[], .broken[], .next[], .unknowns[], .service_readme_parity, .support_levels_completion] | join("\n")) | test("ZeroTea")' 'project name mention' || status=1

forbid_jq '.service_binary == "zerotier-one"' 'wrong daemon name' || status=1
forbid_jq '([.goals[], .verified[], .untested[], .blocked[], .broken[], .next[], .unknowns[]] | join("\n")) | test("(?i)production ready|functionally complete|100% complete")' 'unsupported completion claim' || status=1
forbid_jq '([.goals[], .verified[], .untested[], .blocked[], .broken[], .next[], .unknowns[]] | join("\n")) | test("[0-9]+%")' 'percentage closeness claim' || status=1

exit "$status"
