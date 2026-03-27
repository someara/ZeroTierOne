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
const NetworkConfig = @import("network_config.zig").NetworkConfig;
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

/// Housekeeping period (ms)
const housekeeping_period: i64 = 120000; // 2 minutes

/// Event types (map to ZT_Event)
const event_up: u32 = 0;
const event_offline: u32 = 1;
const event_online: u32 = 2;

/// State object types (map to ZT_StateObjectType)
const state_object_identity_public: u32 = 0;
const state_object_identity_secret: u32 = 1;
const state_object_network_config: u32 = 3;

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

    // PRNG state for generating random values
    prng_state: u64,

    const Self = @This();

    /// Create a new Node instance.
    pub fn init(
        allocator: mem.Allocator,
        user_ptr: ?*anyopaque,
        t_ptr: ?*anyopaque,
        config: *const Config,
        callbacks: Callbacks,
        now: i64,
    ) !Self {
        _ = config;

        // Load or generate identity
        const identity = try Self.loadOrGenerateIdentity(allocator, t_ptr, &callbacks);

        // Initialize Switch
        const switch_engine = try allocator.create(Switch);
        errdefer allocator.destroy(switch_engine);

        switch_engine.* = try Switch.init(allocator);

        // TODO: Initialize other subsystems
        // - Topology
        // - Multicaster
        // - SelfAwareness
        // - Bond
        // - PacketMultiplexer

        var node = Self{
            .allocator = allocator,
            .identity = identity,
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
            .prng_state = @as(u64, @bitCast(now)) ^ identity.address().toInt(),
        };

        // Post UP event
        node.postEvent(t_ptr, event_up);

        return node;
    }

    /// Load identity from state or generate a new one.
    fn loadOrGenerateIdentity(
        allocator: mem.Allocator,
        t_ptr: ?*anyopaque,
        callbacks: *const Callbacks,
    ) !Identity {
        var buf: [2048]u8 = undefined;
        var id_key: [2]u64 = .{ 0, 0 };

        // Try to load existing identity
        const n = callbacks.stateObjectGet(
            callbacks.ctx,
            t_ptr,
            state_object_identity_secret,
            &id_key,
            &buf,
            buf.len - 1,
        );

        if (n > 0) {
            // Parse existing identity
            buf[@intCast(n)] = 0;
            const id_str = buf[0..@intCast(n)];

            var identity = Identity.init();
            if (identity.fromString(id_str)) {
                if (identity.locallyValidate()) {
                    return identity;
                }
            }
            return error.InvalidIdentity;
        }

        // Generate new identity
        var identity = try Identity.generate(allocator);
        errdefer identity.deinit();

        // Save to state
        var secret_str: [512]u8 = undefined;
        const secret_len = identity.toString(true, &secret_str);

        id_key[0] = identity.address().toInt();
        id_key[1] = 0;

        callbacks.stateObjectPut(
            callbacks.ctx,
            t_ptr,
            state_object_identity_secret,
            &id_key,
            &secret_str,
            secret_len,
        );

        var public_str: [512]u8 = undefined;
        const public_len = identity.toString(false, &public_str);

        callbacks.stateObjectPut(
            callbacks.ctx,
            t_ptr,
            state_object_identity_public,
            &id_key,
            &public_str,
            public_len,
        );

        return identity;
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

        // Create proper Switch callbacks
        const switch_callbacks = self.createSwitchCallbacks();

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
        _ = network;

        // Call switch to inject frame
        const callbacks = self.createSwitchCallbacks();
        self.switch_engine.onLocalEthernet(
            t_ptr,
            nwid,
            source_mac,
            dest_mac,
            @intCast(ether_type),
            @intCast(vlan_id),
            data,
            len,
            now,
            &callbacks,
        );
    }

    /// Run periodic background tasks.
    pub fn processBackgroundTasks(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
    ) u64 {
        self.now = now;

        var next_task_deadline: u64 = ping_check_interval;

        // Ping check
        const time_since_last_ping = now - self.last_ping_check;
        const time_until_next_ping = if (self.low_bandwidth_mode)
            ping_check_interval * 5
        else
            ping_check_interval;

        if (time_since_last_ping >= time_until_next_ping) {
            self.last_ping_check = now;

            // TODO: Get roots to contact
            // TODO: Ping active peers
            // TODO: Request network configs
            // TODO: Check online status

            // For now, just mark as online
            if (!self.online) {
                self.online = true;
                self.callbacks.event(self.callbacks.ctx, t_ptr, event_online, null);
            }
        } else {
            next_task_deadline = @intCast(time_until_next_ping - time_since_last_ping);
        }

        // Housekeeping
        if ((now - self.last_housekeeping_run) >= housekeeping_period) {
            self.last_housekeeping_run = now;

            // Periodic housekeeping tasks
            // (Topology, SelfAwareness, Multicaster would be called here when implemented)
        }

        // Switch timer tasks
        const switch_callbacks = self.createSwitchCallbacks();
        const switch_deadline = self.switch_engine.doTimerTasks(
            t_ptr,
            now,
            &switch_callbacks,
        );

        return @min(next_task_deadline, switch_deadline);
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
    pub fn leaveNetwork(
        self: *Self,
        t_ptr: ?*anyopaque,
        nwid: u64,
        user_ptr_out: ?*?*anyopaque,
    ) void {
        self.networks_mutex.lock();

        if (self.networks.fetchRemove(nwid)) |kv| {
            const network = kv.value;

            // Return user pointer if requested
            if (user_ptr_out) |out| {
                out.* = network.userPtr();
            }

            // Notify application
            // TODO: Get network config and send DESTROY event

            self.networks_mutex.unlock();

            network.deinit();
            self.allocator.destroy(network);
        } else {
            self.networks_mutex.unlock();
        }

        // Delete state
        var id_key: [2]u64 = .{ nwid, 0 };
        self.callbacks.stateObjectDelete(
            self.callbacks.ctx,
            t_ptr,
            state_object_network_config,
            &id_key,
        );
    }

    /// Get network configuration.
    pub fn getNetworkConfig(self: *Self, nwid: u64) ?*NetworkConfig {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        if (self.getNetwork(nwid)) |network| {
            // TODO: Return network config
            _ = network;
            return null;
        }
        return null;
    }

    /// List all networks.
    pub fn listNetworks(self: *Self, allocator: mem.Allocator) ![]u64 {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        var list = try allocator.alloc(u64, self.networks.count());
        var iter = self.networks.keyIterator();
        var i: usize = 0;

        while (iter.next()) |nwid| {
            list[i] = nwid.*;
            i += 1;
        }

        return list;
    }

    /// Initialize multithreading (for PacketMultiplexer).
    pub fn initMultithreading(
        self: *Self,
        concurrency: u32,
        cpu_pinning_enabled: bool,
    ) void {
        _ = self;
        _ = concurrency;
        _ = cpu_pinning_enabled;
        // TODO: Call packet_multiplexer.setUpPostDecodeReceiveThreads
    }

    /// Set network controller instance.
    pub fn setNetconfMaster(
        self: *Self,
        controller_instance: ?*anyopaque,
    ) void {
        _ = self;
        _ = controller_instance;
        // TODO: Set local network controller
    }

    /// Add a local interface address for path selection.
    pub fn addLocalInterfaceAddress(
        self: *Self,
        addr: *const InetAddress,
    ) bool {
        _ = self;

        if (!addr.isValid()) {
            return false;
        }

        // TODO: Add to direct paths list
        return true;
    }

    /// Clear all local interface addresses.
    pub fn clearLocalInterfaceAddresses(self: *Self) void {
        _ = self;
        // TODO: Clear direct paths list
    }

    /// Set low bandwidth mode.
    pub fn setLowBandwidthMode(self: *Self, enabled: bool) void {
        self.low_bandwidth_mode = enabled;
    }

    /// Check if online.
    pub fn isOnline(self: *const Self) bool {
        return self.online;
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

    /// Get PRNG value using xorshift64*.
    pub fn prng(self: *Self) u64 {
        // xorshift64* algorithm
        var x = self.prng_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.prng_state = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    /// Check if a path should be used for ZeroTier traffic.
    pub fn shouldUsePathForZeroTierTraffic(
        self: *Self,
        t_ptr: ?*anyopaque,
        zt_addr: Address,
        local_socket: i64,
        remote_addr: *const InetAddress,
    ) bool {
        _ = self;
        _ = t_ptr;
        _ = zt_addr;
        _ = local_socket;

        // Basic validation
        if (!remote_addr.isValid()) {
            return false;
        }

        // TODO: Check topology for prohibited endpoints
        // TODO: Check networks for conflicts with static IPs
        // TODO: Call pathCheckFunction callback if provided

        return true;
    }

    /// Send a user message to another node.
    pub fn sendUserMessage(
        self: *Self,
        t_ptr: ?*anyopaque,
        dest: u64,
        type_id: u64,
        data: [*]const u8,
        len: u32,
    ) bool {
        if (self.identity.address().toInt() == dest) {
            return false;
        }

        _ = t_ptr;
        _ = type_id;
        _ = data;
        _ = len;

        // TODO: Create USER_MESSAGE packet
        // TODO: Send via switch

        return true;
    }

    /// Post an event to the application.
    fn postEvent(self: *Self, t_ptr: ?*anyopaque, event_type: u32) void {
        self.callbacks.event(self.callbacks.ctx, t_ptr, event_type, null);
    }

    /// Create Switch callbacks that route to Node methods.
    fn createSwitchCallbacks(self: *Self) Switch.Callbacks {
        return Switch.Callbacks{
            .ctx = @ptrCast(self),

            .lookupPeer = struct {
                fn f(_: ?*anyopaque, _: Address) ?*anyopaque {
                    // TODO: Call topology.getPeer
                    return null;
                }
            }.f,

            .sendViaPeer = struct {
                fn f(_: ?*anyopaque, _: *anyopaque, _: *const @import("packet.zig").Packet, _: bool, _: i64, _: i32) void {
                    // TODO: Implement peer send
                }
            }.f,

            .peerAddress = struct {
                fn f(_: *anyopaque) Address {
                    // TODO: Get peer address
                    return Address.init(0);
                }
            }.f,

            .isUpstream = struct {
                fn f(_: ?*anyopaque, _: Address) bool {
                    // TODO: Call topology.isUpstream
                    return false;
                }
            }.f,

            .getNetwork = struct {
                fn f(ctx: ?*anyopaque, nwid: u64) ?*anyopaque {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return @ptrCast(node.getNetwork(nwid));
                }
            }.f,

            .networkHasConfig = struct {
                fn f(network: *anyopaque) bool {
                    const net: *Network = @ptrCast(@alignCast(network));
                    return net.hasConfig();
                }
            }.f,

            .networkMac = struct {
                fn f(network: *anyopaque) MAC {
                    const net: *Network = @ptrCast(@alignCast(network));
                    return net.mac();
                }
            }.f,

            .networkId = struct {
                fn f(network: *anyopaque) u64 {
                    const net: *Network = @ptrCast(@alignCast(network));
                    return net.id();
                }
            }.f,

            .networkPermitsBridging = struct {
                fn f(network: *anyopaque, addr: Address) bool {
                    const net: *Network = @ptrCast(@alignCast(network));
                    return net.permitsBridging(addr);
                }
            }.f,

            .networkQosEnabled = struct {
                fn f(network: *anyopaque) bool {
                    const net: *Network = @ptrCast(@alignCast(network));
                    return net.qosEnabled();
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
                    const pkt = @import("packet.zig").Packet.init();
                    // TODO: Set destination, source, verb
                    _ = dest;
                    _ = src;
                    _ = verb;
                    return pkt;
                }
            }.f,

            .packetAppendNetworkId = struct {
                fn f(pkt: *@import("packet.zig").Packet, nwid: u64) void {
                    _ = pkt;
                    _ = nwid;
                    // TODO: Append to packet
                }
            }.f,

            .packetAppendEtherType = struct {
                fn f(pkt: *@import("packet.zig").Packet, et: u16) void {
                    _ = pkt;
                    _ = et;
                    // TODO: Append to packet
                }
            }.f,

            .packetAppendData = struct {
                fn f(pkt: *@import("packet.zig").Packet, data: [*]const u8, len: u32) void {
                    _ = pkt;
                    _ = data;
                    _ = len;
                    // TODO: Append to packet
                }
            }.f,

            .packetAppendByte = struct {
                fn f(pkt: *@import("packet.zig").Packet, b: u8) void {
                    _ = pkt;
                    _ = b;
                    // TODO: Append to packet
                }
            }.f,

            .packetAppendMAC = struct {
                fn f(pkt: *@import("packet.zig").Packet, mac: *const MAC) void {
                    _ = pkt;
                    _ = mac;
                    // TODO: Append to packet
                }
            }.f,

            .putFrame = struct {
                fn f(ctx: ?*anyopaque, nwid: u64, _: *anyopaque, from: *const MAC, to: *const MAC, ether_type: u32, vlan_id: u32, data: [*]const u8, len: u32) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.callbacks.frameInject(
                        node.callbacks.ctx,
                        null,
                        nwid,
                        from.toInt(),
                        to.toInt(),
                        ether_type,
                        vlan_id,
                        data,
                        len,
                    );
                }
            }.f,

            .multicastSend = struct {
                fn f(_: ?*anyopaque, _: *anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: [*]const u8, _: u32, _: bool) void {
                    // TODO: Implement multicast send via multicaster
                }
            }.f,

            .pathReceived = struct {
                fn f(_: ?*anyopaque, _: i64, _: *const InetAddress, _: i64) void {
                    // TODO: Update path timestamp via topology
                }
            }.f,

            .now = struct {
                fn f(ctx: ?*anyopaque) i64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.now;
                }
            }.f,
        };
    }

    /// Get planet (root server world).
    pub fn getPlanet(self: *const Self) ?*const anyopaque {
        _ = self;
        // TODO: Return topology.planet()
        return null;
    }

    /// Get moons (user root servers).
    pub fn getMoons(self: *Self, allocator: mem.Allocator) ![]u64 {
        _ = self;
        // TODO: Get from topology
        return try allocator.alloc(u64, 0);
    }

    /// Free a query result.
    pub fn freeQueryResult(allocator: mem.Allocator, result: anytype) void {
        allocator.free(result);
    }

    /// Check if node belongs to a network.
    pub fn belongsToNetwork(self: *Self, nwid: u64) bool {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();
        return self.networks.contains(nwid);
    }

    /// Get all networks.
    pub fn allNetworks(self: *Self, allocator: mem.Allocator) ![]u64 {
        return self.listNetworks(allocator);
    }

    /// Send a packet on the wire.
    pub fn putPacket(
        self: *Self,
        t_ptr: ?*anyopaque,
        local_socket: i64,
        addr: *const InetAddress,
        data: [*]const u8,
        len: u32,
        ttl: i32,
    ) void {
        self.callbacks.wireSend(
            self.callbacks.ctx,
            t_ptr,
            local_socket,
            addr,
            data,
            len,
            ttl,
        );
    }

    /// Inject a frame into virtual network.
    pub fn putFrame(
        self: *Self,
        t_ptr: ?*anyopaque,
        nwid: u64,
        user_ptr: ?*?*anyopaque,
        source: *const MAC,
        dest: *const MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
    ) void {
        _ = user_ptr;
        self.callbacks.frameInject(
            self.callbacks.ctx,
            t_ptr,
            nwid,
            source.toInt(),
            dest.toInt(),
            ether_type,
            vlan_id,
            data,
            len,
        );
    }

    /// Configure a virtual network port.
    pub fn configureVirtualNetworkPort(
        self: *Self,
        t_ptr: ?*anyopaque,
        nwid: u64,
        user_ptr: ?*?*anyopaque,
        operation: u32,
        config: ?*const anyopaque,
    ) i32 {
        _ = self;
        _ = t_ptr;
        _ = nwid;
        _ = user_ptr;
        _ = operation;
        _ = config;
        // TODO: Call virtualNetworkConfigFunction callback
        return 0;
    }
};

// ── Configuration ─────────────────────────────────────────────────

/// Node configuration (maps to ZT_Node_Config).
pub const Config = struct {
    // Configuration fields would go here
    // For now, this is a placeholder struct
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

    stateObjectDelete: *const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        object_type: u32,
        id: [*]const u64,
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
                return 0; // No stored identity
            }
        }.f,
        .stateObjectPut = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]const u8, _: u32) void {}
        }.f,
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
    defer node.deinit();

    // PRNG should produce different values
    const r1 = node.prng();
    const r2 = node.prng();
    try testing.expect(r1 != 0);
    try testing.expect(r2 != 0);
    // Note: they might be equal by chance, but unlikely
}

test "Node: network list" {
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
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
    defer node.deinit();

    // Join two networks
    _ = try node.joinNetwork(0x1111111111111111);
    _ = try node.joinNetwork(0x2222222222222222);

    // List should have both
    const list = try node.listNetworks(testing.allocator);
    defer testing.allocator.free(list);

    try testing.expectEqual(@as(usize, 2), list.len);
}

test "Node: belongsToNetwork" {
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
        .stateObjectDelete = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}
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

    var node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;

    // Should not belong initially
    try testing.expect(!node.belongsToNetwork(nwid));

    // Join network
    _ = try node.joinNetwork(nwid);

    // Should belong now
    try testing.expect(node.belongsToNetwork(nwid));

    // Leave network
    node.leaveNetwork(null, nwid, null);

    // Should not belong anymore
    try testing.expect(!node.belongsToNetwork(nwid));
}
