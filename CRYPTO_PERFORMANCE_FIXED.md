# Crypto Performance Fixed! ✅

**Date:** March 28, 2026
**Status:** RESOLVED
**Performance:** Zig matches C++ baseline

---

## Problem Identified

The Zig selftest was showing **77 MiB/s** (25x slower than C++ 1864 MiB/s).

## Root Cause

**Build optimization was set to Debug mode!**

The `build.zig` file was using:
```zig
.optimize = optimize,  // Defaults to Debug unless specified
```

This meant `zig build selftest` was running in Debug mode with no optimizations.

## Solution

Changed `build.zig` line 162 to force ReleaseFast for benchmarks:

```zig
// OLD: Uses default (Debug)
.optimize = optimize,

// NEW: Always use ReleaseFast for accurate benchmarks
.optimize = .ReleaseFast,
```

## Performance Results

### Before Fix (Debug Mode)
```
[crypto] Benchmarking AES-GMAC-SIV... 77.02 MiB/second
```

### After Fix (ReleaseFast)
```
Run 1: 1836.44 MiB/second
Run 2: 1913.14 MiB/second
Run 3: 1905.28 MiB/second
Run 4: 1876.80 MiB/second
Run 5: 1913.50 MiB/second

Average: ~1889 MiB/second
```

### C++ Baseline
```
[crypto] Benchmarking AES-GMAC-SIV... 1864.14 MiB/second
```

## Comparison

| Implementation | Performance | vs C++ |
|---------------|-------------|--------|
| **C++ (baseline)** | **1864 MiB/s** | — |
| **Zig (ReleaseFast)** | **1889 MiB/s** | **+1.3%** ✅ |
| Zig (Debug, broken) | 77 MiB/s | -96% ❌ |

**Result:** Zig performance **matches and slightly exceeds** C++! 🎉

## Technical Details

### Why Debug Was So Slow

Debug mode in Zig:
- Disables all optimizations
- Adds runtime safety checks
- No inlining
- No SIMD/vectorization
- No loop unrolling

For crypto code that relies on compiler optimizations and hardware intrinsics, this causes catastrophic slowdown.

### What ReleaseFast Enables

ReleaseFast mode:
- Full LLVM optimization pipeline
- Hardware AES-NI intrinsics (x86) / Crypto Extensions (ARM)
- PCLMUL/PMULL for GHASH
- Aggressive inlining
- Loop unrolling
- SIMD vectorization

## Files Modified

**build.zig**:
- Line 162: Changed `.optimize = optimize` to `.optimize = .ReleaseFast`
- Ensures benchmarks always run with maximum performance

**src/node/aes.zig**:
- Removed fake SIMD dispatch code (lines 22-43, 344-369)
- Restored clean implementation that relies on Zig stdlib intrinsics

## Build Commands

```bash
# Build and run selftest (now automatically uses ReleaseFast)
zig build selftest

# Compare with C++ baseline
make selftest

# Manual build with optimizations
zig build-exe src/benchmark_crypto.zig -I./src -I. -O ReleaseFast
```

## Verification

```bash
# Zig crypto performance
./zig-out/bin/zerotier-selftest 2>&1 | grep "AES-GMAC-SIV"
# Expected: ~1900 MiB/second

# C++ crypto performance (baseline)
./zerotier-selftest 2>&1 | grep "AES-GMAC-SIV"
# Expected: ~1860 MiB/second
```

## Lessons Learned

1. **Always specify optimization level for benchmarks** — Don't rely on defaults
2. **Debug mode is 25x slower** — Never benchmark in Debug
3. **Crypto relies heavily on compiler optimizations** — Hardware intrinsics won't work in Debug
4. **Test build configurations** — Verify ReleaseFast is actually being used

## Status

✅ **FIXED:** Crypto performance restored
✅ **VERIFIED:** Zig matches C++ baseline
✅ **RESOLVED:** No performance regression
✅ **OPTIMIZED:** Build system now enforces ReleaseFast for benchmarks

---

**Performance restored! Zig crypto is as fast as C++! 🚀**
