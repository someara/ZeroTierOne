# Plot Hole Hunting Round 2 — 2026-04-01

## Issues Found

### Issue 4: Network MAC callback returns zero (LOW-MEDIUM severity)
**File**: `node.zig` line 1600
**Type**: Stub callback

**Problem**: `networkMac` callback returns MAC.init(0) instead of actual network MAC address.

**Code**:
```zig
.networkMac = struct {
    fn f(_: ?*anyopaque, _: ?*anyopaque) MAC {
        return MAC.init(0); // TODO: Return network MAC address
    }
}.f,
```

**Impact**:
- Bridged traffic detection broken (switch.zig:359-360)
- Frame processing uses wrong source MAC
- Multicast group management may fail

**Available Data**: Network struct has `_mac` field (network.zig:333)

**Fix**: Cast ctx/network pointers, return network._mac

### Issue 5: Network user pointer callback returns null (LOW severity)
**File**: `node.zig` line 1606
**Type**: Stub callback

**Problem**: `networkUserPtr` callback returns null instead of network's user pointer.

**Code**:
```zig
.networkUserPtr = struct {
    fn f(_: ?*anyopaque, _: ?*anyopaque) ?*anyopaque {
        return null; // TODO: Return network user pointer
    }
}.f,
```

**Impact**:
- pmPutFrame gets null user_ptr (incoming_packet.zig:2204)
- TUN device may not receive proper context
- External API integration may fail

**Available Data**: Network struct has `_u_ptr` field (network.zig:340)

**Fix**: Cast ctx/network pointers, return network._u_ptr

### Issue 6: Peer contact callback is no-op (LOW severity)
**File**: `node.zig` lines 1592-1594
**Type**: Stub callback

**Problem**: `peerAttemptToContactAt` does nothing.

**Code**:
```zig
.peerAttemptToContactAt = struct {
    fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: i64, _: bool) void {
        // TODO: Attempt to contact peer at address
    }
}.f,
```

**Impact**:
- Unclear — may be optional callback for connection hints
- Need to check if C++ implementation does anything meaningful

**Assessment**: Likely LOW priority unless NAT traversal is broken

## Analysis

All three issues are in the **packet multiplexer callback table** (node.zig:1590-1614). These callbacks bridge IncomingPacket → Network → TUN device.

### Callback Signature Issue

The stub callbacks take `(?*anyopaque, ?*anyopaque)` but need to:
1. Cast first param to `*Node` (ctx)
2. Cast second param to `*Network` (network pointer)
3. Access network fields

The actual implementations will look like:
```zig
.networkMac = struct {
    fn f(ctx: ?*anyopaque, nw: ?*anyopaque) MAC {
        const network: *Network = @ptrCast(@alignCast(nw.?));
        return network._mac;
    }
}.f,
```

## Priority

These are **functional gaps blocking frame processing**:
- Issue 4 (MAC): MEDIUM — breaks bridging detection
- Issue 5 (user ptr): LOW — breaks TUN context passing
- Issue 6 (contact): LOW — unclear if needed

## Next Steps

Fix Issues 4-5 in Round 2 (simple field access).
Investigate Issue 6 — check C++ to see if it's used.
