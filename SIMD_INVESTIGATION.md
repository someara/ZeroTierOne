# SIMD Vectorization Investigation for Zig AES

**Date**: 2026-03-28
**Status**: Investigation Complete - No Performance Gain

## Context

The Zig AES-GMAC-SIV implementation reports **866 MiB/s** vs C++ **1911 MiB/s** (2.2x faster).

Both implementations use hardware AES acceleration (AES-NI on x86-64, ARM Crypto Extensions on ARM64).

The C++ version achieves higher throughput through ~2,400 lines of hand-coded platform-specific SIMD intrinsics (VAES-512, PCLMUL, NEON).

## Investigation: Zig Stdlib Portable SIMD

### What Zig Provides

Zig's standard library offers portable SIMD abstractions that eliminate platform-specific code:

1. **`std.crypto.core.modes.ctr()`** - Vectorized CTR mode
   - Automatically uses `xorWide()` with `optimal_parallel_blocks` (CPU-specific: 3-8 blocks)
   - Single implementation works on x86-64 (AVX-512/VAES) and ARM64 (NEON)

2. **`AesEncryptCtx.xorWide(count, dst, src, counters)`** - Parallel block encryption
   - Processes multiple blocks with SIMD instructions
   - Located in `std/crypto/aes/aesni.zig` and `std/crypto/aes/armcrypto.zig`

### Attempted Approach

Modified `Ctr.crypt()` to batch-process blocks using `xorWide()`:

```zig
// Process parallel_blocks at a time (3-8 depending on CPU)
const batch_size = parallel_blocks * 16;
while (remaining.len >= batch_size) {
    // Prepare counter blocks
    for (0..parallel_blocks) |i| {
        @memcpy(ctr_blocks[i*16..], &self.ctr_block);
        self.incrementCounter();
    }

    // SIMD encryption
    self.aes.enc_ctx.xorWide(parallel_blocks, dst, src, ctr_blocks);
    // ...
}
```

### Results

| Implementation | Performance | Change |
|----------------|-------------|--------|
| **Original (single-block)** | 866 MiB/s | Baseline |
| **Manual xorWide with buffer copy** | 831 MiB/s | **-4% (slower!)** |
| **Simplified (reverted)** | 823 MiB/s | -5% |

**Conclusion**: Manual vectorization attempts made performance **worse** due to buffer copy overhead.

## Root Cause Analysis

### Why Vectorization Failed

1. **Pointer Type Mismatch**
   - `xorWide()` expects: `*[N]u8` (array pointer, fixed size)
   - Our streaming API uses: `[*]u8` (many-item pointer, unknown size at compile-time)

2. **Required Workaround**
   ```zig
   var temp: [128]u8 = undefined;  // Intermediate buffer
   xorWide(..., &temp, ...);
   @memcpy(out, &temp);            // Extra copy kills performance
   ```

3. **Streaming State Complexity**
   - Must handle partial blocks from previous calls
   - Counter must be synchronized across calls
   - Cannot easily delegate to stdlib's `modes.ctr()` (it's non-streaming)

### Why C++ is Faster

The C++ implementation achieves 2x performance through:

1. **Zero-Copy SIMD**: Direct pointer casts to SIMD types (`__m512i*`)
2. **Larger Batches**: Processes 4-8 blocks per loop using VAES-512
3. **Optimized GHASH**: PCLMUL-based polynomial multiplication in parallel
4. **Non-Streaming Design**: Processes full messages in one shot (no partial block handling)

Zig's type safety prevents unsafe pointer casts, adding overhead when converting between pointer types.

## Performance Breakdown (Speculation)

The 2x gap likely comes from:
- **30-40%**: SIMD vectorization of AES-CTR (C++ processes 4-8 blocks, Zig processes 1)
- **20-30%**: SIMD vectorization of GHASH/GMAC
- **20-30%**: Two-pass overhead (GMAC-SIV requires encrypt + MAC passes)
- **10-20%**: Streaming state management overhead

## Recommendations

### Option 1: Accept Current Performance ✅ RECOMMENDED

**Rationale**:
- 866 MiB/s is **excellent** for a network protocol (ZeroTier packets are <2KB)
- Network I/O is the bottleneck, not crypto
- Code is maintainable and auditable (vs C++'s 2,400 lines of intrinsics)
- Hardware acceleration is enabled and working

**Example**: A 1 Gbps link = 125 MB/s. AES at 866 MiB/s = 908 MB/s can easily saturate it.

### Option 2: Rewrite as Non-Streaming

Convert `Ctr` to process entire messages at once:

```zig
pub fn cryptAll(aes: Aes, dst: []u8, src: []const u8, iv: [16]u8) void {
    modes.ctr(Aes256EncryptCtx, aes.enc_ctx, dst, src, iv, .big);
}
```

**Pros**: Direct use of vectorized stdlib CTR
**Cons**: Breaks streaming API, requires full-message buffering

### Option 3: Use Inline Assembly (Not Recommended)

Write platform-specific inline asm like C++:

```zig
asm volatile (
    "vaesenc %[key], %[block], %[out]"
    : [out] "=v" (output)
    : [block] "v" (input), [key] "v" (round_key)
);
```

**Pros**: Maximum performance
**Cons**:
- Requires x86-64 and ARM64 versions (2x maintenance)
- Non-portable
- Loses Zig's safety guarantees

## Conclusion

**No changes recommended**. The current implementation is:
- ✅ Simple and maintainable (365 lines vs C++'s 2,400)
- ✅ Portable (single codebase for all platforms)
- ✅ Hardware-accelerated (AES-NI/ARM Crypto enabled)
- ✅ Fast enough (866 MiB/s exceeds network requirements)

The 2x performance gap vs C++ is expected given Zig's type safety and streaming API constraints. Attempting manual vectorization without unsafe pointer casts or non-streaming rewrites provides no benefit.

## Technical Details

### Zig stdlib CTR Implementation

`std/crypto/modes.zig`:
```zig
pub fn ctr(...) void {
    const parallel_count = BlockCipher.block.parallel.optimal_parallel_blocks;
    const wide_block_length = parallel_count * 16;

    if (src.len >= wide_block_length) {
        while (i + wide_block_length <= src.len) {
            // Prepare parallel_count counters
            // ...
            block_cipher.xorWide(parallel_count, dst[...], src[...], counters);
        }
    }
    // Fallback to single-block for remainder
}
```

### AES-NI xorWide Implementation

`std/crypto/aes/aesni.zig`:
```zig
pub fn xorWide(ctx: Self, comptime count: usize,
               dst: *[16 * count]u8, src: *const [16 * count]u8,
               counters: [16 * count]u8) void {
    var ts: [count]Block = undefined;

    // Prepare blocks
    for (0..count) |j| {
        ts[j] = Block.fromBytes(counters[j*16..][0..16])
                     .xorBlocks(round_keys[0]);
    }

    // Encrypt rounds (vectorized)
    for (1..rounds) |round| {
        for (0..count) |j| {
            ts[j] = ts[j].aesenc(round_keys[round]);
        }
    }

    // XOR with plaintext
    for (0..count) |j| {
        dst[16*j..][0..16].* = ts[j].xorBytes(src[16*j..][0..16]);
    }
}
```

The `aesenc()` method compiles to `vaesenc` instruction (VAES) on supporting CPUs.

### Benchmark Methodology

Measured in `src/benchmark_crypto.zig`:

```zig
// 100 iterations of 64KB encryption
for (0..100) {
    enc.initEnc(packet_id, &ciphertext);
    enc.update1(&plaintext);
    enc.finish1();
    enc.update2(&plaintext);
    tag = enc.finish2();
}
// Throughput = (100 * 64KB) / elapsed_ms * 1000
```

## References

- Zig stdlib: `/opt/homebrew/Cellar/zig/0.15.2/lib/zig/std/crypto/`
- AES-NI: `aes/aesni.zig`
- ARM Crypto: `aes/armcrypto.zig`
- CTR mode: `modes.zig`
- ZeroTier AES: `src/node/aes.zig`
- C++ comparison: `node/AES_aesni.cpp` (2,382 lines)
