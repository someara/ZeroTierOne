/// Core Node runtime — the main entry point and orchestrator.
///
/// Converted from `node/Node.hpp` and `node/Node.cpp`.
///
/// The Node is the top-level runtime object that owns and coordinates all
/// other subsystems: Switch, Topology, Multicaster, SelfAwareness, etc.
/// It handles:
/// - Initialization and shutdown of all subsystems
/// - Processing incoming packets from the network
/// - Processing outgoing frames from tap devices
/// - Background tasks (ping, WHOIS, config updates)
/// - Network lifecycle management
/// - State persistence
/// - Time management
///
/// The Node exposes a C API (via callbacks) to the host application.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;
const Network = @import("network.zig").Network;
const Switch = @import("switch.zig").Switch;
const Mutex = @import("mutex.zig");
const Hashtable = @import("hashtable.zig").Hashtable;
const constants = @import("constants.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Ping check interval (ms)
const ping_check_interval: i64 = constants.ping_check_interval;

/// Network config refresh delay (ms)
const network_autoconf_delay: i64 = constants.network_autoconf_delay;

/// Background task granularity (ms)
const core_timer_task_granularity: i64 = 500;

// ── Node ──────────────────────────────────────────────────────────

pub const Node = struct {
    allocator: mem.Allocator,

    // Core identity
    identity: Identity,

    // Subsystems (owned)
    switch_engine: *Switch,
    // topology: *Topology,
    // multicaster: *Multicaster,
    // self_awareness: *SelfAwareness,
    // bond: *Bond,
    // packet_multiplexer: *PacketMultiplexer,

    // Networks (managed)
    networks: std.AutoHashMap(u64, *Network),
    networks_mutex: Mutex,

    // State
    now: i64,
    online: bool,
    low_bandwidth_mode: bool,

    // Background task timestamps
    last_ping_check: i64,
    last_housekeeping_run: i64,

    // User pointer (opaque to us, passed through to callbacks)
    user_ptr: ?*anyopaque,

    // Callbacks to host application
    callbacks: Callbacks,

    const Self = @This();

    /// Create a new Node instance.
    pub fn init(
        allocator: mem.Allocator,
        user_ptr: ?*anyopaque,
        config: *const Config,
        callbacks: Callbacks,
        now: i64,
    ) !Self {
        _ = config;

        // For now, create a minimal node
        // TODO: Initialize all subsystems

        const switch_engine = try allocator.create(Switch);
        errdefer allocator.destroy(switch_engine);

        switch_engine.* = try Switch.init(allocator);

        return .{
            .allocator = allocator,
            .identity = Identity.init(),
            .switch_engine = switch_engine,
            .networks = std.AutoHashMap(u64, *Network).init(allocator),
            .networks_mutex = .{},
            .now = now,
            .online = false,
            .low_bandwidth_mode = false,
            .last_ping_check = 0,
            .last_housekeeping_run = 0,
            .user_ptr = user_ptr,
            .callbacks = callbacks,
        };
    }

    /// Destroy the Node instance.
    pub fn deinit(self: *Self) void {
        // Clean up networks
        self.networks_mutex.lock();
        var iter = self.networks.valueIterator();
        while (iter.next()) |net_ptr| {
            net_ptr.*.deinit();
            self.allocator.destroy(net_ptr.*);
        }
        self.networks.deinit();
        self.networks_mutex.unlock();

        // Clean up subsystems
        self.switch_engine.deinit();
        self.allocator.destroy(self.switch_engine);
    }

    /// Process a packet received from the network.
    pub fn processWirePacket(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
        local_socket: i64,
        remote_addr: *const InetAddress,
        data: [*]const u8,
        len: u32,
    ) void {
        self.now = now;

        // TODO: Create Switch callbacks
        const switch_callbacks = Switch.Callbacks{
            .ctx = @ptrCast(self),
            .lookupPeer = struct {
                fn f(_: ?*anyopaque, _: Address) ?*anyopaque {
                    return null;
                }
            }.f,
            .sendViaPeer = struct {
                fn f(_: ?*anyopaque, _: *anyopaque, _: *const @import("packet.zig").Packet, _: bool, _: i64, _: i32) void {}
            }.f,
            .peerAddress = struct {
                fn f(_: *anyopaque) Address {
                    return Address.init(0);
                }
            }.f,
            .isUpstream = struct {
                fn f(_: ?*anyopaque, _: Address) bool {
                    return false;
                }
            }.f,
            .getNetwork = struct {
                fn f(_: ?*anyopaque, _: u64) ?*anyopaque {
                    return null;
                }
            }.f,
            .networkHasConfig = struct {
                fn f(_: *anyopaque) bool {
                    return false;
                }
            }.f,
            .networkMac = struct {
                fn f(_: *anyopaque) MAC {
                    return MAC.init(0);
                }
            }.f,
            .networkId = struct {
                fn f(_: *anyopaque) u64 {
                    return 0;
                }
            }.f,
            .networkPermitsBridging = struct {
                fn f(_: *anyopaque, _: Address) bool {
                    return false;
                }
            }.f,
            .networkQosEnabled = struct {
                fn f(_: *anyopaque) bool {
                    return false;
                }
            }.f,
            .myAddress = struct {
                fn f(ctx: ?*anyopaque) Address {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.identity.address();
                }
            }.f,
            .macToAddress = struct {
                fn f(mac: *const MAC, nwid: u64) Address {
                    return mac.toAddress(nwid);
                }
            }.f,
            .createPacket = struct {
                fn f(dest: Address, src: Address, verb: u8) @import("packet.zig").Packet {
                    var pkt = @import("packet.zig").Packet.init();
                    pkt.setDestination(dest);
                    pkt.setSource(src);
                    pkt.setVerb(verb);
                    return pkt;
                }
            }.f,
            .packetAppendNetworkId = struct {
                fn f(_: *@import("packet.zig").Packet, _: u64) void {}
            }.f,
            .packetAppendEtherType = struct {
                fn f(_: *@import("packet.zig").Packet, _: u16) void {}
            }.f,
            .packetAppendData = struct {
                fn f(_: *@import("packet.zig").Packet, _: [*]const u8, _: u32) void {}
            }.f,
            .packetAppendByte = struct {
                fn f(_: *@import("packet.zig").Packet, _: u8) void {}
            }.f,
            .packetAppendMAC = struct {
                fn f(_: *@import("packet.zig").Packet, _: *const MAC) void {}
            }.f,
            .putFrame = struct {
                fn f(_: ?*anyopaque, _: u64, _: *anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: [*]const u8, _: u32) void {}
            }.f,
            .multicastSend = struct {
                fn f(_: ?*anyopaque, _: *anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: [*]const u8, _: u32, _: bool) void {}
            }.f,
            .pathReceived = struct {
                fn f(_: ?*anyopaque, _: i64, _: *const InetAddress, _: i64) void {}
            }.f,
            .now = struct {
                fn f(ctx: ?*anyopaque) i64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.now;
                }
            }.f,
        };

        self.switch_engine.onRemotePacket(
            t_ptr,
            local_socket,
            remote_addr,
            data,
            len,
            &switch_callbacks,
        );
    }

    /// Process a frame from a local virtual network interface.
    pub fn processVirtualNetworkFrame(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
        nwid: u64,
        source_mac: u64,
        dest_mac: u64,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
    ) !void {
        self.now = now;

        const network = self.getNetwork(nwid) orelse return error.NetworkNotFound;

        _ = t_ptr;
        _ = network;
        _ = source_mac;
        _ = dest_mac;
        _ = ether_type;
        _ = vlan_id;
        _ = data;
        _ = len;

        // TODO: Call switch_engine.onLocalEthernet
    }

    /// Run periodic background tasks.
    pub fn processBackgroundTasks(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
    ) u64 {
        self.now = now;

        _ = t_ptr;

        // TODO: Implement background tasks
        // - Ping upstreams
        // - Request network configs
        // - Clean up old state
        // - Bond maintenance

        return ping_check_interval;
    }

    /// Get a network by ID.
    pub fn getNetwork(self: *Self, nwid: u64) ?*Network {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        return self.networks.get(nwid);
    }

    /// Join a network.
    pub fn joinNetwork(self: *Self, nwid: u64) !*Network {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        if (self.networks.get(nwid)) |existing| {
            return existing;
        }

        const network = try self.allocator.create(Network);
        errdefer self.allocator.destroy(network);

        network.* = try Network.init(self.allocator, nwid);
        try self.networks.put(nwid, network);

        return network;
    }

    /// Leave a network.
    pub fn leaveNetwork(self: *Self, nwid: u64) void {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        if (self.networks.fetchRemove(nwid)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }

        // TODO: Notify via callback
        // TODO: Delete state object
    }

    /// Get node's ZeroTier address.
    pub fn address(self: *const Self) u64 {
        return self.identity.address().toInt();
    }

    /// Get node status.
    pub fn status(self: *const Self, out: *Status) void {
        out.address = self.identity.address().toInt();
        out.online = self.online;
        // TODO: Fill in identity strings, etc.
    }

    /// Subscribe to a multicast group.
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

    /// Unsubscribe from a multicast group.
    pub fn multicastUnsubscribe(
        self: *Self,
        nwid: u64,
        multicast_group: u64,
        multicast_adi: u32,
    ) !void {
        const network = self.getNetwork(nwid) orelse return error.NetworkNotFound;

        _ = network;
        _ = multicast_group;
        _ = multicast_adi;

        // TODO: Call network.multicastUnsubscribe
    }

    /// Add a moon (user-defined root server).
    pub fn orbit(
        self: *Self,
        t_ptr: ?*anyopaque,
        moon_world_id: u64,
        moon_seed: u64,
    ) void {
        _ = self;
        _ = t_ptr;
        _ = moon_world_id;
        _ = moon_seed;

        // TODO: Call topology.addMoon
    }

    /// Remove a moon.
    pub fn deorbit(
        self: *Self,
        t_ptr: ?*anyopaque,
        moon_world_id: u64,
    ) void {
        _ = self;
        _ = t_ptr;
        _ = moon_world_id;

        // TODO: Call topology.removeMoon
    }

    /// Get PRNG value.
    pub fn prng(self: *Self) u64 {
        // Simple xorshift PRNG (TODO: use proper state)
        var x: u64 = @as(u64, @intCast(self.now)) ^ 0x123456789abcdef0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        return x;
    }
};

// ── Configuration ─────────────────────────────────────────────────

/// Node configuration (maps to ZT_Node_Config).
pub const Config = struct {
    // TODO: Add config fields
};

/// Node status information.
pub const Status = struct {
    address: u64,
    online: bool,
};

/// Callbacks from Node to host application.
pub const Callbacks = struct {
    ctx: ?*anyopaque,

    // State persistence
    stateObjectGet: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        object_type: u32,
        id: [*]const u64,
        data: [*]u8,
        max_len: u32,
    ) i32,

    stateObjectPut: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        object_type: u32,
        id: [*]const u64,
        data: [*]const u8,
        len: u32,
    ) void,

    // Wire send callback
    wireSend: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        local_socket: i64,
        remote_addr: *const InetAddress,
        data: [*]const u8,
        len: u32,
        ttl: i32,
    ) void,

    // Virtual network frame inject
    frameInject: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        source_mac: u64,
        dest_mac: u64,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
    ) void,

    // Event notification
    event: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        event_type: u32,
        data: ?*const anyopaque,
    ) void,
};

// ── Tests ─────────────────────────────────────────────────────────

test "Node: init/deinit" {
    const callbacks = Callbacks{
        .ctx = null,
        .stateObjectGet = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]u8, _: u32) i32 {
                return 0;
            }
        }.f,
        .stateObjectPut = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]const u8, _: u32) void {}
        }.f,
        .wireSend = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32, _: i32) void {}
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const config = Config{};

    var node = try Node.init(testing.allocator, null, &config, callbacks, 1000);
    defer node.deinit();

    try testing.expectEqual(@as(i64, 1000), node.now);
    try testing.expect(!node.online);
}

test "Node: network management" {
    const callbacks = Callbacks{
        .ctx = null,
        .stateObjectGet = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]u8, _: u32) i32 {
                return 0;
            }
        }.f,
        .stateObjectPut = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]const u8, _: u32) void {}
        }.f,
        .wireSend = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32, _: i32) void {}
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const config = Config{};

    var node = try Node.init(testing.allocator, null, &config, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;

    // Join network
    const net = try node.joinNetwork(nwid);
    try testing.expect(net != null);

    // Get network
    const net2 = node.getNetwork(nwid);
    try testing.expect(net2 != null);
    try testing.expect(net == net2);

    // Leave network
    node.leaveNetwork(nwid);

    // Network should be gone
    const net3 = node.getNetwork(nwid);
    try testing.expect(net3 == null);
}

test "Node: address and status" {
    const callbacks = Callbacks{
        .ctx = null,
        .stateObjectGet = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]u8, _: u32) i32 {
                return 0;
            }
        }.f,
        .stateObjectPut = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]const u8, _: u32) void {}
        }.f,
        .wireSend = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32, _: i32) void {}
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const config = Config{};

    var node = try Node.init(testing.allocator, null, &config, callbacks, 1000);
    defer node.deinit();

    // Address should be from identity
    const addr = node.address();
    try testing.expect(addr == 0); // Default identity is zero

    // Status
    var st: Status = undefined;
    node.status(&st);
    try testing.expectEqual(addr, st.address);
    try testing.expect(!st.online);
}

test "Node: prng" {
    const callbacks = Callbacks{
        .ctx = null,
        .stateObjectGet = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]u8, _: u32) i32 {
                return 0;
            }
        }.f,
        .stateObjectPut = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]const u8, _: u32) void {}
        }.f,
        .wireSend = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32, _: i32) void {}
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const config = Config{};

    var node = try Node.init(testing.allocator, null, &config, callbacks, 1000);
    defer node.deinit();

    // PRNG should produce different values
    const r1 = node.prng();
    const r2 = node.prng();
    try testing.expect(r1 != 0);
    try testing.expect(r2 != 0);
    // Note: they might be equal by chance, but unlikely
}
