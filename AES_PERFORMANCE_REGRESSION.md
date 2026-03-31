# AES-GMAC-SIV Performance Regression

**Date:** March 28, 2026
**Severity:** HIGH
**Impact:** 25x slowdown vs C++

## Summary

The Zig AES-GMAC-SIV streaming implementation is significantly slower than the C++ baseline:

- **C++ (baseline)**: 1882 MiB/s
- **Zig (current)**: 77 MiB/s
- **Regression**: **25x slower** (96% performance loss)

## Measurements

```bash
# C++ selftest (baseline)
./zerotier-selftest | grep AES
[crypto] Benchmarking AES-GMAC-SIV... 1882.35 MiB/second

# Zig selftest (current)
./zig-out/bin/zerotier-selftest | grep AES
[crypto] Benchmarking AES-GMAC-SIV... 77.02 MiB/second
```

## Root Cause Investigation

### What Changed
1. Added "SIMD optimization" files (`aes_simd_arm.zig`, `aes_simd_x86.zig`)
2. These files use **scalar loops** instead of actual SIMD intrinsics
3. Added dispatch code in `aes.zig` that calls the fake SIMD
4. Result: Added overhead without actual optimization

### Fix Attempted
Removed SIMD dispatch from `aes.zig`:
- Removed imports of `aes_simd_*` modules
- Removed `cryptBatch()` dispatch code
- Let Zig stdlib use hardware AES intrinsics directly

### Result After Fix
**Still slow:** 77 MiB/s (no improvement)

This means the problem is NOT the SIMD dispatch overhead. There must be another issue with the AES-GMAC-SIV implementation itself.

## Hypothesis

The slowdown might be due to:

1. **Inefficient streaming implementation** — Too much overhead in `update1/finish1/update2/finish2` pattern
2. **Missing compiler optimizations** — Debug code left in release build
3. **Memory allocation** — Unnecessary allocations in hot path
4. **Endianness handling** — Complex byte swapping (see lines 445-494 in aes.zig)
5. **API mismatch** — Using wrong Zig stdlib functions

## Next Steps

### Immediate (for TUN device work)
**Decision**: Accept current performance for now. The TUN device work is unrelated and shouldn't be blocked.

### Future Investigation
1. Profile the Zig code to find bottleneck
2. Compare generated assembly vs C++
3. Check if Zig stdlib AES is being used correctly
4. Consider rewriting GMAC-SIV to match C++ structure more closely
5. Test with `zig build -Doptimize=ReleaseFast -Dstrip=true`

## Impact Assessment

### Production Impact
- **Crypto operations will be 25x slower**
- May impact throughput on high-bandwidth networks
- Could cause CPU bottlenecks under load

### Development Impact
- **TUN device work NOT affected** — This is a separate crypto issue
- Core functionality still works, just slower
- All tests still pass (673/673)

## Temporary Mitigation

For now, the system will run slower but functionally correct. Priority should be:
1. ✅ **Complete TUN device integration** (unrelated, proceed)
2. ✅ **Get working VPN on Mac** (usable even if slower)
3. ⚠️ **Fix AES performance** (optimize after basic functionality works)

## Historical Context

The documentation (`SIMD_IMPLEMENTATION.md`, `SELFTEST_AES_UPDATE.md`) claimed:
- **2422 MiB/s** — This was likely never actually achieved
- **3300 MiB/s** — This was aspirational, not measured

The documents were written today (March 28, 10:20 AM) but the benchmarks don't support these numbers.

## Recommendation

**For current session:**
- ✅ Continue with TUN device integration
- ✅ Don't block on crypto performance
- ✅ File this as a known issue for future optimization

**For next session:**
- Profile and fix AES-GMAC-SIV performance
- Target: Match or exceed C++ (1882+ MiB/s)
- Estimated effort: 1-2 days of optimization work

---

**Status:** Known issue, low priority for immediate VPN functionality
**Next Action:** Complete TUN integration, revisit crypto performance later
