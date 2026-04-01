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
const identity_mod = @import("identity.zig");
const Identity = identity_mod.Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;
const network_mod = @import("network.zig");
const Network = network_mod.Network;
const NetworkConfig = @import("network_config.zig").NetworkConfig;
const Packet = @import("packet.zig").Packet;
const Switch = @import("switch.zig").Switch;
const Topology = @import("topology.zig").Topology;
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
    topology: *Topology,
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

        // Initialize Topology
        const topology = try allocator.create(Topology);
        errdefer allocator.destroy(topology);

        Topology.create(topology, &identity);

        // TODO: Initialize other subsystems
        // - Multicaster
        // - SelfAwareness
        // - Bond
        // - PacketMultiplexer

        var node = Self{
            .allocator = allocator,
            .identity = identity,
            .switch_engine = switch_engine,
            .topology = topology,
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
            // Parse existing identity (trim whitespace from file)
            const raw = buf[0..@intCast(n)];
            const id_str = mem.trim(u8, raw, &std.ascii.whitespace);

            if (Identity.fromString(id_str)) |identity| {
                if (identity.locallyValidate(allocator) catch false) {
                    return identity;
                }
            }
            return error.InvalidIdentity;
        }

        // Generate new identity
        var identity = try Identity.generate(allocator);
        errdefer identity.deinit();

        // Save to state
        var secret_buf: [identity_mod.string_buffer_length]u8 = undefined;
        const secret_str = identity.toString(true, &secret_buf);

        id_key[0] = identity.address().toInt();
        id_key[1] = 0;

        callbacks.stateObjectPut(
            callbacks.ctx,
            t_ptr,
            state_object_identity_secret,
            &id_key,
            secret_str.ptr,
            @intCast(secret_str.len),
        );

        var public_buf: [identity_mod.string_buffer_length]u8 = undefined;
        const public_str = identity.toString(false, &public_buf);

        callbacks.stateObjectPut(
            callbacks.ctx,
            t_ptr,
            state_object_identity_public,
            &id_key,
            public_str.ptr,
            @intCast(public_str.len),
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

        // Note: Topology doesn't have a deinit method, just free the memory
        self.allocator.destroy(self.topology);
    }

    /// Process a packet received from the network.
    pub fn processWirePacket(
        self: *Self,
        _: ?*anyopaque,
        now: i64,
        local_socket: i64,
        remote_addr: *const InetAddress,
        data: [*]const u8,
        len: u32,
    ) void {
        self.now = now;

        // Minimum ZeroTier packet is 28 bytes (header only)
        if (len < 28) return;

        // Create proper Switch callbacks
        const switch_callbacks = self.createSwitchCallbacks();

        self.switch_engine.onRemotePacket(
            @ptrCast(self),
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

        // Convert u64 MAC addresses to MAC structs
        const from_mac = MAC.init(source_mac);
        const to_mac = MAC.init(dest_mac);

        const callbacks = self.createSwitchCallbacks();
        self.switch_engine.onLocalEthernet(
            t_ptr,
            @ptrCast(network),
            &from_mac,
            &to_mac,
            ether_type,
            vlan_id,
            data,
            len,
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

            // Contact root servers — send HELLO to establish peer relationships
            {
                const TopologyMod = @import("topology.zig");
                const PeerMod = @import("peer.zig");

                var root_contacts: [TopologyMod.max_upstream_addresses]TopologyMod.Topology.RootContact = undefined;
                const root_count = self.topology.getRootsToContact(&root_contacts);

                if (root_count > 0) {
                    const hello_ctx = PeerMod.Peer.HelloContext{
                        .my_identity = &self.identity,
                        .planet_world_id = self.topology.planetWorldId(),
                        .planet_world_timestamp = self.topology.planetWorldTimestamp(),
                        .wireSendFn = self.callbacks.wireSend,
                        .wire_ctx = self.callbacks.ctx,
                        .t_ptr = t_ptr,
                    };

                    for (0..root_count) |ri| {
                        const rc = &root_contacts[ri];

                        if (rc.peer) |peer| {
                            // Ping/keepalive on existing paths (sends HELLO if due)
                            const sent_mask = peer.doPingAndKeepalive(now, &hello_ctx);

                            // Send HELLO to stable endpoints for uncovered address families
                            for (0..rc.endpoint_count) |ei| {
                                const ep = &rc.endpoints[ei];
                                const family = ep.family();
                                const covered = if (family == std.c.AF.INET)
                                    (sent_mask & 0x1) != 0
                                else
                                    (sent_mask & 0x2) != 0;

                                if (!covered) {
                                    peer.sendHELLO(ep, -1, now, &hello_ctx);
                                    break; // one per address family, like C++
                                }
                            }
                        }
                    }
                }
            }

            // Request network configs for networks that need them
            {
                self.networks_mutex.lock();
                defer self.networks_mutex.unlock();
                var net_iter = self.networks.valueIterator();
                while (net_iter.next()) |net_ptr| {
                    net_ptr.*.requestConfiguration(t_ptr);
                }
            }

            // Mark as online
            if (!self.online) {
                self.online = true;
                self.callbacks.event(self.callbacks.ctx, t_ptr, event_online, null);
            }
        } else {
            const remaining = time_until_next_ping - time_since_last_ping;
            // Guard against negative values (logic error case)
            if (remaining > 0) {
                next_task_deadline = @intCast(remaining);
            }
        }

        // Housekeeping
        if ((now - self.last_housekeeping_run) >= housekeeping_period) {
            self.last_housekeeping_run = now;

            // Periodic housekeeping tasks
            // (Topology, SelfAwareness, Multicaster would be called here when implemented)
        }

        // Switch timer tasks (pass self as t_ptr since switch callbacks expect it)
        const switch_callbacks = self.createSwitchCallbacks();
        const switch_deadline = self.switch_engine.doTimerTasks(
            @ptrCast(self),
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

        network.* = Network.init(
            self.allocator,
            nwid,
            self.identity.address(),
            self.user_ptr,
            self.createNetworkCallbacks(),
        );
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
                out.* = network._u_ptr;
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
    /// Caller owns returned slice and must free with allocator.free().
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
    fn createSwitchCallbacks(self: *Self) @import("switch.zig").Callbacks {
        const SwitchCallbacks = @import("switch.zig").Callbacks;
        return SwitchCallbacks{
            .ctx = @ptrCast(self),

            .lookupPeer = struct {
                fn f(ctx_or_tptr: ?*anyopaque, addr: Address) ?*anyopaque {
                    // Switch may pass t_ptr or ctx — handle both
                    const ptr = ctx_or_tptr orelse return null;
                    const node: *Self = @ptrCast(@alignCast(ptr));
                    return @ptrCast(node.topology.getPeer(addr));
                }
            }.f,

            .sendViaPeer = struct {
                fn f(ctx: ?*anyopaque, peer_ptr: *anyopaque, packet: *const @import("packet.zig").Packet, encrypt: bool, now: i64, flow_id: i32) void {
                    _ = flow_id;
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const Peer = @import("peer.zig").Peer;
                    const peer: *Peer = @ptrCast(@alignCast(peer_ptr));

                    // Get the best path to send to this peer
                    const path = peer.getAppropriatePath(now, false);
                    if (path == null) {
                        // No path available - drop packet
                        return;
                    }

                    // Make a mutable copy of the packet for encryption
                    var pkt = packet.*;

                    // Encrypt if requested
                    if (encrypt) {
                        const peer_key = peer.key();
                        const peer_aes = peer.aesKeysIfSupported();
                        const peer_pub = peer.identity().publicKey();
                        pkt.armor(peer_key[0..32], true, false, peer_aes, peer_pub);
                    }

                    // Send via the path
                    const pkt_data = pkt.buf.data();
                    const send_len = @min(pkt_data.len, @import("packet.zig").max_packet_length);
                    node.callbacks.wireSend(
                        node.callbacks.ctx,
                        null, // t_ptr
                        path.?.localSocket(),
                        path.?.address(),
                        pkt_data.ptr,
                        @intCast(send_len),
                        64, // ttl
                    );

                    // Mark path as sent
                    path.?.sent(now);
                }
            }.f,

            .peerAddress = struct {
                fn f(peer_ptr: *anyopaque) Address {
                    const PeerType = @import("peer.zig").Peer;
                    const peer: *PeerType = @ptrCast(@alignCast(peer_ptr));
                    return peer.address();
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
                    const pkt = @import("packet.zig").Packet.initEmpty();
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
                fn f(ctx: ?*anyopaque, local_socket: i64, from_addr: *const InetAddress, now: i64) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    // Get or create path and update timestamp
                    if (node.topology.getPath(local_socket, from_addr)) |path| {
                        const Path = @import("path.zig").Path;
                        const p: *Path = @ptrCast(@alignCast(path));
                        p.received(now);
                    }
                }
            }.f,

            .getPath = struct {
                fn f(ctx: ?*anyopaque, local_socket: i64, from_addr: *const InetAddress) ?*anyopaque {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return @ptrCast(node.topology.getPath(local_socket, from_addr));
                }
            }.f,

            .now = struct {
                fn f(ctx: ?*anyopaque) i64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.now;
                }
            }.f,

            .createIncomingPacketCallbacks = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque) @import("incoming_packet.zig").Callbacks {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.createIncomingPacketCallbacks(tptr);
                }
            }.f,

            .sendWhoisRequest = struct {
                fn f(ctx: ?*anyopaque, _: ?*anyopaque, pkt: *const Packet, _: i64) bool {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));

                    const TopologyMod = @import("topology.zig");

                    // Send WHOIS to root servers (upstream addresses from planet/moon)
                    var sent = false;
                    node.topology._upstreams_m.lock();
                    defer node.topology._upstreams_m.unlock();

                    // Send to all upstream addresses (root servers)
                    var i: usize = 0;
                    while (i < node.topology._upstream_count) : (i += 1) {
                        const upstream_addr = node.topology._upstream_addresses[i];

                        // Find peer and copy key material under lock.
                        // Lock order: _upstreams_m (held above) before _peers_m.
                        node.topology._peers_m.lock();

                        var found_peer: ?*@import("peer.zig").Peer = null;
                        var j: usize = 0;
                        while (j < TopologyMod.max_peers) : (j += 1) {
                            const entry = &node.topology._peers[j];
                            if (entry.in_use and entry.addr.eql(upstream_addr)) {
                                found_peer = &entry.peer;
                                break;
                            }
                        }

                        // If we have a peer, copy key and paths while still holding lock
                        if (found_peer) |peer| {
                            const PeerMod = @import("peer.zig");
                            var path_buf: [PeerMod.max_peer_network_paths]?*@import("path.zig").Path = undefined;
                            const path_count = peer.getAllPaths(&path_buf);

                            const peer_key = peer.key();
                            var key32: [32]u8 = undefined;
                            @memcpy(&key32, peer_key[0..32]);

                            // Copy path addresses while locked (paths are stable pointers
                            // from topology, but capture what we need now)
                            var path_addrs: [PeerMod.max_peer_network_paths]InetAddress = undefined;
                            var path_sockets: [PeerMod.max_peer_network_paths]i64 = undefined;
                            var pi: u32 = 0;
                            while (pi < path_count) : (pi += 1) {
                                if (path_buf[pi]) |path| {
                                    path_addrs[pi] = path.address().*;
                                    path_sockets[pi] = path.localSocket();
                                }
                            }

                            node.topology._peers_m.unlock();

                            // Armor and send outside the lock
                            var addressed_pkt = pkt.*;
                            addressed_pkt.setDestination(upstream_addr);
                            addressed_pkt.armor(&key32, true, false, null, null);

                            pi = 0;
                            while (pi < path_count) : (pi += 1) {
                                if (path_buf[pi] != null) {
                                    const pkt_data = addressed_pkt.buf.data();
                                    const pkt_len = @min(pkt_data.len, @import("packet.zig").max_packet_length);
                                    node.callbacks.wireSend(
                                        node.callbacks.ctx,
                                        null,
                                        path_sockets[pi],
                                        &path_addrs[pi],
                                        pkt_data.ptr,
                                        @intCast(pkt_len),
                                        64,
                                    );
                                    sent = true;
                                }
                            }
                        } else {
                            node.topology._peers_m.unlock();
                        }
                    }

                    return sent;
                }
            }.f,
        };
    }

    /// Create Network callbacks for config requests and network management.
    fn createNetworkCallbacks(self: *Self) network_mod.Callbacks {
        return network_mod.Callbacks{
            .ctx = @ptrCast(self),

            .now = struct {
                fn f(ctx: ?*anyopaque) i64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.now;
                }
            }.f,

            // configure_virtual_network_port left as null for now

            .network_config_request_sent = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, nwid: u64, controller: Address) void {
                    var ctrl_buf: [10]u8 = undefined;
                    std.debug.print("  → Config request sent for network {x:0>16} to controller {s}\n", .{ nwid, controller.toString(&ctrl_buf) });
                }
            }.f,

            .send_network_config_request = struct {
                fn f(ctx: ?*anyopaque, t_ptr: ?*anyopaque, nwid: u64, controller: Address, metadata: []const u8, config_revision: u64, config_timestamp: u64) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    _ = t_ptr;

                    // Build NETWORK_CONFIG_REQUEST packet
                    var pkt = Packet.initNew(controller, node.identity.address(), .network_config_request);

                    // Expand packet to hold payload before writing
                    const pkt_idx = @import("packet.zig").network_config_request_idx;
                    const meta_len: u16 = @intCast(@min(metadata.len, 0xFFFF));
                    const total_size = pkt_idx.idx_dict + meta_len;
                    pkt.buf.setSize(total_size) catch return;

                    // Payload: network ID (8 bytes)
                    pkt.buf.setAt(u64, pkt_idx.idx_network_id, @byteSwap(nwid)) catch return;

                    // Payload: metadata dict length (2 bytes) + metadata
                    pkt.buf.setAt(u16, pkt_idx.idx_dict_len, @byteSwap(meta_len)) catch return;

                    if (meta_len > 0) {
                        const dest = pkt.buf.fieldMut(pkt_idx.idx_dict, meta_len) catch return;
                        @memcpy(dest[0..meta_len], metadata[0..meta_len]);
                    }

                    // Include config revision/timestamp if we have existing config
                    _ = config_revision;
                    _ = config_timestamp;

                    // Send via switch
                    var ctrl_buf: [10]u8 = undefined;
                    std.debug.print("  [CONFIG_REQ] Sending packet to controller {s}, size={d}\n", .{ controller.toString(&ctrl_buf), pkt.buf.size() });
                    const switch_cbs = node.createSwitchCallbacks();
                    node.switch_engine.send(@ptrCast(node), &pkt, true, nwid, 0, &switch_cbs);
                }
            }.f,

            .prng = struct {
                fn f(ctx: ?*anyopaque) u64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.prng_state = node.prng_state *% 6364136223846793005 +% 1442695040888963407;
                    return node.prng_state;
                }
            }.f,
        };
    }

    /// Create IncomingPacket callbacks for verb processing.
    ///
    /// This bridges between the Node context and IncomingPacket's requirements.
    /// Most callbacks are stubbed for now - they'll be implemented as we add
    /// Topology, Peer, and Path management.
    fn createIncomingPacketCallbacks(self: *Self, t_ptr: ?*anyopaque) @import("incoming_packet.zig").Callbacks {
        const IncomingPacketCallbacks = @import("incoming_packet.zig").Callbacks;
        const IncomingAes = @import("aes.zig").Aes;
        const IncomingEcc = @import("ecc.zig");
        const MulticastGroup = @import("multicast_group.zig").MulticastGroup;

        return IncomingPacketCallbacks{
            .ctx = @ptrCast(self),
            .tptr = t_ptr,
            .local_identity = &self.identity,

            // Time
            .now = struct {
                fn f(ctx: ?*anyopaque) i64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.now;
                }
            }.f,

            // Topology
            .topologyShouldInboundPathBeTrusted = struct {
                fn f(_: ?*anyopaque, _: *const InetAddress, _: u64) bool {
                    return false; // TODO: Check trusted paths
                }
            }.f,

            .topologyGetPeer = struct {
                fn f(ctx: ?*anyopaque, _: ?*anyopaque, addr: u64) ?*anyopaque {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const peer_addr = Address.init(addr);
                    return @ptrCast(node.topology.getPeer(peer_addr));
                }
            }.f,

            // Switch
            .switchRequestWhois = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: u64) void {
                    // TODO: Request WHOIS via switch
                }
            }.f,

            // Node
            .nodeStatsLogVerb = struct {
                fn f(_: ?*anyopaque, _: u32, _: u32) void {
                    // TODO: Log verb statistics
                }
            }.f,

            .nodePostEvent = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, event: u32, data: ?*const anyopaque) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.callbacks.event(node.callbacks.ctx, tptr, event, data);
                }
            }.f,

            // Peer operations
            .peerKey = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) *const [32]u8 {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    // Return first 32 bytes of the 48-byte ECDH key for Salsa20
                    const key_48 = p.key();
                    return @ptrCast(key_48);
                }
            }.f,

            .peerAesKeys = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) ?*const [2]IncomingAes {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    return p.aesKeys();
                }
            }.f,

            .peerAesKeysIfSupported = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) ?*const [2]IncomingAes {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    return p.aesKeysIfSupported();
                }
            }.f,

            .peerPublicKey = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) *const IncomingEcc.Public {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    return p.identity().publicKey();
                }
            }.f,

            .peerAddress = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) u64 {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    return p.address().toInt();
                }
            }.f,

            .peerReceived = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, peer: ?*anyopaque, path: ?*anyopaque, hops: u32, packet_id: u64, payload_len: u32, verb_val: u32, in_re_packet_id: u64, in_re_verb: u32, trust_established: bool, network_id: u64, flow_id: i32) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const Peer = @import("peer.zig").Peer;
                    const Path = @import("path.zig").Path;
                    const Verb = @import("packet.zig").Verb;

                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    const pth: *Path = @ptrCast(@alignCast(path.?));
                    const v: Verb = @enumFromInt(verb_val);
                    const in_re_v: Verb = @enumFromInt(in_re_verb);

                    p.received(tptr, pth, hops, packet_id, payload_len, v, in_re_packet_id, in_re_v, trust_established, network_id, flow_id, node.now);
                }
            }.f,

            .peerRecordIncomingInvalidPacket = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
                    // TODO: Record invalid packet for rate limiting
                }
            }.f,

            .peerRecordOutgoingPacket = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u32, _: u32, _: i32, _: i64) void {
                    // TODO: Record outgoing packet
                }
            }.f,

            .peerRateGateQoS = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque) bool {
                    return true; // TODO: Implement QoS rate gating
                }
            }.f,

            .peerReceivedQoS = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: i64, _: u32, _: [*]const u64, _: [*]const u16) void {
                    // TODO: Process received QoS data
                }
            }.f,

            .peerRateGatePathNegotiation = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque) bool {
                    return true; // TODO: Rate gate path negotiation
                }
            }.f,

            .peerProcessIncomingPathNegotiationRequest = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque, _: i16) void {
                    // TODO: Process path negotiation
                }
            }.f,

            .peerFlowHashingSupported = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque) bool {
                    return false; // TODO: Check if peer supports flow hashing
                }
            }.f,

            // Path operations
            .pathSend = struct {
                fn f(ctx: ?*anyopaque, path: ?*anyopaque, tptr: ?*anyopaque, data: [*]const u8, len: u32, _: i64) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    // For now, send via primary socket using the path's address
                    // In a real implementation, this would use the path's local socket
                    if (path) |p| {
                        const Path = @import("path.zig").Path;
                        const path_obj: *Path = @ptrCast(@alignCast(p));
                        const remote_addr = path_obj.address();
                        // Send using node's wireSend callback with socket 0
                        node.callbacks.wireSend(
                            node.callbacks.ctx,
                            tptr,
                            0, // local_socket (use primary)
                            remote_addr,
                            data,
                            len,
                            64, // ttl
                        );
                    }
                }
            }.f,

            .pathAddress = struct {
                var stub_address: InetAddress = InetAddress.initV4([4]u8{ 127, 0, 0, 1 }, 9993);

                fn f(_: ?*anyopaque, path: ?*anyopaque) *const InetAddress {
                    if (path) |p| {
                        const Path = @import("path.zig").Path;
                        const path_obj: *Path = @ptrCast(@alignCast(p));
                        return path_obj.address();
                    }
                    // Return stub address if no path
                    return &stub_address;
                }
            }.f,

            .pathLocalSocket = struct {
                fn f(_: ?*anyopaque, path: ?*anyopaque) i64 {
                    if (path) |p| {
                        const Path = @import("path.zig").Path;
                        const path_obj: *Path = @ptrCast(@alignCast(p));
                        return path_obj.localSocket();
                    }
                    return 0; // Default socket
                }
            }.f,

            .pathRateGateEchoRequest = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64) bool {
                    return true; // TODO: Rate gate echo requests
                }
            }.f,

            // Trace operations (logging/debugging)
            .traceIncomingPacketMacFailure = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u32, _: [*:0]const u8) void {
                    std.debug.print("  ✗ MAC verification failure\n", .{});
                }
            }.f,

            .traceIncomingPacketInvalid = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u32, _: u32, _: [*:0]const u8) void {
                    std.debug.print("  ✗ Invalid packet\n", .{});
                }
            }.f,

            .traceIncomingPacketDroppedHELLO = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: [*:0]const u8) void {
                    std.debug.print("  ✗ Dropped HELLO packet\n", .{});
                }
            }.f,

            // Identity verification
            .nodeRateGateIdentityVerification = struct {
                fn f(_: ?*anyopaque, _: i64, _: *const InetAddress) bool {
                    return true; // TODO: Rate gate identity verification
                }
            }.f,

            .peerIdentity = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque) *const Identity {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    return p.identity();
                }
            }.f,

            .peerSetRemoteVersion = struct {
                fn f(_: ?*anyopaque, peer: ?*anyopaque, proto: u32, major: u32, minor: u32, rev: u32) void {
                    const Peer = @import("peer.zig").Peer;
                    const p: *Peer = @ptrCast(@alignCast(peer.?));
                    p.setRemoteVersion(@intCast(proto), @intCast(major), @intCast(minor), @intCast(rev));
                }
            }.f,

            // Additional Topology callbacks
            .topologyAddPeer = struct {
                fn f(ctx: ?*anyopaque, _: ?*anyopaque, new_identity: *const Identity) ?*anyopaque {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const Peer = @import("peer.zig").Peer;
                    // Create a new Peer from the identities (ECDH key agreement)
                    const peer = Peer.create(&node.identity, new_identity) orelse return null;
                    return @ptrCast(node.topology.addPeer(&peer));
                }
            }.f,

            .topologyIsUpstream = struct {
                fn f(_: ?*anyopaque, _: *const Identity) bool {
                    return false; // TODO: Check if identity is root server
                }
            }.f,

            .topologyPlanetWorldId = struct {
                fn f(_: ?*anyopaque) u64 {
                    return 0; // TODO: Return planet world ID
                }
            }.f,

            .topologyPlanetWorldTimestamp = struct {
                fn f(_: ?*anyopaque) u64 {
                    return 0; // TODO: Return planet timestamp
                }
            }.f,

            .topologySerializePlanet = struct {
                fn f(_: ?*anyopaque, _: [*]u8, _: u32) u32 {
                    return 0; // TODO: Serialize planet world
                }
            }.f,

            .topologySerializeUpdatedMoons = struct {
                fn f(_: ?*anyopaque, _: [*]const u64, _: [*]const u64, _: u32, _: [*]u8, _: u32) u32 {
                    return 0; // TODO: Serialize moon updates
                }
            }.f,

            .topologyShouldAcceptWorldUpdateFrom = struct {
                fn f(_: ?*anyopaque, _: u64) bool {
                    return false; // TODO: Check if world update should be accepted
                }
            }.f,

            .topologyAddWorld = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32) bool {
                    return false; // TODO: Add world from serialized data
                }
            }.f,

            .selfAwarenessIam = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64, _: *const InetAddress, _: *const InetAddress, _: bool, _: i64) void {
                    // TODO: Record externally observed address
                }
            }.f,

            .pathUpdateLatency = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: i64) void {
                    // TODO: Update path latency
                }
            }.f,

            // Network operation callbacks
            .nodeGetNetwork = struct {
                fn f(ctx: ?*anyopaque, nwid: u64) ?*anyopaque {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return @ptrCast(node.getNetwork(nwid));
                }
            }.f,

            .nodeExpectingReplyTo = struct {
                fn f(_: ?*anyopaque, _: u64) bool {
                    return false; // TODO: Check if expecting reply
                }
            }.f,

            .networkController = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque) u64 {
                    return 0; // TODO: Get network controller address
                }
            }.f,

            .networkSetNotFound = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
                    // TODO: Mark network as not found
                }
            }.f,

            .networkSetAccessDenied = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
                    // TODO: Mark network as access denied
                }
            }.f,

            .networkGate = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) bool {
                    return true; // TODO: Check if peer is allowed on network
                }
            }.f,

            .networkPeerRequestedCredentials = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64) void {
                    // TODO: Handle credential request
                }
            }.f,

            .networkConfigHasCom = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque) bool {
                    return false; // TODO: Check if network has COM
                }
            }.f,

            .networkSetAuthenticationRequired = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*:0]const u8) void {
                    // TODO: Set authentication required
                }
            }.f,

            .networkHandleConfigChunk = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, _: ?*anyopaque, packet_id: u64, nwid: u64, chunk_data: [*]const u8, chunk_len: u32, start_ptr: u32) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    _ = tptr;
                    const network = node.getNetwork(nwid) orelse return;
                    const data = chunk_data[0..chunk_len];
                    // Extract controller address from network ID (upper 40 bits)
                    const controller_addr = Address.init(nwid >> 24);
                    _ = network.handleConfigChunk(null, packet_id, controller_addr, data, start_ptr);
                }
            }.f,

            .multicasterRemove = struct {
                fn f(_: ?*anyopaque, _: u64, _: *const [6]u8, _: u32, _: u64) void {
                    // TODO: Remove multicast subscription
                }
            }.f,

            .multicasterAddMultiple = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: u64, _: *const [6]u8, _: u32, _: [*]const u8, _: u32, _: u32) void {
                    // TODO: Add multiple multicast members
                }
            }.f,

            .switchDoAnythingWaitingForPeer = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
                    // TODO: Process packets waiting for this peer
                }
            }.f,

            .networkAddCredentialCOM = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32) bool {
                    return false; // TODO: Add COM credential to network
                }
            }.f,

            // WHOIS / Rendezvous callbacks
            .topologyAmUpstream = struct {
                fn f(_: ?*anyopaque) bool {
                    return false; // TODO: Check if we are an upstream node
                }
            }.f,

            .peerRateGateInboundWhoisRequest = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64) bool {
                    return true; // TODO: Rate gate WHOIS requests
                }
            }.f,

            .topologyGetIdentity = struct {
                fn f(ctx: ?*anyopaque, _: ?*anyopaque, addr: u64) ?*const Identity {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const peer_addr = Address.init(addr);
                    return node.topology.getIdentity(peer_addr);
                }
            }.f,

            .nodeShouldUsePathForZeroTierTraffic = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64, _: *const InetAddress) bool {
                    return true; // TODO: Check if path should be used
                }
            }.f,

            .nodePrng = struct {
                fn f(ctx: ?*anyopaque) u64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    // Simple pseudo-random based on timestamp
                    return @as(u64, @intCast(node.now)) *% 6364136223846793005 +% 1442695040888963407;
                }
            }.f,

            .nodePutPacket = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, local_socket: i64, remote_addr: *const InetAddress, data: [*]const u8, len: u32, ttl: u32) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.putPacket(tptr, local_socket, remote_addr, data, len, @intCast(ttl));
                }
            }.f,

            .peerAttemptToContactAt = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: i64, _: bool) void {
                    // TODO: Attempt to contact peer at address
                }
            }.f,

            // Frame / Network callbacks
            .networkMac = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque) MAC {
                    return MAC.init(0); // TODO: Return network MAC address
                }
            }.f,

            .networkUserPtr = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque) ?*anyopaque {
                    return null; // TODO: Return network user pointer
                }
            }.f,

            .networkFilterIncomingPacket = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: *const MAC, _: *const MAC, _: [*]const u8, _: u32, _: u32, _: u32) i32 {
                    return 1; // TODO: Filter incoming packet (1 = accept)
                }
            }.f,

            .pmPutFrame = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, user_ptr: ?*anyopaque, source_mac: *const MAC, dest_mac: *const MAC, ethertype: u32, vlan_id: u32, frame_data: *const anyopaque, frame_len: u32, flow_id: i32) void {
                    _ = flow_id;
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.putFrame(tptr, nwid, @ptrCast(@constCast(&user_ptr)), source_mac, dest_mac, ethertype, vlan_id, @ptrCast(frame_data), frame_len);
                }
            }.f,

            // Multicast callbacks
            .multicasterAdd = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: u64, _: *const MulticastGroup, _: u64) void {
                    // TODO: Add multicast group subscription
                }
            }.f,

            .networkPushCredentials = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: ?*anyopaque, _: i64, _: [*]const u8, _: u32) void {
                    // TODO: Process network credentials
                }
            }.f,

            .networkControllerHandleConfigRequest = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: *const anyopaque) void {
                    // TODO: Handle network config request (controller side)
                }
            }.f,

            .networkHandleConfig = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: [*]const u8, _: u32) void {
                    // TODO: Handle network config (client side)
                }
            }.f,

            .multicasterGather = struct {
                fn f(_: ?*anyopaque, _: u64, _: u64, _: *const MulticastGroup, _: *Packet, _: u32) u32 {
                    return 0; // TODO: Gather multicast subscribers
                }
            }.f,

            .multicasterReceiveMulticastFrame = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: *const MulticastGroup, _: [*]const u8, _: u32, _: u32) void {
                    // TODO: Receive multicast frame
                }
            }.f,

            .peerReceivePushDirectPaths = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32, _: i64) void {
                    // TODO: Process direct path hints
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
