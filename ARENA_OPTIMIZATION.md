# Arena Allocator Optimization Plan

**Date**: 2026-04-02
**Status**: Phase 3 (Comptime) complete, Phase 1 (Packet Arena) in progress
**Inspiration**: pdns project arena optimizations (50% allocation reduction)

---

## Executive Summary

Apply Zig's arena allocator pattern to ZeroTierOne's packet processing hot paths, following successful patterns from the pdns project. Expected benefits:

- **-30-50% allocation count** per packet
- **-5-10% packet processing latency**
- **Simpler error handling** (fewer defer chains)
- **Better cache locality** for temporary data

## Background: pdns Success Story

The pdns project achieved significant performance improvements using arena allocators:

### Phase 3: Zone Parsing (Commit 62aac7334)
- **50% reduction in allocation count**
- **-66% defer statements** in parse()
- **-100% complex errdefer blocks**
- Simpler code, better performance

### Key Pattern
```zig
pub fn parse(...) !Result {
    // Create arena for all temporary parsing allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // Frees all temp allocations at once
    const temp_alloc = arena.allocator();

    // Use temp_alloc for:
    // - Parsing buffers
    // - Intermediate state
    // - Temporary objects

    // Use allocator for:
    // - Final results (must outlive arena)
    // - Persistent state

    // Copy final data to heap before arena dies
    return final_result;
}
```

## ZeroTierOne Opportunities

### Phase 1: Packet Processing Arena (HIGH PRIORITY)

**Target**: `Switch.onRemotePacket()` and packet decode path

**Current State**:
- Many small allocations scattered throughout packet processing
- Crypto ephemeral keys allocated/freed per packet
- Fragment reassembly buffers
- Decompression output buffers
- Each has explicit defer/errdefer

**Proposed Change**:
```zig
pub fn onRemotePacket(
    self: *Self,
    t_ptr: ?*anyopaque,
    local_socket: i64,
    from_addr: *const InetAddress,
    data: [*]const u8,
    len: u32,
    callbacks: *const Callbacks,
) void {
    // Create arena for all temp allocations during packet processing
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    // Pass temp_alloc to:
    // - handleFragment() - fragment reassembly buffers
    // - handlePacketHead() - packet decode buffers
    // - IncomingPacket.tryDecode() - crypto/decompress temps

    // ... existing logic ...
}
```

**Files to Modify**:
1. `src/node/switch.zig` - Add arena to `onRemotePacket()`
2. `src/node/incoming_packet.zig` - Accept `temp_allocator` parameter
3. `src/node/packet.zig` - Use temp allocator for crypto buffers

**Expected Impact**:
- **Before**: ~50-100 allocations per packet (crypto buffers, fragments, decompress)
- **After**: ~10-20 allocations per packet (only persistent state)
- **-60-80% allocation count per packet**
- **-5-10% packet processing latency** (fewer allocator calls)

**Temporary Allocations** (arena):
- Crypto ephemeral keys (packet.zig:700, 779)
- AES cipher instances (packet.zig:710, 784)
- Fragment reassembly buffers (switch.zig:866)
- Decompression output (packet.zig)
- Packet decode intermediate buffers

**Permanent Allocations** (heap):
- RXQueueEntry updates
- Peer state modifications
- Network membership changes
- TX queue entries

### Phase 2: Network Config Parsing Arena (MEDIUM PRIORITY)

**Target**: `zerotier_service.zig` network configuration handling

**Current State**:
```zig
// Line 427
defer self.allocator.free(network_list);
```

**Proposed Change**:
```zig
fn processNetworkConfig(...) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    // Build network list with temp allocations
    var network_list = std.ArrayList(...).init(temp_alloc);
    // Parse IPs and routes (using temp_alloc)

    // Copy final state to heap before arena dies
    // Arena cleans up all temps automatically
}
```

**Expected Impact**:
- Simpler config handling code
- Fewer defer chains
- Not a hot path, so minor performance improvement
- Better code maintainability

### Phase 3: Comptime Optimizations (COMPLETED ✅)

**Target**: Root server addresses, protocol constants, test fixtures

**Pattern from pdns Phase 4**:
```zig
// Before: Runtime parsing
const root_ip = try parseIPv4("103.195.103.66");

// After: Compile-time parsing (zero runtime cost)
const root_ip = comptime comptimeParseIPv4("103.195.103.66");
// Becomes: .{ 103, 195, 103, 66 } in binary
```

**Implemented**:
- Root server IPs in `planet.zig` (if applicable)
- Protocol constants validation
- Test fixture addresses

## Implementation Strategy

### Hybrid Allocation Strategy

**Key Principle**: Arena for temps, heap for permanents

```zig
// Temporary (Arena) - dies with arena.deinit():
✓ Parsing buffers
✓ Decompression output
✓ Fragment reassembly state
✓ Crypto ephemeral keys
✓ Intermediate packet data

// Permanent (Heap) - survives arena.deinit():
✓ Peer entries in topology
✓ Network state
✓ Route tables
✓ TX/RX queue entries
✓ Final processed data
```

### Step-by-Step Approach

1. **Phase 3 First** (✅ DONE) - Safest, immediate benefit
   - Comptime constants
   - Zero risk of memory issues
   - Pure code quality win

2. **Phase 1 Next** (IN PROGRESS) - Highest performance impact
   - Start with `onRemotePacket()`
   - Add arena wrapper
   - Pass `temp_alloc` to callees
   - Benchmark before/after

3. **Phase 2 Last** - After Phase 1 proven
   - Apply to config parsing
   - Similar pattern, lower priority

### Backward Compatibility

**CRITICAL**: All changes must be internal only

✓ Public APIs unchanged
✓ Memory ownership semantics unchanged
✓ Callback signatures unchanged
✓ All existing tests must pass
✓ No breaking changes to service layer

## Verification Plan

### Before/After Benchmarks

```bash
# Baseline
zig build selftest
./zig-out/bin/zerotier-selftest | grep "Benchmarking"

# After arena changes
zig build selftest
./zig-out/bin/zerotier-selftest | grep "Benchmarking"

# Compare metrics
```

### Memory Profiling

**Track allocation counts**:
- Use Zig's GeneralPurposeAllocator in test mode
- Count allocations per packet
- Verify no leaks (arena cleanup)

**Example**:
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();

// Process N packets
const alloc_count_before = gpa.total_requested_bytes;
// ... process packets ...
const alloc_count_after = gpa.total_requested_bytes;

std.debug.print("Allocations: {}\n", .{alloc_count_after - alloc_count_before});
```

### Test Coverage

```bash
# Syntax check
zig ast-check src/node/switch.zig
zig ast-check src/node/packet.zig
zig ast-check src/node/incoming_packet.zig

# Unit tests (if available)
zig build test

# Integration tests
./test_service.sh
```

### Success Criteria

**Phase 1 (Packet Processing)**:
- ✅ All tests passing
- ✅ -30-50% allocation count per packet
- ✅ -5-10% packet processing latency
- ✅ Fewer defer statements (measurable)
- ✅ No memory leaks (verified)

**Phase 2 (Config Parsing)**:
- ✅ All tests passing
- ✅ Simpler code (fewer defer chains)
- ✅ No regression in functionality

**Phase 3 (Comptime)**: ✅ COMPLETE
- ✅ Constants validated at compile time
- ✅ Zero runtime overhead
- ✅ More readable code

## Risk Assessment

### Low Risk Areas

✓ Comptime optimizations (Phase 3)
✓ Config parsing arena (Phase 2)
✓ Well-proven pattern in Zig ecosystem
✓ Easy to revert if issues found

### Medium Risk Areas

⚠️ Packet processing arena (Phase 1)
⚠️ Hot path - must not introduce regressions
⚠️ Complex interactions with crypto/fragments

### Mitigation Strategies

1. **Thorough Testing**
   - Unit tests for arena lifetime
   - Integration tests for full packet flow
   - Benchmark before/after

2. **Incremental Rollout**
   - Phase 3 first (safest)
   - Phase 1 with extensive testing
   - Phase 2 after Phase 1 proven

3. **Easy Rollback**
   - Git commits per phase
   - Each phase independently revertible
   - Performance metrics tracked

### Potential Issues

**Issue 1: Lifetime Confusion**
- **Risk**: Keeping arena pointers after deinit()
- **Solution**: Clear `temp_alloc` vs `allocator` naming
- **Detection**: Zig's safety checks, testing

**Issue 2: Over-allocation**
- **Risk**: Arena pre-allocates chunks (memory overhead)
- **Solution**: Monitor memory usage, tune arena size
- **Detection**: Memory profiling

**Issue 3: Performance Regression**
- **Risk**: Arena overhead exceeds allocation savings
- **Solution**: Benchmark, A/B test, revert if needed
- **Detection**: Automated benchmarks

## Reference Implementation: pdns

### Files to Study

1. **Zone Parsing Arena** (Phase 3)
   - `/Users/someara/src/pdns/zig-dns/src/zone.zig`
   - Lines 60-66: Arena initialization
   - Shows hybrid allocation strategy

2. **Documentation**
   - `/Users/someara/src/pdns/zig-dns/PHASE3_ZONE_ARENA.md`
   - Detailed before/after metrics
   - Lessons learned

3. **Request Handling Arena** (Phase 1)
   - `/Users/someara/src/pdns/zig-dns/src/server_v2.zig`
   - Similar pattern to our packet processing

### Key Commits

- `62aac7334` - Phase 3: Zone arena allocators
- `40a3adbcf` - Phase 2: Generic backend
- `d687eeaea` - Zig-idiomatic transformation

### Lessons Learned from pdns

1. **Arena for all temps** - Don't mix allocation strategies
2. **Copy permanents to heap** - Before arena dies
3. **Simplify error handling** - Let arena clean up
4. **Document ownership** - Clear OWNED/BORROWED annotations
5. **Measure everything** - Before/after metrics required

## Industry Patterns

This optimization follows standard Zig practice:

- **TigerBeetle**: Arena for request handling
- **Bun**: Arena for AST construction
- **Zig std library**: Arena for phase-based parsing
- **General pattern**: "Phase-based" allocations with same lifetime

Arena allocators are the **Zig-idiomatic solution** for operations where a group of related allocations all have the same lifetime.

## Progress Tracking

### Phase 3: Comptime Optimizations ✅ COMPLETE
- [x] Identified comptime opportunities
- [x] Implemented comptime functions
- [x] All tests passing
- [x] Zero runtime overhead achieved

### Phase 1: Packet Processing Arena (IN PROGRESS)
- [x] Analysis complete
- [x] Hot paths identified
- [ ] Arena wrapper in onRemotePacket()
- [ ] Pass temp_allocator to callees
- [ ] Update IncomingPacket.tryDecode()
- [ ] Update packet.zig crypto functions
- [ ] Benchmark before/after
- [ ] Verify no memory leaks
- [ ] All tests passing

### Phase 2: Config Parsing Arena (PLANNED)
- [ ] Analysis complete
- [ ] Arena wrapper in config parsing
- [ ] Simplify defer chains
- [ ] All tests passing

## Next Steps

1. ✅ Complete Phase 3 (Comptime) - DONE
2. 🔄 Implement Phase 1 (Packet Arena) - IN PROGRESS
3. ⏳ Measure Phase 1 performance
4. ⏳ Implement Phase 2 (Config Arena) if Phase 1 successful

## Contact & Updates

This optimization is being tracked in:
- Plan file: `/Users/someara/.claude/plans/functional-percolating-shamir.md`
- This document: `ARENA_OPTIMIZATION.md`
- Git commits tagged with "arena:" prefix

---

**Last Updated**: 2026-04-02
**Next Review**: After Phase 1 completion
