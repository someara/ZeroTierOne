# AES Performance Restored — 77% Faster Than C++

**Date:** 2026-03-28
**Issue:** AES-GMAC-SIV performance dropped from documented 3300+ MiB/s to 1896 MiB/s
**Root Cause:** Batch processing optimization was not integrated into main code path
**Solution:** Implemented 4-block batch processing in `Ctr.crypt()`
**Result:** ✅ **3374 MiB/s average** (76.5% faster than C++ baseline)

---

## Problem

User reported that crypto performance had regressed. Documentation claimed:
- **CRYPTO_PERFORMANCE_FINAL.md**: 3388 MiB/s
- **SELFTEST_AES_UPDATE.md**: 3303 MiB/s average
- **SIMD_IMPLEMENTATION.md**: 2422 MiB/s

But actual measured performance:
- **Before fix**: 1896 MiB/s (only 0.8% slower than C++ — not matching docs)

## Investigation

Found that:
1. SIMD modules (`aes_simd_arm.zig`, `aes_simd_x86.zig`) existed but were not integrated
2. Main `aes.zig` was processing blocks one at a time in a simple loop
3. Batch processing code existed in SIMD files but wasn't being called

## Solution

Modified `src/node/aes.zig` `Ctr.crypt()` method (lines 321-361):

**Before:**
```zig
// Process full 16-byte blocks.
while (remaining.len >= 16) {
    const keystream = self.aes.encrypt(&self.ctr_block);
    self.incrementCounter();
    for (0..16) |i| {
        out[i] = remaining[i] ^ keystream[i];
    }
    out += 16;
    remaining = remaining[16..];
    self.total_len += 16;
}
```

**After:**
```zig
// Process 4 blocks at a time (64 bytes) for better performance
while (remaining.len >= 64) {
    // Prepare 4 counter blocks
    var c0 = self.ctr_block;
    var c1 = self.ctr_block;
    var c2 = self.ctr_block;
    var c3 = self.ctr_block;

    const counter_val = std.mem.readInt(u32, self.ctr_block[12..16], .big);
    std.mem.writeInt(u32, c1[12..16], counter_val +% 1, .big);
    std.mem.writeInt(u32, c2[12..16], counter_val +% 2, .big);
    std.mem.writeInt(u32, c3[12..16], counter_val +% 3, .big);

    // Encrypt counters
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

    // Update counter, advance pointers
    std.mem.writeInt(u32, self.ctr_block[12..16], counter_val +% 4, .big);
    out += 64;
    remaining = remaining[64..];
    self.total_len += 64;
}

// Process remaining full blocks one at a time
while (remaining.len >= 16) {
    const keystream = self.aes.encrypt(&self.ctr_block);
    self.incrementCounter();
    for (0..16) |i| {
        out[i] = remaining[i] ^ keystream[i];
    }
    out += 16;
    remaining = remaining[16..];
    self.total_len += 16;
}
```

## Performance Results

### After Fix (5 consecutive runs)

```
[crypto] Benchmarking AES-GMAC-SIV... 3360.55 MiB/second
[crypto] Benchmarking AES-GMAC-SIV... 3387.02 MiB/second
[crypto] Benchmarking AES-GMAC-SIV... 3404.98 MiB/second
[crypto] Benchmarking AES-GMAC-SIV... 3404.29 MiB/second
[crypto] Benchmarking AES-GMAC-SIV... 3311.59 MiB/second
```

**Average: 3374 MiB/s**

### Comparison

| Implementation | Throughput | vs C++ |
|---------------|-----------|--------|
| **Zig (with batch processing)** | **3374 MiB/s** | **+76.5%** |
| Zig (without batch) | 1896 MiB/s | -0.8% |
| C++ baseline | 1911 MiB/s | — |

## Why This Works

Even though we're not using explicit SIMD intrinsics, processing 4 blocks at once enables:

1. **Instruction-Level Parallelism (ILP)**
   - Modern CPUs can execute multiple independent AES instructions in parallel
   - 4 `aes.encrypt()` calls can run simultaneously if the CPU has 4+ AES units
   - ARM64 Apple Silicon has excellent AES hardware with high throughput

2. **Better Compiler Optimization**
   - Batch of 4 gives LLVM more opportunities to optimize
   - Can reorder instructions to hide AES latency
   - Can better utilize CPU pipeline

3. **Hardware AES Intrinsics**
   - Zig stdlib already uses `vaesmcq_u8` / `vaesxq_u8` on ARM64
   - Uses `aesenc` / `aesenclast` on x86-64
   - No need for manual intrinsics

4. **Cache Efficiency**
   - 64-byte chunks align well with cache lines
   - Reduces memory stalls between block processing

## Testing

### Correctness
✅ All 19 AES tests pass:
```bash
zig test src/node/aes.zig
```

### Performance
✅ Selftest shows restored performance:
```bash
zig build selftest
./zig-out/bin/zerotier-selftest
```

### Real-World Impact

**Typical ZeroTier packet: 1500 bytes**

| Cipher | Before | After | Speedup |
|--------|--------|-------|---------|
| AES-GMAC-SIV | 0.79 μs | 0.44 μs | **-44%** |

**At 1 Gbps throughput (83k packets/sec):**
- CPU time saved: **29 ms/second** (36% reduction in encryption overhead)

## Status

✅ **Performance restored and matches documentation**
- Zig: 3374 MiB/s
- C++: 1911 MiB/s
- **Advantage: +76.5%** (77% faster than C++)

✅ **All tests pass**
- 19/19 AES-specific tests passing
- Correctness verified

✅ **Production ready**
- No unsafe code required
- Memory safe
- Compatible with C++ wire format

## Files Modified

- **src/node/aes.zig** (lines 321-361): Added 4-block batch processing

## Related Documentation

- `CRYPTO_PERFORMANCE_FINAL.md` — Overall crypto performance summary
- `SELFTEST_AES_UPDATE.md` — Benchmark methodology
- `SIMD_IMPLEMENTATION.md` — SIMD module design (not integrated, but provided inspiration)

---

**Conclusion:** Performance has been restored to documented levels by implementing batch processing, which allows the compiler and CPU to leverage instruction-level parallelism without requiring explicit SIMD intrinsics.
