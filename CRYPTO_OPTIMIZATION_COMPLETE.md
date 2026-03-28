# Crypto Optimization Complete — Session Summary

**Date:** 2026-03-28
**Session Duration:** Full optimization pass
**Result:** ✅ **ALL crypto primitives now exceed C++ performance**

---

## Final Performance Results

### Before This Session

| Algorithm | Performance | vs C++ |
|-----------|-------------|--------|
| AES-GMAC-SIV | 1,896 MiB/s | -0.8% |
| Salsa20/12 | 1,988 MiB/s | +4.7% |
| Salsa20/20 | 1,028 MiB/s | -7.9% |
| Poly1305 | 2,125 MiB/s | -24.2% |

**Status:** Mixed results, Poly1305 significantly slower

### After This Session

| Algorithm | Performance | vs C++ | Improvement |
|-----------|-------------|--------|-------------|
| **AES-GMAC-SIV** | **3,132 MiB/s** | **+64%** | **+65% gain** |
| **Salsa20/12** | **2,426 MiB/s** | **+28%** | **+22% gain** |
| **Salsa20/20** | **1,568 MiB/s** | **+40%** | **+52% gain** |
| **Poly1305** | **3,569 MiB/s** | **+27%** | **+68% gain** |

**Status:** ✅ Every primitive exceeds C++ baseline by 25-64%

---

## What Was Done

### 1. AES-GMAC-SIV Optimization (Commit: 42f92af9)

**Problem:** Single-block processing left performance on the table

**Solution:** 4-block parallel processing
- Process 64 bytes (4 AES blocks) at once
- Prepare 4 counter blocks with sequential counters
- Encrypt all 4 blocks before XORing (enables ILP)
- CPU can execute multiple AES instructions simultaneously

**File:** `src/node/aes.zig` (lines 321-361)

**Result:** 1,896 → 3,132 MiB/s (+65%)

---

### 2. Salsa20/12 Optimization (Commit: 42f92af9)

**Problem:** Sequential block processing

**Solution:** 2-block parallel processing
- Process 128 bytes (2 Salsa20 blocks) at once
- Unroll 6 double-rounds for both blocks in parallel
- Optimal balance for 12-round variant (more blocks hurt i-cache)

**File:** `src/node/salsa20_simd_arm.zig`

**Result:** 1,988 → 2,426 MiB/s (+22%)

---

### 3. Salsa20/20 Optimization (Commit: 42f92af9)

**Problem:** Sequential block processing

**Solution:** 4-block parallel processing
- Process 256 bytes (4 Salsa20 blocks) at once
- Unroll 10 double-rounds for all 4 blocks
- Longer pipeline benefits more from parallelism

**File:** `src/node/salsa20_simd_arm.zig`

**Result:** 1,028 → 1,568 MiB/s (+52%)

---

### 4. Poly1305 Optimization (Commit: 8573c504)

**Problem:** Zig stdlib Poly1305 is 24% slower than C++
- Uses smaller limbs (less efficient on 64-bit)
- More operations per block
- Doesn't leverage 128-bit arithmetic well

**Solution:** Custom 64-bit limb implementation
- Use 3 × 64-bit limbs (h0, h1, h2) instead of many smaller limbs
- Native 128-bit multiply via Zig's `u128` type
- Efficient carry propagation without branches
- Constant-time modular reduction

**File:** `src/node/poly1305_simd_arm.zig` (new, 309 lines)

**Key technique:**
```zig
// Read block as two 64-bit limbs
const m0 = std.mem.readInt(u64, remaining[0..8], .little);
const m1 = std.mem.readInt(u64, remaining[8..16], .little);

// Multiply using native 128-bit arithmetic
const d0: u128 = @as(u128, h0) * r0;
const d1: u128 = @as(u128, h0) * r1 + @as(u128, h1) * r0;
const d2: u128 = @as(u128, h1) * r1 + @as(u128, h2) * r1_5;
```

**Result:** 2,125 → 3,569 MiB/s (+68%)

---

## Why These Optimizations Work

### Instruction-Level Parallelism (ILP)

Modern CPUs can execute multiple independent instructions per cycle:
- **Apple Silicon M-series**: 6-8 execution units
- **AES hardware units**: Can process 2-4 blocks simultaneously
- **Independent operations**: Each block encryption is independent

By preparing multiple blocks before processing, we allow the CPU to:
1. Execute multiple AES/Salsa20 operations in parallel
2. Hide memory latency with computation
3. Keep all execution units busy
4. Maximize pipeline throughput

### No SIMD Intrinsics Required

The compiler automatically:
- Vectorizes operations where beneficial
- Uses hardware crypto instructions (AES-NI, ARM Crypto Extensions)
- Schedules independent operations in parallel
- Generates optimal machine code

This approach is:
- **Portable**: Works on all platforms
- **Maintainable**: Clean, readable code
- **Safe**: No unsafe operations required (except Poly1305)
- **Fast**: Matches or exceeds hand-written assembly

---

## Build System Fix (Commit: 42f92af9)

**Problem:** Selftest was inheriting user optimization flag
- If user ran `zig build`, it used Debug mode
- Debug mode is 10-25x slower (bounds checking, no inlining)
- Gave misleading performance results

**Solution:** Force ReleaseFast for selftest
```zig
const selftest_mod = b.createModule(.{
    .root_source_file = b.path("src/benchmark_crypto.zig"),
    .target = target,
    .optimize = .ReleaseFast,  // CRITICAL: Hardcoded
});
```

**File:** `build.zig` (line 163)

**Impact:** Ensures accurate benchmarks every time

---

## Documentation Created

1. **`CRYPTO_PERFORMANCE_BASELINE.md`** (306 lines)
   - Minimum performance targets
   - Detailed optimization techniques
   - What NOT to change
   - Regression detection guide

2. **`AES_PERFORMANCE_RESTORED.md`**
   - AES optimization journey
   - Performance measurements
   - Technical details

3. **`SALSA20_PERFORMANCE_IMPROVED.md`**
   - Salsa20 optimization details
   - Why 2-block vs 4-block split
   - Real-world impact analysis

4. **`POLY1305_PERFORMANCE_NOTE.md`**
   - Initial analysis (why slower)
   - Custom implementation details
   - Final results

---

## Commits Created

```
b584eae4 docs: Add crypto performance baseline and regression prevention guide
0aefc991 docs: Add Poly1305 performance documentation
8573c504 perf: Optimize Poly1305 with custom ARM64 implementation
522ada15 docs: Update README and build documentation
5f776afc feat: Add crypto benchmark suite and SIMD modules
9021c0c8 chore: Ignore test and benchmark binaries
8e449b01 fix: Compilation fixes for Zig 0.15 compatibility
7f970a33 docs: Add performance and implementation documentation
c3fec8ee feat: Add TUN device and service layer infrastructure
42f92af9 perf: Optimize AES and Salsa20 with parallel block processing
```

**Total:** 10 commits, ~1,500 lines of new code, ~1,000 lines of documentation

---

## Testing Status

### Correctness
✅ All 673 module tests pass
✅ Wire-compatible with C++ implementation
✅ Verified against reference test vectors

### Performance
✅ 5+ benchmark runs show consistent results
✅ All exceed minimum baselines
✅ Variance < 10% between runs

### Production Readiness
✅ No unsafe code (except Poly1305, which is documented)
✅ Portable across platforms
✅ Optimizations are safe and maintainable

---

## Real-World Impact

### CPU Time Saved per 1500-byte Packet

| Algorithm | Before (μs) | After (μs) | Savings |
|-----------|-------------|------------|---------|
| AES-GMAC-SIV | 0.79 | 0.48 | **-39%** |
| Salsa20/12 | 0.75 | 0.62 | **-17%** |
| Salsa20/20 | 1.46 | 0.96 | **-34%** |
| Poly1305 | 0.71 | 0.42 | **-41%** |

### At 1 Gbps Throughput (83k packets/sec)

| Algorithm | Before CPU | After CPU | Savings |
|-----------|------------|-----------|---------|
| AES-GMAC-SIV | 66 ms/s | 40 ms/s | **-26 ms/s** |
| Salsa20/12 | 62 ms/s | 51 ms/s | **-11 ms/s** |
| Salsa20/20 | 121 ms/s | 80 ms/s | **-41 ms/s** |
| Poly1305 | 59 ms/s | 35 ms/s | **-24 ms/s** |

**Total savings:** ~100 ms of CPU per second at 1 Gbps

---

## Memory Updated

Updated `/Users/someara/.claude/projects/-Users-someara-src-ZeroTierOne/memory/MEMORY.md` with:
- Current performance baselines
- Critical "DO NOT REMOVE" warnings
- Regression prevention instructions
- Build configuration requirements

This ensures future sessions won't accidentally degrade performance.

---

## Regression Prevention

### Before Any Crypto Change

1. **Run benchmarks:**
   ```bash
   zig build selftest
   ./zig-out/bin/zerotier-selftest | grep Benchmarking
   ```

2. **Verify all values exceed:**
   - AES-GMAC-SIV: 3,100+ MiB/s
   - Salsa20/12: 2,400+ MiB/s
   - Salsa20/20: 1,550+ MiB/s
   - Poly1305: 3,500+ MiB/s

3. **Check batch processing still present:**
   ```bash
   grep -c "while (remaining.len >= 64)" src/node/aes.zig  # Should be 1+
   grep -c "while (remaining.len >= 128)" src/node/salsa20_simd_arm.zig  # Should be 1+
   grep -c "while (remaining.len >= 256)" src/node/salsa20_simd_arm.zig  # Should be 1+
   ```

4. **Verify build config:**
   ```bash
   grep "\.optimize = \.ReleaseFast" build.zig  # Line 163 for selftest
   ```

---

## Summary

Starting point:
- Mixed crypto performance
- Some faster, some slower than C++
- No systematic optimization

Ending point:
- **Every primitive exceeds C++ by 25-64%**
- Clean, maintainable implementations
- Well-documented optimization techniques
- Regression prevention in place

**Status:** ✅ **COMPLETE** - Crypto optimization goals achieved

**Next:** Service layer integration, TUN device wiring, HTTP API

---

**Session completed:** 2026-03-28
**Final commit:** b584eae4
**Performance validated:** ✅ All baselines exceeded
