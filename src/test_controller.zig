/// Simple ZeroTier network controller for testing
///
/// This implements a minimal network controller that can:
/// - Handle NETWORK_CONFIG_REQUEST packets
/// - Issue network configurations
/// - Authorize members
///
/// This allows testing the full network join flow in Docker/QEMU

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const buffer_mod = @import("node/buffer.zig");
const PacketBuffer = buffer_mod.Buffer(pkt.max_packet_length);

const NetworkConfig = struct {
    network_id: u64,
    name: []const u8,
    mtu: u16,
    multicast_limit: u32,
    revision: u64,

    // Members authorized on this network
    members: std.AutoHashMap(u64, MemberInfo),

    const MemberInfo = struct {
        address: Address,
        authorized: bool,
        ip_assignments: std.ArrayList([4]u8),
    };
};

const Controller = struct {
    identity: Identity,
    address: Address,
    socket: std.posix.socket_t,
    allocator: std.mem.Allocator,

    // Networks managed by this controller
    networks: std.AutoHashMap(u64, NetworkConfig),

    // Known peers (for shared keys)
    peers: std.AutoHashMap(u64, PeerInfo),

    const PeerInfo = struct {
        address: Address,
        identity: ?Identity,
        shared_key: [32]u8,
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !Controller {
        std.debug.print("Initializing network controller on port {}...\n", .{port});

        var identity = try Identity.generate(allocator);
        const address = identity.address();

        std.debug.print("  Controller identity: {}\n", .{address});

        // Bind socket
        const bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(sock);

        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        const flags = try std.posix.fcntl(sock, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(sock, std.posix.F.SETFL, flags | @as(i32, 0x04));

        std.debug.print("  ✓ Listening on 0.0.0.0:{}\n", .{port});

        var ctrl = Controller{
            .identity = identity,
            .address = address,
            .socket = sock,
            .allocator = allocator,
            .networks = std.AutoHashMap(u64, NetworkConfig).init(allocator),
            .peers = std.AutoHashMap(u64, PeerInfo).init(allocator),
        };

        // Create a test network
        try ctrl.createNetwork(0x8056c2e21c000001, "TestNetwork");

        return ctrl;
    }

    pub fn deinit(self: *Controller) void {
        std.posix.close(self.socket);
        self.identity.deinit();

        var net_it = self.networks.iterator();
        while (net_it.next()) |entry| {
            entry.value_ptr.members.deinit();
        }
        self.networks.deinit();

        var peer_it = self.peers.iterator();
        while (peer_it.next()) |entry| {
            if (entry.value_ptr.identity) |*id| {
                id.deinit();
            }
        }
        self.peers.deinit();
    }

    fn createNetwork(self: *Controller, network_id: u64, name: []const u8) !void {
        const config = NetworkConfig{
            .network_id = network_id,
            .name = name,
            .mtu = 2800,
            .multicast_limit = 32,
            .revision = 1,
            .members = std.AutoHashMap(u64, NetworkConfig.MemberInfo).init(self.allocator),
        };

        try self.networks.put(network_id, config);
        std.debug.print("  ✓ Created network: {s} (ID: 0x{x})\n", .{ name, network_id });
    }

    pub fn run(self: *Controller) !void {
        std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
        std.debug.print("  NETWORK CONTROLLER RUNNING\n", .{});
        std.debug.print("═" ** 60 ++ "\n\n", .{});
        std.debug.print("Press Ctrl+C to stop\n\n", .{});

        var recv_buf: [4096]u8 = undefined;
        var packet_count: usize = 0;

        while (true) {
            var from_addr: net.Address = undefined;
            var from_len: std.posix.socklen_t = @sizeOf(net.Address);

            const len = std.posix.recvfrom(
                self.socket,
                &recv_buf,
                0,
                &from_addr.any,
                &from_len,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            packet_count += 1;

            std.debug.print("[{}] Received {} bytes from {}:{}\n", .{
                packet_count,
                len,
                from_addr.in.sa.addr,
                std.mem.bigToNative(u16, from_addr.in.sa.port),
            });

            // Parse packet
            var pkt_buf: PacketBuffer = .{};
            try pkt_buf.copyFrom(recv_buf[0..len]);
            var received_pkt = Packet{ .buf = pkt_buf };

            const source = received_pkt.source();
            const verb = received_pkt.verb();

            std.debug.print("  Source: {}\n", .{source});
            std.debug.print("  Verb: {}\n", .{verb});

            // Handle packet
            try self.handlePacket(&received_pkt, &from_addr, source);
        }
    }

    fn handlePacket(self: *Controller, packet: *Packet, from_addr: *net.Address, source: Address) !void {
        const verb = packet.verb();

        switch (verb) {
            .network_config_request => try self.handleNetworkConfigRequest(packet, from_addr, source),
            .hello => std.debug.print("  → HELLO (controller doesn't handle these - root server does)\n", .{}),
            else => std.debug.print("  → Unhandled verb: {}\n", .{verb}),
        }
    }

    fn handleNetworkConfigRequest(
        self: *Controller,
        packet: *Packet,
        from_addr: *net.Address,
        source: Address,
    ) !void {
        std.debug.print("  → Processing NETWORK_CONFIG_REQUEST\n", .{});

        // Get or create peer info
        const peer_addr_int = source._a;
        const peer_info = self.peers.get(peer_addr_int);

        var shared_key: [32]u8 = undefined;
        var key_available = false;

        if (peer_info) |info| {
            shared_key = info.shared_key;
            key_available = true;
        }

        // Try to dearmor
        if (key_available) {
            const mac_valid = packet.dearmor(&shared_key, null, null);
            if (!mac_valid) {
                std.debug.print("    ❌ Invalid MAC\n", .{});
                return;
            }
            std.debug.print("    ✓ MAC valid\n", .{});
        }

        // Parse network ID from payload
        const network_id = packet.buf.at(u64, pkt.idx_payload) catch {
            std.debug.print("    ❌ Failed to parse network ID\n", .{});
            return;
        };

        std.debug.print("    Requested network: 0x{x}\n", .{network_id});

        // Check if we manage this network
        var network_config = self.networks.getPtr(network_id);
        if (network_config == null) {
            std.debug.print("    ❌ Unknown network\n", .{});
            return;
        }

        // Auto-authorize the member
        const member_result = try network_config.?.members.getOrPut(peer_addr_int);
        if (!member_result.found_existing) {
            // New member - assign IP
            var ip_list = std.ArrayList([4]u8){};
            const member_count = network_config.?.members.count();
            const ip = [4]u8{ 10, 147, @intCast((member_count / 256) % 256), @intCast(member_count % 256) };
            try ip_list.append(self.allocator, ip);

            member_result.value_ptr.* = .{
                .address = source,
                .authorized = true,
                .ip_assignments = ip_list,
            };

            std.debug.print("    ✓ New member authorized: 10.147.{}.{}\n", .{ ip[2], ip[3] });
        } else {
            std.debug.print("    ✓ Existing member\n", .{});
        }

        // Send network config
        try self.sendNetworkConfig(packet, from_addr, source, network_config.?, &shared_key, key_available);
    }

    fn sendNetworkConfig(
        self: *Controller,
        _: *Packet,
        to_addr: *net.Address,
        to_address: Address,
        network_config: *NetworkConfig,
        shared_key: *[32]u8,
        key_available: bool,
    ) !void {
        std.debug.print("  → Sending NETWORK_CONFIG\n", .{});

        var config_resp = Packet.initNew(to_address, self.address, .network_config);

        const now = std.time.milliTimestamp();

        // Network config payload
        try config_resp.buf.appendInt(u64, network_config.network_id);
        try config_resp.buf.appendInt(i64, now);
        try config_resp.buf.appendInt(u64, network_config.revision);
        try config_resp.buf.appendInt(u64, to_address._a); // issued to
        try config_resp.buf.appendByte(0, 1); // flags
        try config_resp.buf.appendInt(u16, network_config.mtu);
        try config_resp.buf.appendInt(u32, network_config.multicast_limit);

        // Name (empty for now)
        try config_resp.buf.appendByte(0, 1);

        // Get member's IP assignments
        const member = network_config.members.get(to_address._a);
        if (member) |m| {
            try config_resp.buf.appendInt(u16, @intCast(m.ip_assignments.items.len));
            for (m.ip_assignments.items) |ip| {
                try config_resp.buf.appendByte(4, 1); // IPv4
                try config_resp.buf.appendByte(8, 1); // metric
                try config_resp.buf.appendBytes(&ip);
                try config_resp.buf.appendByte(24, 1); // netmask bits
            }
        } else {
            try config_resp.buf.appendInt(u16, 0); // no IPs
        }

        // Routes, static IPs, rules, capabilities, tags, certificates (all empty)
        try config_resp.buf.appendInt(u16, 0); // routes
        try config_resp.buf.appendInt(u16, 0); // static IPs
        try config_resp.buf.appendInt(u16, 0); // rules
        try config_resp.buf.appendInt(u16, 0); // capabilities
        try config_resp.buf.appendInt(u16, 0); // tags
        try config_resp.buf.appendInt(u16, 0); // certificates

        // Armor
        if (key_available) {
            config_resp.armor(shared_key, false, false, null, null);
        } else {
            const placeholder_key = [_]u8{0} ** 32;
            config_resp.armor(&placeholder_key, false, false, null, null);
        }

        const config_data = config_resp.buf.data();
        const sent = try std.posix.sendto(
            self.socket,
            config_data,
            0,
            &to_addr.any,
            to_addr.getOsSockLen(),
        );

        std.debug.print("    ✓ Sent NETWORK_CONFIG ({} bytes)\n", .{sent});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = 9995;

    var controller = try Controller.init(allocator, port);
    defer controller.deinit();

    try controller.run();
}
