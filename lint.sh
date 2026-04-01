#!/bin/bash
# Automated coding standards checks for ZeroTier Zig port.
# Checks for known anti-patterns from STYLE.md and CODING_STANDARDS.md.
#
# Usage: bash lint.sh
# Returns 0 if clean, non-zero if issues found.
#
# Suppress a false positive by adding "// ok:" comment on the line.

set -euo pipefail
cd "$(dirname "$0")"

ISSUES=0

echo "=== ZeroTier Zig lint ==="

# ── §2.1: catch-return that silently drops (non-error return) ─────
# "catch return;" or "catch return false/true/0/null" silently drops errors.
# "catch return error.X" is intentional remapping (acceptable).
# Excludes test blocks and "// ok:" overrides.
SILENT_RETURN=$(grep -rn 'catch return;$\|catch return false\|catch return true\|catch return 0\|catch return null' \
    src/ --include='*.zig' \
    | grep -v 'test "' | grep -v '// ok:' | grep -v '//' \
    | grep -v 'getByte.*catch return' | grep -v 'serializeForSign.*catch return' || true)
if [ -n "$SILENT_RETURN" ]; then
    echo ""
    echo "§2.1 catch-return silent drop (add comment or // ok:):"
    echo "$SILENT_RETURN"
    ISSUES=$((ISSUES + 1))
fi

# ── §2.1: silent catch {} ─────────────────────────────────────────
# catch {} with no comment on the same line swallows errors.
# Lines with any // comment are considered documented.
SILENT=$(grep -rn 'catch {}' src/ --include='*.zig' \
    | grep -v 'test "' | grep -v '// ok:' | grep -v '//' || true)
if [ -n "$SILENT" ]; then
    echo ""
    echo "§2.1 silent catch {} (add comment or // ok:):"
    echo "$SILENT"
    ISSUES=$((ISSUES + 1))
fi

# ── §4.7: untrusted count in multiplication ───────────────────────
# Pattern: @as(u32, count) * N where count may come from packet data.
# Info-only (not counted as failure) — verify cap exists above.
COUNTMUL=$(grep -rn '@as(u32, count) \*' src/ --include='*.zig' \
    | grep -v '// ok:' || true)
if [ -n "$COUNTMUL" ]; then
    echo ""
    echo "§4.7 [info] untrusted count in multiplication:"
    echo "$COUNTMUL"
    echo "  (verify each has a bounds check on a prior line)"
fi

# ── §5.5: bitwise & without parens ────────────────────────────────
# flags & 0xNN != 0 without outer parens — misread by C/C++ devs.
BITWISE=$(grep -rn ' & 0x[0-9a-fA-F]* [!=]= 0' src/ --include='*.zig' \
    | grep -v '(.*&' | grep -v '// ok:' || true)
if [ -n "$BITWISE" ]; then
    echo ""
    echo "§5.5 bitwise expression without parens:"
    echo "$BITWISE"
    ISSUES=$((ISSUES + 1))
fi

# ── §7.5: @intCast on .len without bounds check ──────────────────
# @intCast(expr.len) casts usize→smaller without validation.
LENCAST=$(grep -rn '@intCast(.*\.len)' src/ --include='*.zig' \
    | grep -v 'test "' | grep -v '// ok:' | grep -v '@min' \
    | grep -v 'std.math.cast' || true)
if [ -n "$LENCAST" ]; then
    echo ""
    echo "§7.5 @intCast on .len without bounds check:"
    echo "$LENCAST"
    ISSUES=$((ISSUES + 1))
fi

# ── §5.7: discarded return values ─────────────────────────────────
# _ = function_call(...) discards a meaningful return value.
# Excludes: unused parameters (_ = param_name;), test blocks, // ok:.
# Only flags lines where _ = is followed by a function call (has parens).
DISCARDED=$(grep -rn '^\s*_ = [a-zA-Z].*(' src/ --include='*.zig' \
    | grep -v 'test "' | grep -v '// ok:' | grep -v '_ = try' || true)
if [ -n "$DISCARDED" ]; then
    echo ""
    echo "§5.7 discarded return values:"
    echo "$DISCARDED"
    ISSUES=$((ISSUES + 1))
fi

# ── zig fmt ───────────────────────────────────────────────────────
if ! zig fmt --check src/node/ >/dev/null 2>&1; then
    echo ""
    echo "zig fmt: formatting drift detected. Run: zig fmt src/node/"
    ISSUES=$((ISSUES + 1))
fi

# ── zig ast-check ─────────────────────────────────────────────────
AST_FAIL=0
for f in src/node/*.zig; do
    if ! zig ast-check "$f" >/dev/null 2>&1; then
        echo "zig ast-check FAIL: $f"
        AST_FAIL=1
    fi
done
if [ "$AST_FAIL" -eq 1 ]; then
    ISSUES=$((ISSUES + 1))
fi

echo ""
if [ "$ISSUES" -eq 0 ]; then
    echo "PASS: 0 issues found"
else
    echo "FAIL: $ISSUES issue category(ies) found"
fi

exit "$ISSUES"
