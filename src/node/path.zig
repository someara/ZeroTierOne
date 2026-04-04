/// A path across the physical network to a remote peer.
///
/// Converted from `node/Path.hpp` and `node/Path.cpp`. A Path represents
/// a specific network route to a peer — identified by {local socket,
/// remote InetAddress}. It tracks timing (last in/out, trust expiry),
/// latency, and bond-related quality metrics.
///
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const constants = @import("constants.zig");
const inet_address = @import("inet_address.zig");
const InetAddress = inet_address.InetAddress;
const IpScope = inet_address.IpScope;

// ── Constants ─────────────────────────────────────────────────────

/// Maximum path preference rank: `(MAX_SCOPE << 1) | 1`.
pub const max_preference_rank = constants.path_max_preference_rank;

/// Grace period beyond heartbeat interval for considering a path alive (ms).
const alive_grace_ms: i64 = 5000;

// ── SendFunction callback type ────────────────────────────────────
//
// In C++, Path::send() calls RR->node->putPacket(), which is a C
// callback into the embedding application. During conversion, we
// model this as a function pointer that can be set by the Node
// integration layer.

/// Callback for sending a packet via this path.
///
/// Parameters: context, local_socket, remote_addr, data, data_len.
/// Returns true if the transport layer reports success.
pub const SendFunction = *const fn (
    ctx: ?*anyopaque,
    local_socket: i64,
    remote_addr: *const InetAddress,
    data: [*]const u8,
    data_len: u32,
) bool;

// ── HashKey ───────────────────────────────────────────────────────

/// Efficient unique key for paths in a Hashtable.
///
/// Composed of three u64 values derived from the local socket handle
/// and the remote IP address/port. This matches the C++ Path::HashKey.
pub const HashKey = struct {
    _k: [3]u64,

    /// Create a zero/default key.
    pub fn zero() HashKey {
        return .{ ._k = .{ 0, 0, 0 } };
    }

    /// Create a key from a local socket handle and a remote address.
    ///
    /// Uses raw access to the underlying sockaddr_storage to extract
    /// address/port components, matching the C++ HashKey constructor.
    pub fn init(local_socket: i64, remote_addr: *const InetAddress) HashKey {
        var key = HashKey.zero();
        const family = remote_addr.family();

        if (family == std.c.AF.INET) {
            // IPv4: extract sin_addr (4 bytes) and sin_port (2 bytes)
            const sin: *const std.c.sockaddr.in = @ptrCast(@alignCast(&remote_addr.storage));
            const addr_ptr: *const u32 = @ptrCast(&sin.addr);
            key._k[0] = @as(u64, addr_ptr.*);
            key._k[1] = @as(u64, sin.port);
            key._k[2] = @as(u64, @bitCast(local_socket));
        } else if (family == std.c.AF.INET6) {
            // IPv6: copy 16-byte address into first two u64s
            const sin6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(&remote_addr.storage));
            const addr_bytes: *const [16]u8 = &sin6.addr;
            key._k[0] = mem.readInt(u64, addr_bytes[0..8], .little);
            key._k[1] = mem.readInt(u64, addr_bytes[8..16], .little);
            // XOR port (shifted) with local socket into third u64
            key._k[2] = (@as(u64, sin6.port) << 32) ^ @as(u64, @bitCast(local_socket));
        } else {
            // Fallback: copy raw bytes of the sockaddr_storage
            const raw: *const [24]u8 = @ptrCast(&remote_addr.storage);
            key._k[0] = mem.readInt(u64, raw[0..8], .little);
            key._k[1] = mem.readInt(u64, raw[8..16], .little);
            key._k[2] = mem.readInt(u64, raw[16..24], .little);
            key._k[2] +%= @as(u64, @bitCast(local_socket));
        }

        return key;
    }

    /// Hash code for use in hash tables.
    pub fn hashCode(self: HashKey) u64 {
        return self._k[0] +% self._k[1] +% self._k[2];
    }

    /// Equality comparison.
    pub fn eql(self: HashKey, other: HashKey) bool {
        return self._k[0] == other._k[0] and
            self._k[1] == other._k[1] and
            self._k[2] == other._k[2];
    }
};

// ── Path ──────────────────────────────────────────────────────────

pub const Path = struct {
    // -- Interface name (bond layer) --

    /// Physical interface name that this path lives on.
    /// OWNED: inline fixed buffer, no heap allocation.
    _ifname: [constants.max_physifname]u8,

    // -- Timing fields --

    /// Last time a packet was sent on this path (ms, monotonic).
    _last_out: i64,

    /// Last time a packet was received on this path (ms, monotonic).
    _last_in: i64,

    /// Last time a trust-established packet was received (ms, monotonic).
    _last_trust_established_packet_received: i64,

    /// Last time an ECHO request was received (for rate-limiting).
    _last_echo_request_received: i64,

    // -- Socket info --

    /// Local port corresponding to the local socket.
    _local_port: u16,

    /// Local socket handle (opaque, set by external code).
    _local_socket: i64,

    // -- Bond quality metrics (set by bonding layer) --

    /// Mean latency as reported by the bonding layer.
    _latency_mean: f32,

    /// Latency variance as reported by the bonding layer.
    _latency_variance: f32,

    /// Packet loss ratio as reported by the bonding layer.
    _packet_loss_ratio: f32,

    /// Packet error ratio as reported by the bonding layer.
    _packet_error_ratio: f32,

    /// Number of flows assigned to this path (bond layer).
    _assigned_flow_count: u16,

    /// Whether this path is valid as reported by the bonding layer.
    _valid: bool,

    /// Whether this path is eligible for use in a bond.
    _eligible: bool,

    /// Whether this path is currently bonded.
    _bonded: bool,

    /// User-specified MTU for this path (bond layer).
    _mtu: u16,

    /// Given link speed as reported by the bonding layer.
    _given_link_speed: u32,

    /// Path's relative quality as reported by the bonding layer.
    _relative_quality: f32,

    // -- Latency tracking --

    /// Current latency estimate, or 0xffff if unknown.
    _latency: u32,

    // -- Address info --

    /// Remote address of this path.
    _addr: InetAddress,

    /// Memoized IP scope (computed from _addr at construction).
    _ip_scope: IpScope,

    // ── Construction ──────────────────────────────────────────

    /// Create a default/null path (all fields zeroed or at defaults).
    pub fn init() Path {
        return .{
            ._ifname = [_]u8{0} ** constants.max_physifname,
            ._last_out = 0,
            ._last_in = 0,
            ._last_trust_established_packet_received = 0,
            ._last_echo_request_received = 0,
            ._local_port = 0,
            ._local_socket = -1,
            ._latency_mean = 0.0,
            ._latency_variance = 0.0,
            ._packet_loss_ratio = 0.0,
            ._packet_error_ratio = 0.0,
            ._assigned_flow_count = 0,
            ._valid = true,
            ._eligible = false,
            ._bonded = false,
            ._mtu = 0,
            ._given_link_speed = 0,
            ._relative_quality = 0,
            ._latency = 0xffff,
            ._addr = InetAddress.zero(),
            ._ip_scope = .none,
        };
    }

    /// Create a path with the given local socket and remote address.
    pub fn initWithAddress(local_socket: i64, addr: InetAddress) Path {
        var p = init();
        p._local_socket = local_socket;
        p._addr = addr;
        p._ip_scope = addr.ipScope();
        return p;
    }

    // ── Receive / Send ────────────────────────────────────────

    /// Called when a packet is received from this remote path.
    pub fn received(self: *Path, now: i64) void {
        self._last_in = now;
    }

    /// Set time last trusted packet was received.
    pub fn trustedPacketReceived(self: *Path, now: i64) void {
        self._last_trust_established_packet_received = now;
    }

    /// Send a packet via this path using the provided send callback.
    ///
    /// Returns true if the transport layer reports success. Updates
    /// `_last_out` on success.
    pub fn send(
        self: *Path,
        send_fn: SendFunction,
        ctx: ?*anyopaque,
        data: []const u8,
        now: i64,
    ) bool {
        const send_len: u32 = std.math.cast(u32, data.len) orelse return false;
        if (send_fn(ctx, self._local_socket, &self._addr, data.ptr, send_len)) {
            self._last_out = now;
            return true;
        }
        return false;
    }

    /// Manually update last sent time.
    pub fn sent(self: *Path, now: i64) void {
        self._last_out = now;
    }

    // ── Latency ───────────────────────────────────────────────

    /// Update path latency with a new measurement.
    ///
    /// Uses exponential moving average: `(old + new) / 2`. If the
    /// current latency is unknown (0xffff), the new measurement is
    /// used directly.
    pub fn updateLatency(self: *Path, latency_val: u32) void {
        const prev = self._latency;
        if (prev < 0xffff) {
            self._latency = (prev + latency_val) / 2;
        } else {
            self._latency = latency_val;
        }
    }

    /// Current latency estimate, or 0xffff if unknown.
    pub fn latency(self: *const Path) u32 {
        return self._latency;
    }

    // ── Accessors ─────────────────────────────────────────────

    /// Local socket handle (opaque, set by external code).
    pub fn localSocket(self: *const Path) i64 {
        return self._local_socket;
    }

    /// Local port corresponding to the local socket.
    pub fn localPort(self: *const Path) u16 {
        return self._local_port;
    }

    /// Remote address of this path.
    pub fn address(self: *const Path) *const InetAddress {
        return &self._addr;
    }

    /// IP scope — cached from address at construction time.
    pub fn ipScope(self: *const Path) IpScope {
        return self._ip_scope;
    }

    // ── Status queries ────────────────────────────────────────

    /// Returns true if this path has received a trust-established
    /// packet within the trust expiration window.
    pub fn trustEstablished(self: *const Path, now: i64) bool {
        return (now - self._last_trust_established_packet_received) < constants.trust_expiration;
    }

    /// Preference rank for path selection, higher == better.
    ///
    /// Ranks by IP scope (higher scope = better), with IPv6 preferred
    /// over IPv4 within the same scope class.
    pub fn preferenceRank(self: *const Path) u32 {
        const scope_val: u32 = @intFromEnum(self._ip_scope);
        const is_v6: u32 = if (self._addr.family() == std.c.AF.INET6) 1 else 0;
        return (scope_val << 1) | is_v6;
    }

    /// Path quality metric — lower is better.
    ///
    /// Factors in latency and age, penalizing paths that haven't
    /// received traffic recently. Weighted by inverse IP scope.
    pub fn quality(self: *const Path, now: i64) i64 {
        const lat: i64 = @intCast(self._latency);
        const age_raw = now - self._last_in;
        const max_age: i64 = @intCast(constants.path_heartbeat_period * 10);
        const clamped_age = @min(age_raw, max_age);
        const heartbeat_plus_grace: i64 = @intCast(constants.path_heartbeat_period + 5000);

        const effective_lat: i64 = if (clamped_age < heartbeat_plus_grace)
            lat
        else
            lat + 0xffff + clamped_age;

        const scope_weight: i64 = @as(i64, inet_address.MAX_SCOPE) - @as(i64, @intFromEnum(self._ip_scope)) + 1;
        return effective_lat * scope_weight;
    }

    /// Returns true if this path is alive (receiving heartbeats).
    pub fn alive(self: *const Path, now: i64) bool {
        return (now - self._last_in) < (@as(i64, constants.path_heartbeat_period) + alive_grace_ms);
    }

    /// Returns true if this path needs a heartbeat sent.
    pub fn needsHeartbeat(self: *const Path, now: i64) bool {
        return (now - self._last_out) >= constants.path_heartbeat_period;
    }

    /// Last time we sent something (ms, monotonic).
    pub fn lastOut(self: *const Path) i64 {
        return self._last_out;
    }

    /// Last time we received anything (ms, monotonic).
    pub fn lastIn(self: *const Path) i64 {
        return self._last_in;
    }

    /// Age of the path in terms of receiving packets (ms).
    pub fn age(self: *const Path, now: i64) i64 {
        return now - self._last_in;
    }

    /// Time last trust-established packet was received.
    pub fn lastTrustEstablishedPacketReceived(self: *const Path) i64 {
        return self._last_trust_established_packet_received;
    }

    /// Rate limit gate for inbound ECHO requests.
    ///
    /// Returns true if enough time has elapsed since the last ECHO
    /// request, and updates the timestamp. Returns false if the
    /// request should be rate-limited.
    pub fn rateGateEchoRequest(self: *Path, now: i64) bool {
        const interval: i64 = @intCast(constants.peer_general_rate_limit / 6);
        if ((now - self._last_echo_request_received) >= interval) {
            self._last_echo_request_received = now;
            return true;
        }
        return false;
    }

    // ── Bond accessors ────────────────────────────────────────

    /// Mean latency as reported by the bonding layer.
    pub fn latencyMean(self: *const Path) f32 {
        return self._latency_mean;
    }

    /// Latency variance as reported by the bonding layer.
    pub fn latencyVariance(self: *const Path) f32 {
        return self._latency_variance;
    }

    /// Packet loss ratio as reported by the bonding layer.
    pub fn packetLossRatio(self: *const Path) f32 {
        return self._packet_loss_ratio;
    }

    /// Packet error ratio as reported by the bonding layer.
    pub fn packetErrorRatio(self: *const Path) f32 {
        return self._packet_error_ratio;
    }

    /// Number of flows assigned to this path.
    pub fn assignedFlowCount(self: *const Path) u16 {
        return self._assigned_flow_count;
    }

    /// Whether this path is valid as reported by the bonding layer.
    pub fn valid(self: *const Path) bool {
        return self._valid;
    }

    /// Whether this path is eligible for use in a bond.
    pub fn eligible(self: *const Path) bool {
        return self._eligible;
    }

    /// Whether this path is bonded.
    pub fn bonded(self: *const Path) bool {
        return self._bonded;
    }

    /// User-specified MTU for this path.
    pub fn mtu(self: *const Path) u16 {
        return self._mtu;
    }

    /// Given link speed as reported by the bonding layer.
    pub fn givenLinkSpeed(self: *const Path) u32 {
        return self._given_link_speed;
    }

    /// Path's relative quality as reported by the bonding layer.
    pub fn relativeQuality(self: *const Path) f32 {
        return self._relative_quality;
    }

    /// Pointer to the interface name buffer.
    pub fn ifname(self: *Path) *[constants.max_physifname]u8 {
        return &self._ifname;
    }

    // ── Static helpers ────────────────────────────────────────

    /// Check whether an address is valid for use as a ZeroTier path.
    ///
    /// Accepts private, pseudo-private, shared (carrier-grade NAT),
    /// and global scope addresses. Rejects loopback, link-local,
    /// multicast, and unrecognized scopes. Also blacklists he.net
    /// IPv6 tunnel addresses (2001:0470::/32) due to low MTU and
    /// spotty performance.
    pub fn isAddressValidForPath(addr: *const InetAddress) bool {
        const family = addr.family();
        if (family != std.c.AF.INET and family != std.c.AF.INET6) {
            return false;
        }

        const scope = addr.ipScope();
        switch (scope) {
            .private, .pseudoprivate, .shared, .global => {
                if (family == std.c.AF.INET6) {
                    // Blacklist he.net IPv6 tunnels: 2001:0470::/32
                    if (addr.rawIpData()) |ip_data| {
                        if (ip_data.len >= 4 and
                            ip_data[0] == 0x20 and
                            ip_data[1] == 0x01 and
                            ip_data[2] == 0x04 and
                            ip_data[3] == 0x70)
                        {
                            return false;
                        }
                    }
                }
                return true;
            },
            else => return false,
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "Path: default init" {
    const p = Path.init();
    try testing.expectEqual(@as(i64, 0), p._last_out);
    try testing.expectEqual(@as(i64, 0), p._last_in);
    try testing.expectEqual(@as(i64, 0), p._last_trust_established_packet_received);
    try testing.expectEqual(@as(i64, -1), p._local_socket);
    try testing.expectEqual(@as(u16, 0), p._local_port);
    try testing.expectEqual(@as(u32, 0xffff), p._latency);
    try testing.expect(p._valid);
    try testing.expect(!p._eligible);
    try testing.expect(!p._bonded);
    try testing.expectEqual(IpScope.none, p._ip_scope);
}

test "Path: initWithAddress" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 1 }, 9993);
    const p = Path.initWithAddress(42, addr);
    try testing.expectEqual(@as(i64, 42), p._local_socket);
    try testing.expectEqual(IpScope.private, p._ip_scope);
}

test "Path: received / sent / age" {
    var p = Path.init();
    p.received(1000);
    try testing.expectEqual(@as(i64, 1000), p.lastIn());
    try testing.expectEqual(@as(i64, 500), p.age(1500));

    p.sent(2000);
    try testing.expectEqual(@as(i64, 2000), p.lastOut());
}

test "Path: trustedPacketReceived / trustEstablished" {
    var p = Path.init();

    // At time 0, _last_trust_established_packet_received=0, so
    // (1000 - 0) = 1000 < trust_expiration (600000) -> trust IS established
    // This matches C++ behavior where a freshly initialized path at time 0
    // would show trust established for any "now" < trust_expiration.
    try testing.expect(p.trustEstablished(1000));

    // Well beyond expiration from time 0
    try testing.expect(!p.trustEstablished(constants.trust_expiration + 1));

    // Set trust at a specific time
    p.trustedPacketReceived(500000);
    try testing.expect(p.trustEstablished(500000));
    try testing.expect(p.trustEstablished(500000 + constants.trust_expiration - 1));

    // Expired
    try testing.expect(!p.trustEstablished(500000 + constants.trust_expiration));
}

test "Path: updateLatency" {
    var p = Path.init();

    // First measurement sets directly (was 0xffff)
    p.updateLatency(100);
    try testing.expectEqual(@as(u32, 100), p.latency());

    // Subsequent measurements average
    p.updateLatency(200);
    try testing.expectEqual(@as(u32, 150), p.latency());

    p.updateLatency(200);
    try testing.expectEqual(@as(u32, 175), p.latency());
}

test "Path: preferenceRank" {
    // Private IPv4 -> scope=7, v6=0 -> rank=14
    const addr_v4 = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    const p_v4 = Path.initWithAddress(0, addr_v4);
    try testing.expectEqual(@as(u32, 14), p_v4.preferenceRank());

    // Global IPv6 -> scope=4, v6=1 -> rank=9
    const addr_v6 = InetAddress.initV6(.{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, 9993);
    const p_v6 = Path.initWithAddress(0, addr_v6);
    try testing.expectEqual(@as(u32, 9), p_v6.preferenceRank());
}

test "Path: alive / needsHeartbeat" {
    var p = Path.init();
    p.received(1000);

    // Just received -> alive
    try testing.expect(p.alive(1000));

    // Within heartbeat + grace -> alive
    try testing.expect(p.alive(1000 + constants.path_heartbeat_period + 4999));

    // Past heartbeat + grace -> not alive
    try testing.expect(!p.alive(1000 + constants.path_heartbeat_period + alive_grace_ms));

    // Needs heartbeat?
    p.sent(1000);
    try testing.expect(!p.needsHeartbeat(1000 + constants.path_heartbeat_period - 1));
    try testing.expect(p.needsHeartbeat(1000 + constants.path_heartbeat_period));
}

test "Path: quality" {
    var p = Path.initWithAddress(0, InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993));
    p.received(1000);
    p.updateLatency(50);

    // Recently received, private scope (7) -> weight = (7 - 7 + 1) = 1
    const q1 = p.quality(1000);
    try testing.expectEqual(@as(i64, 50), q1);

    // Global scope -> weight = (7 - 4 + 1) = 4
    var p2 = Path.initWithAddress(0, InetAddress.initV6(.{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, 9993));
    p2.received(1000);
    p2.updateLatency(50);
    const q2 = p2.quality(1000);
    try testing.expectEqual(@as(i64, 200), q2);
}

test "Path: rateGateEchoRequest" {
    var p = Path.init();

    // First request always allowed
    try testing.expect(p.rateGateEchoRequest(1000));

    // Too soon
    const interval: i64 = @intCast(constants.peer_general_rate_limit / 6);
    try testing.expect(!p.rateGateEchoRequest(1000 + interval - 1));

    // Enough time passed
    try testing.expect(p.rateGateEchoRequest(1000 + interval));
}

test "Path: bond accessors have defaults" {
    const p = Path.init();
    try testing.expectEqual(@as(f32, 0.0), p.latencyMean());
    try testing.expectEqual(@as(f32, 0.0), p.latencyVariance());
    try testing.expectEqual(@as(f32, 0.0), p.packetLossRatio());
    try testing.expectEqual(@as(f32, 0.0), p.packetErrorRatio());
    try testing.expectEqual(@as(u16, 0), p.assignedFlowCount());
    try testing.expect(p.valid());
    try testing.expect(!p.eligible());
    try testing.expect(!p.bonded());
    try testing.expectEqual(@as(u16, 0), p.mtu());
    try testing.expectEqual(@as(u32, 0), p.givenLinkSpeed());
    try testing.expectEqual(@as(f32, 0.0), p.relativeQuality());
}

test "Path: isAddressValidForPath" {
    // Private IPv4 -> valid
    const priv4 = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    try testing.expect(Path.isAddressValidForPath(&priv4));

    // Global IPv4 -> valid
    const global4 = InetAddress.initV4(.{ 8, 8, 8, 8 }, 53);
    try testing.expect(Path.isAddressValidForPath(&global4));

    // Loopback -> invalid
    const lo4 = InetAddress.initV4(.{ 127, 0, 0, 1 }, 9993);
    try testing.expect(!Path.isAddressValidForPath(&lo4));

    // Link-local -> invalid
    const ll4 = InetAddress.initV4(.{ 169, 254, 1, 1 }, 9993);
    try testing.expect(!Path.isAddressValidForPath(&ll4));

    // he.net IPv6 tunnel (2001:0470::/32) -> blacklisted
    const he_net = InetAddress.initV6(.{
        0x20, 0x01, 0x04, 0x70, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, 9993);
    try testing.expect(!Path.isAddressValidForPath(&he_net));

    // Normal global IPv6 -> valid
    const global6 = InetAddress.initV6(.{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, 9993);
    try testing.expect(Path.isAddressValidForPath(&global6));

    // Zero/null address -> invalid
    const null_addr = InetAddress.zero();
    try testing.expect(!Path.isAddressValidForPath(&null_addr));
}

test "HashKey: init IPv4" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 1 }, 9993);
    const k1 = HashKey.init(42, &addr);
    const k2 = HashKey.init(42, &addr);

    try testing.expect(k1.eql(k2));
    try testing.expect(k1.hashCode() == k2.hashCode());

    // Different socket -> different key
    const k3 = HashKey.init(43, &addr);
    try testing.expect(!k1.eql(k3));
}

test "HashKey: init IPv6" {
    const addr = InetAddress.initV6(.{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, 9993);
    const k1 = HashKey.init(10, &addr);
    const k2 = HashKey.init(10, &addr);

    try testing.expect(k1.eql(k2));

    // Different address -> different key
    const addr2 = InetAddress.initV6(.{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    }, 9993);
    const k3 = HashKey.init(10, &addr2);
    try testing.expect(!k1.eql(k3));
}

test "HashKey: zero" {
    const k = HashKey.zero();
    try testing.expectEqual(@as(u64, 0), k.hashCode());
    try testing.expect(k.eql(HashKey.zero()));
}

test "Path: send with callback" {
    // Test the send function with a mock callback
    const MockSender = struct {
        var call_count: u32 = 0;
        var last_socket: i64 = 0;
        var last_len: u32 = 0;

        fn sendFn(
            _: ?*anyopaque,
            local_socket: i64,
            _: *const InetAddress,
            _: [*]const u8,
            data_len: u32,
        ) bool {
            call_count += 1;
            last_socket = local_socket;
            last_len = data_len;
            return true;
        }
    };

    MockSender.call_count = 0;

    var p = Path.initWithAddress(77, InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993));
    const data = "hello";

    const result = p.send(&MockSender.sendFn, null, data, 5000);
    try testing.expect(result);
    try testing.expectEqual(@as(u32, 1), MockSender.call_count);
    try testing.expectEqual(@as(i64, 77), MockSender.last_socket);
    try testing.expectEqual(@as(u32, 5), MockSender.last_len);
    try testing.expectEqual(@as(i64, 5000), p.lastOut());
}

test "Path: send failure does not update lastOut" {
    const FailSender = struct {
        fn sendFn(_: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32) bool {
            return false;
        }
    };

    var p = Path.initWithAddress(1, InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993));
    const result = p.send(&FailSender.sendFn, null, "test", 5000);
    try testing.expect(!result);
    try testing.expectEqual(@as(i64, 0), p.lastOut());
}
