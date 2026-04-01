# Bug Hunting Round 3 — 2026-04-01

## Issues Found

### Issue 7: Silent error swallowing in init() (LOW severity)
**File**: `incoming_packet.zig` line 689
**Violation**: CODING_STANDARDS.md §2.1 — "No silent error swallowing"

**Problem**: `setSize(0)` error silently discarded in packet initialization. This resets the buffer before copying new data — if it fails, we proceed with invalid buffer state.

**Original code**:
```zig
pub fn init(
    self: *IncomingPacket,
    data: []const u8,
    path: ?*anyopaque,
    now: i64,
) !void {
    self.pkt.buf.setSize(0) catch {};  // WRONG - silent failure
    try self.pkt.buf.copyFrom(data);
    // ...
}
```

**Impact**: Low severity because:
- Next line (`copyFrom`) will likely fail if buffer is corrupt
- Initialization failure would be caught upstream
- However, still violates §2.1 principle

**Fix**: Add warning log:
```zig
self.pkt.buf.setSize(0) catch |err| {
    std.log.warn("Failed to reset packet buffer size: {}", .{err});
};
```

### Issue 8: Silent error in HELLO OK world update serialization (LOW-MEDIUM severity)
**File**: `incoming_packet.zig` lines 1419, 1437, 1443
**Violation**: CODING_STANDARDS.md §2.1 — "No silent error swallowing"

**Problem**: HELLO OK response includes planet/moon topology updates. If appending this data fails, the packet is sent with incomplete world info but no error indication.

**Original code**:
```zig
// Line 1419 - planet data
outp.buf.appendBytes(tmp_buf[0..planet_len]) catch {};

// Line 1437 - moon data
outp.buf.appendBytes(tmp_buf[0..moon_len]) catch {};

// Line 1443 - size field update
outp.buf.setAt(u16, world_update_size_at, @intCast(world_bytes_written)) catch {};
```

**Impact**:
- Medium severity for protocol correctness
- Peer receives HELLO OK but missing/corrupt world updates
- May cause peer to not learn about root servers or custom moons
- Silent failure makes debugging difficult

**Fix**: Add warning logs for all three locations:
```zig
outp.buf.appendBytes(tmp_buf[0..planet_len]) catch |err| {
    std.log.warn("Failed to append planet data to HELLO OK: {}", .{err});
};

outp.buf.appendBytes(tmp_buf[0..moon_len]) catch |err| {
    std.log.warn("Failed to append moon data to HELLO OK: {}", .{err});
};

outp.buf.setAt(u16, world_update_size_at, @intCast(world_bytes_written)) catch |err| {
    std.log.warn("Failed to set world update size in HELLO OK: {}", .{err});
};
```

**Rationale**: HELLO OK is a critical handshake response. Any serialization failure should be visible in logs for debugging.

## Fixes Applied

1. ✅ **Line 689**: Added error logging to init() setSize
2. ✅ **Lines 1419, 1437, 1443**: Added error logging to HELLO OK world update serialization

## Testing

- ✅ Build successful: `zig build`

## Completion Status

**Round 3**: 3/3 issues fixed (counted as 2 logical issues: init + HELLO OK serialization)
- Issue 7: ✅ FIXED
- Issue 8: ✅ FIXED (3 locations)

## Summary

Addressed silent error swallowing in incoming_packet.zig:
- Packet initialization buffer reset
- HELLO OK world update serialization (planet + moon + size field)

All violations of §2.1 now log warnings instead of silently discarding errors.
