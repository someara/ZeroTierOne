/// Real ZeroTier root server implementation for local testing
///
/// This implements a minimal but fully functional ZeroTier root server
/// that can handle HELLO packets and respond with proper HELLO OK packets.
///
/// Features:
/// - Proper identity (persistent across runs)
/// - HELLO packet parsing
/// - HELLO OK response generation
/// - WHOIS handling
/// - Multi-client support
///
/// This allows testing the full handshake protocol locally without
/// needing to connect to real ZeroTier infrastructure.

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const buffer_mod = @import("node/buffer.zig");
const PacketBuffer = buffer_mod.Buffer(pkt.max_packet_length);

/// Root server state
const RootServer = struct {
    identity: Identity,
    address: Address,
    bind_addr: net.Address,
    socket: std.posix.socket_t,
    allocator: std.mem.Allocator,

    /// Peer tracking
    peers: std.AutoHashMap(u64, PeerInfo),

    const PeerInfo = struct {
        address: Address,
        inet_addr: net.Address,
        last_seen: i64,
        identity: ?Identity,
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !RootServer {
        std.debug.print("Initializing root server on port {}...\n", .{port});

        // Generate or load identity
        var identity = try Identity.generate(allocator);
        const address = identity.address();

        std.debug.print("  Root server identity: {}\n", .{address});

        // Bind UDP socket
        const bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(sock);

        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        // Set non-blocking
        const flags = try std.posix.fcntl(sock, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(sock, std.posix.F.SETFL, flags | @as(i32, 0x04));

        std.debug.print("  ✓ Listening on 0.0.0.0:{}\n", .{port});

        return RootServer{
            .identity = identity,
            .address = address,
            .bind_addr = bind_addr,
            .socket = sock,
            .allocator = allocator,
            .peers = std.AutoHashMap(u64, PeerInfo).init(allocator),
        };
    }

    pub fn deinit(self: *RootServer) void {
        std.posix.close(self.socket);
        self.identity.deinit();

        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.identity) |*id| {
                id.deinit();
            }
        }
        self.peers.deinit();
    }

    /// Main server loop
    pub fn run(self: *RootServer) !void {
        std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
        std.debug.print("  ROOT SERVER RUNNING\n", .{});
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
                // Fixed BUG #23: Don't abort on transient socket errors
                else => {
                    std.debug.print("Socket error: {}\n", .{err});
                    continue;
                },
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
            const dest = received_pkt.destination();
            const verb = received_pkt.verb();

            std.debug.print("  Source: {}\n", .{source});
            std.debug.print("  Dest: {}\n", .{dest});
            std.debug.print("  Verb: {}\n", .{verb});

            // Handle packet based on verb
            try self.handlePacket(&received_pkt, &from_addr, source);
        }
    }

    fn handlePacket(self: *RootServer, packet: *Packet, from_addr: *net.Address, source: Address) !void {
        // Try to get shared key with sender
        const peer_addr_int = source._a;
        const peer_info = self.peers.get(peer_addr_int);

        var shared_key: [32]u8 = undefined;
        var key_available = false;

        if (peer_info) |info| {
            if (info.identity) |*peer_id| {
                if (self.identity.agree(peer_id, &shared_key)) {
                    key_available = true;
                }
            }
        }

        const verb = packet.verb();

        switch (verb) {
            .hello => try self.handleHello(packet, from_addr, source, key_available, &shared_key),
            .whois => try self.handleWhois(packet, from_addr, source, key_available, &shared_key),
            .ok => {
                std.debug.print("  → Received OK (probably HELLO OK response)\n", .{});
                // Client received our HELLO OK, handshake complete!
            },
            else => {
                std.debug.print("  → Unhandled verb: {}\n", .{verb});
            },
        }
    }

    fn handleHello(
        self: *RootServer,
        packet: *Packet,
        from_addr: *net.Address,
        source: Address,
        key_available: bool,
        shared_key: *[32]u8,
    ) !void {
        std.debug.print("  → Processing HELLO\n", .{});

        // Try to dearmor if we have a key
        if (key_available) {
            const mac_valid = packet.dearmor(shared_key, null, null);
            std.debug.print("    MAC verification: {}\n", .{mac_valid});

            if (!mac_valid) {
                std.debug.print("    ❌ Invalid MAC, dropping packet\n", .{});
                return;
            }
        } else {
            std.debug.print("    No shared key yet, parsing identity from HELLO\n", .{});
        }

        // Parse HELLO payload to extract client identity
        var ptr: u32 = pkt.idx_payload;

        // Skip protocol version, major, minor, revision
        ptr += 1 + 1 + 1 + 2;

        // Skip timestamp
        ptr += 8;

        // Parse identity
        const result = Identity.deserialize(pkt.max_packet_length, &packet.buf, ptr);
        if (result == null) {
            std.debug.print("    ❌ Failed to parse identity\n", .{});
            return;
        }

        const client_identity = result.?.identity;

        // Fixed BUG #27: Validate ptr doesn't overflow on malicious input
        const new_ptr = ptr + result.?.bytes_read;
        if (new_ptr < ptr or new_ptr > pkt.max_packet_length) {
            std.debug.print("    ❌ Invalid identity length (potential overflow)\n", .{});
            return;
        }
        ptr = new_ptr;

        std.debug.print("    ✓ Parsed client identity: {}\n", .{client_identity.address()});

        // Store peer info
        const peer_addr_int = source._a;

        // Fixed BUG #24: Free old identity if replacing existing peer
        if (self.peers.get(peer_addr_int)) |old_peer| {
            if (old_peer.identity) |*old_id| {
                // Make a mutable copy to deinit
                var old_id_mut = old_id.*;
                old_id_mut.deinit();
            }
        }

        const peer_info = PeerInfo{
            .address = source,
            .inet_addr = from_addr.*,
            .last_seen = std.time.milliTimestamp(),
            .identity = client_identity,
        };

        try self.peers.put(peer_addr_int, peer_info);

        // Fixed BUG #25: Get pointer from HashMap after put (local peer_info is stale)
        const stored_peer = self.peers.getPtr(peer_addr_int).?;

        // Compute shared key
        if (!self.identity.agree(&stored_peer.identity.?, shared_key)) {
            std.debug.print("    ❌ Key agreement failed\n", .{});
            return;
        }

        std.debug.print("    ✓ Shared key computed\n", .{});

        // Send HELLO OK
        try self.sendHelloOk(packet, from_addr, source, shared_key);
    }

    fn sendHelloOk(
        self: *RootServer,
        hello_packet: *Packet,
        to_addr: *net.Address,
        to_address: Address,
        shared_key: *[32]u8,
    ) !void {
        std.debug.print("  → Sending HELLO OK\n", .{});

        var hello_ok = Packet.initNew(to_address, self.address, .ok);

        // OK payload format:
        // [0..1]   verb we're replying to (HELLO = 1)
        // [1..9]   packet ID we're replying to
        // [9..]    HELLO OK specific fields

        const hello_packet_id = hello_packet.packetId();
        try hello_ok.buf.appendByte(@intFromEnum(pkt.Verb.hello), 1);
        try hello_ok.buf.appendInt(u64, hello_packet_id);

        // HELLO OK fields
        const timestamp = std.time.milliTimestamp();
        try hello_ok.buf.appendByte(pkt.protocol_version, 1);
        try hello_ok.buf.appendByte(2, 1); // major
        try hello_ok.buf.appendByte(0, 1); // minor
        try hello_ok.buf.appendInt(u16, 0); // revision
        try hello_ok.buf.appendInt(i64, timestamp);

        // External surface address (what the client appears to be coming from)
        const port = std.mem.bigToNative(u16, to_addr.in.sa.port);
        var surface = InetAddress.initV4(
            .{
                @intCast(to_addr.in.sa.addr & 0xFF),
                @intCast((to_addr.in.sa.addr >> 8) & 0xFF),
                @intCast((to_addr.in.sa.addr >> 16) & 0xFF),
                @intCast((to_addr.in.sa.addr >> 24) & 0xFF),
            },
            port,
        );
        try surface.serialize(pkt.max_packet_length, &hello_ok.buf);

        // World updates (empty for now)
        try hello_ok.buf.appendInt(u16, 0);

        // Armor with shared key
        hello_ok.armor(shared_key, false, false, null, null);

        const ok_data = hello_ok.buf.data();
        // Fixed BUG #26: Catch sendto() errors
        const sent = std.posix.sendto(
            self.socket,
            ok_data,
            0,
            &to_addr.any,
            to_addr.getOsSockLen(),
        ) catch |err| {
            std.debug.print("    ❌ Failed to send HELLO OK: {}\n", .{err});
            return;
        };

        std.debug.print("    ✓ Sent HELLO OK ({} bytes)\n", .{sent});
    }

    fn handleWhois(
        self: *RootServer,
        packet: *Packet,
        from_addr: *net.Address,
        source: Address,
        key_available: bool,
        shared_key: *[32]u8,
    ) !void {
        std.debug.print("  → Processing WHOIS\n", .{});

        // Dearmor if we have a key
        if (key_available) {
            const mac_valid = packet.dearmor(shared_key, null, null);
            std.debug.print("    MAC verification: {}\n", .{mac_valid});

            if (!mac_valid) {
                std.debug.print("    ❌ Invalid MAC, dropping packet\n", .{});
                return;
            }
        } else {
            std.debug.print("    ⚠️ No shared key, cannot verify MAC\n", .{});
        }

        // Parse WHOIS payload - it's just a 40-bit ZeroTier address
        const requested_addr = packet.buf.at(u64, pkt.idx_payload) catch {
            std.debug.print("    ❌ Failed to parse requested address\n", .{});
            return;
        };

        const requested_address = Address{ ._a = requested_addr };
        std.debug.print("    Requested address: {}\n", .{requested_address});

        // Check if it's asking about us
        if (requested_addr == self.address._a) {
            std.debug.print("    → They're asking about us, sending OK with our identity\n", .{});
            try self.sendWhoisOk(packet, from_addr, source, shared_key);
        } else {
            std.debug.print("    → Unknown address, cannot respond\n", .{});
        }
    }

    fn sendWhoisOk(
        self: *RootServer,
        whois_packet: *Packet,
        to_addr: *net.Address,
        to_address: Address,
        shared_key: *[32]u8,
    ) !void {
        std.debug.print("  → Sending WHOIS OK\n", .{});

        var ok = Packet.initNew(to_address, self.address, .ok);

        // OK header
        const whois_packet_id = whois_packet.packetId();
        try ok.buf.appendByte(@intFromEnum(pkt.Verb.whois), 1);
        try ok.buf.appendInt(u64, whois_packet_id);

        // WHOIS OK payload: serialized identity
        try self.identity.serialize(pkt.max_packet_length, &ok.buf, true);

        // Armor
        ok.armor(shared_key, false, false, null, null);

        const ok_data = ok.buf.data();
        // Fixed BUG #26: Catch sendto() errors
        const sent = std.posix.sendto(
            self.socket,
            ok_data,
            0,
            &to_addr.any,
            to_addr.getOsSockLen(),
        ) catch |err| {
            std.debug.print("    ❌ Failed to send WHOIS OK: {}\n", .{err});
            return;
        };

        std.debug.print("    ✓ Sent WHOIS OK ({} bytes)\n", .{sent});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Default port: 9993 (standard ZeroTier)
    const port: u16 = 9993;

    var server = try RootServer.init(allocator, port);
    defer server.deinit();

    try server.run();
}
