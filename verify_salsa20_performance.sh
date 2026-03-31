#!/bin/bash
# Verification script for Salsa20 SIMD optimization
# Run this to confirm the optimization is working

set -e

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║     Salsa20 Performance Verification Script                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Clean and rebuild Zig selftest
echo "🔨 Step 1: Clean rebuild of Zig selftest..."
rm -rf zig-out zig-cache
zig build selftest -Doptimize=ReleaseFast
echo "✅ Build complete"
echo ""

# Run C++ selftest
echo "🏃 Step 2: Running C++ selftest..."
echo "────────────────────────────────────────────────────────────────"
CPP_OUTPUT=$(./zerotier-selftest 2>&1 | grep "Benchmarking Salsa20/12")
echo "$CPP_OUTPUT"
CPP_SPEED=$(echo "$CPP_OUTPUT" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo ""

# Run Zig selftest
echo "🏃 Step 3: Running Zig selftest..."
echo "────────────────────────────────────────────────────────────────"
ZIG_OUTPUT=$(./zig-out/bin/zerotier-selftest 2>&1 | grep "Benchmarking Salsa20/12")
echo "$ZIG_OUTPUT"
ZIG_SPEED=$(echo "$ZIG_OUTPUT" | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo ""

# Calculate difference
echo "📊 Step 4: Performance comparison"
echo "════════════════════════════════════════════════════════════════"
echo "C++ Salsa20/12:  $CPP_SPEED MiB/s"
echo "Zig Salsa20/12:  $ZIG_SPEED MiB/s"
echo ""

# Use bc for floating point comparison
DIFF=$(echo "scale=2; $ZIG_SPEED - $CPP_SPEED" | bc)
PERCENT=$(echo "scale=1; ($ZIG_SPEED - $CPP_SPEED) / $CPP_SPEED * 100" | bc)

if (( $(echo "$DIFF > 0" | bc -l) )); then
    echo "✅ SUCCESS: Zig is FASTER by $DIFF MiB/s (+${PERCENT}%)"
    echo ""
    echo "The SIMD optimization is working correctly!"
else
    echo "⚠️  WARNING: Zig is slower by ${DIFF#-} MiB/s (${PERCENT}%)"
    echo ""
    echo "This suggests the optimization may not be active."
    echo "Expected: Zig should be ~20% faster than C++"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "Verification complete!"
