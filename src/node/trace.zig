/// Remote tracing and trace logging handler.
///
/// Converted from `node/Trace.hpp` and `node/Trace.cpp`. This module
/// provides the `Level` enum, `RuleResultLog` data type (used by network
/// filter evaluation), and a `Trace` struct with a callback-based dispatch
/// interface for trace events.
///
/// In the C++ implementation, Trace methods build Dictionary messages and
/// send them via `RR->sw->send()`. Since Switch is not yet converted
/// (Phase 6), we model the dispatch as a configurable callback interface.
/// The actual methods that construct trace event dictionaries will be
/// implemented when Switch and Node are available.
///
/// No heap allocation is performed by this struct itself.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const constants = @import("constants.zig");
const c_api = constants.c_api;
const InetAddress = @import("inet_address.zig").InetAddress;
const IpScope = @import("inet_address.zig").IpScope;
const Mutex = @import("mutex.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Maximum size of a remote trace message (from C API).
pub const max_remote_trace_size: u32 = c_api.ZT_MAX_REMOTE_TRACE_SIZE;

/// Maximum number of network rules (from C API).
pub const max_network_rules: u32 = c_api.ZT_MAX_NETWORK_RULES;

// ── Level ─────────────────────────────────────────────────────────

/// Trace verbosity level.
///
/// Values match the C++ `Trace::Level` enum.
pub const Level = enum(u8) {
    /// Normal operational messages.
    normal = 0,

    /// Verbose diagnostic output.
    verbose = 10,

    /// Network filter rule evaluation traces.
    rules = 15,

    /// Debug-level output.
    debug = 20,

    /// Maximum verbosity (insane amount of output).
    insane = 30,

    /// Compare levels: returns true if `self` is at least as verbose as `required`.
    pub fn atLeast(self: Level, required: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(required);
    }
};

// ── RuleResultLog ─────────────────────────────────────────────────

/// Filter rule evaluation result log.
///
/// Each rule in a rule set gets a four-bit log entry. A log entry of
/// zero means not evaluated. Otherwise each four-bit log entry contains
/// two two-bit values: bits [3:2] = (thisRuleMatches + 1), bits [1:0] =
/// (thisSetMatches + 1). Values of 01 mean 'false', 10 mean 'true',
/// and 00 means 'not evaluated'.
pub const RuleResultLog = struct {
    _l: [max_network_rules / 2]u8,

    /// Create a zeroed rule result log.
    pub fn init() RuleResultLog {
        return .{ ._l = [_]u8{0} ** (max_network_rules / 2) };
    }

    /// Log the result of evaluating rule number `rn`.
    ///
    /// `this_rule_matches`: 0 for false, 1 for true.
    /// `this_set_matches`: 0 for false, 1 for true.
    pub fn log(self: *RuleResultLog, rn: u32, this_rule_matches: u8, this_set_matches: u8) void {
        if (rn >= max_network_rules) return;
        const idx = rn >> 1;
        const shift: u3 = @intCast((rn & 1) << 2);
        const entry: u8 = (((this_rule_matches + 1) << 2) | (this_set_matches + 1));
        self._l[idx] |= entry << shift;
    }

    /// Log a skipped rule (no rule match info, only set match).
    pub fn logSkipped(self: *RuleResultLog, rn: u32, this_set_matches: u8) void {
        if (rn >= max_network_rules) return;
        const idx = rn >> 1;
        const shift: u3 = @intCast((rn & 1) << 2);
        self._l[idx] |= (this_set_matches + 1) << shift;
    }

    /// Clear the entire log.
    pub fn clear(self: *RuleResultLog) void {
        @memset(&self._l, 0);
    }

    /// Return a const pointer to the raw log data.
    pub fn data(self: *const RuleResultLog) []const u8 {
        return &self._l;
    }

    /// Return the size of the log data in bytes.
    pub fn sizeBytes() u32 {
        return max_network_rules / 2;
    }
};

// ── NetworkTarget ─────────────────────────────────────────────────

/// A per-network trace target (address + verbosity level).
pub const NetworkTarget = struct {
    dest: Address,
    lvl: Level,
};

// ── TraceCallback ─────────────────────────────────────────────────

/// Callback for sending a trace event dictionary as a VERB_REMOTE_TRACE
/// packet to a destination address.
///
/// Parameters: context, thread_ptr, dictionary_data (null-terminated),
///             destination address.
///
/// This callback will be wired to Switch.send() when Phase 6 is complete.
pub const SendCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    dict_data: [*]const u8,
    dict_len: u32,
    dest: Address,
) void;

// ── Trace ─────────────────────────────────────────────────────────

/// Remote tracing and trace logging handler.
///
/// Holds the global trace target and per-network trace targets.
/// Methods that dispatch trace events are stubs during Phase 4; they
/// will be fully implemented when Switch and Node are available (Phase 6).
pub const Trace = struct {
    /// Global trace target address (zero = disabled).
    _global_target: Address,

    /// Global trace verbosity level.
    _global_level: Level,

    /// Per-network trace targets. Fixed-size array indexed by a simple
    /// linear scan (networks rarely exceed a few dozen). Each entry maps
    /// a network ID to a (destination, level) pair.
    ///
    /// In the C++ implementation this uses a Hashtable; for the Zig
    /// conversion we use a fixed array to avoid heap allocation in the
    /// Trace struct itself. 64 slots matches ZT_MAX_PEER_NETWORK_PATHS.
    _by_net: [max_by_net_entries]ByNetEntry,
    _by_net_count: u32,

    /// Mutex protecting `_by_net` and `_by_net_count`.
    _by_net_m: Mutex,

    /// Optional send callback (set during Node init).
    _send_fn: ?SendCallback,
    _send_ctx: ?*anyopaque,

    const max_by_net_entries = 64;

    const ByNetEntry = struct {
        network_id: u64,
        target: NetworkTarget,
    };

    // ── Construction ──────────────────────────────────────────

    /// Create a new Trace handler with no targets configured.
    pub fn init() Trace {
        return .{
            ._global_target = Address.init(0),
            ._global_level = .normal,
            ._by_net = [_]ByNetEntry{.{
                .network_id = 0,
                .target = .{ .dest = Address.init(0), .lvl = .normal },
            }} ** max_by_net_entries,
            ._by_net_count = 0,
            ._by_net_m = .{},
            ._send_fn = null,
            ._send_ctx = null,
        };
    }

    /// Set the send callback.
    pub fn setSendCallback(self: *Trace, send_fn: SendCallback, ctx: ?*anyopaque) void {
        self._send_fn = send_fn;
        self._send_ctx = ctx;
    }

    // ── Configuration ────────────────────────────────────────

    /// Set the global trace target and level.
    pub fn setGlobalTarget(self: *Trace, target: Address, lvl: Level) void {
        self._global_target = target;
        self._global_level = lvl;
    }

    /// Clear all per-network trace targets and repopulate from the
    /// given list. This is called from `updateMemoizedSettings()`.
    pub fn setNetworkTargets(self: *Trace, targets: []const ByNetEntry) void {
        self._by_net_m.lock();
        defer self._by_net_m.unlock();

        self._by_net_count = 0;
        for (targets) |entry| {
            if (self._by_net_count >= max_by_net_entries) break;
            self._by_net[@intCast(self._by_net_count)] = entry;
            self._by_net_count += 1;
        }
    }

    /// Look up the trace target for a specific network.
    pub fn getNetworkTarget(self: *Trace, network_id: u64) ?NetworkTarget {
        self._by_net_m.lock();
        defer self._by_net_m.unlock();

        const count = self._by_net_count;
        for (self._by_net[0..count]) |entry| {
            if (entry.network_id == network_id) {
                return entry.target;
            }
        }
        return null;
    }

    /// Returns true if any trace target is configured (global or per-network).
    pub fn hasAnyTarget(self: *Trace) bool {
        if (self._global_target.isSet()) return true;
        return self._by_net_count > 0;
    }

    // ── Event stubs ──────────────────────────────────────────
    //
    // These methods correspond to the C++ Trace methods. During Phase 4
    // they are minimal stubs. Full implementation (building Dictionary
    // messages and dispatching via _send) will be added in Phase 6.

    /// Record a "resetting paths in scope" event.
    pub fn resettingPathsInScope(
        self: *Trace,
        t_ptr: ?*anyopaque,
        reporter: Address,
        reporter_phys: *const InetAddress,
        my_phys: *const InetAddress,
        scope: IpScope,
    ) void {
        _ = reporter_phys;
        _ = my_phys;
        _ = scope;
        _ = reporter;
        _ = t_ptr;
        // Stub: will build Dictionary and send in Phase 6
        _ = self;
    }

    /// Record a bond state message.
    pub fn bondStateMessage(self: *Trace, t_ptr: ?*anyopaque, msg: [*:0]const u8) void {
        _ = self;
        _ = t_ptr;
        _ = msg;
    }

    // ── Private helpers ──────────────────────────────────────

    /// Internal: send a trace dictionary to a destination.
    fn sendTrace(self: *Trace, t_ptr: ?*anyopaque, dict_data: []const u8, dest: Address) void {
        if (self._send_fn) |send_fn| {
            send_fn(self._send_ctx, t_ptr, dict_data.ptr, @intCast(dict_data.len), dest);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "Level: enum values match C++" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Level.normal));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(Level.verbose));
    try testing.expectEqual(@as(u8, 15), @intFromEnum(Level.rules));
    try testing.expectEqual(@as(u8, 20), @intFromEnum(Level.debug));
    try testing.expectEqual(@as(u8, 30), @intFromEnum(Level.insane));
}

test "Level: atLeast" {
    try testing.expect(Level.insane.atLeast(.normal));
    try testing.expect(Level.insane.atLeast(.insane));
    try testing.expect(Level.normal.atLeast(.normal));
    try testing.expect(!Level.normal.atLeast(.verbose));
    try testing.expect(!Level.rules.atLeast(.debug));
    try testing.expect(Level.debug.atLeast(.rules));
}

test "RuleResultLog: init is zeroed" {
    const log_data = RuleResultLog.init();
    for (log_data.data()) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
    try testing.expectEqual(@as(u32, max_network_rules / 2), RuleResultLog.sizeBytes());
}

test "RuleResultLog: log and logSkipped" {
    var rlog = RuleResultLog.init();

    // Log rule 0: rule matches (1), set matches (1)
    // entry = ((1+1) << 2) | (1+1) = (2 << 2) | 2 = 10 = 0x0a
    // rule 0 is even, so shift = 0 -> byte[0] = 0x0a
    rlog.log(0, 1, 1);
    try testing.expectEqual(@as(u8, 0x0a), rlog.data()[0]);

    // Log rule 1: rule doesn't match (0), set matches (1)
    // entry = ((0+1) << 2) | (1+1) = (1 << 2) | 2 = 6 = 0x06
    // rule 1 is odd, so shift = 4 -> byte[0] |= 0x60
    rlog.log(1, 0, 1);
    try testing.expectEqual(@as(u8, 0x6a), rlog.data()[0]);

    // logSkipped for rule 2: set doesn't match (0)
    // entry = (0+1) = 1
    // rule 2 is even, shift = 0 -> byte[1] = 0x01
    rlog.logSkipped(2, 0);
    try testing.expectEqual(@as(u8, 0x01), rlog.data()[1]);

    // Clear should zero everything
    rlog.clear();
    for (rlog.data()) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "RuleResultLog: log at boundary" {
    var rlog = RuleResultLog.init();

    // Log at last valid rule (max_network_rules - 1)
    rlog.log(max_network_rules - 1, 1, 0);
    const last_idx = (max_network_rules - 1) >> 1;
    try testing.expect(rlog.data()[last_idx] != 0);

    // Log at invalid rule (>= max) should be a no-op
    rlog.clear();
    rlog.log(max_network_rules, 1, 1);
    for (rlog.data()) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "Trace: init" {
    var t = Trace.init();
    try testing.expect(!t._global_target.isSet());
    try testing.expectEqual(Level.normal, t._global_level);
    try testing.expectEqual(@as(u32, 0), t._by_net_count);
    try testing.expect(!t.hasAnyTarget());
    _ = &t;
}

test "Trace: setGlobalTarget" {
    var t = Trace.init();
    t.setGlobalTarget(Address.init(0x1234567890), .debug);
    try testing.expect(t._global_target.isSet());
    try testing.expectEqual(Level.debug, t._global_level);
    try testing.expect(t.hasAnyTarget());
}

test "Trace: setNetworkTargets and getNetworkTarget" {
    var t = Trace.init();
    const targets = [_]Trace.ByNetEntry{
        .{ .network_id = 0xdeadbeef, .target = .{ .dest = Address.init(0x1111111111), .lvl = .verbose } },
        .{ .network_id = 0xcafebabe, .target = .{ .dest = Address.init(0x2222222222), .lvl = .rules } },
    };
    t.setNetworkTargets(&targets);
    try testing.expectEqual(@as(u32, 2), t._by_net_count);
    try testing.expect(t.hasAnyTarget());

    const nt1 = t.getNetworkTarget(0xdeadbeef);
    try testing.expect(nt1 != null);
    try testing.expectEqual(Level.verbose, nt1.?.lvl);

    const nt2 = t.getNetworkTarget(0xcafebabe);
    try testing.expect(nt2 != null);
    try testing.expectEqual(Level.rules, nt2.?.lvl);

    // Not found
    try testing.expect(t.getNetworkTarget(0x99999999) == null);
}

test "Trace: resettingPathsInScope stub" {
    var t = Trace.init();
    const addr = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    // Should not crash
    t.resettingPathsInScope(null, Address.init(0), &addr, &addr, .global);
}

test "Trace: sendTrace with null callback" {
    var t = Trace.init();
    // Should be a no-op when send_fn is null
    t.sendTrace(null, "test", Address.init(0x1234567890));
}

test "Trace: sendTrace with callback" {
    const Ctx = struct {
        var called: bool = false;
        var dest_addr: u64 = 0;

        fn mockSend(
            _: ?*anyopaque,
            _: ?*anyopaque,
            _: [*]const u8,
            _: u32,
            dest: Address,
        ) void {
            called = true;
            dest_addr = dest.toInt();
        }
    };

    Ctx.called = false;
    Ctx.dest_addr = 0;

    var t = Trace.init();
    t.setSendCallback(&Ctx.mockSend, null);

    const dest = Address.init(0xaabbccddee);
    t.sendTrace(null, "hello", dest);
    try testing.expect(Ctx.called);
    try testing.expectEqual(@as(u64, 0xaabbccddee), Ctx.dest_addr);
}
