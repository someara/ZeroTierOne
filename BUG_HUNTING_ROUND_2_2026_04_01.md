# Bug Hunting Round 2 — 2026-04-01

Following STYLE.md §9.1 workflow: Find up to 3 issues, fix them, test, commit, repeat.

## Issues Found

### Issue 1: Integer underflow in payload length calculation (MEDIUM severity)

**File**: `src/node/incoming_packet.zig` line 1868
**Type**: Unprotected integer subtraction on untrusted data
**Severity**: MEDIUM (violates STYLE.md §4.3 - no silent truncation)

**Problem**: Payload length calculated by subtracting offset from packet size without bounds check.

```zig
fn doOK_NETWORK_CONFIG_REQUEST(self: *Self, cb: *const Callbacks, _: ?*anyopaque) u64 {
    const nwid = self.pkt.buf.at(u64, packet.ok_idx.idx_ok_payload) catch return 0;
    const nw = cb.nodeGetNetwork(cb.ctx, nwid) orelse return nwid;

    const payload_len = self.pkt.buf.size() - packet.ok_idx.idx_ok_payload;  // ← UNSAFE
    const payload = self.pkt.buf.field(packet.ok_idx.idx_ok_payload, payload_len) catch return nwid;
```

**Root Cause**: `idx_ok_payload = 37`. If `buf.size() < 37`, the u32 subtraction wraps:
- `buf.size() = 30`
- `payload_len = 30 - 37 = 0xFFFFFFE9` (4,294,967,273)
- `buf.field(37, 4294967273)` attempts to read billions of bytes

**Impact**: Malformed OK packet with `size < 37` causes integer wraparound, leading to:
1. Out-of-bounds read attempt in `buf.field()`
2. The `catch` at line 1869 silently swallows the error and returns early
3. No crash, but incorrect behavior (packet ignored when it should be rejected with error)

**STYLE.md §4.3 violation**: "If data does not fit in a buffer, return an error. Never silently clip, wrap, or discard."

**Fix**: Add bounds check before subtraction:
```zig
fn doOK_NETWORK_CONFIG_REQUEST(self: *Self, cb: *const Callbacks, _: ?*anyopaque) u64 {
    const nwid = self.pkt.buf.at(u64, packet.ok_idx.idx_ok_payload) catch return 0;
    const nw = cb.nodeGetNetwork(cb.ctx, nwid) orelse return nwid;

    // Validate packet is large enough to have payload
    if (self.pkt.buf.size() < packet.ok_idx.idx_ok_payload) return nwid;

    const payload_len = self.pkt.buf.size() - packet.ok_idx.idx_ok_payload;
    const payload = self.pkt.buf.field(packet.ok_idx.idx_ok_payload, payload_len) catch return nwid;
    // ... rest of function
}
```

---

### Issue 2: Missing documentation for assert in critical path (LOW severity)

**File**: `src/node/packet.zig` line 573
**Type**: Debug-only assertion without release-mode validation
**Severity**: LOW (code correctness, not a runtime bug given current constraints)

**Problem**: Added assertion for packet size constraint in previous bug hunt round, but it only runs in debug builds.

```zig
// Note: ZeroTier protocol limits packets to 16-bit size (max 65535 bytes).
// Current max_packet_length (10024) is well under this limit.
const sz = self.buf.size();
std.debug.assert(sz <= 0xFFFF); // Protocol constraint  // ← Debug-only
out[19] = in_key[19] ^ @as(u8, @truncate(sz & 0xff));
out[20] = in_key[20] ^ @as(u8, @truncate((sz >> 8) & 0xff));
```

**Root Cause**: `std.debug.assert()` compiles to a no-op in ReleaseFast/ReleaseSafe builds. If `max_packet_length` were ever increased beyond 65535 (e.g., to support jumbo frames), the assertion wouldn't catch it in production.

**Impact**: Currently safe because `max_packet_length = 10024 < 65535`. But if future changes increase packet size limits, the silent truncation would occur without warning in release builds.

**Fix**: Either:
1. Use runtime validation: `if (sz > 0xFFFF) return error.PacketTooLarge;`
2. Or use compile-time assertion if max_packet_length is comptime-known:
   `comptime std.debug.assert(max_packet_length <= 0xFFFF);`

**Recommended fix** (compile-time validation):
```zig
// Verify protocol constraint at compile time
comptime {
    if (max_packet_length > 0xFFFF) {
        @compileError("max_packet_length exceeds protocol limit of 65535 bytes");
    }
}

// Packet size as little-endian u16 (protocol-mandated truncation)
const sz = self.buf.size();
out[19] = in_key[19] ^ @as(u8, @truncate(sz & 0xff));
out[20] = in_key[20] ^ @as(u8, @truncate((sz >> 8) & 0xff));
```

This ensures the constraint is enforced at compile time, making the runtime assertion unnecessary.

---

## Summary

**Round 2**: 2 issues found
- **Issue 1 (MEDIUM)**: Integer underflow in doOK_NETWORK_CONFIG_REQUEST payload length
- **Issue 2 (LOW)**: Debug-only assertion should be compile-time check

## Next Steps

1. Fix both issues
2. Run `zig build test`
3. Commit
4. Begin Round 3
