# Plot Hole Hunting Round 1 — 2026-04-01

## Methodology

Per STYLE.md §9.1 and §9.6: hunting for **incomplete implementations**, **missing edge case handling**, **stub functions**, and **TODOs that block functionality**.

Unlike bug hunting (which finds errors in working code), plot hole hunting finds **missing pieces** — functionality that should exist but doesn't, or exists only as a stub/comment.

## Issues Found

### Issue 1: Fragment reassembly disabled due to callback type mismatch (HIGH severity)
**File**: `switch.zig` lines 597-616
**Type**: Functionality disabled/commented out

**Problem**: Fragment reassembly is completely disabled. Reassembled packets are never processed.

**Code**:
```zig
// TODO: Fix callback type mismatch - needs IncomingPacket.Callbacks not Switch.Callbacks
for (&self.rx_queue) |*rq| {
    rq.lock.lock();
    defer rq.lock.unlock();
    if (rq.timestamp != 0 and rq.complete) {
        // Temporarily disabled due to callback type mismatch
        // Fragment reassembly will be re-enabled after fixing callback conversion
        if ((now - rq.timestamp) > constants.receive_queue_timeout) {
            rq.timestamp = 0;
        }
        // COMMENTED OUT:
        // if (rq.frag0.tryDecode(callbacks, rq.flow_id) or (now - rq.timestamp) > constants.receive_queue_timeout) {
        //     rq.timestamp = 0;
        // } else { ... }
    }
}
```

**Impact**:
- Fragmented packets are reassembled but never decoded/processed
- They sit in rx_queue until timeout, then are silently discarded
- Any packet that requires fragmentation will be dropped
- Network functionality limited to single-fragment packets only

**Root Cause**: IncomingPacket.tryDecode expects `IncomingPacket.Callbacks`, but Switch.doBackgroundTasks passes `Switch.Callbacks`. Type mismatch.

**Fix Required**: Create adapter or refactor callback types to align.

### Issue 2: Hashtable cleanup disabled — memory leak in WHOIS tracking (MEDIUM severity)
**File**: `switch.zig` lines 619-629, 636-638
**Type**: Cleanup code commented out

**Problem**: Old WHOIS requests and UNITE attempts are never removed from hashtables, causing unbounded memory growth.

**Code**:
```zig
// Clean up old WHOIS requests
// TODO: Implement hashtable.remove() method
{
    self.last_sent_whois_request_mutex.lock();
    defer self.last_sent_whois_request_mutex.unlock();
    // var whois_iter = self.last_sent_whois_request.iterator();
    // while (whois_iter.next()) |entry| {
    //     if ((now - @as(i64, @intCast(entry.value_ptr.*))) >= (constants.whois_retry_delay * 2)) {
    //         _ = self.last_sent_whois_request.remove(entry.key_ptr.*);
    //     }
    // }
}

// Clean up old UNITE attempts
self.last_unite_attempt_mutex.lock();
var unite_iter = self.last_unite_attempt.iterator();
while (unite_iter.next()) |entry| {
    if ((now - @as(i64, @intCast(entry.value_ptr.*))) >= (constants.min_unite_interval * 8)) {
        // TODO: Implement hashtable.remove()
        // _ = self.last_unite_attempt.remove(entry.key_ptr.*);
    }
}
self.last_unite_attempt_mutex.unlock();
```

**Impact**:
- WHOIS rate-limit tracking grows unbounded (one entry per peer ever seen)
- UNITE attempt tracking grows unbounded (one entry per NAT traversal attempt)
- Memory leak in long-running service
- Eventually causes OOM after processing many peers

**False TODO**: The comment says "TODO: Implement hashtable.remove()" but `hashtable.zig:82-84` already implements `erase()`:
```zig
pub fn erase(self: *Self, key: K) bool {
    return self.map.fetchRemove(key) != null;
}
```

**Fix Required**:
1. Uncomment the cleanup code
2. Change `.remove()` to `.erase()` (correct method name)
3. Handle iteration-during-mutation (see CODING_STANDARDS.md Rule 7)

### Issue 3: Network config retrieval returns null (LOW-MEDIUM severity)
**File**: `node.zig` lines 521-531
**Type**: Stub function

**Problem**: `getNetworkConfig()` is a stub that always returns null.

**Code**:
```zig
pub fn getNetworkConfig(self: *Self, nwid: u64) ?*NetworkConfig {
    self.networks_mutex.lock();
    defer self.networks_mutex.unlock();

    if (self.getNetwork(nwid)) |network| {
        // TODO: Return network config
        _ = network;
        return null;  // Always returns null!
    }
    return null;
}
```

**Impact**:
- Callers cannot retrieve network configuration
- May block status reporting or API queries
- Unclear if this is blocking critical functionality or just diagnostics

**Fix Required**: Return `&network.config` or equivalent.

## Summary

**Round 1**: 3 plot holes found
1. ✅ HIGH: Fragment reassembly disabled (callback type mismatch)
2. ✅ MEDIUM: Hashtable cleanup disabled (memory leak + false TODO)
3. ✅ LOW-MEDIUM: Network config getter is stub

All are **functional gaps** that should be fixed to complete the implementation.

## Next Steps

Will fix these in order of severity across multiple rounds.
