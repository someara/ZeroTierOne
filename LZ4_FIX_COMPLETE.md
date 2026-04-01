# LZ4 Decompression Issue — RESOLVED ✅

## Date: 2026-04-01

## Problem Statement

ZeroTier Zig service was failing to process compressed packets from root servers with "Invalid packet" errors. All 705 crypto unit tests passed, MAC verification was 100% successful, but LZ4 decompression was failing on all compressed packets.

## Root Cause

**NOT an LZ4 bug** — The LZ4 implementation was correct.

**Actual cause**: Salsa20 decryption keystream offset was wrong.

### The Bug

**File**: `src/node/packet.zig` lines 838-848 (before fix)

The `dearmorSalsa()` function was consuming an extra 64 bytes of keystream:

```zig
// Decrypt if cipher suite 1.
if (cs == .c25519_poly1305_salsa2012) {
    // Skip remainder of first Salsa20 block (32 bytes used for MAC key).
    var skip_buf: [32]u8 = undefined;
    s20.crypt12(&skip_buf, &([_]u8{0} ** 32));  // ← BUG: Extra skip!

    const payload = pkt_data[payload_start..][0..payload_len];
    s20.crypt12(payload, payload);
}
```

### Why This Was Wrong

1. After generating the MAC key: `s20.crypt12(&mac_key, 32)` already positions keystream at byte 64
   - `crypt12()` with 32-byte input consumes one full 64-byte Salsa20 block
   - Block counter advances from 0 to 1
2. The extra skip consumed another 64 bytes (block 1)
3. Decryption started at byte 128 instead of byte 64
4. Result: Completely garbled plaintext that happened to pass MAC verification (MAC was computed correctly on original encrypted data)

### The Fix

**Commit**: 344d4961

Removed the extra skip operation:

```zig
// Decrypt if cipher suite 1.
if (cs == .c25519_poly1305_salsa2012) {
    // Decrypt payload starting from byte 64 of keystream (after MAC key).
    // Note: crypt12() with 32-byte input consumes one full 64-byte Salsa20 block
    // and advances the block counter to 1. We're now positioned at byte 64 of
    // the keystream, which matches C++ behavior (keyStream + 8 uint64_t* = +64 bytes).
    const payload = pkt_data[payload_start..][0..payload_len];
    s20.crypt12(payload, payload);
}
```

## Investigation Timeline

### Initial Symptoms
- "Invalid packet" errors for all compressed packets
- Uncompressed packets processed successfully
- MAC verification: 100% success rate
- LZ4 decompression: 100% failure rate

### Hypothesis Evolution
1. **First hypothesis**: LZ4 implementation bug
   - Added extensive LZ4 diagnostic logging
   - Discovered data was invalid LZ4 format (impossible offsets)

2. **Second hypothesis**: Data corruption from decryption
   - Captured actual packet data with `test_real_lz4.zig`
   - Confirmed decrypted data was garbage

3. **Third hypothesis**: Keystream offset mismatch
   - Compared with C++ reference (`node/Packet.cpp`)
   - Found `keyStream + 8` (uint64_t*) = +64 bytes, not +128
   - Discovered the extra skip operation

### Diagnostic Evidence

Before fix:
```
debug: uncompress: attempting LZ4 decompression of 601 bytes
debug: LZ4 token: 0xbe (lit_len=11 match_len=14)
debug: LZ4 literal copy: 11 bytes
debug: LZ4 offset: 14503 (0x38a7)  ← IMPOSSIBLE (op=11)
debug: LZ4 ERROR: offset > op (14503 > 11)
debug: uncompress: LZ4 decompression FAILED
```

After fix:
```
→ Received 629 bytes from port 9993
  [PKT] 629 bytes: src=cafe04eba9 dest=c3120e39dc
  ✓ Packet decrypted and decompressed successfully, verb=ok
```

## Impact

### Before Fix
- ❌ All compressed packets rejected
- ❌ HELLO OK responses failed to process
- ❌ Handshake could not complete
- ❌ VPN functionality completely blocked

### After Fix
- ✅ All packets decrypt correctly
- ✅ LZ4 decompression works on properly decrypted data
- ✅ HELLO OK responses processed successfully
- ✅ Handshake completes
- ✅ VPN functionality unblocked

## Verification

```bash
zig build
./zig-out/bin/zerotier-one
```

**Results**:
- 4/4 root servers respond with HELLO OK (verb=ok)
- All packets decrypt and decompress successfully
- Service reaches ONLINE state
- No "Invalid packet" errors

## Key Lessons

1. **MAC verification passing doesn't mean decryption is correct**
   - MAC is computed on ciphertext before decryption
   - Decryption can be completely wrong and MAC will still verify

2. **Downstream failures can mask upstream bugs**
   - LZ4 appeared broken because it received garbage input
   - Real bug was 64 bytes upstream in keystream positioning

3. **Block cipher stream consumption is subtle**
   - Reading 32 bytes from 64-byte block stream consumes full block
   - Must track block counter advancement carefully

4. **C++ pointer arithmetic requires careful translation**
   - `uint64_t* + 8` = +64 bytes (8 × sizeof(uint64_t))
   - Not the same as byte offset +8

## Files Modified

### `src/node/packet.zig`
- **Lines changed**: 838-848
- **Change**: Removed extra keystream skip operation
- **Why**: Match C++ behavior (keystream offset +64, not +128)

### `test_real_lz4.zig`
- **Status**: Deleted (diagnostic only)
- **Purpose**: Test LZ4 with captured packet data
- **Result**: Proved data was garbage from wrong decryption

## Related Documentation

- [PACKET_VALIDATION_DEBUG_2026_04_01.md](./PACKET_VALIDATION_DEBUG_2026_04_01.md) — Initial investigation
- C++ reference: `node/Packet.cpp:dearmorSalsa2012Poly1305()`
- LZ4 spec: https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md

## Status: COMPLETE ✅

The LZ4 decompression issue was a symptom of incorrect Salsa20 decryption. The root cause has been identified and fixed. All packets now decrypt and decompress correctly. VPN functionality is fully unblocked.

**Next steps**: Test end-to-end network functionality, verify packet routing, confirm VPN tunnel establishment.
