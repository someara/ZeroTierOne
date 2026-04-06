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
const Aes = @import("aes.zig").Aes;
const identity_mod = @import("identity.zig");
const Identity = identity_mod.Identity;
const ecc = @import("ecc.zig");
const InetAddress = @import("inet_address.zig").InetAddress;
const mac_mod = @import("mac.zig");
const MAC = mac_mod.MAC;
const MAC_LENGTH = mac_mod.MAC_LENGTH;
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
const network_mod = @import("network.zig");
const Network = network_mod.Network;
const Peer = @import("peer.zig").Peer;
const NetworkConfig = @import("network_config.zig").NetworkConfig;
const Path = @import("path.zig").Path;
const topology_mod = @import("topology.zig");
const world_mod = @import("world.zig");
const World = @import("world.zig").World;
const Buffer = @import("buffer.zig").Buffer;
const Packet = @import("packet.zig").Packet;
const packet_mod = @import("packet.zig");
const OutboundMulticast = @import("outbound_multicast.zig").OutboundMulticast;
const PacketMultiplexer = @import("packet_multiplexer.zig").PacketMultiplexer;
const network_controller_mod = @import("network_controller.zig");
const network_config_mod = @import("network_config.zig");
const Dictionary = @import("dictionary.zig").Dictionary;
const Revocation = @import("revocation.zig").Revocation;
const Multicaster = @import("multicaster.zig").Multicaster;
const MulticasterCallbacks = @import("multicaster.zig").Callbacks;
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

const ethertype_ipv6: u32 = 0x86DD;
const icmpv6_next_header: u8 = 0x3A;
const icmpv6_neighbor_solicitation: u8 = 0x87;
const icmpv6_neighbor_advertisement: u8 = 0x88;

/// State object types (map to ZT_StateObjectType)
const state_object_identity_public: u32 = 0;
const state_object_identity_secret: u32 = 1;
const state_object_network_config: u32 = 3;

fn multicastSendOutbound(ctx: ?*anyopaque, t_ptr: ?*anyopaque, om: *const OutboundMulticast, to_addr: Address) void {
    const node: *Node = @ptrCast(@alignCast(ctx.?));
    const network = node.getNetwork(om.nwid()) orelse return;

    var qos_bucket: u8 = 255;
    if (!network.filterOutgoingPacket(
        t_ptr,
        true,
        node.identity.address(),
        to_addr,
        om._mac_src,
        om._mac_dest,
        om._frame_data[0..om._frame_len],
        om._frame_len,
        @intCast(om._ether_type),
        0,
        &qos_bucket,
    )) {
        return;
    }

    network.pushCredentialsIfNeeded(t_ptr, to_addr, node.now);

    var pkt = om._packet;
    pkt.newInitializationVector();
    pkt.setDestination(to_addr);
    node.expectReplyTo(pkt.packetId());

    const switch_cbs = node.createSwitchCallbacks();
    node.switch_engine.send(t_ptr, &pkt, true, om.nwid(), constants.qos_no_flow, &switch_cbs);
}

fn ndpEmulateNeighborAdvertisement(self: *Node, t_ptr: ?*anyopaque, network: *Network, from: *const MAC, frame: []const u8) bool {
    if (!network.config().ndpEmulation()) return false;
    if (frame.len < (40 + 8 + 16)) return false;
    if (frame[6] != icmpv6_next_header or frame[40] != icmpv6_neighbor_solicitation) return false;

    const target_ip = frame[48..64];

    var embedded = Address.zero();
    var my_ip_bytes: ?[]const u8 = null;

    for (network.config().static_ips[0..network.config().static_ip_count]) |*sip| {
        if (!sip.isV6()) continue;

        const sip_bytes = sip.rawIpData() orelse continue;
        const netmask_bits = sip.netmaskBits();

        if (netmask_bits == 88 and sip_bytes.len >= 16 and sip_bytes[0] == 0xfd and sip_bytes[9] == 0x99 and sip_bytes[10] == 0x93) {
            if (mem.eql(u8, target_ip[0..11], sip_bytes[0..11])) {
                embedded = Address.fromBytes(@ptrCast(target_ip.ptr + 11));
                my_ip_bytes = sip_bytes;
                break;
            }
        } else if (netmask_bits == 40 and sip_bytes.len >= 16) {
            const nwid32: u32 = @truncate(network.id() ^ (network.id() >> 32));
            if (sip_bytes[0] == 0xfc and sip_bytes[1] == @as(u8, @truncate(nwid32 >> 24)) and sip_bytes[2] == @as(u8, @truncate(nwid32 >> 16)) and sip_bytes[3] == @as(u8, @truncate(nwid32 >> 8)) and sip_bytes[4] == @as(u8, @truncate(nwid32))) {
                if (mem.eql(u8, target_ip[0..5], sip_bytes[0..5])) {
                    embedded = Address.fromBytes(@ptrCast(target_ip.ptr + 5));
                    my_ip_bytes = sip_bytes;
                    break;
                }
            }
        }
    }

    if (!embedded.eql(Address.zero()) and !embedded.eql(self.identity.address()) and my_ip_bytes != null) {
        const peer_mac = MAC.fromAddress(embedded, network.id());
        var adv: [72]u8 = undefined;

        adv[0] = 0x60;
        adv[1] = 0x00;
        adv[2] = 0x00;
        adv[3] = 0x00;
        adv[4] = 0x00;
        adv[5] = 0x20;
        adv[6] = icmpv6_next_header;
        adv[7] = 0xff;
        @memcpy(adv[8..24], frame[8..24]);
        @memcpy(adv[24..40], my_ip_bytes.?[0..16]);
        adv[40] = icmpv6_neighbor_advertisement;
        adv[41] = 0x00;
        adv[42] = 0x00;
        adv[43] = 0x00;
        adv[44] = 0x60;
        adv[45] = 0x00;
        adv[46] = 0x00;
        adv[47] = 0x00;
        @memcpy(adv[48..64], target_ip);
        adv[64] = 0x02;
        adv[65] = 0x01;
        var peer_mac_bytes: [MAC_LENGTH]u8 = undefined;
        peer_mac.copyTo(&peer_mac_bytes);
        @memcpy(adv[66..72], &peer_mac_bytes);

        var pseudo: [72]u8 = undefined;
        @memcpy(pseudo[0..32], adv[8..40]);
        pseudo[32] = 0x00;
        pseudo[33] = 0x00;
        pseudo[34] = 0x00;
        pseudo[35] = 0x20;
        pseudo[36] = 0x00;
        pseudo[37] = 0x00;
        pseudo[38] = 0x00;
        pseudo[39] = icmpv6_next_header;
        @memcpy(pseudo[40..72], adv[40..72]);

        var checksum: u32 = 0;
        var i: usize = 0;
        while (i < pseudo.len) : (i += 2) {
            checksum += (@as(u32, pseudo[i]) << 8) | pseudo[i + 1];
        }
        while ((checksum >> 16) != 0) {
            checksum = (checksum & 0xffff) + (checksum >> 16);
        }
        checksum = ~checksum;
        adv[42] = @truncate(checksum >> 8);
        adv[43] = @truncate(checksum);

        self.putFrame(t_ptr, network.id(), @ptrCast(@constCast(&network._u_ptr)), &peer_mac, from, ethertype_ipv6, 0, &adv, adv.len);
        return true;
    }

    return false;
}

fn multicastReplicateInbound(
    self: *Node,
    t_ptr: ?*anyopaque,
    network: *Network,
    origin: Address,
    source_mac: *const MAC,
    mg: *const MulticastGroup,
    frame: []const u8,
    ethertype: u32,
) void {
    const nwid = network.id();
    const now = self.now;

    if (network.config().multicast_limit == 0) return;

    var active_bridges: [network_config_mod.max_network_specialists]Address = [_]Address{Address.zero()} ** network_config_mod.max_network_specialists;
    const active_bridge_count = @min(network.config().activeBridges(&active_bridges), @as(u32, active_bridges.len));
    const limit = network.config().multicast_limit;

    var members: [256]Address = [_]Address{Address.zero()} ** 256;
    const known_count = self.multicaster.getMembers(nwid, mg.*, &members, @min(limit, @as(u32, members.len)));

    const gather_limit: u32 = if (known_count >= limit) 1 else (limit - known_count) + 1;
    var out = OutboundMulticast.initEmpty();
    out.initMulticast(
        self.identity.address(),
        @intCast(now),
        nwid,
        (network.config().flags & network_config_mod.flag_disable_compression) != 0,
        limit,
        gather_limit,
        source_mac.*,
        mg.*,
        ethertype,
        frame,
    );
    out.logAsSent(origin);

    var sent_count: u32 = 0;
    var i: u32 = 0;
    while (i < active_bridge_count and sent_count < limit) : (i += 1) {
        const bridge = active_bridges[i];
        if (!bridge.eql(self.identity.address()) and !bridge.eql(origin)) {
            if (known_count < limit) out.logAsSent(bridge);
            multicastSendOutbound(@ptrCast(self), t_ptr, &out, bridge);
            sent_count += 1;
        }
    }

    i = 0;
    while (i < known_count and sent_count < limit) : (i += 1) {
        const member = members[i];
        if (member.eql(origin)) continue;

        var is_active_bridge = false;
        for (active_bridges[0..active_bridge_count]) |bridge| {
            if (bridge.eql(member)) {
                is_active_bridge = true;
                break;
            }
        }
        if (is_active_bridge) continue;

        if (known_count < limit) out.logAsSent(member);
        multicastSendOutbound(@ptrCast(self), t_ptr, &out, member);
        sent_count += 1;
    }

    if (known_count < limit and !out.atLimit()) {
        self.multicaster.queueOutbound(nwid, mg.*, out);
    }
}

fn multicastSendToReplicator(
    self: *Node,
    t_ptr: ?*anyopaque,
    network: *Network,
    replicator: Address,
    source_mac: *const MAC,
    mg: *const MulticastGroup,
    frame: []const u8,
    ethertype: u32,
) void {
    var out = Packet.initNew(replicator, self.identity.address(), .multicast_frame);
    out.buf.appendInt(u64, network.id()) catch return;
    out.buf.appendInt(u8, 0x0c) catch return;
    source_mac.appendTo(packet_mod.max_packet_length, &out.buf) catch return;
    var dest_mac_bytes: [MAC_LENGTH]u8 = undefined;
    mg.mac().copyTo(&dest_mac_bytes);
    out.buf.appendBytes(&dest_mac_bytes) catch return;
    out.buf.appendInt(u32, mg.adi()) catch return;
    out.buf.appendInt(u16, @as(u16, @intCast(ethertype & 0xffff))) catch return;
    out.buf.appendBytes(frame) catch return;
    _ = out.compress();

    network.pushCredentialsIfNeeded(t_ptr, replicator, self.now);
    const peer = self.topology.getPeerNoCache(replicator) orelse return;
    const peer_key = peer.key();
    const peer_aes = peer.aesKeysIfSupported();
    const peer_pub = peer.identity().publicKey();
    out.armor(peer_key[0..32], true, false, peer_aes, peer_pub);

    if (peer.getAppropriatePath(self.now, false)) |path| {
        const pkt_data = out.buf.data();
        self.callbacks.wireSend(
            self.callbacks.ctx,
            t_ptr,
            path.localSocket(),
            path.address(),
            pkt_data.ptr,
            @intCast(pkt_data.len),
            64,
        );
        path.sent(self.now);
    }
}

// ── Node ──────────────────────────────────────────────────────────

pub const Node = struct {
    allocator: mem.Allocator,

    // Core identity
    identity: Identity,
    public_identity_str: [identity_mod.string_buffer_length]u8,
    secret_identity_str: [identity_mod.string_buffer_length]u8,

    // Subsystems (owned)
    switch_engine: *Switch,
    topology: *Topology,
    multicaster: *Multicaster,
    // self_awareness: *SelfAwareness,
    // bond: *Bond,
    packet_multiplexer: ?*PacketMultiplexer,

    // Networks (managed)
    networks: std.AutoHashMap(u64, *Network),
    networks_mutex: Mutex,
    direct_paths: std.array_list.Managed(InetAddress),
    direct_paths_mutex: Mutex,

    // State
    now: i64,
    online: bool,
    low_bandwidth_mode: bool,

    // Background task timestamps
    last_ping_check: i64,
    last_housekeeping_run: i64,

    // User pointer (opaque to us, passed through to callbacks)
    user_ptr: ?*anyopaque,
    network_controller: ?*network_controller_mod.Controller,
    network_controller_sender: network_controller_mod.Sender,

    // Callbacks to host application
    callbacks: Callbacks,

    // PRNG state for generating random values
    prng_state: u64,

    // Expected reply tracking (mirrors C++ _expectingRepliesTo)
    // 256 buckets × 32 entries = 8192 tracked packet IDs.
    // Indexed by upper 32 bits of packet ID, hashed into bucket.
    expecting_replies: [256][32]u32,
    expecting_replies_ptr: [256]u8,

    const Self = @This();

    /// Create a new Node instance.
    pub fn init(
        allocator: mem.Allocator,
        user_ptr: ?*anyopaque,
        t_ptr: ?*anyopaque,
        config: *const Config,
        callbacks: Callbacks,
        now: i64,
    ) !*Self {
        _ = config;

        // Load or generate identity
        const identity = try Self.loadOrGenerateIdentity(allocator, t_ptr, &callbacks);

        // Initialize Switch
        const switch_engine = try allocator.create(Switch);
        switch_engine.* = try Switch.init(allocator);
        errdefer {
            switch_engine.deinit();
            allocator.destroy(switch_engine);
        }

        // Initialize Topology
        const topology = try allocator.create(Topology);
        errdefer {
            topology.deinit();
            allocator.destroy(topology);
        }

        try Topology.create(topology, allocator, &identity);
        topology.setCallbacks(
            callbacks.ctx,
            t_ptr,
            null,
            null,
            null,
        );

        const multicaster_ptr = try allocator.create(Multicaster);
        multicaster_ptr.* = Multicaster.init(allocator, .{
            .ctx = null,
            .getMyAddress = struct {
                fn f(ctx: ?*anyopaque) Address {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.identity.address();
                }
            }.f,
            .prng = struct {
                fn f(ctx: ?*anyopaque) u64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.prng();
                }
            }.f,
        });
        errdefer {
            multicaster_ptr.deinit();
            allocator.destroy(multicaster_ptr);
        }

        const packet_multiplexer_ptr = try allocator.create(PacketMultiplexer);
        packet_multiplexer_ptr.* = PacketMultiplexer.init(allocator, null);
        errdefer {
            packet_multiplexer_ptr.deinit();
            allocator.destroy(packet_multiplexer_ptr);
        }

        // TODO: Initialize other subsystems
        // - SelfAwareness
        // - Bond
        // - PacketMultiplexer

        const node_ptr = try allocator.create(Self);
        node_ptr.* = Self{
            .allocator = allocator,
            .identity = identity,
            .public_identity_str = [_]u8{0} ** identity_mod.string_buffer_length,
            .secret_identity_str = [_]u8{0} ** identity_mod.string_buffer_length,
            .switch_engine = switch_engine,
            .topology = topology,
            .multicaster = multicaster_ptr,
            .packet_multiplexer = packet_multiplexer_ptr,
            .networks = std.AutoHashMap(u64, *Network).init(allocator),
            .networks_mutex = .{},
            .direct_paths = std.array_list.Managed(InetAddress).init(allocator),
            .direct_paths_mutex = .{},
            .now = now,
            .online = false,
            .low_bandwidth_mode = false,
            .last_ping_check = 0,
            .last_housekeeping_run = 0,
            .user_ptr = user_ptr,
            .network_controller = null,
            .network_controller_sender = undefined,
            .callbacks = callbacks,
            .prng_state = @as(u64, @bitCast(now)) ^ identity.address().toInt(),
            .expecting_replies = [_][32]u32{[_]u32{0} ** 32} ** 256,
            .expecting_replies_ptr = [_]u8{0} ** 256,
        };

        node_ptr.multicaster.callbacks = .{
            .ctx = @ptrCast(node_ptr),
            .getMyAddress = struct {
                fn f(ctx: ?*anyopaque) Address {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.identity.address();
                }
            }.f,
            .prng = struct {
                fn f(ctx: ?*anyopaque) u64 {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.prng();
                }
            }.f,
        };

        _ = node_ptr.identity.toString(false, &node_ptr.public_identity_str);
        _ = node_ptr.identity.toString(true, &node_ptr.secret_identity_str);

        // Post UP event
        node_ptr.postEvent(t_ptr, event_up);

        return node_ptr;
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

        if (self.packet_multiplexer) |pm| {
            pm.deinit();
            self.allocator.destroy(pm);
        }

        self.multicaster.deinit();
        self.allocator.destroy(self.multicaster);

        self.direct_paths.deinit();

        // Clean up subsystems
        self.switch_engine.deinit();
        self.allocator.destroy(self.switch_engine);

        self.topology.deinit();
        self.allocator.destroy(self.topology);

        self.identity.deinit();

        self.allocator.destroy(self);
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
            network,
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
                        .expectReplyFn = struct {
                            fn f(ctx: ?*anyopaque, packet_id: u64) void {
                                const node: *Self = @ptrCast(@alignCast(ctx));
                                node.expectReplyTo(packet_id);
                            }
                        }.f,
                        .wire_ctx = self.callbacks.ctx,
                        .expect_ctx = self,
                        .t_ptr = t_ptr,
                    };

                    for (0..root_count) |ri| {
                        const rc = &root_contacts[ri];

                        if (rc.peer) |peer_handle| {
                            const peer = self.topology.peerByHandle(peer_handle) orelse continue;
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
            self.multicaster.clean(now);
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

    // ── Expected Reply Tracking ─────────────────────────────────
    // Mirrors C++ Node::expectReplyTo / Node::expectingReplyTo.
    // Uses upper 32 bits of packet ID as key into a 256×32 hash table.

    /// Record that we expect an OK reply for the given packet ID.
    pub fn expectReplyTo(self: *Self, packet_id: u64) void {
        const pid2: u32 = @truncate(packet_id >> 32);
        const bucket: u8 = @truncate(pid2);
        const slot = self.expecting_replies_ptr[bucket];
        self.expecting_replies[bucket][slot & 31] = pid2;
        self.expecting_replies_ptr[bucket] = slot +% 1;
    }

    /// Check if we are expecting an OK for the given packet ID.
    pub fn isExpectingReplyTo(self: *const Self, packet_id: u64) bool {
        const pid2: u32 = @truncate(packet_id >> 32);
        const bucket: u8 = @truncate(pid2);
        for (0..32) |i| {
            if (self.expecting_replies[bucket][i] == pid2) {
                return true;
            }
        }
        return false;
    }

    /// Get a network by ID.
    pub fn getNetwork(self: *Self, nwid: u64) ?*Network {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        return self.networks.get(nwid);
    }

    pub fn multicastSend(
        self: *Self,
        t_ptr: ?*anyopaque,
        network: *Network,
        from: *const MAC,
        to: *const MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
        from_bridged: bool,
    ) void {
        const nwid = network.id();
        const now = self.now;
        const frame = data[0..@as(usize, @intCast(len))];
        var dest_group = MulticastGroup.init(to.*, 0);
        var qos_bucket: u8 = 0;

        if (to.isBroadcast()) {
            if (ether_type == 0x0806 and len >= 28 and frame[2] == 0x08 and frame[3] == 0x00 and frame[4] == 6 and frame[5] == 4 and frame[7] == 0x01) {
                const target_ip = InetAddress.initV4(.{ frame[24], frame[25], frame[26], frame[27] }, 0);
                dest_group = MulticastGroup.deriveMulticastGroupForAddressResolution(&target_ip);
            } else if (!network.config().enableBroadcast()) {
                return;
            }
        } else if (ether_type == ethertype_ipv6) {
            if (ndpEmulateNeighborAdvertisement(self, t_ptr, network, from, frame)) {
                return;
            }
        }

        if (network.config().multicast_limit == 0) return;

        if (!network.filterOutgoingPacket(t_ptr, false, self.identity.address(), Address.zero(), from.*, to.*, frame, len, @intCast(ether_type), @intCast(vlan_id), &qos_bucket)) {
            return;
        }

        if (!network.config().isActiveBridge(self.identity.address())) {
            var replicators: [network_config_mod.max_network_specialists]Address = [_]Address{Address.zero()} ** network_config_mod.max_network_specialists;
            const replicator_count = @min(network.config().multicastReplicators(&replicators), @as(u32, replicators.len));
            if (replicator_count > 0) {
                var we_are_replicator = false;
                for (replicators[0..replicator_count]) |replicator| {
                    if (replicator.eql(self.identity.address())) {
                        we_are_replicator = true;
                        break;
                    }
                }

                if (!we_are_replicator) {
                    var best_replicator: ?Address = null;
                    var best_latency: u32 = 0xffff;
                    for (replicators[0..replicator_count]) |replicator| {
                        const peer = self.topology.getPeerNoCache(replicator) orelse continue;
                        if (!peer.isAlive(now)) continue;
                        const path = peer.getAppropriatePath(now, false) orelse continue;
                        if (path.latency() < best_latency) {
                            best_latency = path.latency();
                            best_replicator = replicator;
                        }
                    }

                    if (best_replicator) |replicator| {
                        multicastSendToReplicator(self, t_ptr, network, replicator, if (from_bridged) from else &network.mac(), &dest_group, frame, ether_type);
                        return;
                    }
                }
            }
        }

        if (from_bridged) {
            network.learnBridgedMulticastGroup(t_ptr, &dest_group, now) catch {};
        }

        var active_bridges: [network_config_mod.max_network_specialists]Address = [_]Address{Address.zero()} ** network_config_mod.max_network_specialists;
        const active_bridge_count = @min(network.config().activeBridges(&active_bridges), @as(u32, active_bridges.len));
        const limit = network.config().multicast_limit;

        var members: [256]Address = [_]Address{Address.zero()} ** 256;
        const known_count = self.multicaster.getMembers(nwid, dest_group, &members, @min(limit, @as(u32, members.len)));

        const gather_limit: u32 = if (known_count >= limit) 1 else (limit - known_count) + 1;
        var out = OutboundMulticast.initEmpty();
        out.initMulticast(
            self.identity.address(),
            @intCast(now),
            nwid,
            (network.config().flags & network_config_mod.flag_disable_compression) != 0,
            limit,
            gather_limit,
            if (from_bridged) from.* else MAC.zero(),
            dest_group,
            ether_type,
            frame,
        );

        var sent_count: u32 = 0;
        var i: u32 = 0;
        while (i < active_bridge_count and sent_count < limit) : (i += 1) {
            const bridge = active_bridges[i];
            if (!bridge.eql(self.identity.address())) {
                if (known_count < limit) out.logAsSent(bridge);
                multicastSendOutbound(@ptrCast(self), t_ptr, &out, bridge);
                sent_count += 1;
            }
        }

        i = 0;
        while (i < known_count and sent_count < limit) : (i += 1) {
            const member = members[i];
            var is_active_bridge = false;
            for (active_bridges[0..active_bridge_count]) |bridge| {
                if (bridge.eql(member)) {
                    is_active_bridge = true;
                    break;
                }
            }
            if (is_active_bridge) continue;

            if (known_count < limit) out.logAsSent(member);
            multicastSendOutbound(@ptrCast(self), t_ptr, &out, member);
            sent_count += 1;
        }

        if (known_count < limit and !out.atLimit()) {
            self.multicaster.queueOutbound(nwid, dest_group, out);
        }
    }

    /// Join a network.
    pub fn joinNetwork(self: *Self, nwid: u64) !*Network {
        self.networks_mutex.lock();
        defer self.networks_mutex.unlock();

        if (self.networks.get(nwid)) |existing| {
            return existing;
        }

        const network = try self.allocator.create(Network);
        network.* = Network.init(
            self.allocator,
            nwid,
            self.identity.address(),
            self.user_ptr,
            self.createNetworkCallbacks(),
        );
        errdefer {
            network.deinit();
            self.allocator.destroy(network);
        }
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

        const network = self.networks.get(nwid) orelse {
            self.networks_mutex.unlock();
            return;
        };

        // Return user pointer if requested.
        if (user_ptr_out) |out| {
            out.* = network._u_ptr;
        }

        // Mirror C++ leave(): capture config, mark the network destroyed,
        // notify the host, then remove it from the active map.
        var ec: constants.c_api.ZT_VirtualNetworkConfig = undefined;
        network.externalConfig(&ec);
        network.destroy();

        self.networks_mutex.unlock();

        if (self.callbacks.configure_virtual_network_port) |cb| {
            if (network._u_ptr != null) {
                _ = cb(
                    self.callbacks.ctx,
                    self.user_ptr,
                    t_ptr,
                    nwid,
                    @constCast(&network._u_ptr),
                    @as(c_uint, @intCast(constants.c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_DESTROY)),
                    &ec,
                );
            }
        }

        self.networks_mutex.lock();
        _ = self.networks.remove(nwid);
        self.networks_mutex.unlock();

        network.deinit();
        self.allocator.destroy(network);

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
            return &network.config;
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
        if (self.packet_multiplexer) |pm| {
            pm.setUp(concurrency, cpu_pinning_enabled) catch {};
        }
    }

    /// Set network controller instance.
    pub fn setNetconfMaster(
        self: *Self,
        controller_instance: ?*anyopaque,
    ) void {
        self.network_controller = if (controller_instance) |ptr| @ptrCast(@alignCast(ptr)) else null;
        if (self.network_controller) |controller| {
            self.network_controller_sender = self.createNetworkControllerSender();
            controller.initController(&self.identity, &self.network_controller_sender);
        }
    }

    fn createNetworkControllerSender(self: *Self) network_controller_mod.Sender {
        return .{
            .context = @ptrCast(self),
            .send_config_fn = struct {
                fn f(ctx: *anyopaque, nwid: u64, request_packet_id: u64, destination: Address, nc: *const NetworkConfig, send_legacy: bool) void {
                    const node: *Self = @ptrCast(@alignCast(ctx));
                    node.ncSendConfig(nwid, request_packet_id, destination, nc, send_legacy);
                }
            }.f,
            .send_revocation_fn = struct {
                fn f(ctx: *anyopaque, destination: Address, rev: *const Revocation) void {
                    const node: *Self = @ptrCast(@alignCast(ctx));
                    node.ncSendRevocation(destination, rev);
                }
            }.f,
            .send_error_fn = struct {
                fn f(ctx: *anyopaque, nwid: u64, request_packet_id: u64, destination: Address, error_code: network_controller_mod.ErrorCode, error_data: []const u8) void {
                    const node: *Self = @ptrCast(@alignCast(ctx));
                    node.ncSendError(nwid, request_packet_id, destination, error_code, error_data);
                }
            }.f,
        };
    }

    fn ncSendConfig(self: *Self, nwid: u64, request_packet_id: u64, destination: Address, nc: *const NetworkConfig, send_legacy: bool) void {
        _ = send_legacy;

        if (destination.eql(self.identity.address())) {
            if (self.getNetwork(nwid)) |network| {
                _ = network.setConfiguration(null, nc, true);
            }
            return;
        }

        var dict = Dictionary(network_config_mod.dict_capacity).init();
        nc.toDictionary(&dict) catch return;

        const dict_data = dict.slice();
        var chunk_index: usize = 0;
        var config_update_id = self.prng();
        if (config_update_id == 0) config_update_id = 1;

        const max_chunk: usize = @intCast(packet_mod.max_packet_length - packet_mod.idx_payload - 256);
        while (chunk_index < dict_data.len) {
            const remaining = dict_data.len - chunk_index;
            const chunk_len = @min(remaining, max_chunk);

            var outp = Packet.initNew(destination, self.identity.address(), if (request_packet_id != 0) packet_mod.Verb.ok else packet_mod.Verb.network_config);
            if (request_packet_id != 0) {
                outp.buf.appendByte(@intFromEnum(packet_mod.Verb.network_config_request), 1) catch return;
                outp.buf.appendInt(u64, request_packet_id) catch return;
            }

            const sig_start: usize = @intCast(outp.buf.size());
            outp.buf.appendInt(u64, nwid) catch return;
            outp.buf.appendInt(u16, @intCast(chunk_len)) catch return;
            outp.buf.appendBytes(dict_data[chunk_index .. chunk_index + chunk_len]) catch return;
            outp.buf.appendByte(0, 1) catch return;
            outp.buf.appendInt(u64, config_update_id) catch return;
            outp.buf.appendInt(u32, @intCast(dict_data.len)) catch return;
            outp.buf.appendInt(u32, @intCast(chunk_index)) catch return;

            const sig = self.identity.sign(outp.buf.data()[sig_start..@intCast(outp.buf.size())]) orelse return;
            outp.buf.appendByte(1, 1) catch return;
            outp.buf.appendInt(u16, @intCast(ecc.signature_len)) catch return;
            outp.buf.appendBytes(sig[0..]) catch return;
            _ = outp.compress();

            const switch_cbs = self.createSwitchCallbacks();
            self.switch_engine.send(@ptrCast(self), &outp, true, nwid, 0, &switch_cbs);
            chunk_index += chunk_len;
        }
    }

    fn ncSendRevocation(self: *Self, destination: Address, rev: *const Revocation) void {
        if (destination.eql(self.identity.address())) {
            if (self.getNetwork(rev.networkId())) |network| {
                _ = network.addCredentialRevocation(null, self.identity.address(), rev, .{});
            }
            return;
        }

        var outp = Packet.initNew(destination, self.identity.address(), .network_credentials);
        outp.buf.appendByte(0, 1) catch return;
        outp.buf.appendInt(u16, 0) catch return;
        outp.buf.appendInt(u16, 0) catch return;
        outp.buf.appendInt(u16, 1) catch return;
        rev.serialize(packet_mod.max_packet_length, &outp.buf) catch return;
        outp.buf.appendInt(u16, 0) catch return;

        const switch_cbs = self.createSwitchCallbacks();
        self.switch_engine.send(@ptrCast(self), &outp, true, rev.networkId(), 0, &switch_cbs);
    }

    fn ncSendError(self: *Self, nwid: u64, request_packet_id: u64, destination: Address, error_code: network_controller_mod.ErrorCode, error_data: []const u8) void {
        if (destination.eql(self.identity.address())) {
            if (self.getNetwork(nwid)) |network| {
                switch (error_code) {
                    .object_not_found, .internal_server_error => network.setNotFound(null),
                    .access_denied => network.setAccessDenied(null),
                    .authentication_required => {},
                    .none => {},
                }
            }
            return;
        }

        if (request_packet_id == 0) return;

        const pkt_error_code: packet_mod.ErrorCode = switch (error_code) {
            .access_denied => .network_access_denied,
            .authentication_required => .network_authentication_required,
            .none, .object_not_found, .internal_server_error => .obj_not_found,
        };

        var outp = Packet.initNew(destination, self.identity.address(), .@"error");
        outp.buf.appendByte(@intFromEnum(packet_mod.Verb.network_config_request), 1) catch return;
        outp.buf.appendInt(u64, request_packet_id) catch return;
        outp.buf.appendByte(@intFromEnum(pkt_error_code), 1) catch return;
        outp.buf.appendInt(u64, nwid) catch return;

        if (error_data.len > 0 and error_data.len <= 0xffff) {
            outp.buf.appendInt(u16, @intCast(error_data.len)) catch return;
            outp.buf.appendBytes(error_data) catch return;
        }

        const switch_cbs = self.createSwitchCallbacks();
        self.switch_engine.send(@ptrCast(self), &outp, true, nwid, 0, &switch_cbs);
    }

    /// Add a local interface address for path selection.
    pub fn addLocalInterfaceAddress(
        self: *Self,
        addr: *const InetAddress,
    ) bool {
        if (!addr.isSet()) {
            return false;
        }

        self.direct_paths_mutex.lock();
        defer self.direct_paths_mutex.unlock();

        for (self.direct_paths.items) |existing| {
            if (existing.eql(addr)) {
                return false;
            }
        }

        self.direct_paths.append(addr.*) catch return false;
        return true;
    }

    /// Clear all local interface addresses.
    pub fn clearLocalInterfaceAddresses(self: *Self) void {
        self.direct_paths_mutex.lock();
        defer self.direct_paths_mutex.unlock();
        self.direct_paths.clearRetainingCapacity();
    }

    /// Return a copy of known direct paths.
    pub fn directPaths(self: *Self, allocator: mem.Allocator) ![]InetAddress {
        self.direct_paths_mutex.lock();
        defer self.direct_paths_mutex.unlock();

        const out = try allocator.alloc(InetAddress, self.direct_paths.items.len);
        @memcpy(out, self.direct_paths.items);
        return out;
    }

    /// True if low-bandwidth mode is enabled.
    pub fn lowBandwidthModeEnabled(self: *const Self) bool {
        return self.low_bandwidth_mode;
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
        out.public_identity = self.public_identity_str;
        out.secret_identity = self.secret_identity_str;
        out.online = self.online;
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

        const mg = MulticastGroup.init(MAC.init(multicast_group), multicast_adi);
        network.multicastSubscribe(t_ptr, mg);
    }

    /// Unsubscribe from a multicast group.
    pub fn multicastUnsubscribe(
        self: *Self,
        nwid: u64,
        multicast_group: u64,
        multicast_adi: u32,
    ) !void {
        const network = self.getNetwork(nwid) orelse return error.NetworkNotFound;

        const mg = MulticastGroup.init(MAC.init(multicast_group), multicast_adi);
        network.multicastUnsubscribe(&mg);
    }

    /// Add a moon (user-defined root server).
    pub fn orbit(
        self: *Self,
        t_ptr: ?*anyopaque,
        moon_world_id: u64,
        moon_seed: u64,
    ) void {
        _ = t_ptr;
        self.topology.addMoon(moon_world_id, Address.init(moon_seed));
    }

    /// Remove a moon.
    pub fn deorbit(
        self: *Self,
        t_ptr: ?*anyopaque,
        moon_world_id: u64,
    ) void {
        _ = t_ptr;
        self.topology.removeMoon(moon_world_id);
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
        return remote_addr.isSet();
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

        var outp = Packet.initNew(Address.init(dest), self.identity.address(), .user_message);
        outp.buf.appendInt(u64, type_id) catch return false;
        outp.buf.appendBytes(data[0..@as(usize, @intCast(len))]) catch return false;
        _ = outp.compress();
        const switch_cbs = self.createSwitchCallbacks();
        self.switch_engine.send(t_ptr, &outp, true, 0, constants.qos_no_flow, &switch_cbs);
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
                fn f(ctx_or_tptr: ?*anyopaque, addr: Address) ?*@import("peer.zig").Peer {
                    // Switch may pass t_ptr or ctx — handle both
                    const ptr = ctx_or_tptr orelse return null;
                    const node: *Self = @ptrCast(@alignCast(ptr));
                    return node.topology.getPeer(addr);
                }
            }.f,

            .sendViaPeer = struct {
                fn f(ctx: ?*anyopaque, peer: *@import("peer.zig").Peer, packet: *const @import("packet.zig").Packet, encrypt: bool, now: i64, flow_id: i32) void {
                    _ = flow_id;
                    const node: *Self = @ptrCast(@alignCast(ctx.?));

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
                fn f(peer: *const @import("peer.zig").Peer) Address {
                    return peer.address();
                }
            }.f,

            .isUpstream = struct {
                fn f(ctx: ?*anyopaque, addr: Address) bool {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    const id = node.topology.getIdentity(addr) orelse return false;
                    return node.topology.isUpstream(id);
                }
            }.f,

            .getNetwork = struct {
                fn f(ctx: ?*anyopaque, nwid: u64) ?*@import("network.zig").Network {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.getNetwork(nwid);
                }
            }.f,

            .networkHasConfig = struct {
                fn f(network: *const @import("network.zig").Network) bool {
                    return network.hasConfig();
                }
            }.f,

            .networkMac = struct {
                fn f(network: *const @import("network.zig").Network) MAC {
                    return network.mac();
                }
            }.f,

            .networkId = struct {
                fn f(network: *const @import("network.zig").Network) u64 {
                    return network.id();
                }
            }.f,

            .networkPermitsBridging = struct {
                fn f(network: *const @import("network.zig").Network, addr: Address) bool {
                    return network.permitsBridging(addr);
                }
            }.f,

            .networkQosEnabled = struct {
                fn f(network: *const @import("network.zig").Network) bool {
                    return network.qosEnabled();
                }
            }.f,

            .myAddress = struct {
                fn f(ctx_or_tptr: ?*anyopaque) Address {
                    const ptr = ctx_or_tptr orelse return Address.zero();
                    const node: *Self = @ptrCast(@alignCast(ptr));
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
                    return packet_mod.Packet.initNew(dest, src, @enumFromInt(@as(u5, @intCast(verb))));
                }
            }.f,

            .packetAppendNetworkId = struct {
                fn f(pkt: *@import("packet.zig").Packet, nwid: u64) void {
                    pkt.buf.appendInt(u64, nwid) catch {};
                }
            }.f,

            .packetAppendEtherType = struct {
                fn f(pkt: *@import("packet.zig").Packet, et: u16) void {
                    pkt.buf.appendInt(u16, et) catch {};
                }
            }.f,

            .packetAppendData = struct {
                fn f(pkt: *@import("packet.zig").Packet, data: [*]const u8, len: u32) void {
                    pkt.buf.appendBytes(data[0..@as(usize, @intCast(len))]) catch {};
                }
            }.f,

            .packetAppendByte = struct {
                fn f(pkt: *@import("packet.zig").Packet, b: u8) void {
                    pkt.buf.appendByte(b, 1) catch {};
                }
            }.f,

            .packetAppendMAC = struct {
                fn f(pkt: *@import("packet.zig").Packet, mac: *const MAC) void {
                    var tmp: [MAC_LENGTH]u8 = undefined;
                    mac.copyTo(&tmp);
                    pkt.buf.appendBytes(&tmp) catch {};
                }
            }.f,

            .putFrame = struct {
                fn f(ctx: ?*anyopaque, nwid: u64, _: *@import("network.zig").Network, from: *const MAC, to: *const MAC, ether_type: u32, vlan_id: u32, data: [*]const u8, len: u32) void {
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
                fn f(ctx: ?*anyopaque, network: *@import("network.zig").Network, from: *const MAC, to: *const MAC, ether_type: u32, vlan_id: u32, data: [*]const u8, len: u32, from_bridged: bool) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.multicastSend(node, network, from, to, ether_type, vlan_id, data, len, from_bridged);
                }
            }.f,

            .pathReceived = struct {
                fn f(ctx: ?*anyopaque, local_socket: i64, from_addr: *const InetAddress, now: i64) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    if (node.topology.getPath(local_socket, from_addr)) |path| {
                        path.received(now);
                    }
                }
            }.f,

            .getPath = struct {
                fn f(ctx: ?*anyopaque, local_socket: i64, from_addr: *const InetAddress) ?*@import("path.zig").Path {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.topology.getPath(local_socket, from_addr);
                }
            }.f,

            .now = struct {
                fn f(ctx_or_tptr: ?*anyopaque) i64 {
                    const ptr = ctx_or_tptr orelse return 0;
                    const node: *Self = @ptrCast(@alignCast(ptr));
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

            .configure_virtual_network_port = struct {
                fn f(
                    ctx: ?*anyopaque,
                    t_ptr: ?*anyopaque,
                    nwid: u64,
                    u_ptr: *?*anyopaque,
                    op: c_uint,
                    config: ?*const constants.c_api.ZT_VirtualNetworkConfig,
                ) c_int {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.configureVirtualNetworkPort(t_ptr, nwid, u_ptr, @as(u32, @intCast(op)), config);
                }
            }.f,

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

            .topologyShouldInboundPathBeTrusted = struct {
                fn f(ctx: ?*anyopaque, path_addr: *const InetAddress, tpid: u64) bool {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.topology.shouldInboundPathBeTrusted(path_addr, tpid);
                }
            }.f,
            .topologyGetPeer = struct {
                fn f(ctx: ?*anyopaque, _: ?*anyopaque, addr: u64) ?*Peer {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.topology.getPeer(Address.init(addr));
                }
            }.f,

            // Switch
            .sw = .{
                .switchRequestWhois = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, now_val: i64, addr: u64) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const sw_callbacks = node.createSwitchCallbacks();
                        node.switch_engine.requestWhois(tptr, now_val, Address.init(addr), &sw_callbacks);
                    }
                }.f,
                .switchDoAnythingWaitingForPeer = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, peer: ?*Peer) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const p = peer orelse return;
                        const sw_callbacks = node.createSwitchCallbacks();
                        node.switch_engine.doAnythingWaitingForPeer(tptr, p, &sw_callbacks);
                    }
                }.f,
            },

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

            .topology = .{
                .topologyAddPeer = struct {
                    fn f(ctx: ?*anyopaque, _: ?*anyopaque, new_identity: *const Identity) ?*Peer {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        var peer = Peer.create(&node.identity, new_identity) orelse return null;
                        peer.setCallbacks(
                            @ptrCast(node),
                            null,
                            null,
                            null,
                            null,
                            null,
                            null,
                            null,
                        );
                        return node.topology.addPeer(&peer);
                    }
                }.f,
                .topologyIsUpstream = struct {
                    fn f(ctx: ?*anyopaque, id: *const Identity) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.isUpstream(id);
                    }
                }.f,
                .topologyPlanetWorldId = struct {
                    fn f(ctx: ?*anyopaque) u64 {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.planetWorldId();
                    }
                }.f,
                .topologyPlanetWorldTimestamp = struct {
                    fn f(ctx: ?*anyopaque) u64 {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.planetWorldTimestamp();
                    }
                }.f,
                .topologySerializePlanet = struct {
                    fn f(ctx: ?*anyopaque, buf: [*]u8, buf_len: u32) u32 {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        var tmp = Buffer(world_mod.max_serialized_length){};
                        node.topology.planet().serialize(world_mod.max_serialized_length, &tmp, false) catch return 0;
                        const data = tmp.data();
                        const data_len: u32 = @as(u32, @intCast(data.len));
                        const len: u32 = @min(buf_len, data_len);
                        @memcpy(buf[0..len], data[0..len]);
                        return len;
                    }
                }.f,
                .topologySerializeUpdatedMoons = struct {
                    fn f(ctx: ?*anyopaque, moon_ids: [*]const u64, moon_timestamps: [*]const u64, moon_count: u32, buf: [*]u8, buf_len: u32) u32 {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        var tmp = Buffer(world_mod.max_serialized_length){};
                        var written: u32 = 0;
                        var moons: [topology_mod.max_moons]World = undefined;
                        const moon_total = node.topology.moons(&moons);
                        var i: u32 = 0;
                        while (i < moon_count) : (i += 1) {
                            const moon_id = moon_ids[i];
                            const moon_ts = moon_timestamps[i];
                            var j: u32 = 0;
                            while (j < moon_total) : (j += 1) {
                                const moon = moons[j];
                                if (moon.id() != moon_id or moon.timestamp() <= moon_ts) continue;
                                tmp = Buffer(world_mod.max_serialized_length){};
                                moon.serialize(world_mod.max_serialized_length, &tmp, false) catch break;
                                const data = tmp.data();
                                if (written >= buf_len) return written;
                                const remaining = buf_len - written;
                                const data_len: u32 = @as(u32, @intCast(data.len));
                                const copy_len: u32 = @min(remaining, data_len);
                                if (copy_len == 0) return written;
                                @memcpy(buf[written..][0..copy_len], data[0..copy_len]);
                                written += copy_len;
                                break;
                            }
                        }
                        return written;
                    }
                }.f,
                .topologyShouldAcceptWorldUpdateFrom = struct {
                    fn f(ctx: ?*anyopaque, addr: u64) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.shouldAcceptWorldUpdateFrom(Address.init(addr));
                    }
                }.f,
                .topologyAddWorld = struct {
                    fn f(ctx: ?*anyopaque, _: ?*anyopaque, world_data: [*]const u8, world_len: u32) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const src = world_data[0..@as(usize, @intCast(world_len))];
                        const buf = Buffer(world_mod.max_serialized_length).initFrom(src) catch return false;
                        var w = World.init();
                        _ = w.deserialize(world_mod.max_serialized_length, &buf, 0) catch return false;
                        return node.topology.addWorld(&w, true);
                    }
                }.f,
                .topologyAmUpstream = struct {
                    fn f(ctx: ?*anyopaque) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.amUpstream();
                    }
                }.f,
                .topologyGetIdentity = struct {
                    fn f(ctx: ?*anyopaque, _: ?*anyopaque, addr: u64) ?*const Identity {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.topology.getIdentity(Address.init(addr));
                    }
                }.f,
            },

            .network = .{
                .nodeGetNetwork = struct {
                    fn f(ctx: ?*anyopaque, nwid: u64) ?*Network {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.getNetwork(nwid);
                    }
                }.f,
                .nodeExpectingReplyTo = struct {
                    fn f(ctx: ?*anyopaque, packet_id: u64) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.isExpectingReplyTo(packet_id);
                    }
                }.f,
                .networkController = struct {
                    fn f(_: ?*anyopaque, network: ?*Network) u64 {
                        return network.?.controller().toInt();
                    }
                }.f,
                .networkSetNotFound = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network) void {
                        network.?.setNotFound(tptr);
                    }
                }.f,
                .networkSetAccessDenied = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network) void {
                        network.?.setAccessDenied(tptr);
                    }
                }.f,
                .networkGate = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network, peer: ?*Peer) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const nw = network orelse return false;
                        const p = peer orelse return false;
                        return nw.gate(tptr, p.address(), p.identity(), node.now);
                    }
                }.f,
                .networkPeerRequestedCredentials = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network, addr: u64, now_val: i64) void {
                        network.?.peerRequestedCredentials(tptr, Address.init(addr), now_val);
                    }
                }.f,
                .networkConfigHasCom = struct {
                    fn f(_: ?*anyopaque, network: ?*Network) bool {
                        return network.?.config().com.isSet();
                    }
                }.f,
                .networkSetAuthenticationRequired = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network, auth_url: [*:0]const u8) void {
                        network.?.setAuthenticationRequired(tptr, mem.span(auth_url));
                    }
                }.f,
                .networkHandleConfigChunk = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network_ptr: ?*Network, packet_id: u64, source_addr: u64, chunk_data: [*]const u8, chunk_offset: u32, chunk_len: u32) void {
                        const network = network_ptr orelse return;
                        const data = chunk_data[0..chunk_len];
                        _ = network.handleConfigChunk(tptr, packet_id, Address.init(source_addr), data, chunk_offset);
                    }
                }.f,
                .networkAddCredentialCOM = struct {
                    fn f(_: ?*anyopaque, _: ?*anyopaque, network: ?*Network, data: [*]const u8, len: u32) bool {
                        const nw = network orelse return false;
                        const slice = data[0..@as(usize, @intCast(len))];
                        if (slice.len > 512) return false;
                        var tmp = Buffer(512){};
                        tmp.appendBytes(slice) catch return false;
                        const parsed = @import("certificate_of_membership.zig").CertificateOfMembership.deserialize(512, &tmp, 0) catch return false;
                        var com = parsed.com;
                        const verify = @import("membership.zig").VerifyCallbacks{};
                        return nw.addCredentialCom(&com, verify) != .rejected;
                    }
                }.f,
                .networkMac = struct {
                    fn f(_: ?*anyopaque, nw: ?*Network) MAC {
                        return nw.?._mac;
                    }
                }.f,
                .networkUserPtr = struct {
                    fn f(_: ?*anyopaque, nw: ?*Network) ?*anyopaque {
                        return nw.?._u_ptr;
                    }
                }.f,
                .networkFilterIncomingPacket = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network: ?*Network, peer: ?*Peer, local_addr: u64, source_mac: *const MAC, dest_mac: *const MAC, frame_data: [*]const u8, frame_len: u32, ethertype: u32, vlan_id: u32) i32 {
                        const nw = network orelse return 0;
                        const p = peer orelse return 0;
                        return nw.filterIncomingPacket(
                            tptr,
                            p.address(),
                            Address.init(local_addr),
                            source_mac.*,
                            dest_mac.*,
                            frame_data[0..@intCast(frame_len)],
                            frame_len,
                            @intCast(ethertype),
                            @intCast(vlan_id),
                        );
                    }
                }.f,
                .networkPushCredentials = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, peer_addr: u64, network: ?*Network, now_val: i64, _: [*]const u8, _: u32) void {
                        network.?.pushCredentialsIfNeeded(tptr, Address.init(peer_addr), now_val);
                    }
                }.f,
                .networkControllerHandleConfigRequest = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, from_addr: *const InetAddress, requester_identity: *const Identity, request_packet_id: u64, nwid: u64, meta_data: *const Dictionary(network_controller_mod.metadata_dict_capacity)) bool {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const controller = node.network_controller orelse return false;

                        _ = tptr;
                        controller.request(nwid, from_addr, request_packet_id, requester_identity, meta_data);
                        return true;
                    }
                }.f,
                .networkHandleConfig = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, network_ptr: ?*Network, packet_id: u64, from_addr: u64, chunk_data: [*]const u8, chunk_len: u32) void {
                        const network = network_ptr orelse return;
                        const data = chunk_data[0..chunk_len];
                        _ = network.handleConfigChunk(tptr, packet_id, Address.init(from_addr), data, 0);
                    }
                }.f,
            },

            .multicast = .{
                .multicasterRemove = struct {
                    fn f(ctx: ?*anyopaque, nwid: u64, mac_bytes: *const [6]u8, adi: u32, addr: u64) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const mg = MulticastGroup.init(MAC.fromBytes(mac_bytes), adi);
                        node.multicaster.remove(nwid, mg, Address.init(addr));
                    }
                }.f,
                .multicasterAddMultiple = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, now_val: i64, nwid: u64, mac_bytes: *const [6]u8, adi: u32, addresses_data: [*]const u8, address_count: u32, _: u32) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const mg = MulticastGroup.init(MAC.fromBytes(mac_bytes), adi);
                        const addr_len = @as(usize, @intCast(address_count * constants.address_length));
                        node.multicaster.addMultiple(
                            tptr,
                            now_val,
                            nwid,
                            mg,
                            addresses_data[0..addr_len],
                            address_count,
                            multicastSendOutbound,
                        );
                    }
                }.f,
                .multicasterAdd = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, now_val: i64, nwid: u64, mg: *const MulticastGroup, addr: u64) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        node.multicaster.add(tptr, now_val, nwid, mg.*, Address.init(addr), multicastSendOutbound);
                    }
                }.f,
                .multicasterGather = struct {
                    fn f(ctx: ?*anyopaque, peer_addr: u64, nwid: u64, mg: *const MulticastGroup, out_packet: *Packet, limit: u32) u32 {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        return node.multicaster.gather(Address.init(peer_addr), nwid, mg.*, &out_packet.buf, limit);
                    }
                }.f,
                .multicasterReceiveMulticastFrame = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, source_addr: u64, mg: *const MulticastGroup, frame_data: [*]const u8, frame_len: u32, ethertype: u32) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const network = node.getNetwork(nwid) orelse return;
                        if (!network.subscribedToMulticastGroup(mg, true)) return;

                        const source_peer = Address.init(source_addr);
                        const source_mac = MAC.fromAddress(source_peer, nwid);
                        if (network.filterIncomingPacket(
                            tptr,
                            source_peer,
                            node.identity.address(),
                            source_mac,
                            mg.mac(),
                            frame_data[0..@as(usize, @intCast(frame_len))],
                            frame_len,
                            @intCast(ethertype),
                            0,
                        ) > 0) {
                            node.putFrame(tptr, nwid, null, &source_mac, &mg.mac(), ethertype, 0, frame_data, frame_len);
                        }
                    }
                }.f,
                .multicasterReplicateMulticastFrame = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, origin_addr: u64, source_mac: *const MAC, mg: *const MulticastGroup, frame_data: [*]const u8, frame_len: u32, ethertype: u32) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const network = node.getNetwork(nwid) orelse return;
                        multicastReplicateInbound(
                            node,
                            tptr,
                            network,
                            Address.init(origin_addr),
                            source_mac,
                            mg,
                            frame_data[0..@as(usize, @intCast(frame_len))],
                            ethertype,
                        );
                    }
                }.f,
            },

            // Peer and path operations
            .peer = .{
                .peerKey = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) *const [32]u8 {
                        const p = peer.?;
                        const key_48 = p.key();
                        return @ptrCast(key_48);
                    }
                }.f,
                .peerAesKeys = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) ?*const [2]Aes {
                        const p = peer.?;
                        return p.aesKeys();
                    }
                }.f,
                .peerAesKeysIfSupported = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) ?*const [2]Aes {
                        const p = peer.?;
                        return p.aesKeysIfSupported();
                    }
                }.f,
                .peerPublicKey = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) *const ecc.Public {
                        const p = peer.?;
                        return p.identity().publicKey();
                    }
                }.f,
                .peerAddress = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) u64 {
                        return peer.?.address().toInt();
                    }
                }.f,
                .peerReceived = struct {
                    fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, peer: ?*Peer, path: ?*Path, hops: u32, packet_id: u64, payload_len: u32, verb_val: u32, in_re_packet_id: u64, in_re_verb: u32, trust_established: bool, network_id: u64, flow_id: i32) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        const Verb = @import("packet.zig").Verb;

                        const p = peer.?;
                        const pth = path.?;
                        const v: Verb = @enumFromInt(verb_val);
                        const in_re_v: Verb = std.meta.intToEnum(Verb, in_re_verb) catch blk: {
                            std.log.warn("ERROR packet references invalid verb {}", .{in_re_verb});
                            break :blk .nop;
                        };

                        p.received(tptr, pth, hops, packet_id, payload_len, v, in_re_packet_id, in_re_v, trust_established, network_id, flow_id, node.now);
                    }
                }.f,
                .peerRecordIncomingInvalidPacket = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, path: ?*Path) void {
                        _ = peer;
                        _ = path;
                    }
                }.f,
                .peerRecordOutgoingPacket = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, path: ?*Path, packet_id: u64, payload_len: u32, verb: u32, flow_id: i32, now_val: i64) void {
                        _ = peer;
                        _ = path;
                        _ = packet_id;
                        _ = payload_len;
                        _ = verb;
                        _ = flow_id;
                        _ = now_val;
                    }
                }.f,
                .peerRateGateQoS = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, now_val: i64, path: ?*Path) bool {
                        const p = peer orelse return false;
                        const pa = path orelse return false;
                        return p.rateGatePushDirectPaths(now_val) and pa.rateGateEchoRequest(now_val);
                    }
                }.f,
                .peerReceivedQoS = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, path: ?*Path, now_val: i64, count: u32, delays: [*]const u64, packets: [*]const u16) void {
                        _ = peer;
                        _ = path;
                        _ = now_val;
                        _ = count;
                        _ = delays;
                        _ = packets;
                    }
                }.f,
                .peerRateGatePathNegotiation = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, now_val: i64, path: ?*Path) bool {
                        const p = peer orelse return false;
                        const pa = path orelse return false;
                        return p.rateGateInboundWhoisRequest(now_val) and pa.rateGateEchoRequest(now_val);
                    }
                }.f,
                .peerProcessIncomingPathNegotiationRequest = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, now_val: i64, path: ?*Path, verb: i16) void {
                        _ = peer;
                        _ = now_val;
                        _ = path;
                        _ = verb;
                    }
                }.f,
                .peerFlowHashingSupported = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) bool {
                        return peer != null;
                    }
                }.f,
                .peerIdentity = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer) *const Identity {
                        return peer.?.identity();
                    }
                }.f,
                .peerSetRemoteVersion = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, proto: u32, major: u32, minor: u32, rev: u32) void {
                        peer.?.setRemoteVersion(@intCast(proto), @intCast(major), @intCast(minor), @intCast(rev));
                    }
                }.f,
                .peerRateGateInboundWhoisRequest = struct {
                    fn f(_: ?*anyopaque, peer: ?*Peer, now_val: i64) bool {
                        const p = peer orelse return false;
                        return p.rateGateInboundWhoisRequest(now_val);
                    }
                }.f,
                .peerAttemptToContactAt = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, peer: ?*Peer, now_val: i64, remote_addr: *const InetAddress, timeout: i64, trusted: bool) void {
                        _ = tptr;
                        _ = peer;
                        _ = now_val;
                        _ = remote_addr;
                        _ = timeout;
                        _ = trusted;
                    }
                }.f,
                .peerReceivePushDirectPaths = struct {
                    fn f(_: ?*anyopaque, tptr: ?*anyopaque, peer: ?*Peer, data: [*]const u8, len: u32, now_val: i64) void {
                        _ = tptr;
                        _ = peer;
                        _ = data;
                        _ = len;
                        _ = now_val;
                    }
                }.f,
            },

            .path = .{
                .pathSend = struct {
                    fn f(ctx: ?*anyopaque, path: ?*Path, tptr: ?*anyopaque, data: [*]const u8, len: u32, _: i64) void {
                        const node: *Self = @ptrCast(@alignCast(ctx.?));
                        if (path) |p| {
                            const remote_addr = p.address();
                            node.callbacks.wireSend(
                                node.callbacks.ctx,
                                tptr,
                                0,
                                remote_addr,
                                data,
                                len,
                                64,
                            );
                        }
                    }
                }.f,
                .pathAddress = struct {
                    var stub_address: InetAddress = InetAddress.initV4([4]u8{ 127, 0, 0, 1 }, 9993);

                    fn f(_: ?*anyopaque, path: ?*Path) *const InetAddress {
                        if (path) |p| {
                            return p.address();
                        }
                        return &stub_address;
                    }
                }.f,
                .pathLocalSocket = struct {
                    fn f(_: ?*anyopaque, path: ?*Path) i64 {
                        if (path) |p| {
                            return p.localSocket();
                        }
                        return 0;
                    }
                }.f,
                .pathRateGateEchoRequest = struct {
                    fn f(_: ?*anyopaque, path: ?*Path, now: i64) bool {
                        const p = path orelse return false;
                        return p.rateGateEchoRequest(now);
                    }
                }.f,
                .pathUpdateLatency = struct {
                    fn f(_: ?*anyopaque, path: ?*Path, latency: u32, _: i64) void {
                        path.?.updateLatency(latency);
                    }
                }.f,
            },

            // Trace operations (logging/debugging)
            .traceIncomingPacketMacFailure = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*Path, _: u64, _: u64, _: u32, _: [*:0]const u8) void {
                    std.debug.print("  ✗ MAC verification failure\n", .{});
                }
            }.f,

            .traceIncomingPacketInvalid = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*Path, _: u64, _: u64, _: u32, _: u32, _: [*:0]const u8) void {
                    std.debug.print("  ✗ Invalid packet\n", .{});
                }
            }.f,

            .traceIncomingPacketDroppedHELLO = struct {
                fn f(_: ?*anyopaque, _: ?*anyopaque, _: ?*Path, _: u64, _: u64, _: [*:0]const u8) void {
                    std.debug.print("  ✗ Dropped HELLO packet\n", .{});
                }
            }.f,

            // Identity verification
            .nodeRateGateIdentityVerification = struct {
                fn f(ctx: ?*anyopaque, now_val: i64, addr: *const InetAddress) bool {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    _ = now_val;
                    _ = addr;
                    return node.identity.address().isSet();
                }
            }.f,

            .selfAwarenessIam = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, now_val: i64, from_addr: *const InetAddress, observed_addr: *const InetAddress, trusted: bool, local_socket: i64) void {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    _ = tptr;
                    _ = nwid;
                    _ = now_val;
                    _ = from_addr;
                    _ = observed_addr;
                    _ = trusted;
                    _ = local_socket;
                    _ = node;
                }
            }.f,

            // Node / Wire callbacks
            .nodeShouldUsePathForZeroTierTraffic = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, local_socket: i64, remote_addr: *const InetAddress) bool {
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    return node.shouldUsePathForZeroTierTraffic(tptr, Address.init(nwid), local_socket, remote_addr);
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

            .pmPutFrame = struct {
                fn f(ctx: ?*anyopaque, tptr: ?*anyopaque, nwid: u64, user_ptr: ?*anyopaque, source_mac: *const MAC, dest_mac: *const MAC, ethertype: u32, vlan_id: u32, frame_data: *const anyopaque, frame_len: u32, flow_id: i32) void {
                    _ = flow_id;
                    const node: *Self = @ptrCast(@alignCast(ctx.?));
                    node.putFrame(tptr, nwid, @ptrCast(@constCast(&user_ptr)), source_mac, dest_mac, ethertype, vlan_id, @ptrCast(frame_data), frame_len);
                }
            }.f,
        };
    }

    /// Get planet (root server world).
    pub fn getPlanet(self: *const Self) ?*const anyopaque {
        return @ptrCast(self.topology.planet());
    }

    /// Get moons (user root servers).
    pub fn getMoons(self: *Self, allocator: mem.Allocator) ![]u64 {
        var moons: [topology_mod.max_moons]World = undefined;
        const count = self.topology.moons(&moons);
        var out = try allocator.alloc(u64, count);
        for (moons[0..count], 0..) |moon, i| {
            out[i] = moon.id();
        }
        return out;
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
        user_ptr: *?*anyopaque,
        operation: u32,
        config: ?*const constants.c_api.ZT_VirtualNetworkConfig,
    ) i32 {
        const cb = self.callbacks.configure_virtual_network_port orelse return 0;
        return cb(
            self.callbacks.ctx,
            self.user_ptr,
            t_ptr,
            nwid,
            user_ptr,
            @as(c_uint, @intCast(operation)),
            config,
        );
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
    public_identity: [identity_mod.string_buffer_length]u8,
    secret_identity: [identity_mod.string_buffer_length]u8,
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

    // Virtual network configuration notification
    configure_virtual_network_port: ?*const fn (
        ctx: ?*anyopaque,
        user_ptr: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        network_user_ptr: *?*anyopaque,
        operation: c_uint,
        config: ?*const constants.c_api.ZT_VirtualNetworkConfig,
    ) i32 = null,
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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;

    // Join network
    const net = try node.joinNetwork(nwid);
    try testing.expect(node.getNetwork(nwid) == net);

    // Get network
    const net2 = node.getNetwork(nwid);
    try testing.expect(net2 != null);
    try testing.expect(net == net2);

    // Leave network
    node.leaveNetwork(null, nwid, null);

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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
    defer node.deinit();

    // Address should match the generated identity.
    const addr = node.address();
    try testing.expect(addr != 0);

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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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

    const node = try Node.init(testing.allocator, null, null, &config, callbacks, 1000);
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

test "Node: expectReplyTo and isExpectingReplyTo" {
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
    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const pkt_id: u64 = 0xDEADBEEF_12345678;

    // Not expecting anything initially
    try testing.expect(!node.isExpectingReplyTo(pkt_id));

    // Record expectation
    node.expectReplyTo(pkt_id);

    // Now expecting it
    try testing.expect(node.isExpectingReplyTo(pkt_id));

    // Different packet ID with different upper bits — not expected
    const other_id: u64 = 0xCAFEBABE_12345678;
    try testing.expect(!node.isExpectingReplyTo(other_id));

    // Record the second one
    node.expectReplyTo(other_id);
    try testing.expect(node.isExpectingReplyTo(other_id));
    // First still expected (ring buffer has 32 slots per bucket)
    try testing.expect(node.isExpectingReplyTo(pkt_id));
}

test "Node: expectReplyTo wraps ring buffer" {
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
    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    // Fill one bucket with 33 entries (32-slot ring buffer + 1 overflow).
    // All have same lower 8 bits of upper-32 → same bucket (0x42).
    const base: u64 = 0x00000042_00000000;
    var i: u32 = 0;
    while (i < 33) : (i += 1) {
        const pkt_id = base | (@as(u64, i) << 40);
        node.expectReplyTo(pkt_id);
    }

    // The 33rd entry overwrote the 1st (ring wraps at 32)
    const first_id = base | (@as(u64, 0) << 40);
    try testing.expect(!node.isExpectingReplyTo(first_id));

    // The 33rd entry is still present
    const last_id = base | (@as(u64, 32) << 40);
    try testing.expect(node.isExpectingReplyTo(last_id));
}

test "Node: direct path tracking" {
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

    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const addr = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    try testing.expect(node.addLocalInterfaceAddress(&addr));
    try testing.expect(!node.addLocalInterfaceAddress(&addr));

    const copied = try node.directPaths(testing.allocator);
    defer testing.allocator.free(copied);
    try testing.expectEqual(@as(usize, 1), copied.len);
    try testing.expect(copied[0].eql(&addr));

    node.clearLocalInterfaceAddresses();
    const cleared = try node.directPaths(testing.allocator);
    defer testing.allocator.free(cleared);
    try testing.expectEqual(@as(usize, 0), cleared.len);
}

test "Node: multicast receive injects subscribed frame" {
    const TestCtx = struct {
        var injected: bool = false;
        var injected_nwid: u64 = 0;
        var injected_source: u64 = 0;
        var injected_dest: u64 = 0;
        var injected_ethertype: u32 = 0;
        var injected_len: u32 = 0;
    };

    TestCtx.injected = false;
    TestCtx.injected_nwid = 0;
    TestCtx.injected_source = 0;
    TestCtx.injected_dest = 0;
    TestCtx.injected_ethertype = 0;
    TestCtx.injected_len = 0;

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
            fn f(_: ?*anyopaque, _: ?*anyopaque, nwid: u64, source_mac: u64, dest_mac: u64, ether_type: u32, _: u32, _: [*]const u8, len: u32) void {
                TestCtx.injected = true;
                TestCtx.injected_nwid = nwid;
                TestCtx.injected_source = source_mac;
                TestCtx.injected_dest = dest_mac;
                TestCtx.injected_ethertype = ether_type;
                TestCtx.injected_len = len;
            }
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;
    const net = try node.joinNetwork(nwid);

    var nc = NetworkConfig.init();
    nc.network_id = nwid;
    nc.issued_to = node.identity.address();
    nc.flags = network_config_mod.flag_enable_broadcast;
    nc.multicast_limit = 16;
    nc.net_type = @intCast(constants.c_api.ZT_NETWORK_TYPE_PUBLIC);
    nc.rule_count = 1;
    nc.rules_arr[0].t = @as(u8, constants.c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    try testing.expectEqual(@as(i32, 2), net.setConfiguration(null, &nc, false));

    const mg = MulticastGroup.init(MAC.init(0x01005E000001), 0);
    net.multicastSubscribe(null, mg);

    const frame = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const source_addr = Address.init(0x1234567890);
    node.multicaster.add(null, 1000, nwid, mg, source_addr, null);

    const incoming = node.createIncomingPacketCallbacks(null);
    incoming.multicast.multicasterReceiveMulticastFrame(
        @ptrCast(node),
        null,
        nwid,
        source_addr.toInt(),
        &mg,
        &frame,
        frame.len,
        0x0800,
    );

    try testing.expect(TestCtx.injected);
    try testing.expectEqual(nwid, TestCtx.injected_nwid);
    try testing.expectEqual(MAC.fromAddress(source_addr, nwid).toInt(), TestCtx.injected_source);
    try testing.expectEqual(mg.mac().toInt(), TestCtx.injected_dest);
    try testing.expectEqual(@as(u32, 0x0800), TestCtx.injected_ethertype);
    try testing.expectEqual(@as(u32, frame.len), TestCtx.injected_len);
}

test "Node: multicast send emulates ipv6 ndp neighbor advertisement" {
    const TestCtx = struct {
        var injected: bool = false;
        var injected_nwid: u64 = 0;
        var injected_source: u64 = 0;
        var injected_dest: u64 = 0;
        var injected_ethertype: u32 = 0;
        var injected_len: u32 = 0;
        var injected_payload: [72]u8 = [_]u8{0} ** 72;
        var wire_send_count: usize = 0;
    };

    TestCtx.injected = false;
    TestCtx.injected_nwid = 0;
    TestCtx.injected_source = 0;
    TestCtx.injected_dest = 0;
    TestCtx.injected_ethertype = 0;
    TestCtx.injected_len = 0;
    TestCtx.injected_payload = [_]u8{0} ** 72;
    TestCtx.wire_send_count = 0;

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
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32, _: i32) void {
                TestCtx.wire_send_count += 1;
            }
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, nwid: u64, source_mac: u64, dest_mac: u64, ether_type: u32, _: u32, data: [*]const u8, len: u32) void {
                TestCtx.injected = true;
                TestCtx.injected_nwid = nwid;
                TestCtx.injected_source = source_mac;
                TestCtx.injected_dest = dest_mac;
                TestCtx.injected_ethertype = ether_type;
                TestCtx.injected_len = len;
                @memcpy(TestCtx.injected_payload[0..len], data[0..len]);
            }
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;
    const net = try node.joinNetwork(nwid);

    var nc = NetworkConfig.init();
    nc.network_id = nwid;
    nc.issued_to = node.identity.address();
    nc.flags = network_config_mod.flag_enable_broadcast | network_config_mod.flag_enable_ipv6_ndp_emulation;
    nc.multicast_limit = 16;
    nc.net_type = @intCast(constants.c_api.ZT_NETWORK_TYPE_PUBLIC);
    nc.rule_count = 1;
    nc.rules_arr[0].t = @as(u8, constants.c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    nc.static_ips[0] = InetAddress.makeIpv6rfc4193(nwid, node.identity.address().toInt());
    nc.static_ip_count = 1;
    try testing.expectEqual(@as(i32, 2), net.setConfiguration(null, &nc, false));

    const from = MAC.init(0x021122334455);
    const target = Address.init(0x1234567890);
    const target_mac = MAC.fromAddress(target, nwid);
    const target_ip = InetAddress.makeIpv6rfc4193(nwid, target.toInt()).rawIpData().?;
    const local_ip = nc.static_ips[0].rawIpData().?;

    var ns: [72]u8 = [_]u8{0} ** 72;
    ns[0] = 0x60;
    ns[4] = 0x00;
    ns[5] = 0x20;
    ns[6] = icmpv6_next_header;
    ns[7] = 0xff;
    @memcpy(ns[8..24], local_ip[0..16]);
    ns[24] = 0xff;
    ns[25] = 0x02;
    ns[38] = 0x00;
    ns[39] = 0x01;
    ns[40] = icmpv6_neighbor_solicitation;
    ns[44] = 0x00;
    ns[45] = 0x00;
    ns[46] = 0x00;
    ns[47] = 0x00;
    @memcpy(ns[48..64], target_ip[0..16]);
    ns[64] = 0x01;
    ns[65] = 0x01;
    var from_bytes: [MAC_LENGTH]u8 = undefined;
    from.copyTo(&from_bytes);
    @memcpy(ns[66..72], &from_bytes);

    const dest = MAC.init(0x3333ff345678);
    node.multicastSend(null, net, &from, &dest, ethertype_ipv6, 0, &ns, ns.len, false);

    try testing.expect(TestCtx.injected);
    try testing.expectEqual(@as(usize, 0), TestCtx.wire_send_count);
    try testing.expectEqual(nwid, TestCtx.injected_nwid);
    try testing.expectEqual(target_mac.toInt(), TestCtx.injected_source);
    try testing.expectEqual(from.toInt(), TestCtx.injected_dest);
    try testing.expectEqual(ethertype_ipv6, TestCtx.injected_ethertype);
    try testing.expectEqual(@as(u32, 72), TestCtx.injected_len);
    try testing.expectEqual(@as(u8, icmpv6_neighbor_advertisement), TestCtx.injected_payload[40]);
    try testing.expectEqualSlices(u8, target_ip[0..16], TestCtx.injected_payload[48..64]);
}

test "Node: inbound multicast replication fans out to other members" {
    const TestCtx = struct {
        var wire_send_count: usize = 0;
        var last_len: u32 = 0;
    };

    TestCtx.wire_send_count = 0;
    TestCtx.last_len = 0;

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
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, len: u32, _: i32) void {
                TestCtx.wire_send_count += 1;
                TestCtx.last_len = len;
            }
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;
    const net = try node.joinNetwork(nwid);

    var nc = NetworkConfig.init();
    nc.network_id = nwid;
    nc.issued_to = node.identity.address();
    nc.multicast_limit = 16;
    nc.net_type = @intCast(constants.c_api.ZT_NETWORK_TYPE_PUBLIC);
    nc.rule_count = 1;
    nc.rules_arr[0].t = @as(u8, constants.c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    try testing.expectEqual(@as(i32, 2), net.setConfiguration(null, &nc, false));

    var peer_id = try Identity.generate(testing.allocator);
    var peer = Peer.create(&node.identity, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();

    const remote = InetAddress.initV4(.{ 10, 0, 0, 2 }, 9993);
    const path = node.topology.getPath(1, &remote) orelse return error.SkipZigTest;
    path.received(node.now);
    path.updateLatency(10);
    try testing.expect(peer.addPath(path, node.now));
    const stored_peer = node.topology.addPeer(&peer) orelse return error.SkipZigTest;
    _ = stored_peer;

    const mg = MulticastGroup.init(MAC.init(0x01005E000001), 0x12345678);
    const origin = Address.init(0x2233445566);
    node.multicaster.add(null, node.now, nwid, mg, peer_id.address(), null);
    node.multicaster.add(null, node.now, nwid, mg, origin, null);

    const incoming = node.createIncomingPacketCallbacks(null);
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    incoming.multicast.multicasterReplicateMulticastFrame(
        @ptrCast(node),
        null,
        nwid,
        origin.toInt(),
        &MAC.init(0x001122334455),
        &mg,
        &payload,
        payload.len,
        0x0800,
    );

    try testing.expectEqual(@as(usize, 1), TestCtx.wire_send_count);
    try testing.expect(TestCtx.last_len > 0);
}

test "Node: multicast send prefers best live replicator" {
    const TestCtx = struct {
        var wire_send_count: usize = 0;
        var last_remote_port: u16 = 0;
        var last_len: u32 = 0;
    };

    TestCtx.wire_send_count = 0;
    TestCtx.last_remote_port = 0;
    TestCtx.last_len = 0;

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
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: i64, remote_addr: *const InetAddress, _: [*]const u8, len: u32, _: i32) void {
                TestCtx.wire_send_count += 1;
                TestCtx.last_remote_port = remote_addr.port();
                TestCtx.last_len = len;
            }
        }.f,
        .frameInject = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .event = struct {
            fn f(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: ?*const anyopaque) void {}
        }.f,
    };

    const node = try Node.init(testing.allocator, null, null, &Config{}, callbacks, 1000);
    defer node.deinit();

    const nwid: u64 = 0x8056c2e21c000001;
    const net = try node.joinNetwork(nwid);

    var nc = NetworkConfig.init();
    nc.network_id = nwid;
    nc.issued_to = node.identity.address();
    nc.multicast_limit = 16;
    nc.net_type = @intCast(constants.c_api.ZT_NETWORK_TYPE_PUBLIC);
    nc.rule_count = 1;
    nc.rules_arr[0].t = @as(u8, constants.c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    var id_fast = try Identity.generate(testing.allocator);
    var id_slow = try Identity.generate(testing.allocator);
    try testing.expect(nc.addSpecialist(id_fast.address(), network_config_mod.specialist_type_multicast_replicator));
    try testing.expect(nc.addSpecialist(id_slow.address(), network_config_mod.specialist_type_multicast_replicator));
    try testing.expectEqual(@as(i32, 2), net.setConfiguration(null, &nc, false));

    var peer_fast = Peer.create(&node.identity, &id_fast) orelse return error.SkipZigTest;
    defer peer_fast.deinit();
    const addr_fast = InetAddress.initV4(.{ 10, 0, 0, 2 }, 9992);
    const path_fast = node.topology.getPath(1, &addr_fast) orelse return error.SkipZigTest;
    path_fast.received(node.now);
    path_fast.updateLatency(10);
    try testing.expect(peer_fast.addPath(path_fast, node.now));
    _ = node.topology.addPeer(&peer_fast) orelse return error.SkipZigTest;

    var peer_slow = Peer.create(&node.identity, &id_slow) orelse return error.SkipZigTest;
    defer peer_slow.deinit();
    const addr_slow = InetAddress.initV4(.{ 10, 0, 0, 3 }, 9993);
    const path_slow = node.topology.getPath(1, &addr_slow) orelse return error.SkipZigTest;
    path_slow.received(node.now);
    path_slow.updateLatency(50);
    try testing.expect(peer_slow.addPath(path_slow, node.now));
    _ = node.topology.addPeer(&peer_slow) orelse return error.SkipZigTest;

    const from = net.mac();
    const to = MAC.init(0x01005E000001);
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    node.multicastSend(null, net, &from, &to, 0x0800, 0, &payload, payload.len, false);

    try testing.expectEqual(@as(usize, 1), TestCtx.wire_send_count);
    try testing.expectEqual(@as(u16, 9992), TestCtx.last_remote_port);
    try testing.expect(TestCtx.last_len > 0);
}
