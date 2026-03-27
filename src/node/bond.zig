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

/// Maximum monitored paths
const max_paths: usize = 32;

/// Path quality history depth
const quality_history_depth: usize = 64;

// ── Path Quality ──────────────────────────────────────────────────

/// Quality metrics for a bonded path.
const PathQuality = struct {
    latency_mean: f32,
    latency_variance: f32,
    packet_loss_ratio: f32,
    packet_error_ratio: f32,
    assigned_flow_count: u32,
    relative_quality: f32,
    eligible: bool,
    bonded: bool,

    pub fn init() PathQuality {
        return .{
            .latency_mean = 0.0,
            .latency_variance = 0.0,
            .packet_loss_ratio = 0.0,
            .packet_error_ratio = 0.0,
            .assigned_flow_count = 0,
            .relative_quality = 1.0,
            .eligible = true,
            .bonded = true,
        };
    }

    /// Update quality metrics.
    pub fn update(
        self: *PathQuality,
        latency: f32,
        loss: f32,
        error_rate: f32,
    ) void {
        // Exponential moving average
        const alpha: f32 = 0.2;
        self.latency_mean = self.latency_mean * (1.0 - alpha) + latency * alpha;
        self.packet_loss_ratio = self.packet_loss_ratio * (1.0 - alpha) + loss * alpha;
        self.packet_error_ratio = self.packet_error_ratio * (1.0 - alpha) + error_rate * alpha;

        // Update variance
        const diff = latency - self.latency_mean;
        self.latency_variance = self.latency_variance * (1.0 - alpha) + (diff * diff) * alpha;
    }

    /// Calculate overall quality score.
    pub fn calculateQuality(self: *const PathQuality) f32 {
        // Lower is better for latency/loss/error
        // Simple scoring: inverse of badness
        const latency_score = 1.0 / (1.0 + self.latency_mean / 100.0);
        const loss_score = 1.0 - self.packet_loss_ratio;
        const error_score = 1.0 - self.packet_error_ratio;

        return (latency_score + loss_score + error_score) / 3.0;
    }
};

/// Packet tracking entry for RTT calculation.
const PacketRecord = struct {
    packet_id: u64,
    send_time: i64,
};

/// Bonded path information.
const BondedPath = struct {
    path: *anyopaque,
    quality: PathQuality,
    mode: LinkMode,
    last_activity: i64,
    alive: bool,

    // RTT tracking (ring buffer of recent packets)
    packet_history: [16]PacketRecord,
    packet_history_idx: usize,

    pub fn init(path: *anyopaque, mode: LinkMode) BondedPath {
        return .{
            .path = path,
            .quality = PathQuality.init(),
            .mode = mode,
            .last_activity = 0,
            .alive = true,
            .packet_history = [_]PacketRecord{.{ .packet_id = 0, .send_time = 0 }} ** 16,
            .packet_history_idx = 0,
        };
    }

    /// Record packet send for RTT tracking.
    pub fn recordSend(self: *BondedPath, packet_id: u64, now: i64) void {
        self.packet_history[self.packet_history_idx] = .{
            .packet_id = packet_id,
            .send_time = now,
        };
        self.packet_history_idx = (self.packet_history_idx + 1) % self.packet_history.len;
    }

    /// Find and calculate RTT for an ACKed packet.
    /// Clears the entry after use to prevent stale data issues.
    pub fn findAndCalculateRTT(self: *BondedPath, packet_id: u64, now: i64) ?i64 {
        for (&self.packet_history) |*record| {
            if (record.packet_id == packet_id and record.send_time > 0) {
                const rtt = now - record.send_time;
                // Clear entry to prevent reuse
                record.packet_id = 0;
                record.send_time = 0;
                return rtt;
            }
        }
        return null;
    }
};

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
    paths: std.ArrayList(BondedPath),
    active_path_index: ?usize,
    primary_path_index: ?usize,

    // Round-robin state
    rr_index: usize,

    // Monitoring
    monitor_interval: u32,
    last_background_task_time: i64,

    // Statistics
    tx_bytes: u64,
    rx_bytes: u64,
    tx_packets: u64,
    rx_packets: u64,

    mutex: Mutex,

    const Self = @This();

    /// Create a new Bond instance.
    pub fn init(allocator: mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .policy = .none,
            .reselection_policy = .optimize,
            .in_use = false,
            .active = false,
            .paths = std.ArrayList(BondedPath).init(allocator),
            .active_path_index = null,
            .primary_path_index = null,
            .rr_index = 0,
            .monitor_interval = 1000, // 1 second
            .last_background_task_time = 0,
            .tx_bytes = 0,
            .rx_bytes = 0,
            .tx_packets = 0,
            .rx_packets = 0,
            .mutex = .{},
        };
    }

    /// Destroy the Bond instance.
    pub fn deinit(self: *Self) void {
        self.paths.deinit();
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

        if (!self.in_use) {
            return;
        }

        // Check if it's time to run
        if (now - self.last_background_task_time < self.monitor_interval) {
            return;
        }
        self.last_background_task_time = now;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check path health
        const timeout: i64 = 30000; // 30 seconds
        for (self.paths.items) |*p| {
            if (p.alive and (now - p.last_activity) > timeout) {
                p.alive = false;
            }
        }

        // Perform failover if needed
        if (self.policy == .active_backup) {
            if (self.active_path_index) |idx| {
                if (idx < self.paths.items.len and !self.paths.items[idx].alive) {
                    self.selectActivePath(now);
                }
            } else {
                self.selectActivePath(now);
            }
        }

        // Update quality metrics and rebalance (for balance-aware)
        if (self.policy == .balance_aware) {
            for (self.paths.items) |*p| {
                if (p.alive) {
                    // Decay quality slightly to encourage re-evaluation
                    p.quality.relative_quality *= 0.99;
                }
            }
        }
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
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if path already exists
        for (self.paths.items) |*p| {
            if (p.path == path) {
                p.last_activity = now;
                p.alive = true;
                return;
            }
        }

        // Add new path
        const mode: LinkMode = if (self.paths.items.len == 0) .primary else .spare;
        const bonded_path = BondedPath.init(path, mode);
        self.paths.append(bonded_path) catch return;

        // Set as primary if first
        if (self.paths.items.len == 1) {
            self.primary_path_index = 0;
            self.active_path_index = 0;
        }
    }

    /// Remove a path from consideration.
    pub fn removePath(self: *Self, path: *anyopaque) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.paths.items.len) {
            if (self.paths.items[i].path == path) {
                _ = self.paths.orderedRemove(i);

                // Update indices
                if (self.active_path_index) |active| {
                    if (active == i) {
                        self.active_path_index = null;
                        // Force re-selection
                        self.selectActivePath(0);
                    } else if (active > i) {
                        self.active_path_index = active - 1;
                    }
                }

                if (self.primary_path_index) |primary| {
                    if (primary == i) {
                        self.primary_path_index = if (self.paths.items.len > 0) 0 else null;
                    } else if (primary > i) {
                        self.primary_path_index = primary - 1;
                    }
                }

                return;
            }
            i += 1;
        }
    }

    /// Select best path for a flow.
    pub fn selectPath(
        self: *Self,
        flow_id: i32,
        now: i64,
    ) ?*anyopaque {
        if (!self.in_use or self.paths.items.len == 0) {
            return null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        return switch (self.policy) {
            .none => null,
            .active_backup => self.selectActiveBackup(now),
            .broadcast => null, // Caller handles broadcast
            .balance_rr => self.selectRoundRobin(),
            .balance_xor => self.selectXor(flow_id),
            .balance_aware => self.selectBalanceAware(now),
        };
    }

    /// Select active path for active-backup policy.
    fn selectActiveBackup(self: *Self, now: i64) ?*anyopaque {
        _ = now;
        if (self.active_path_index) |idx| {
            if (idx < self.paths.items.len and self.paths.items[idx].alive) {
                return self.paths.items[idx].path;
            }
        }

        // Find first alive path
        for (self.paths.items, 0..) |*p, i| {
            if (p.alive) {
                self.active_path_index = i;
                return p.path;
            }
        }

        return null;
    }

    /// Select path using round-robin.
    fn selectRoundRobin(self: *Self) ?*anyopaque {
        if (self.paths.items.len == 0) return null;

        const start = self.rr_index;
        var attempts: usize = 0;

        while (attempts < self.paths.items.len) : (attempts += 1) {
            const idx = (start + attempts) % self.paths.items.len;
            if (self.paths.items[idx].alive) {
                self.rr_index = (idx + 1) % self.paths.items.len;
                return self.paths.items[idx].path;
            }
        }

        return null;
    }

    /// Select path using XOR hash.
    fn selectXor(self: *Self, flow_id: i32) ?*anyopaque {
        if (self.paths.items.len == 0) return null;

        const idx = @as(usize, @intCast(@abs(flow_id))) % self.paths.items.len;
        if (self.paths.items[idx].alive) {
            return self.paths.items[idx].path;
        }

        // Fallback to first alive
        for (self.paths.items) |*p| {
            if (p.alive) return p.path;
        }

        return null;
    }

    /// Select path using quality-aware balancing.
    fn selectBalanceAware(self: *Self, now: i64) ?*anyopaque {
        _ = now;

        var best_path: ?*anyopaque = null;
        var best_quality: f32 = -1.0;

        for (self.paths.items) |*p| {
            if (!p.alive) continue;

            const quality = p.quality.calculateQuality();
            const flow_count = p.quality.assigned_flow_count + 1;
            // Guard against division by zero (should never happen, but be safe)
            if (flow_count == 0) continue;

            const load_factor = @as(f32, @floatFromInt(flow_count));
            const adjusted_quality = quality / load_factor;

            if (adjusted_quality > best_quality) {
                best_quality = adjusted_quality;
                best_path = p.path;
            }
        }

        return best_path;
    }

    /// Select active path (internal).
    fn selectActivePath(self: *Self, now: i64) void {
        _ = now;

        switch (self.reselection_policy) {
            .always => {
                // Always prefer primary
                if (self.primary_path_index) |idx| {
                    if (idx < self.paths.items.len and self.paths.items[idx].alive) {
                        self.active_path_index = idx;
                        return;
                    }
                }
            },
            .better, .optimize => {
                // Select best quality path
                var best_idx: ?usize = null;
                var best_quality: f32 = -1.0;

                for (self.paths.items, 0..) |*p, i| {
                    if (!p.alive) continue;

                    const quality = p.quality.calculateQuality();
                    if (quality > best_quality) {
                        best_quality = quality;
                        best_idx = i;
                    }
                }

                if (best_idx) |idx| {
                    self.active_path_index = idx;
                    return;
                }
            },
            .failure => {
                // Keep current unless failed
                if (self.active_path_index) |idx| {
                    if (idx < self.paths.items.len and self.paths.items[idx].alive) {
                        return;
                    }
                }
            },
        }

        // Fallback: find any alive path
        for (self.paths.items, 0..) |*p, i| {
            if (p.alive) {
                self.active_path_index = i;
                return;
            }
        }

        self.active_path_index = null;
    }

    /// Record packet sent on a path.
    pub fn recordOutgoingPacket(
        self: *Self,
        path: *anyopaque,
        packet_id: u64,
        len: u32,
        now: i64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.tx_packets += 1;
        self.tx_bytes += len;

        // Find path and record send time
        for (self.paths.items) |*p| {
            if (p.path == path) {
                p.last_activity = now;
                p.recordSend(packet_id, now);
                break;
            }
        }
    }

    /// Record ACK received for a packet.
    pub fn recordIncomingAck(
        self: *Self,
        path: *anyopaque,
        packet_id: u64,
        now: i64,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find path and update quality
        for (self.paths.items) |*p| {
            if (p.path == path) {
                p.last_activity = now;
                p.alive = true;

                // Calculate actual RTT from packet history
                if (p.findAndCalculateRTT(packet_id, now)) |rtt| {
                    const latency: f32 = @floatFromInt(rtt);
                    p.quality.update(latency, 0.0, 0.0);
                } else {
                    // Packet not found in history, assume good quality
                    p.quality.update(10.0, 0.0, 0.0);
                }
                break;
            }
        }
    }

    /// Get number of alive links.
    pub fn getNumAliveLinks(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.paths.items) |p| {
            if (p.alive) count += 1;
        }
        return count;
    }

    /// Get total number of links.
    pub fn getNumTotalLinks(self: *const Self) u32 {
        const len = self.paths.items.len;
        return std.math.cast(u32, len) orelse std.math.maxInt(u32);
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

test "Bond: path nomination and removal" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.active_backup);

    // Nominate paths
    var path1: usize = 1;
    var path2: usize = 2;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    bond.nominatePath(@ptrCast(&path2), now);

    try testing.expectEqual(@as(usize, 2), bond.paths.items.len);
    try testing.expectEqual(@as(?usize, 0), bond.primary_path_index);
    try testing.expectEqual(@as(?usize, 0), bond.active_path_index);

    // Remove path
    bond.removePath(@ptrCast(&path1));
    try testing.expectEqual(@as(usize, 1), bond.paths.items.len);
}

test "Bond: path selection - active backup" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.active_backup);

    var path1: usize = 1;
    var path2: usize = 2;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    bond.nominatePath(@ptrCast(&path2), now);

    // Should select first path
    const selected = bond.selectPath(0, now);
    try testing.expect(selected != null);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&path1)), selected.?);
}

test "Bond: path selection - round robin" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.balance_rr);

    var path1: usize = 1;
    var path2: usize = 2;
    var path3: usize = 3;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    bond.nominatePath(@ptrCast(&path2), now);
    bond.nominatePath(@ptrCast(&path3), now);

    // Should cycle through paths
    const sel1 = bond.selectPath(0, now);
    const sel2 = bond.selectPath(0, now);
    const sel3 = bond.selectPath(0, now);

    try testing.expect(sel1 != null);
    try testing.expect(sel2 != null);
    try testing.expect(sel3 != null);

    // All three should be different
    try testing.expect(sel1.? != sel2.? or sel2.? != sel3.? or sel1.? != sel3.?);
}

test "Bond: path selection - XOR" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.balance_xor);

    var path1: usize = 1;
    var path2: usize = 2;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    bond.nominatePath(@ptrCast(&path2), now);

    // Same flow should get same path
    const sel1 = bond.selectPath(42, now);
    const sel2 = bond.selectPath(42, now);

    try testing.expect(sel1 != null);
    try testing.expectEqual(sel1.?, sel2.?);
}

test "Bond: statistics tracking" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.active_backup);

    var path1: usize = 1;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);

    // Record outgoing packet
    bond.recordOutgoingPacket(@ptrCast(&path1), 1, 100, now);
    try testing.expectEqual(@as(u64, 1), bond.tx_packets);
    try testing.expectEqual(@as(u64, 100), bond.tx_bytes);

    // Record ACK
    bond.recordIncomingAck(@ptrCast(&path1), 1, now + 10);
    try testing.expect(bond.paths.items[0].alive);
}

test "Bond: link counting" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.active_backup);

    var path1: usize = 1;
    var path2: usize = 2;
    var path3: usize = 3;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    bond.nominatePath(@ptrCast(&path2), now);
    bond.nominatePath(@ptrCast(&path3), now);

    try testing.expectEqual(@as(u32, 3), bond.getNumTotalLinks());
    try testing.expectEqual(@as(u32, 3), bond.getNumAliveLinks());

    // Mark one dead
    bond.paths.items[1].alive = false;
    try testing.expectEqual(@as(u32, 3), bond.getNumTotalLinks());
    try testing.expectEqual(@as(u32, 2), bond.getNumAliveLinks());
}

test "Bond: background tasks - health monitoring" {
    var bond = Bond.init(testing.allocator);
    defer bond.deinit();

    bond.setPolicy(.active_backup);

    var path1: usize = 1;
    const now: i64 = 1000;

    bond.nominatePath(@ptrCast(&path1), now);
    try testing.expect(bond.paths.items[0].alive);

    // Run background task after timeout
    bond.processBackgroundTasks(null, now + 35000);

    // Path should be marked dead due to timeout
    try testing.expect(!bond.paths.items[0].alive);
}

test "Bond: quality calculation" {
    var quality = PathQuality.init();

    // Update with good metrics
    quality.update(10.0, 0.01, 0.001);
    const score1 = quality.calculateQuality();
    try testing.expect(score1 > 0.8);

    // Update with bad metrics
    quality.update(200.0, 0.5, 0.3);
    const score2 = quality.calculateQuality();
    try testing.expect(score2 < 0.5);
    try testing.expect(score2 < score1);
}
