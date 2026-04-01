# Plot Hole Hunting Round 3 — 2026-04-01

## Issues Found

### Issue 7: Multicast subscribe/unsubscribe are stubs (MEDIUM severity)
**File**: `node.zig` lines 622-646
**Type**: Missing forwarding logic

**Problem**: `multicastSubscribe()` and `multicastUnsubscribe()` do nothing — they discard all parameters.

**Code (before fix)**:
```zig
pub fn multicastSubscribe(
    self: *Self,
    t_ptr: ?*anyopaque,
    nwid: u64,
    multicast_group: u64,
    multicast_adi: u32,
) !void {
    const network = self.getNetwork(nwid) orelse return error.NetworkNotFound;

    _ = t_ptr;
    _ = network;
    _ = multicast_group;
    _ = multicast_adi;

    // TODO: Call network.multicastSubscribe
}
```

**Impact**:
- Multicast group subscriptions never registered
- Network can't receive multicast traffic (ARP, IPv6 neighbor discovery, etc.)
- Breaks functionality for Layer 2 bridges and multicast applications

**Available Implementation**: Network.multicastSubscribe() exists at network.zig:805

**Fix**: Forward to Network.multicastSubscribe/Unsubscribe with proper MulticastGroup construction

### Code Changes

**Added import**:
```zig
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
```

**Implemented subscribe**:
```zig
const mg = MulticastGroup.init(MAC.init(multicast_group), multicast_adi);
network.multicastSubscribe(t_ptr, mg);
```

**Implemented unsubscribe**:
```zig
const mg = MulticastGroup.init(MAC.init(multicast_group), multicast_adi);
network.multicastUnsubscribe(&mg);
```

## Impact

**Before**: Multicast subscriptions silently ignored
**After**: Multicast groups properly registered in Network._my_multicast_groups

This unblocks:
- IPv4 ARP (broadcast MAC with IP as ADI)
- IPv6 Neighbor Discovery (solicited-node multicast)
- Layer 2 bridging with multicast traffic
- Application-level multicast groups

## Verification

- ✅ Build successful (zig build)
- ✅ Network.multicastSubscribe verified at network.zig:805-833
- ✅ Network.multicastUnsubscribe verified at network.zig:834-860

## Summary

**Round 3**: 1 issue fixed (multicast subscribe/unsubscribe forwarding)
- Issue 7: MEDIUM severity — multicast subscriptions now functional
