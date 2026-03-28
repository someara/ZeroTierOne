# ZeroTier Zig Crypto Performance Baseline

**IMPORTANT: These are the optimized baseline performance numbers. Do not introduce regressions below these values.**

**Platform:** ARM64 Apple Silicon (M-series)
**Compiler:** Zig 0.15.2, ReleaseFast
**Date:** 2026-03-28
**Commit:** 8573c504

---

## Performance Baselines (Minimum Acceptable)

All crypto primitives **exceed C++ baseline performance**. These are the **minimum** performance targets:

| Algorithm | Zig Baseline (MiB/s) | C++ Baseline (MiB/s) | Minimum Speedup |
|-----------|----------------------|----------------------|-----------------|
| **AES-GMAC-SIV** | **3,100+** | 1,911 | **+60% minimum** |
| **Salsa20/12** | **2,400+** | 1,899 | **+25% minimum** |
| **Salsa20/20** | **1,550+** | 1,116 | **+40% minimum** |
| **Poly1305** | **3,500+** | 2,803 | **+25% minimum** |

### Measured Performance (as of commit 8573c504)

```
[crypto] Benchmarking Salsa20/12... 2426 MiB/second (000ff000)
[crypto] Benchmarking Salsa20/20... 1568 MiB/second (000ff000)
[crypto] Benchmarking AES-GMAC-SIV... 3132 MiB/second
[crypto] Benchmarking Poly1305... 3569 MiB/second
```

**Status:** ✅ All exceed minimum baselines

---

## Optimization Techniques (DO NOT REMOVE)

### 1. AES-GMAC-SIV: 4-Block Parallel Processing

**File:** `src/node/aes.zig` (lines 321-361)

**Technique:**
- Process 4 AES blocks (64 bytes) at once in `Ctr.crypt()`
- Prepare 4 counter blocks with sequential values
- Encrypt all 4 blocks before XORing with input
- Enables CPU instruction-level parallelism

**Code pattern:**
```zig
while (remaining.len >= 64) {
    // Prepare 4 counter blocks
    var c0 = self.ctr_block;
    var c1 = self.ctr_block;
    var c2 = self.ctr_block;
    var c3 = self.ctr_block;
    // ... set counters ...

    // Encrypt all 4 (CPU parallelizes)
    const k0 = self.aes.encrypt(&c0);
    const k1 = self.aes.encrypt(&c1);
    const k2 = self.aes.encrypt(&c2);
    const k3 = self.aes.encrypt(&c3);

    // XOR with input
    for (0..16) |i| {
        out[i] = remaining[i] ^ k0[i];
        out[16 + i] = remaining[16 + i] ^ k1[i];
        out[32 + i] = remaining[32 + i] ^ k2[i];
        out[48 + i] = remaining[48 + i] ^ k3[i];
    }

    // Update and continue
    remaining = remaining[64..];
    self.total_len += 64;
}
```

**DO NOT:**
- Process blocks one at a time
- Remove the batch processing loop
- Change batch size below 4 blocks

---

### 2. Salsa20/12: 2-Block Parallel Processing

**File:** `src/node/salsa20_simd_arm.zig`

**Technique:**
- Process 2 Salsa20 blocks (128 bytes) at once
- Unroll 6 double-rounds for both blocks
- Optimal balance for 12-round variant

**Key insight:** More than 2 blocks causes instruction cache pressure and degrades performance for the 12-round variant.

**DO NOT:**
- Process blocks sequentially
- Use 4-block batching for Salsa20/12 (tested, slower)
- Remove unrolling

---

### 3. Salsa20/20: 4-Block Parallel Processing

**File:** `src/node/salsa20_simd_arm.zig`

**Technique:**
- Process 4 Salsa20 blocks (256 bytes) at once
- Unroll 10 double-rounds for all 4 blocks
- Longer pipeline benefits from more parallelism

**DO NOT:**
- Process blocks sequentially
- Reduce to 2-block batching (leaves performance on table)
- Remove unrolling

---

### 4. Poly1305: Custom 64-bit Limb Implementation

**File:** `src/node/poly1305_simd_arm.zig`

**Technique:**
- Use 64-bit limbs (h0, h1, h2) instead of smaller limbs
- Native 128-bit arithmetic via Zig's `u128` type
- Efficient carry propagation without branches
- Modular reduction using constant-time masking

**Key advantages:**
- Better register utilization on 64-bit ARM
- Fewer operations per block (fewer limbs)
- Native 128-bit multiply is fast on ARM64

**Code pattern:**
```zig
// Read block as two 64-bit limbs
const m0 = std.mem.readInt(u64, remaining[0..8], .little);
const m1 = std.mem.readInt(u64, remaining[8..16], .little);

// Add to accumulator with overflow tracking
const s0 = @addWithOverflow(h0, m0);
h0 = s0[0];
const c0: u64 = s0[1];

// Multiply using 128-bit arithmetic
const d0: u128 = @as(u128, h0) * r0;
const d1: u128 = @as(u128, h0) * r1 + @as(u128, h1) * r0;
// ...
```

**DO NOT:**
- Switch back to stdlib implementation for large buffers
- Use smaller limbs (32-bit, 26-bit)
- Remove the 128-bit multiply optimization
- Change the modular reduction logic

---

## Build Configuration (CRITICAL)

**File:** `build.zig` (line 163)

```zig
const selftest_mod = b.createModule(.{
    .root_source_file = b.path("src/benchmark_crypto.zig"),
    .target = target,
    .optimize = .ReleaseFast,  // CRITICAL: Must be ReleaseFast
});
```

**IMPORTANT:** The selftest **must** use `.ReleaseFast` optimization. Debug builds show 10-25x slower performance and give misleading results.

**DO NOT:**
- Use `.optimize = optimize` (inherits user flag, could be Debug)
- Use `.Debug` or `.ReleaseSafe` for benchmarks
- Remove the hardcoded `.ReleaseFast`

---

## Testing Performance

### Running Benchmarks

```bash
zig build selftest
./zig-out/bin/zerotier-selftest
```

### Expected Output Format

```
[crypto] Benchmarking AES-GMAC-SIV... XXXX.XX MiB/second
[crypto] Benchmarking Salsa20/12... XXXX.XX MiB/second (000ff000)
[crypto] Benchmarking Salsa20/20... XXXX.XX MiB/second (000ff000)
[crypto] Benchmarking Poly1305... XXXX.XX MiB/second
```

### Validating Performance

Run 5 times and check average:

```bash
for i in {1..5}; do
    ./zig-out/bin/zerotier-selftest 2>&1 | grep "Benchmarking"
done
```

**Acceptance criteria:**
- All values must exceed minimum baselines above
- Variance should be <10% between runs
- First run may be slower (cache cold) - ignore if outlier

---

## Performance Regression Detection

### If Performance Drops Below Baseline

1. **Check build configuration:**
   ```bash
   grep "optimize.*ReleaseFast" build.zig
   ```
   Verify selftest uses `.ReleaseFast`

2. **Check if batch processing was removed:**
   ```bash
   # Should find "while (remaining.len >= 64)" in AES
   grep -n "while (remaining.len >= 64)" src/node/aes.zig

   # Should find "while (remaining.len >= 128)" in Salsa20/12
   grep -n "while (remaining.len >= 128)" src/node/salsa20_simd_arm.zig

   # Should find "while (remaining.len >= 256)" in Salsa20/20
   grep -n "while (remaining.len >= 256)" src/node/salsa20_simd_arm.zig
   ```

3. **Check if Poly1305 optimization is active:**
   ```bash
   # Should dispatch to ARM optimized version
   grep -n "simd_arm.compute" src/node/poly1305.zig
   ```

4. **Verify tests still pass:**
   ```bash
   zig test src/node/aes.zig
   zig test src/node/salsa20.zig
   zig test src/node/poly1305.zig
   ```

5. **Compare with this commit:**
   ```bash
   git diff 8573c504 src/node/aes.zig
   git diff 8573c504 src/node/salsa20_simd_arm.zig
   git diff 8573c504 src/node/poly1305_simd_arm.zig
   ```

---

## Future Optimizations (Safe to Add)

These optimizations can be added **without** removing existing optimizations:

### 1. x86-64 SIMD (Not Yet Implemented)

Could add x86-64 AVX2/AVX-512 implementations for:
- AES (AVX-NI)
- Salsa20 (AVX2)
- Poly1305 (PCLMUL for parallel GHASH)

**Expected gain:** 30-50% on Intel/AMD CPUs

### 2. Larger Batch Sizes (Experimental)

Could try 8-block batching for AES on CPUs with more execution units.

**Test carefully:** May hurt cache performance.

### 3. Prefetching (Advanced)

Add memory prefetch hints for large buffers.

**Benefit:** Marginal (<5%), high complexity.

---

## Summary

**DO NOT:**
- Remove batch processing from any crypto primitive
- Change selftest to use Debug or ReleaseSafe
- Replace optimized implementations with stdlib for performance-critical paths
- Reduce batch sizes without thorough testing

**DO:**
- Run benchmarks after any crypto changes
- Verify performance exceeds baselines
- Keep batch processing patterns for new optimizations
- Document any new optimization techniques

**Current Status:** ✅ All crypto primitives exceed C++ baseline by 25-64%

---

**Last Updated:** 2026-03-28
**Commit:** 8573c504
**Validated By:** Claude Opus 4.6
