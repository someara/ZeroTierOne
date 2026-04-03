/// Tracks changes to this peer's real-world external addresses.
///
/// Converted from `node/SelfAwareness.hpp` and `node/SelfAwareness.cpp`.
/// When trusted remote peers report our external IP address, this module
/// detects changes and triggers path resets within the affected scope so
/// that the node can re-establish connectivity through the new address.
///
/// Uses a fixed-size table (no heap allocation) to store external surface
/// entries. Each entry maps a composite key (reporter, local socket,
/// reporter physical address, scope) to our reported surface address and
/// timestamp.
///
/// Cross-module calls to Trace and Topology are modeled as configurable
/// callbacks. These will be wired to real subsystems during Node init
/// (Phase 6).
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const constants = @import("constants.zig");
const InetAddress = @import("inet_address.zig").InetAddress;
const IpScope = @import("inet_address.zig").IpScope;
const Mutex = @import("mutex.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Maximum number of surface entries. Each unique (reporter, socket,
/// reporter-phys, scope) tuple occupies one slot. In practice the
/// number of active reporters is bounded by the number of roots plus
/// a small number of direct peers, so 128 is generous.
const max_entries = 128;

/// Maximum number of unique addresses returned by `whoami()`.
pub const max_whoami_addresses = 32;

/// Timeout for stale entries (ms). Matches ZT_SELFAWARENESS_ENTRY_TIMEOUT.
const entry_timeout: i64 = constants.selfawareness_entry_timeout;

// ── Callback types ────────────────────────────────────────────────

/// Called when external address change is detected and paths within a
/// scope need to be reset.
///
/// Parameters:
///   ctx         - opaque context (typically RuntimeEnvironment)
///   t_ptr       - thread pointer (passed through to subsystems)
///   reporter    - ZeroTier address of the peer that reported the change
///   reporter_phys - physical address of the reporter
///   my_phys     - our new external address as reported
///   scope       - IP scope of the address change
pub const ResettingPathsCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    reporter: Address,
    reporter_phys: *const InetAddress,
    my_phys: *const InetAddress,
    scope: IpScope,
) void;

/// Called to reset paths on all peers within a given scope and
/// address family. This corresponds to `Topology::eachPeer` with the
/// `_ResetWithinScope` functor in the C++ implementation.
///
/// Parameters:
///   ctx    - opaque context (typically RuntimeEnvironment)
///   t_ptr  - thread pointer
///   scope  - IP scope to reset
///   family - address family (AF_INET or AF_INET6) as sa_family_t
///   now    - current timestamp
pub const ResetPeersInScopeCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    scope: IpScope,
    af: std.c.sa_family_t,
    now: i64,
) void;

// ── PhySurfaceKey ─────────────────────────────────────────────────

/// Composite key identifying a particular reporter + local socket +
/// reporter physical address + scope combination.
const PhySurfaceKey = struct {
    reporter: Address,
    received_on_local_socket: i64,
    reporter_physical_address: InetAddress,
    scope: IpScope,

    fn eql(self: PhySurfaceKey, other: PhySurfaceKey) bool {
        return self.reporter.eql(other.reporter) and
            self.received_on_local_socket == other.received_on_local_socket and
            self.reporter_physical_address.eql(&other.reporter_physical_address) and
            self.scope == other.scope;
    }
};

// ── PhySurfaceEntry ───────────────────────────────────────────────

/// Value stored for each key: our reported external address, timestamp,
/// and whether the reporter is trusted.
const PhySurfaceEntry = struct {
    my_surface: InetAddress,
    ts: i64,
    trusted: bool,

    fn init() PhySurfaceEntry {
        return .{
            .my_surface = InetAddress.zero(),
            .ts = 0,
            .trusted = false,
        };
    }
};

// ── TableSlot ─────────────────────────────────────────────────────

/// A single slot in the fixed-size surface table.
const TableSlot = struct {
    key: PhySurfaceKey,
    value: PhySurfaceEntry,
    occupied: bool,
};

// ── SelfAwareness ─────────────────────────────────────────────────

/// Tracks changes to this peer's real-world external addresses.
///
/// Thread-safe: all public methods acquire the internal mutex.
pub const SelfAwareness = struct {
    _table: [max_entries]TableSlot,
    _count: u32,
    _m: Mutex,

    // Callbacks (set during Node init)
    _resetting_paths_fn: ?ResettingPathsCallback,
    _reset_peers_fn: ?ResetPeersInScopeCallback,
    _cb_ctx: ?*anyopaque,

    // ── Construction ──────────────────────────────────────────

    /// Create a new SelfAwareness instance with no entries.
    pub fn init() SelfAwareness {
        return .{
            ._table = [_]TableSlot{.{
                .key = .{
                    .reporter = Address.zero(),
                    .received_on_local_socket = 0,
                    .reporter_physical_address = InetAddress.zero(),
                    .scope = .none,
                },
                .value = PhySurfaceEntry.init(),
                .occupied = false,
            }} ** max_entries,
            ._count = 0,
            ._m = .{},
            ._resetting_paths_fn = null,
            ._reset_peers_fn = null,
            ._cb_ctx = null,
        };
    }

    /// Set the callbacks for path reset notifications.
    pub fn setCallbacks(
        self: *SelfAwareness,
        resetting_fn: ResettingPathsCallback,
        reset_peers_fn: ResetPeersInScopeCallback,
        ctx: ?*anyopaque,
    ) void {
        self._resetting_paths_fn = resetting_fn;
        self._reset_peers_fn = reset_peers_fn;
        self._cb_ctx = ctx;
    }

    // ── Core methods ─────────────────────────────────────────

    /// Called when a trusted remote peer informs us of our external
    /// network address.
    ///
    /// If the reported address differs from what we previously knew (and
    /// the reporter is trusted and the entry is fresh), this triggers:
    ///   1. A "resetting paths in scope" trace event
    ///   2. Erasure of all other entries in the same scope (anti-thrash)
    ///   3. A reset of all peer paths in the affected scope/family
    ///
    /// Otherwise the entry is simply updated.
    pub fn iam(
        self: *SelfAwareness,
        t_ptr: ?*anyopaque,
        reporter: Address,
        received_on_local_socket: i64,
        reporter_physical_address: *const InetAddress,
        my_physical_address: *const InetAddress,
        trusted: bool,
        now: i64,
    ) void {
        const scope = my_physical_address.ipScope();

        // Ignore if scope mismatch or non-routable scopes
        if (scope != reporter_physical_address.ipScope() or
            scope == .none or
            scope == .loopback or
            scope == .multicast)
        {
            return;
        }

        self._m.lock();
        defer self._m.unlock();

        const key = PhySurfaceKey{
            .reporter = reporter,
            .received_on_local_socket = received_on_local_socket,
            .reporter_physical_address = reporter_physical_address.*,
            .scope = scope,
        };

        // Find existing entry or allocate a new slot
        const slot_idx = self.findOrInsert(key);
        if (slot_idx == null) {
            // Table full — cannot track this reporter. In practice
            // this shouldn't happen with 128 slots.
            return;
        }
        const idx = slot_idx.?;

        const entry = &self._table[idx].value;
        const old_ts = entry.ts;
        const old_surface_differs = !entry.my_surface.ipsEqual(my_physical_address);

        if (trusted and (now - old_ts) < entry_timeout and old_surface_differs) {
            // Address changed! Trusted peer reports different surface.

            // Notify trace
            if (self._resetting_paths_fn) |cb| {
                cb(
                    self._cb_ctx,
                    t_ptr,
                    reporter,
                    reporter_physical_address,
                    my_physical_address,
                    scope,
                );
            }

            // Update this entry
            entry.my_surface = my_physical_address.*;
            entry.ts = now;
            entry.trusted = trusted;

            // Erase all entries in this scope NOT from this reporter
            // physical address to prevent thrashing from multiple reports.
            // Must iterate by index since we modify the table.
            self.eraseOtherEntriesInScope(reporter_physical_address, scope);

            // Reset all paths within this scope and address family
            if (self._reset_peers_fn) |cb| {
                cb(
                    self._cb_ctx,
                    t_ptr,
                    scope,
                    my_physical_address.family(),
                    now,
                );
            }
        } else {
            // No change (or first report / untrusted) — just update DB
            entry.my_surface = my_physical_address.*;
            entry.ts = now;
            entry.trusted = trusted;
        }
    }

    /// Return all known external surface addresses reported by peers.
    ///
    /// Returns a fixed-size array and a count. Duplicates are removed.
    pub fn whoami(self: *SelfAwareness) struct { addrs: [max_whoami_addresses]InetAddress, count: u32 } {
        var result: [max_whoami_addresses]InetAddress = undefined;
        @memset(mem.sliceAsBytes(&result), 0);
        var count: u32 = 0;

        self._m.lock();
        defer self._m.unlock();

        for (&self._table) |*slot| {
            if (!slot.occupied) continue;
            if (count >= max_whoami_addresses) break;

            // Check for duplicate
            var found = false;
            for (result[0..count]) |*existing| {
                if (existing.eql(&slot.value.my_surface)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                result[count] = slot.value.my_surface;
                count += 1;
            }
        }

        return .{ .addrs = result, .count = count };
    }

    /// Garbage-collect entries older than `entry_timeout`.
    pub fn clean(self: *SelfAwareness, now: i64) void {
        self._m.lock();
        defer self._m.unlock();

        for (&self._table) |*slot| {
            if (slot.occupied and (now - slot.value.ts) >= entry_timeout) {
                slot.occupied = false;
                self._count -= 1;
            }
        }
    }

    /// Return the number of active entries.
    pub fn entryCount(self: *SelfAwareness) u32 {
        self._m.lock();
        defer self._m.unlock();
        return self._count;
    }

    // ── Private helpers ──────────────────────────────────────

    /// Find an existing slot matching `key`, or insert into an empty slot.
    /// Returns the index, or null if the table is full.
    fn findOrInsert(self: *SelfAwareness, key: PhySurfaceKey) ?usize {
        var first_empty: ?usize = null;

        for (&self._table, 0..) |*slot, i| {
            if (slot.occupied) {
                if (slot.key.eql(key)) return i;
            } else if (first_empty == null) {
                first_empty = i;
            }
        }

        // Not found — insert into first empty slot
        if (first_empty) |idx| {
            self._table[idx].key = key;
            self._table[idx].value = PhySurfaceEntry.init();
            self._table[idx].occupied = true;
            self._count += 1;
            return idx;
        }

        return null; // Table full
    }

    /// Erase all entries in the given scope whose reporter physical address
    /// does NOT match `keep_reporter_phys`. Called after an address change
    /// to prevent thrashing from multiple reporters.
    fn eraseOtherEntriesInScope(
        self: *SelfAwareness,
        keep_reporter_phys: *const InetAddress,
        scope: IpScope,
    ) void {
        for (&self._table) |*slot| {
            if (slot.occupied and
                slot.key.scope == scope and
                !slot.key.reporter_physical_address.eql(keep_reporter_phys))
            {
                slot.occupied = false;
                self._count -= 1;
            }
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "SelfAwareness: init creates empty state" {
    var sa = SelfAwareness.init();
    try testing.expectEqual(@as(u32, 0), sa.entryCount());
    const result = sa.whoami();
    try testing.expectEqual(@as(u32, 0), result.count);
}

test "SelfAwareness: iam adds entry" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);

    try testing.expectEqual(@as(u32, 1), sa.entryCount());
    const result = sa.whoami();
    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(result.addrs[0].ipsEqual(&my_phys));
}

test "SelfAwareness: iam ignores scope mismatch" {
    var sa = SelfAwareness.init();

    // Reporter claims we have a global address, but reporter's own address
    // is loopback — scopes don't match, should be ignored.
    const reporter = Address.init(0x1111111111);
    const reporter_phys = InetAddress.initV4(.{ 127, 0, 0, 1 }, 9993); // loopback
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993); // global

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);

    try testing.expectEqual(@as(u32, 0), sa.entryCount());
}

test "SelfAwareness: iam ignores loopback scope" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1111111111);
    const reporter_phys = InetAddress.initV4(.{ 127, 0, 0, 1 }, 9993);
    const my_phys = InetAddress.initV4(.{ 127, 0, 0, 2 }, 9993);

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);

    try testing.expectEqual(@as(u32, 0), sa.entryCount());
}

test "SelfAwareness: iam update same reporter" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys1 = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);
    const my_phys2 = InetAddress.initV4(.{ 5, 6, 7, 9 }, 9993);

    // First report
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys1, true, 1000);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());

    // Second report from same reporter — should update, not add
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys2, true, 2000);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());

    const result = sa.whoami();
    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(result.addrs[0].ipsEqual(&my_phys2));
}

test "SelfAwareness: iam address change triggers callbacks" {
    const Ctx = struct {
        var resetting_called: bool = false;
        var reset_peers_called: bool = false;
        var reset_scope: IpScope = .none;

        fn resettingPaths(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: Address,
            _: *const InetAddress,
            _: *const InetAddress,
            scope: IpScope,
        ) void {
            resetting_called = true;
            reset_scope = scope;
        }

        fn resetPeers(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: IpScope,
            _: std.c.sa_family_t,
            _: i64,
        ) void {
            reset_peers_called = true;
        }
    };

    Ctx.resetting_called = false;
    Ctx.reset_peers_called = false;
    Ctx.reset_scope = .none;

    var sa = SelfAwareness.init();
    sa.setCallbacks(&Ctx.resettingPaths, &Ctx.resetPeers, null);

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys1 = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);
    // Use a global-scope IP (not 10.x.x.x which is private / RFC 1918)
    const my_phys2 = InetAddress.initV4(.{ 50, 60, 70, 80 }, 9993);

    // First report — no change, callbacks should NOT fire
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys1, true, 1000);
    try testing.expect(!Ctx.resetting_called);

    // Second report with different address — trusted, within timeout
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys2, true, 2000);
    try testing.expect(Ctx.resetting_called);
    try testing.expect(Ctx.reset_peers_called);
    try testing.expect(Ctx.reset_scope == .global);
}

test "SelfAwareness: iam address change erases other scope entries" {
    var sa = SelfAwareness.init();

    const reporter1 = Address.init(0x1111111111);
    const reporter2 = Address.init(0x2222222222);
    const reporter_phys1 = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const reporter_phys2 = InetAddress.initV4(.{ 9, 8, 7, 6 }, 9993);
    const my_phys1 = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);
    // Use a global-scope IP (not 10.x.x.x which is private / RFC 1918)
    const my_phys2 = InetAddress.initV4(.{ 50, 60, 70, 80 }, 9993);

    // Reporter 1 says we're at my_phys1
    sa.iam(null, reporter1, 0, &reporter_phys1, &my_phys1, true, 1000);
    // Reporter 2 says we're at my_phys1 (same)
    sa.iam(null, reporter2, 0, &reporter_phys2, &my_phys1, true, 1000);
    try testing.expectEqual(@as(u32, 2), sa.entryCount());

    // Reporter 1 now says address changed — should erase reporter2's entry
    // (different reporter_physical_address, same scope)
    sa.iam(null, reporter1, 0, &reporter_phys1, &my_phys2, true, 2000);

    // Reporter2's entry should be erased (different reporter phys addr)
    try testing.expectEqual(@as(u32, 1), sa.entryCount());
}

test "SelfAwareness: iam no callback on untrusted change" {
    const Ctx = struct {
        var called: bool = false;

        fn resettingPaths(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: Address,
            _: *const InetAddress,
            _: *const InetAddress,
            _: IpScope,
        ) void {
            called = true;
        }

        fn resetPeers(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: IpScope,
            _: std.c.sa_family_t,
            _: i64,
        ) void {}
    };

    Ctx.called = false;

    var sa = SelfAwareness.init();
    sa.setCallbacks(&Ctx.resettingPaths, &Ctx.resetPeers, null);

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys1 = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);
    // Use a global-scope IP (not 10.x.x.x which is private / RFC 1918)
    const my_phys2 = InetAddress.initV4(.{ 50, 60, 70, 80 }, 9993);

    // First report (untrusted)
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys1, false, 1000);
    // Second report with different address, but still untrusted
    sa.iam(null, reporter, 0, &reporter_phys, &my_phys2, false, 2000);

    // Untrusted changes should NOT trigger callbacks
    try testing.expect(!Ctx.called);
}

test "SelfAwareness: whoami deduplicates addresses" {
    var sa = SelfAwareness.init();

    const reporter1 = Address.init(0x1111111111);
    const reporter2 = Address.init(0x2222222222);
    const reporter_phys1 = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const reporter_phys2 = InetAddress.initV4(.{ 9, 8, 7, 6 }, 9993);
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    // Two reporters both say we have the same address
    sa.iam(null, reporter1, 0, &reporter_phys1, &my_phys, true, 1000);
    sa.iam(null, reporter2, 0, &reporter_phys2, &my_phys, true, 1000);
    try testing.expectEqual(@as(u32, 2), sa.entryCount());

    // whoami should deduplicate
    const result = sa.whoami();
    try testing.expectEqual(@as(u32, 1), result.count);
}

test "SelfAwareness: clean removes stale entries" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());

    // Clean with time far in the future (past timeout)
    sa.clean(1000 + entry_timeout + 1);
    try testing.expectEqual(@as(u32, 0), sa.entryCount());
}

test "SelfAwareness: clean preserves fresh entries" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());

    // Clean with time just before timeout — entry should survive
    sa.clean(1000 + entry_timeout - 1);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());
}

test "SelfAwareness: different local sockets create separate entries" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const my_phys = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    // Same reporter but different local sockets
    sa.iam(null, reporter, 1, &reporter_phys, &my_phys, true, 1000);
    sa.iam(null, reporter, 2, &reporter_phys, &my_phys, true, 1000);

    try testing.expectEqual(@as(u32, 2), sa.entryCount());
}

test "SelfAwareness: IPv6 addresses work" {
    var sa = SelfAwareness.init();

    const reporter = Address.init(0x1234567890);
    const reporter_phys = InetAddress.initV6(
        .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        9993,
    );
    const my_phys = InetAddress.initV6(
        .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 },
        9993,
    );

    sa.iam(null, reporter, 0, &reporter_phys, &my_phys, true, 1000);
    try testing.expectEqual(@as(u32, 1), sa.entryCount());

    const result = sa.whoami();
    try testing.expectEqual(@as(u32, 1), result.count);
    try testing.expect(result.addrs[0].ipsEqual(&my_phys));
}

test "SelfAwareness: setCallbacks" {
    const Ctx = struct {
        fn resettingPaths(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: Address,
            _: *const InetAddress,
            _: *const InetAddress,
            _: IpScope,
        ) void {}
        fn resetPeers(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: IpScope,
            _: std.c.sa_family_t,
            _: i64,
        ) void {}
    };

    var sa = SelfAwareness.init();
    try testing.expect(sa._resetting_paths_fn == null);
    try testing.expect(sa._reset_peers_fn == null);

    sa.setCallbacks(&Ctx.resettingPaths, &Ctx.resetPeers, null);
    try testing.expect(sa._resetting_paths_fn != null);
    try testing.expect(sa._reset_peers_fn != null);
}
