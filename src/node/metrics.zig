/// Prometheus-compatible metrics for ZeroTier.
///
/// Converted from `node/Metrics.hpp` and `node/Metrics.cpp`. The C++ version
/// uses the `prometheus-cpp-lite` library with global counter/gauge objects.
/// This Zig version implements the same metric names and semantics using
/// simple atomic integers, avoiding the C++ library dependency.
///
/// During the transition period, the C++ `Metrics.cpp` is still compiled and
/// linked (for unconverted C++ code that references it). This Zig module
/// provides the Zig-side metric types for newly converted Zig code to use.
/// Once all C++ callers are converted, `Metrics.cpp` can be removed.
const std = @import("std");

// ── Metric Types ───────────────────────────────────────────────────

/// A monotonically increasing counter (thread-safe).
pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Increment by 1.
    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Increment by `n`.
    pub fn add(self: *Counter, n: u64) void {
        _ = self.value.fetchAdd(n, .monotonic);
    }

    /// Read the current value.
    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }
};

/// A gauge that can go up and down (thread-safe).
pub const Gauge = struct {
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    /// Set to an absolute value.
    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .monotonic);
    }

    /// Increment by 1.
    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    /// Decrement by 1.
    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    /// Read the current value.
    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

// ── Packet Type Counters ───────────────────────────────────────────

/// Incoming packet counters by type (direction = rx).
pub const pkt_in = struct {
    pub var nop = Counter{};
    pub var err = Counter{};
    pub var ack = Counter{};
    pub var qos = Counter{};
    pub var hello = Counter{};
    pub var ok = Counter{};
    pub var whois = Counter{};
    pub var rendezvous = Counter{};
    pub var frame = Counter{};
    pub var ext_frame = Counter{};
    pub var echo = Counter{};
    pub var multicast_like = Counter{};
    pub var network_credentials = Counter{};
    pub var network_config_request = Counter{};
    pub var network_config = Counter{};
    pub var multicast_gather = Counter{};
    pub var multicast_frame = Counter{};
    pub var push_direct_paths = Counter{};
    pub var user_message = Counter{};
    pub var remote_trace = Counter{};
    pub var path_negotiation_request = Counter{};
};

/// Outgoing packet counters by type (direction = tx).
pub const pkt_out = struct {
    pub var nop = Counter{};
    pub var err = Counter{};
    pub var ack = Counter{};
    pub var qos = Counter{};
    pub var hello = Counter{};
    pub var ok = Counter{};
    pub var whois = Counter{};
    pub var rendezvous = Counter{};
    pub var frame = Counter{};
    pub var ext_frame = Counter{};
    pub var echo = Counter{};
    pub var multicast_like = Counter{};
    pub var network_credentials = Counter{};
    pub var network_config_request = Counter{};
    pub var network_config = Counter{};
    pub var multicast_gather = Counter{};
    pub var multicast_frame = Counter{};
    pub var push_direct_paths = Counter{};
    pub var user_message = Counter{};
    pub var remote_trace = Counter{};
    pub var path_negotiation_request = Counter{};
};

// ── Packet Error Counters ──────────────────────────────────────────

/// Incoming packet error counters.
pub const pkt_error_in = struct {
    pub var obj_not_found = Counter{};
    pub var unsupported_op = Counter{};
    pub var identity_collision = Counter{};
    pub var need_membership_cert = Counter{};
    pub var network_access_denied = Counter{};
    pub var unwanted_multicast = Counter{};
    pub var authentication_required = Counter{};
    pub var internal_server_error = Counter{};
};

/// Outgoing packet error counters.
pub const pkt_error_out = struct {
    pub var obj_not_found = Counter{};
    pub var unsupported_op = Counter{};
    pub var identity_collision = Counter{};
    pub var need_membership_cert = Counter{};
    pub var network_access_denied = Counter{};
    pub var unwanted_multicast = Counter{};
    pub var authentication_required = Counter{};
    pub var internal_server_error = Counter{};
};

// ── Data Transfer Counters ─────────────────────────────────────────

pub var udp_send = Counter{};
pub var udp_recv = Counter{};
pub var tcp_send = Counter{};
pub var tcp_recv = Counter{};

// ── Network Gauges ─────────────────────────────────────────────────

pub var network_num_joined = Gauge{};

// ── Controller Metrics ─────────────────────────────────────────────

pub var network_count = Gauge{};
pub var member_count = Gauge{};
pub var network_changes = Counter{};
pub var member_changes = Counter{};
pub var member_auths = Counter{};
pub var member_deauths = Counter{};
pub var network_config_request_queue_size = Gauge{};
pub var sso_expiration_checks = Counter{};
pub var sso_member_deauth = Counter{};
pub var network_config_request = Counter{};
pub var network_config_request_threads = Gauge{};

pub var db_get_network = Counter{};
pub var db_get_network_and_member = Counter{};
pub var db_get_network_and_member_and_summary = Counter{};
pub var db_get_member_list = Counter{};
pub var db_get_network_list = Counter{};
pub var db_member_change = Counter{};
pub var db_network_change = Counter{};

// ── Tests ──────────────────────────────────────────────────────────

test "counter increment" {
    var c = Counter{};
    try std.testing.expectEqual(@as(u64, 0), c.get());

    c.inc();
    c.inc();
    c.inc();
    try std.testing.expectEqual(@as(u64, 3), c.get());

    c.add(10);
    try std.testing.expectEqual(@as(u64, 13), c.get());
}

test "gauge set and inc/dec" {
    var g = Gauge{};
    try std.testing.expectEqual(@as(i64, 0), g.get());

    g.inc();
    g.inc();
    try std.testing.expectEqual(@as(i64, 2), g.get());

    g.dec();
    try std.testing.expectEqual(@as(i64, 1), g.get());

    g.set(42);
    try std.testing.expectEqual(@as(i64, 42), g.get());

    g.set(-5);
    try std.testing.expectEqual(@as(i64, -5), g.get());
}

test "global metrics are accessible" {
    // Verify that global metrics are initialized to zero
    try std.testing.expectEqual(@as(u64, 0), pkt_in.hello.get());
    try std.testing.expectEqual(@as(u64, 0), pkt_out.hello.get());
    try std.testing.expectEqual(@as(u64, 0), udp_send.get());
    try std.testing.expectEqual(@as(i64, 0), network_num_joined.get());
}
