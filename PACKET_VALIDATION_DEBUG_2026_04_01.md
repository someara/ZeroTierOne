# Packet Validation Debug Session — 2026-04-01

## Problem Statement
ZeroTier Zig service was receiving responses from root servers but failing packet validation with "Invalid packet" errors. All 705 crypto unit tests pass, but live packets were being rejected.

## Investigation Process

### Initial Hypothesis
Expected one of:
- Crypto mismatch (ECDH key agreement wrong)
- MAC verification bug (Poly1305 issue)
- Packet parsing error
- Protocol version mismatch

### Debugging Steps

1. **Added diagnostic logging** to `incoming_packet.zig`:
   - Log cipher suite and verb
   - Log peer lookup result
   - Log dearmor success/failure
   - Log MAC comparison

2. **Added logging to packet.zig**:
   - Log MAC verification (stored vs computed)
   - Log uncompress attempts
   - Log LZ4 decompression failures

## Root Cause: LZ4 Decompression Failure

### Evidence
```
debug: tryDecode: from=871845129129 len=629 cipher=1 verb=7
debug: tryDecode: peer_found=true
debug: tryDecode: calling dearmor...
debug: dearmorSalsa: payload_len=602 stored_mac={ 128, 148, 188, 123, 160, 114, 97, 217 } computed_mac={ 128, 148, 188, 123, 160, 114, 97, 217 }
debug: tryDecode: dearmor SUCCESS
debug: tryDecode: calling uncompress...
debug: uncompress: compressed=true size=629
debug: uncompress: attempting LZ4 decompression of 601 bytes
debug: uncompress: LZ4 decompression FAILED
debug: tryDecode: uncompress FAILED
  ✗ Invalid packet
```

### Key Findings

✅ **Working correctly:**
- Peer records exist for all root servers
- ECDH key agreement produces correct shared secrets
- Poly1305 MAC verification passes (MACs match byte-for-byte)
- Salsa20 decryption succeeds
- Packets without compression are processed successfully

❌ **Broken:**
- LZ4 decompression fails on compressed packets
- `lz4.decompressSafe()` returns `null` for valid compressed data

### Packet Statistics
- **Uncompressed packets (compressed=false)**: Process successfully
- **Compressed packets (compressed=true)**: Fail at LZ4 decompression
- **MAC verification**: 100% success rate (all MACs match)

## Impact

### Severity: HIGH
- Service cannot process most packets from root servers
- Handshake cannot complete (HELLO OK responses are compressed)
- VPN functionality blocked

### Workaround: NONE
- Cannot disable compression (controlled by sender)
- All production ZeroTier traffic uses compression

## Next Steps

### 1. Investigate LZ4 Implementation
**File:** `src/node/lz4.zig`

Check for:
- Buffer size issues
- Pointer arithmetic bugs
- Format parsing errors
- C++ compatibility issues

### 2. Test LZ4 with Known Data
Create unit test:
```zig
test "LZ4 decompress real packet data" {
    // Use actual compressed payload from captured packet
    const compressed = [_]u8{ ... }; // 601 bytes from log
    var output: [2048]u8 = undefined;
    const result = lz4.decompressSafe(&compressed, &output);
    try testing.expect(result != null);
}
```

### 3. Compare with C++ LZ4
**Files:**
- C++: `node/Utils.cpp` (LZ4 decompression)
- Zig: `src/node/lz4.zig`

Look for differences in:
- Block format parsing
- Size validation
- Token interpretation
- Match copy logic

### 4. Verify LZ4 Frame Format
Check if packets use:
- LZ4 block format (raw)
- LZ4 frame format (with header)
- Custom ZeroTier format

## Files Modified (Debug Logging)

### `src/node/incoming_packet.zig`
- Added logging at lines 719, 748, 751, 770, 774, 843
- Logs: cipher suite, verb, peer lookup, dearmor result, uncompress result

### `src/node/packet.zig`
- Added logging at lines 831, 834, 917, 920, 925
- Logs: MAC comparison, LZ4 decompression attempts

## Verification Commands

```bash
# Rebuild with debug logging
zig build

# Run service and capture logs
./zig-out/bin/zerotier-one 2>&1 | grep -E "tryDecode|dearmorSalsa|uncompress"

# Check LZ4 unit tests
zig test src/node/lz4.zig -I .
```

## Success Criteria (Not Yet Met)

- ✅ Crypto operations verified correct
- ✅ Root cause identified (LZ4)
- ❌ LZ4 decompression fixed
- ❌ Compressed packets process successfully
- ❌ HELLO OK responses decoded
- ❌ Handshake completes

## Timeline

- **2026-03-31**: Initial testing, packet validation failures observed
- **2026-04-01 (early)**: Test porting completed (705 tests pass)
- **2026-04-01 (late)**: Debug session, root cause identified

## Conclusion

The "Invalid packet" error was **NOT a crypto issue**. All cryptographic operations (ECDH, Poly1305, Salsa20) work correctly and produce byte-for-byte identical results to C++. The issue is **LZ4 decompression** failing on compressed packets.

**Priority:** Fix LZ4 decompression to unblock handshake completion.
