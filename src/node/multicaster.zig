/// Database of known multicast peers within a network.
///
/// Converted from `node/Multicaster.hpp` and `node/Multicaster.cpp`.
///
/// Tracks multicast group membership per network, manages pending outbound
/// multicasts (tx queue), and supports random-order gather responses.
///
/// Thread safety: callers must synchronize externally or use the provided
/// Mutex (the C++ version uses an internal mutex; we expose it for callers).
///
/// Design notes for Phase 5:
///   - `send()` is heavily coupled to Network, Node, Switch, Topology, Peer,
///     and Path in C++. Here it is modeled via `SendCallbacks` — a struct of
///     function pointers that the caller provides.
///   - `gather()` appends directly to a Buffer, matching the C++ pattern.
///   - Members within each group are kept sorted by address for binary search.
///   - The tx queue and member list use fixed-size arrays (no heap allocation
///     per group status entry).
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const constants = @import("constants.zig");
const Hashtable = @import("hashtable.zig").Hashtable;
const MAC = @import("mac.zig").MAC;
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
const Mutex = @import("mutex.zig");
const nc = @import("network_config.zig");
const OutboundMulticast = @import("outbound_multicast.zig").OutboundMulticast;
const packet_mod = @import("packet.zig");
const Packet = packet_mod.Packet;

// ── Constants ────────────────────────────────────────────────────────

/// Maximum members tracked per multicast group.
/// C++ uses std::vector (unbounded); we cap at a reasonable size.
const max_members_per_group: u32 = 1024;

/// Maximum pending outbound multicasts per group.
/// C++ uses `std::list<OutboundMulticast>` limited by ZT_TX_QUEUE_SIZE.
const max_tx_queue_per_group: u32 = constants.tx_queue_size;

/// Address length in bytes (5 bytes = 40 bits).
const address_length: u32 = 5;

// ── Key ──────────────────────────────────────────────────────────────

/// Composite hash key for (network ID, multicast group) pairs.
pub const Key = struct {
    nwid: u64,
    mg: MulticastGroup,

    pub fn init(nwid: u64, mg: MulticastGroup) Key {
        return .{ .nwid = nwid, .mg = mg };
    }

    pub fn zero() Key {
        return .{ .nwid = 0, .mg = MulticastGroup.init(MAC.init(0), 0) };
    }

    pub fn eql(self: Key, other: Key) bool {
        return self.nwid == other.nwid and self.mg._mac._m == other.mg._mac._m and self.mg._adi == other.mg._adi;
    }

    pub fn hashCode(self: Key) u64 {
        const mg_hash = self.mg._mac._m ^ @as(u64, self.mg._adi);
        return mg_hash ^ (self.nwid ^ (self.nwid >> 32));
    }
};

// ── MulticastGroupMember ─────────────────────────────────────────────

/// A member of a multicast group, with the time of last notification.
pub const MulticastGroupMember = struct {
    address: Address,
    timestamp: i64,

    pub fn init(addr: Address, ts: i64) MulticastGroupMember {
        return .{ .address = addr, .timestamp = ts };
    }

    pub fn zero() MulticastGroupMember {
        return .{ .address = Address.zero(), .timestamp = 0 };
    }
};

// ── MulticastGroupStatus ─────────────────────────────────────────────

/// Status of a multicast group — members + pending tx queue.
pub const MulticastGroupStatus = struct {
    /// Time of last explicit gather request.
    last_explicit_gather: i64,

    /// Pending outbound multicasts awaiting more member discovery.
    tx_queue: [max_tx_queue_per_group]OutboundMulticast,
    tx_queue_count: u32,

    /// Sorted list of group members.
    members: [max_members_per_group]MulticastGroupMember,
    member_count: u32,

    pub fn init() MulticastGroupStatus {
        return .{
            .last_explicit_gather = 0,
            .tx_queue = [_]OutboundMulticast{OutboundMulticast.initEmpty()} ** max_tx_queue_per_group,
            .tx_queue_count = 0,
            .members = [_]MulticastGroupMember{MulticastGroupMember.zero()} ** max_members_per_group,
            .member_count = 0,
        };
    }

    /// Find the insertion point for `addr` in the sorted members list.
    /// Returns the index where `addr` should be inserted, and whether
    /// it already exists at that position.
    fn findMember(self: *const MulticastGroupStatus, addr: Address) struct { index: u32, found: bool } {
        if (self.member_count == 0) {
            return .{ .index = 0, .found = false };
        }

        // Binary search by address value.
        var lo: u32 = 0;
        var hi: u32 = self.member_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.members[mid].address.toInt() < addr.toInt()) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo < self.member_count and self.members[lo].address.eql(addr)) {
            return .{ .index = lo, .found = true };
        }
        return .{ .index = lo, .found = false };
    }

    /// Add or update a member. Returns true if newly added.
    pub fn addMember(self: *MulticastGroupStatus, addr: Address, now: i64) bool {
        const result = self.findMember(addr);
        if (result.found) {
            // Update timestamp of existing member.
            self.members[result.index].timestamp = now;
            return false;
        }

        if (self.member_count >= max_members_per_group) {
            return false; // Full
        }

        // Insert at the right position to maintain sorted order.
        // Shift elements right.
        var i: u32 = self.member_count;
        while (i > result.index) : (i -= 1) {
            self.members[i] = self.members[i - 1];
        }
        self.members[result.index] = MulticastGroupMember.init(addr, now);
        self.member_count += 1;
        return true;
    }

    /// Remove a member by address. Returns true if found and removed.
    pub fn removeMember(self: *MulticastGroupStatus, addr: Address) bool {
        const result = self.findMember(addr);
        if (!result.found) return false;

        // Shift elements left.
        var i: u32 = result.index;
        while (i + 1 < self.member_count) : (i += 1) {
            self.members[i] = self.members[i + 1];
        }
        self.member_count -= 1;
        return true;
    }

    /// Push an OutboundMulticast onto the tx queue.
    /// If the queue is full, drops the oldest entry (front).
    pub fn pushTx(self: *MulticastGroupStatus, om: OutboundMulticast) void {
        if (self.tx_queue_count >= max_tx_queue_per_group) {
            // Drop front, shift left.
            var i: u32 = 0;
            while (i + 1 < self.tx_queue_count) : (i += 1) {
                self.tx_queue[i] = self.tx_queue[i + 1];
            }
            self.tx_queue_count -= 1;
        }
        self.tx_queue[self.tx_queue_count] = om;
        self.tx_queue_count += 1;
    }

    /// Remove a tx queue entry by index, shifting remaining entries left.
    pub fn removeTx(self: *MulticastGroupStatus, idx: u32) void {
        if (idx >= self.tx_queue_count) return;
        var i: u32 = idx;
        while (i + 1 < self.tx_queue_count) : (i += 1) {
            self.tx_queue[i] = self.tx_queue[i + 1];
        }
        self.tx_queue_count -= 1;
    }
};

// ── Callbacks ────────────────────────────────────────────────────────

/// Callback for getting our own ZeroTier address.
pub const GetMyAddressFn = *const fn (ctx: ?*anyopaque) Address;

/// Callback for a PRNG value (used for random member selection).
pub const PrngFn = *const fn (ctx: ?*anyopaque) u64;

/// Callback for sending an OutboundMulticast to a specific address.
/// This wraps the full send pipeline: filter, credential push, IV, switch send.
pub const SendMulticastFn = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    om: *const OutboundMulticast,
    to_addr: Address,
) void;

/// Full set of callbacks needed by the Multicaster.
pub const Callbacks = struct {
    /// Opaque context (RuntimeEnvironment / Node / etc.)
    ctx: ?*anyopaque,
    /// Get our own ZeroTier address.
    getMyAddress: GetMyAddressFn,
    /// PRNG.
    prng: PrngFn,
};

// ── Multicaster ──────────────────────────────────────────────────────

/// Database of known multicast peers within networks.
///
/// Manages multicast group membership, pending tx queues, and gather
/// responses. The `send()` method from C++ is decomposed: callers build
/// OutboundMulticast objects and use `add()` which drains the tx queue.
pub const Multicaster = struct {
    /// Groups hashtable: Key -> MulticastGroupStatus.
    /// Note: MulticastGroupStatus is very large (~5 MB due to the tx queue
    /// of OutboundMulticast objects, each containing a Packet). The hashtable
    /// heap-allocates values, so this is fine.
    groups: Hashtable(Key, MulticastGroupStatus),

    /// Callbacks for cross-module interactions.
    callbacks: Callbacks,

    // ── Init / Deinit ────────────────────────────────────

    /// Create a new Multicaster.
    pub fn init(allocator: std.mem.Allocator, callbacks: Callbacks) Multicaster {
        return .{
            .groups = Hashtable(Key, MulticastGroupStatus).init(allocator),
            .callbacks = callbacks,
        };
    }

    /// Free all resources.
    pub fn deinit(self: *Multicaster) void {
        self.groups.deinit();
    }

    // ── Add members ──────────────────────────────────────

    /// Add or update a member in a multicast group.
    ///
    /// If new members are discovered, drains any pending tx queue entries
    /// by calling `sendIfNew` on them (matching C++ `_add` behavior).
    pub fn add(
        self: *Multicaster,
        t_ptr: ?*anyopaque,
        now: i64,
        nwid: u64,
        mg: MulticastGroup,
        member: Address,
        send_fn: ?SendMulticastFn,
    ) void {
        // Do not add self.
        const my_addr = self.callbacks.getMyAddress(self.callbacks.ctx);
        if (member.eql(my_addr)) return;

        const key = Key.init(nwid, mg);
        const gs: *MulticastGroupStatus = self.groups.getOrPut(key, MulticastGroupStatus.init()) catch return;

        if (gs.addMember(member, now)) {
            // New member — drain tx queue (matches C++ _add behavior).
            if (send_fn) |sfn| {
                var i: u32 = 0;
                while (i < gs.tx_queue_count) {
                    if (gs.tx_queue[i].atLimit()) {
                        gs.removeTx(i);
                        // Don't increment i; the next element shifted into this slot.
                    } else {
                        // Check if not already sent to this member.
                        if (!gs.tx_queue[i].alreadySentTo(member)) {
                            // Send via the multicaster-level callback.
                            sfn(self.callbacks.ctx, t_ptr, &gs.tx_queue[i], member);
                            gs.tx_queue[i].logAsSent(member);
                        }
                        // Check if now at limit after potential send.
                        if (gs.tx_queue[i].atLimit()) {
                            gs.removeTx(i);
                        } else {
                            i += 1;
                        }
                    }
                }
            }
        }
    }

    /// The sendIfNew callback adapter — matches OutboundMulticast.SendFn signature.
    /// This is a helper for when the caller wants to use OutboundMulticast.sendIfNew
    /// with the same SendMulticastFn interface. Since OutboundMulticast.sendIfNew
    /// calls the SendFn with the full parameter set, we don't need this adapter.
    /// Add multiple addresses from a binary array of 5-byte address fields.
    pub fn addMultiple(
        self: *Multicaster,
        t_ptr: ?*anyopaque,
        now: i64,
        nwid: u64,
        mg: MulticastGroup,
        addresses: []const u8,
        count: u32,
        send_fn: ?SendMulticastFn,
    ) void {
        _ = count; // We derive count from slice length.
        var offset: usize = 0;
        while (offset + address_length <= addresses.len) {
            const addr = Address.fromSlice(addresses[offset..][0..address_length]);
            self.add(t_ptr, now, nwid, mg, addr, send_fn);
            offset += address_length;
        }
    }

    /// Remove a member from a multicast group.
    pub fn remove(self: *Multicaster, nwid: u64, mg: MulticastGroup, member: Address) void {
        const key = Key.init(nwid, mg);
        if (self.groups.get(key)) |gs| {
            _ = gs.removeMember(member);
        }
    }

    // ── Gather ───────────────────────────────────────────

    /// Append gather results to a buffer by choosing members at random.
    ///
    /// Appends:
    ///   - [4] u32 total number of known members
    ///   - [2] u16 number of members enumerated in this response
    ///   - [...] series of 5-byte ZeroTier addresses
    ///
    /// The querying peer is excluded from results.
    ///
    /// Returns the number of addresses appended.
    pub fn gather(
        self: *const Multicaster,
        querying_peer: Address,
        nwid: u64,
        mg: MulticastGroup,
        buf: *Buffer(packet_mod.max_packet_length),
        limit_val: u32,
    ) u32 {
        if (limit_val == 0) return 0;

        const effective_limit: u32 = @min(limit_val, 0xFFFF);
        var added: u32 = 0;
        var total_known: u32 = 0;

        // Reserve space for totalKnown (u32) and added count (u16).
        const total_at = buf.size();
        buf.addSize(4) catch return 0;
        const added_at = buf.size();
        buf.addSize(2) catch return 0;

        const key = Key.init(nwid, mg);
        if (self.groups.getCopy(key)) |gs| {
            if (gs.member_count > 0) {
                total_known += gs.member_count;

                // Random permutation selection.
                // Use a simple approach: generate random indices and dedup.
                var picked: [max_members_per_group]bool = [_]bool{false} ** max_members_per_group;
                var attempts: u32 = 0;
                const max_attempts = gs.member_count * 3; // Prevent infinite loop.

                while (added < effective_limit and attempts < max_attempts) {
                    if (buf.size() + address_length > packet_mod.max_packet_length) break;

                    const rnd = self.callbacks.prng(self.callbacks.ctx);
                    const idx: u32 = @intCast(rnd % gs.member_count);
                    attempts += 1;

                    if (picked[idx]) continue;
                    picked[idx] = true;

                    const member_addr = gs.members[idx].address;
                    if (member_addr.eql(querying_peer)) continue;

                    // Append 5-byte address.
                    member_addr.appendTo(packet_mod.max_packet_length, buf) catch break;
                    added += 1;

                    // If we've picked all members, stop.
                    if (added + 1 >= gs.member_count) break;
                }
            }
        }

        // Write back totalKnown and added. These offsets were pre-calculated
        // within the buffer's allocated size, so setAt cannot fail here.
        buf.setAt(u32, total_at, total_known) catch {};
        buf.setAt(u16, added_at, @as(u16, @intCast(added))) catch {};

        return added;
    }

    // ── Get members ──────────────────────────────────────

    /// Get members of a multicast group (most-recently-added first, up to limit).
    /// Returns the number of members written to `out`.
    pub fn getMembers(
        self: *const Multicaster,
        nwid: u64,
        mg: MulticastGroup,
        out: []Address,
        limit_val: u32,
    ) u32 {
        const key = Key.init(nwid, mg);
        if (self.groups.getCopy(key)) |gs| {
            var count: u32 = 0;
            // Reverse order (most recent last in sorted list -> first in output).
            var i: u32 = gs.member_count;
            while (i > 0 and count < limit_val and count < out.len) {
                i -= 1;
                out[count] = gs.members[i].address;
                count += 1;
            }
            return count;
        }
        return 0;
    }

    // ── Queue management ─────────────────────────────────

    /// Queue an outbound multicast for a group.
    ///
    /// This is the Zig equivalent of the C++ "push to txQueue" path in
    /// Multicaster::send() when there aren't enough known members.
    pub fn queueOutbound(
        self: *Multicaster,
        nwid: u64,
        mg: MulticastGroup,
        om: OutboundMulticast,
    ) void {
        const key = Key.init(nwid, mg);
        const gs: *MulticastGroupStatus = self.groups.getOrPut(key, MulticastGroupStatus.init()) catch return;
        gs.pushTx(om);
    }

    /// Get the group status for a given (nwid, mg) pair, if it exists.
    pub fn getGroupStatus(self: *Multicaster, nwid: u64, mg: MulticastGroup) ?*MulticastGroupStatus {
        return self.groups.get(Key.init(nwid, mg));
    }

    // ── Clean ────────────────────────────────────────────

    /// Clean expired entries from the database.
    ///
    /// - Removes expired or at-limit entries from tx queues.
    /// - Removes members whose timestamp is older than multicast_like_expire.
    /// - Removes empty groups (no members and no pending tx).
    pub fn clean(self: *Multicaster, now: i64) void {
        // Collect keys to erase after iteration (can't erase during iteration).
        var keys_to_erase: [256]Key = undefined;
        var erase_count: u32 = 0;

        var iter = self.groups.iterator();
        while (iter.next()) |entry| {
            const k = entry.key_ptr;
            const gs = entry.value_ptr;

            // Clean tx queue: remove expired or at-limit entries.
            var i: u32 = 0;
            while (i < gs.tx_queue_count) {
                if (gs.tx_queue[i].expired(now) or gs.tx_queue[i].atLimit()) {
                    gs.removeTx(i);
                } else {
                    i += 1;
                }
            }

            // Clean members: remove those with expired timestamps.
            var new_count: u32 = 0;
            for (0..gs.member_count) |mi| {
                if ((now - gs.members[mi].timestamp) < constants.multicast_like_expire) {
                    if (new_count != mi) {
                        gs.members[new_count] = gs.members[mi];
                    }
                    new_count += 1;
                }
            }
            gs.member_count = new_count;

            // If no members and no pending tx, mark for removal.
            if (gs.member_count == 0 and gs.tx_queue_count == 0) {
                if (erase_count < keys_to_erase.len) {
                    keys_to_erase[erase_count] = k.*;
                    erase_count += 1;
                }
            }
        }

        // Erase empty groups.
        for (0..erase_count) |ei| {
            _ = self.groups.erase(keys_to_erase[ei]);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

fn testGetMyAddress(_: ?*anyopaque) Address {
    return Address.init(0xAABBCCDDEE);
}

fn testPrng(_: ?*anyopaque) u64 {
    // Simple deterministic PRNG for tests.
    const S = struct {
        var state: u64 = 12345;
    };
    S.state = S.state *% 6364136223846793005 +% 1442695040888963407;
    return S.state;
}

fn testCallbacks() Callbacks {
    return .{
        .ctx = null,
        .getMyAddress = testGetMyAddress,
        .prng = testPrng,
    };
}

test "Key: init, eql, hashCode" {
    const mg1 = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    const mg2 = MulticastGroup.init(MAC.init(0xFFFFFF000002), 42);

    const k1 = Key.init(0x1234, mg1);
    const k2 = Key.init(0x1234, mg1);
    const k3 = Key.init(0x1234, mg2);
    const k4 = Key.init(0x5678, mg1);

    try testing.expect(k1.eql(k2));
    try testing.expect(!k1.eql(k3));
    try testing.expect(!k1.eql(k4));

    // Same keys should produce same hash.
    try testing.expectEqual(k1.hashCode(), k2.hashCode());
}

test "MulticastGroupStatus: addMember sorted insert" {
    var gs = MulticastGroupStatus.init();

    const a3 = Address.init(0x0000000003);
    const a1 = Address.init(0x0000000001);
    const a2 = Address.init(0x0000000002);

    // Insert out of order.
    try testing.expect(gs.addMember(a3, 100));
    try testing.expect(gs.addMember(a1, 200));
    try testing.expect(gs.addMember(a2, 300));

    try testing.expectEqual(@as(u32, 3), gs.member_count);

    // Should be sorted by address.
    try testing.expect(gs.members[0].address.eql(a1));
    try testing.expect(gs.members[1].address.eql(a2));
    try testing.expect(gs.members[2].address.eql(a3));
}

test "MulticastGroupStatus: addMember updates timestamp" {
    var gs = MulticastGroupStatus.init();

    const addr = Address.init(0x1234567890);

    try testing.expect(gs.addMember(addr, 100));
    try testing.expectEqual(@as(i64, 100), gs.members[0].timestamp);

    // Adding again should update timestamp but not add duplicate.
    try testing.expect(!gs.addMember(addr, 200));
    try testing.expectEqual(@as(u32, 1), gs.member_count);
    try testing.expectEqual(@as(i64, 200), gs.members[0].timestamp);
}

test "MulticastGroupStatus: removeMember" {
    var gs = MulticastGroupStatus.init();

    const a1 = Address.init(0x0000000001);
    const a2 = Address.init(0x0000000002);
    const a3 = Address.init(0x0000000003);

    _ = gs.addMember(a1, 100);
    _ = gs.addMember(a2, 100);
    _ = gs.addMember(a3, 100);

    try testing.expect(gs.removeMember(a2));
    try testing.expectEqual(@as(u32, 2), gs.member_count);
    try testing.expect(gs.members[0].address.eql(a1));
    try testing.expect(gs.members[1].address.eql(a3));

    // Remove non-existent.
    try testing.expect(!gs.removeMember(a2));
    try testing.expectEqual(@as(u32, 2), gs.member_count);
}

test "MulticastGroupStatus: pushTx and removeTx" {
    var gs = MulticastGroupStatus.init();

    var om1 = OutboundMulticast.initEmpty();
    om1._timestamp = 1000;
    var om2 = OutboundMulticast.initEmpty();
    om2._timestamp = 2000;

    gs.pushTx(om1);
    gs.pushTx(om2);

    try testing.expectEqual(@as(u32, 2), gs.tx_queue_count);
    try testing.expectEqual(@as(u64, 1000), gs.tx_queue[0].timestamp());
    try testing.expectEqual(@as(u64, 2000), gs.tx_queue[1].timestamp());

    gs.removeTx(0);
    try testing.expectEqual(@as(u32, 1), gs.tx_queue_count);
    try testing.expectEqual(@as(u64, 2000), gs.tx_queue[0].timestamp());
}

test "MulticastGroupStatus: pushTx drops oldest when full" {
    var gs = MulticastGroupStatus.init();

    // Fill the queue.
    for (0..max_tx_queue_per_group) |i| {
        var om = OutboundMulticast.initEmpty();
        om._timestamp = @as(u64, @intCast(i)) * 1000;
        gs.pushTx(om);
    }
    try testing.expectEqual(max_tx_queue_per_group, gs.tx_queue_count);

    // Push one more — should drop the oldest (timestamp=0).
    var om_new = OutboundMulticast.initEmpty();
    om_new._timestamp = 99999;
    gs.pushTx(om_new);

    try testing.expectEqual(max_tx_queue_per_group, gs.tx_queue_count);
    // First element should now be timestamp=1000 (was index 1).
    try testing.expectEqual(@as(u64, 1000), gs.tx_queue[0].timestamp());
    // Last element should be the new one.
    try testing.expectEqual(@as(u64, 99999), gs.tx_queue[gs.tx_queue_count - 1].timestamp());
}

test "Multicaster: init and deinit" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    try testing.expectEqual(@as(u32, 0), mc.groups.count());
}

test "Multicaster: add creates group and member" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    const member = Address.init(0x1234567890);

    mc.add(null, 1000, 0xABCD, mg, member, null);

    try testing.expectEqual(@as(u32, 1), mc.groups.count());

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 1), gs.?.member_count);
    try testing.expect(gs.?.members[0].address.eql(member));
}

test "Multicaster: add skips self" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    // testGetMyAddress returns 0xAABBCCDDEE.
    const my_addr = Address.init(0xAABBCCDDEE);

    mc.add(null, 1000, 0xABCD, mg, my_addr, null);

    // Should not have been added.
    try testing.expectEqual(@as(u32, 0), mc.groups.count());
}

test "Multicaster: remove" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    const member = Address.init(0x1234567890);

    mc.add(null, 1000, 0xABCD, mg, member, null);
    mc.remove(0xABCD, mg, member);

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 0), gs.?.member_count);
}

test "Multicaster: addMultiple" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Build binary address array: two 5-byte addresses.
    var addrs: [10]u8 = undefined;
    // Address 0x0000000001 = 00 00 00 00 01
    addrs[0] = 0x00;
    addrs[1] = 0x00;
    addrs[2] = 0x00;
    addrs[3] = 0x00;
    addrs[4] = 0x01;
    // Address 0x0000000002 = 00 00 00 00 02
    addrs[5] = 0x00;
    addrs[6] = 0x00;
    addrs[7] = 0x00;
    addrs[8] = 0x00;
    addrs[9] = 0x02;

    mc.addMultiple(null, 1000, 0xABCD, mg, &addrs, 2, null);

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 2), gs.?.member_count);
}

test "Multicaster: gather appends addresses" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Add several members.
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000001), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000002), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000003), null);

    var buf: Buffer(packet_mod.max_packet_length) = .{};
    const querying = Address.init(0x9999999999);
    const added = mc.gather(querying, 0xABCD, mg, &buf, 10);

    // Should have added up to 3 members.
    try testing.expect(added > 0);
    try testing.expect(added <= 3);

    // Buffer should contain: 4 bytes totalKnown + 2 bytes added + N * 5 bytes.
    try testing.expectEqual(@as(u32, 4 + 2 + added * address_length), buf.size());

    // Verify totalKnown field.
    const total_known = buf.at(u32, 0) catch 0;
    try testing.expectEqual(@as(u32, 3), total_known);
}

test "Multicaster: gather excludes querying peer" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    const peer_addr = Address.init(0x0000000001);

    mc.add(null, 1000, 0xABCD, mg, peer_addr, null);

    var buf: Buffer(packet_mod.max_packet_length) = .{};
    const added = mc.gather(peer_addr, 0xABCD, mg, &buf, 10);

    // The only member is the querying peer, so nothing should be returned.
    try testing.expectEqual(@as(u32, 0), added);
}

test "Multicaster: gather with zero limit returns 0" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000001), null);

    var buf: Buffer(packet_mod.max_packet_length) = .{};
    const added = mc.gather(Address.init(0x9999999999), 0xABCD, mg, &buf, 0);

    try testing.expectEqual(@as(u32, 0), added);
}

test "Multicaster: getMembers returns in reverse order" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000001), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000002), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000003), null);

    var out: [10]Address = [_]Address{Address.zero()} ** 10;
    const count = mc.getMembers(0xABCD, mg, &out, 10);

    try testing.expectEqual(@as(u32, 3), count);
    // Reverse order: highest address first.
    try testing.expect(out[0].eql(Address.init(0x0000000003)));
    try testing.expect(out[1].eql(Address.init(0x0000000002)));
    try testing.expect(out[2].eql(Address.init(0x0000000001)));
}

test "Multicaster: getMembers respects limit" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000001), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000002), null);
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000003), null);

    var out: [10]Address = [_]Address{Address.zero()} ** 10;
    const count = mc.getMembers(0xABCD, mg, &out, 2);

    try testing.expectEqual(@as(u32, 2), count);
}

test "Multicaster: clean removes expired members" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Add member with old timestamp.
    mc.add(null, 100, 0xABCD, mg, Address.init(0x0000000001), null);
    // Add member with recent timestamp.
    mc.add(null, 1_000_000, 0xABCD, mg, Address.init(0x0000000002), null);

    // Clean with now = 1_000_000.
    // multicast_like_expire = 600000.
    // Member 1: 1_000_000 - 100 = 999900 >= 600000 -> expired.
    // Member 2: 1_000_000 - 1_000_000 = 0 < 600000 -> kept.
    mc.clean(1_000_000);

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 1), gs.?.member_count);
    try testing.expect(gs.?.members[0].address.eql(Address.init(0x0000000002)));
}

test "Multicaster: clean removes empty groups" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Add member with old timestamp.
    mc.add(null, 100, 0xABCD, mg, Address.init(0x0000000001), null);

    // Clean long after expiry — should remove member and then the group.
    mc.clean(1_000_000);

    try testing.expectEqual(@as(u32, 0), mc.groups.count());
}

test "Multicaster: clean keeps group with pending tx" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Add member with old timestamp.
    mc.add(null, 100, 0xABCD, mg, Address.init(0x0000000001), null);

    // Add a pending tx that hasn't expired yet (timestamp close to now).
    var om = OutboundMulticast.initEmpty();
    om._timestamp = 999_000;
    om._limit = 10;
    mc.queueOutbound(0xABCD, mg, om);

    // Clean at now = 1_000_000.
    // Member expired (1_000_000 - 100 = 999900 >= 600000).
    // But tx not expired (1_000_000 - 999_000 = 1000 < 5000).
    mc.clean(1_000_000);

    // Group should still exist (has pending tx).
    try testing.expectEqual(@as(u32, 1), mc.groups.count());
    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 0), gs.?.member_count);
    try testing.expectEqual(@as(u32, 1), gs.?.tx_queue_count);
}

test "Multicaster: clean removes expired tx entries" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // Add a current member so group isn't empty.
    mc.add(null, 999_000, 0xABCD, mg, Address.init(0x0000000001), null);

    // Add an expired tx.
    var om = OutboundMulticast.initEmpty();
    om._timestamp = 100;
    om._limit = 10;
    mc.queueOutbound(0xABCD, mg, om);

    mc.clean(1_000_000);

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    try testing.expectEqual(@as(u32, 0), gs.?.tx_queue_count);
}

test "Multicaster: add drains tx queue for new member" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    // First add a member so the group exists.
    mc.add(null, 1000, 0xABCD, mg, Address.init(0x0000000001), null);

    // Queue an outbound multicast with limit 1.
    var om = OutboundMulticast.initEmpty();
    om._timestamp = 999_000;
    om._limit = 1;
    mc.queueOutbound(0xABCD, mg, om);

    // Track sends.
    const Ctx = struct {
        var send_count: u32 = 0;
        fn sendFn(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: *const OutboundMulticast,
            _: Address,
        ) void {
            send_count += 1;
        }
    };
    Ctx.send_count = 0;

    // Add new member with send callback — should drain the queue.
    mc.add(null, 999_000, 0xABCD, mg, Address.init(0x0000000002), Ctx.sendFn);

    // The tx entry had limit 1, so it should have been sent once and removed.
    try testing.expectEqual(@as(u32, 1), Ctx.send_count);

    const gs = mc.groups.get(Key.init(0xABCD, mg));
    try testing.expect(gs != null);
    // Tx queue should be empty after the send hit the limit.
    try testing.expectEqual(@as(u32, 0), gs.?.tx_queue_count);
}

test "Multicaster: gather returns 0 for unknown group" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);
    var buf: Buffer(packet_mod.max_packet_length) = .{};
    const added = mc.gather(Address.init(0x9999999999), 0xABCD, mg, &buf, 10);

    try testing.expectEqual(@as(u32, 0), added);
    // Should still have written totalKnown(0) and added(0) headers.
    try testing.expectEqual(@as(u32, 6), buf.size());
}

test "Multicaster: multiple groups on same network" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0xFFFFFF000001), 1);
    const mg2 = MulticastGroup.init(MAC.init(0xFFFFFF000002), 2);

    mc.add(null, 1000, 0xABCD, mg1, Address.init(0x0000000001), null);
    mc.add(null, 1000, 0xABCD, mg2, Address.init(0x0000000002), null);

    try testing.expectEqual(@as(u32, 2), mc.groups.count());

    var out1: [10]Address = [_]Address{Address.zero()} ** 10;
    var out2: [10]Address = [_]Address{Address.zero()} ** 10;

    const c1 = mc.getMembers(0xABCD, mg1, &out1, 10);
    const c2 = mc.getMembers(0xABCD, mg2, &out2, 10);

    try testing.expectEqual(@as(u32, 1), c1);
    try testing.expectEqual(@as(u32, 1), c2);
    try testing.expect(out1[0].eql(Address.init(0x0000000001)));
    try testing.expect(out2[0].eql(Address.init(0x0000000002)));
}

test "Multicaster: same group on different networks" {
    var mc = Multicaster.init(testing.allocator, testCallbacks());
    defer mc.deinit();

    const mg = MulticastGroup.init(MAC.init(0xFFFFFF000001), 42);

    mc.add(null, 1000, 0x1111, mg, Address.init(0x0000000001), null);
    mc.add(null, 1000, 0x2222, mg, Address.init(0x0000000002), null);

    try testing.expectEqual(@as(u32, 2), mc.groups.count());

    var out1: [10]Address = [_]Address{Address.zero()} ** 10;
    var out2: [10]Address = [_]Address{Address.zero()} ** 10;

    const c1 = mc.getMembers(0x1111, mg, &out1, 10);
    const c2 = mc.getMembers(0x2222, mg, &out2, 10);

    try testing.expectEqual(@as(u32, 1), c1);
    try testing.expectEqual(@as(u32, 1), c2);
    try testing.expect(out1[0].eql(Address.init(0x0000000001)));
    try testing.expect(out2[0].eql(Address.init(0x0000000002)));
}
