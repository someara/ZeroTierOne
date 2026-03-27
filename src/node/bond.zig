/// Link aggregation and bonding for multipath networking.
///
/// Converted from `node/Bond.hpp` and `node/Bond.cpp`.
///
/// The Bond module provides multipath link aggregation with various bonding
/// policies for fault tolerance and load balancing:
/// - active-backup: Single active path with immediate failover
/// - broadcast: Send on all paths simultaneously
/// - balance-rr: Round-robin stripe packets
/// - balance-xor: Hash-based path selection per peer
/// - balance-aware: Performance-based flow balancing
///
/// Features:
/// - Quality monitoring (latency, packet loss, jitter)
/// - Automatic failover
/// - Path nomination and selection
/// - Link health tracking
/// - Flow assignment for balanced policies

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const InetAddress = @import("inet_address.zig").InetAddress;
const Mutex = @import("mutex.zig");
const constants = @import("constants.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Bonding policies
pub const Policy = enum(u8) {
    none = 0,
    active_backup = 1,
    broadcast = 2,
    balance_rr = 3,
    balance_xor = 4,
    balance_aware = 5,
};

/// Link reselection methods
pub const ReselectionPolicy = enum(u8) {
    always = 0,
    better = 1,
    failure = 2,
    optimize = 3,
};

/// Link mode
pub const LinkMode = enum(u8) {
    primary = 0,
    spare = 1,
};

/// Quality weight indices
pub const QualityWeightIndex = enum(u8) {
    lat_max = 0,
    pdv_max = 1,
    plr_max = 2,
    per_max = 3,
    lat_weight = 4,
    pdv_weight = 5,
    plr_weight = 6,
    per_weight = 7,
};

pub const qos_parameter_size: usize = 8;

// ── Bond ──────────────────────────────────────────────────────────

pub const Bond = struct {
    allocator: mem.Allocator,

    // Bond configuration
    policy: Policy,
    reselection_policy: ReselectionPolicy,

    // State
    in_use: bool,
    active: bool,

    // Paths
    // TODO: Add path management

    // Monitoring
    monitor_interval: u32,

    // Statistics
    // TODO: Add statistics tracking

    const Self = @This();

    /// Create a new Bond instance.
    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .policy = .none,
            .reselection_policy = .optimize,
            .in_use = false,
            .active = false,
            .monitor_interval = 1000, // 1 second
        };
    }

    /// Destroy the Bond instance.
    pub fn deinit(self: *Self) void {
        _ = self;
        // TODO: Cleanup paths and resources
    }

    /// Check if bonding is in use.
    pub fn isInUse(self: *const Self) bool {
        return self.in_use;
    }

    /// Set bonding policy.
    pub fn setPolicy(self: *Self, policy: Policy) void {
        self.policy = policy;
        self.in_use = (policy != .none);
    }

    /// Get bonding policy.
    pub fn getPolicy(self: *const Self) Policy {
        return self.policy;
    }

    /// Process background bond tasks.
    pub fn processBackgroundTasks(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
    ) void {
        _ = t_ptr;
        _ = now;

        if (!self.in_use) {
            return;
        }

        // TODO: Implement bond maintenance
        // - Check path health
        // - Update quality metrics
        // - Perform failover if needed
        // - Rebalance flows
    }

    /// Get minimum required monitor interval.
    pub fn minReqMonitorInterval(self: *const Self) u64 {
        return self.monitor_interval;
    }

    /// Nominate a path for use.
    pub fn nominatePath(
        self: *Self,
        path: *anyopaque,
        now: i64,
    ) void {
        _ = self;
        _ = path;
        _ = now;
        // TODO: Add path to bond
    }

    /// Remove a path from consideration.
    pub fn removePath(self: *Self, path: *anyopaque) void {
        _ = self;
        _ = path;
        // TODO: Remove path from bond
    }

    /// Select best path for a flow.
    pub fn selectPath(
        self: *Self,
        flow_id: i32,
        now: i64,
    ) ?*anyopaque {
        _ = flow_id;
        _ = now;

        if (!self.in_use) {
            return null;
        }

        // TODO: Implement path selection based on policy
        return null;
    }

    /// Record packet sent on a path.
    pub fn recordOutgoingPacket(
        self: *Self,
        path: *anyopaque,
        packet_id: u64,
        len: u32,
        now: i64,
    ) void {
        _ = self;
        _ = path;
        _ = packet_id;
        _ = len;
        _ = now;
        // TODO: Update statistics
    }

    /// Record ACK received for a packet.
    pub fn recordIncomingAck(
        self: *Self,
        path: *anyopaque,
        packet_id: u64,
        now: i64,
    ) void {
        _ = self;
        _ = path;
        _ = packet_id;
        _ = now;
        // TODO: Update latency and quality metrics
    }

    /// Get number of alive links.
    pub fn getNumAliveLinks(self: *const Self) u32 {
        _ = self;
        // TODO: Count alive paths
        return 0;
    }

    /// Get total number of links.
    pub fn getNumTotalLinks(self: *const Self) u32 {
        _ = self;
        // TODO: Count all paths
        return 0;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "Bond: init/deinit" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    try testing.expect(!bond.isInUse());
    try testing.expectEqual(Policy.none, bond.getPolicy());
}

test "Bond: policy" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    // Set active-backup policy
    bond.setPolicy(.active_backup);
    try testing.expect(bond.isInUse());
    try testing.expectEqual(Policy.active_backup, bond.getPolicy());

    // Set broadcast policy
    bond.setPolicy(.broadcast);
    try testing.expectEqual(Policy.broadcast, bond.getPolicy());

    // Disable bonding
    bond.setPolicy(.none);
    try testing.expect(!bond.isInUse());
}

test "Bond: monitor interval" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    const interval = bond.minReqMonitorInterval();
    try testing.expect(interval > 0);
}
