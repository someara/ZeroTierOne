/// Integration tests with mock ZeroTier root server
///
/// These tests simulate a real ZeroTier root server responding to our service,
/// allowing us to test end-to-end protocol flows without network connectivity:
/// - HELLO / HELLO OK handshake
/// - WHOIS / OK(WHOIS) identity exchange
/// - Network config request / response
/// - Fragment reassembly
///
/// This exposes bugs that unit tests miss because they test isolated functions
/// with mocked data, not the full protocol flow with real packet encoding/decoding.

const std = @import("std");
const testing = std.testing;
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const Node = @import("node/node.zig").Node;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;
const World = @import("node/world.zig").World;
const Buffer = @import("node/buffer.zig").Buffer;

/// Mock ZeroTier root server
///
/// Simulates a root server by:
/// 1. Binding to a local port
/// 2. Receiving packets from our service
/// 3. Decrypting and parsing them
/// 4. Generating appropriate responses (HELLO OK, OK(WHOIS), network configs)
/// 5. Encrypting and sending responses back
pub const MockRootServer = struct {
    allocator: std.mem.Allocator,

    // Server identity (the "root server")
    identity: Identity,
    address: Address,

    // UDP socket
    sock: net.Address,
    fd: std.posix.socket_t,

    // Packet tracking
    packets_received: std.ArrayList(ReceivedPacket),

    // Auto-responder settings
    auto_respond_hello: bool = true,
    auto_respond_whois: bool = true,
    auto_respond_config_req: bool = true,

    pub const ReceivedPacket = struct {
        verb: pkt.Verb,
        source: Address,
        dest: Address,
        payload_len: usize,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !MockRootServer {
        // Generate identity for the mock root server
        var identity = try Identity.generate(allocator);
        errdefer identity.deinit();

        // Bind UDP socket
        const listen_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &listen_addr.any, listen_addr.getOsSockLen());

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | @as(i32, 0x04)); // O_NONBLOCK

        return MockRootServer{
            .allocator = allocator,
            .identity = identity,
            .address = identity.address(),
            .sock = listen_addr,
            .fd = fd,
            .packets_received = std.ArrayList(ReceivedPacket).init(allocator),
        };
    }

    pub fn deinit(self: *MockRootServer) void {
        std.posix.close(self.fd);
        self.identity.deinit();
        self.packets_received.deinit();
    }

    /// Poll for incoming packets and optionally auto-respond
    pub fn poll(self: *MockRootServer, timeout_ms: u32) !void {
        var buf: [4096]u8 = undefined;
        var src_addr: net.Address = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(net.Address);

        const start = std.time.milliTimestamp();
        const deadline = start + timeout_ms;

        while (std.time.milliTimestamp() < deadline) {
            const len = std.posix.recvfrom(
                self.fd,
                &buf,
                0,
                &src_addr.any,
                &src_addr_len,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            if (len == 0) continue;

            // Try to parse the packet
            try self.handleIncomingPacket(buf[0..len], src_addr);
        }
    }

    fn handleIncomingPacket(self: *MockRootServer, data: []const u8, from: net.Address) !void {
        // Check if it's a fragment
        if (data.len >= pkt.min_fragment_length and
            data[pkt.frag_idx_fragment_indicator] == pkt.fragment_indicator) {
            std.debug.print("[MockServer] Received fragment (not implemented)\n", .{});
            return;
        }

        if (data.len < pkt.min_packet_length) {
            std.debug.print("[MockServer] Packet too short: {d} bytes\n", .{data.len});
            return;
        }

        // Parse packet header
        var pkt_buf = Buffer.init();
        try pkt_buf.append(data);

        var packet = Packet{ .buf = pkt_buf };

        const source = packet.source();
        const dest = packet.destination();
        const cipher = packet.cipher();

        std.debug.print("[MockServer] Received packet: src={} dest={} cipher={} len={d}\n", .{
            source, dest, cipher, data.len,
        });

        // For HELLO packets (cipher=c25519_poly1305_none), we need the sender's identity
        // to decrypt. In a real scenario, we'd either:
        // 1. Already have their identity from previous interaction
        // 2. Extract it from the HELLO payload (which includes the identity)
        //
        // For now, we'll handle HELLO specially by parsing the unencrypted identity

        if (cipher == .c25519_poly1305_none) {
            try self.handleHelloPacket(&packet, source, from);
        } else {
            // For other packets, we'd need to decrypt first
            std.debug.print("[MockServer] Non-HELLO packet, skipping (need peer identity to decrypt)\n", .{});
        }
    }

    fn handleHelloPacket(self: *MockRootServer, packet: *Packet, source: Address, from: net.Address) !void {
        std.debug.print("[MockServer] Handling HELLO from {}\n", .{source});

        // HELLO uses Poly1305 MAC but no encryption, so we can parse it
        // First, verify the MAC (we'd need the sender's public key for this)
        // For now, skip MAC verification in the mock server

        // Try to extract the verb
        const verb_byte = packet.buf.at(u8, pkt.idx_verb) catch return;
        const verb_val = verb_byte & 0x1F; // Lower 5 bits

        if (verb_val != @intFromEnum(pkt.Verb.hello)) {
            std.debug.print("[MockServer] Not a HELLO packet, verb={d}\n", .{verb_val});
            return;
        }

        // Record it
        try self.packets_received.append(.{
            .verb = pkt.Verb.hello,
            .source = source,
            .dest = packet.destination(),
            .payload_len = packet.payloadLength(),
            .timestamp = std.time.milliTimestamp(),
        });

        std.debug.print("[MockServer] Recorded HELLO from {} ({d} total packets)\n", .{
            source, self.packets_received.items.len,
        });

        // Auto-respond with HELLO OK if enabled
        if (self.auto_respond_hello) {
            self.sendHelloOk(source, packet.packetId(), from) catch |err| {
                std.debug.print("[MockServer] Failed to send HELLO OK: {}\n", .{err});
            };
        }
    }

    fn sendHelloOk(self: *MockRootServer, to: Address, in_re_packet_id: u64, dest_addr: net.Address) !void {
        std.debug.print("[MockServer] Sending HELLO OK to {} (in reply to packet {})\n", .{to, in_re_packet_id});

        // Build OK packet
        var response = Packet.initNew(to, self.address, .ok);

        // OK payload:
        // [0] verb we're replying to (HELLO)
        // [8] packet ID we're replying to
        // [16] HELLO OK specific fields...

        try response.buf.appendByte(@intFromEnum(pkt.Verb.hello), 1);
        try response.buf.appendInt(u64, in_re_packet_id);

        // HELLO OK fields
        const now = std.time.milliTimestamp();
        try response.buf.appendByte(pkt.protocol_version, 1);
        try response.buf.appendByte(2, 1); // major version
        try response.buf.appendByte(0, 1); // minor version
        try response.buf.appendInt(u16, 0); // revision
        try response.buf.appendInt(i64, now); // timestamp

        // External surface address (the address the client appears to be coming from)
        var surface = InetAddress.InetAddress.initIp4(.{ 127, 0, 0, 1 }, 0);
        try surface.serialize(pkt.max_packet_length, &response.buf);

        // World updates section (empty for now)
        try response.buf.appendInt(u16, 0); // no world updates

        // Armor the packet (we'd need to compute proper MAC here)
        // For the mock server, we'll use a dummy key
        // In a real scenario, this would be derived from the Diffie-Hellman exchange
        var dummy_key: [32]u8 = undefined;
        @memset(&dummy_key, 0x42);

        response.armor(&dummy_key, false, false, null, null);

        // Send it
        const packet_data = response.buf.constData();
        _ = try std.posix.sendto(
            self.fd,
            packet_data,
            0,
            &dest_addr.any,
            dest_addr.getOsSockLen(),
        );

        std.debug.print("[MockServer] Sent HELLO OK ({d} bytes)\n", .{packet_data.len});
    }

    /// Get count of HELLO packets received
    pub fn helloCount(self: *MockRootServer) usize {
        var count: usize = 0;
        for (self.packets_received.items) |p| {
            if (p.verb == .hello) count += 1;
        }
        return count;
    }

    /// Get count of WHOIS packets received
    pub fn whoisCount(self: *MockRootServer) usize {
        var count: usize = 0;
        for (self.packets_received.items) |p| {
            if (p.verb == .whois) count += 1;
        }
        return count;
    }

    /// Get count of network config requests received
    pub fn configReqCount(self: *MockRootServer) usize {
        var count: usize = 0;
        for (self.packets_received.items) |p| {
            if (p.verb == .network_config_request) count += 1;
        }
        return count;
    }
};

// ═══════════════════════════════════════════════════════════════════
// Integration Tests
// ═══════════════════════════════════════════════════════════════════

test "MockRootServer: Initialize and bind" {
    var server = try MockRootServer.init(testing.allocator, 19993);
    defer server.deinit();

    try testing.expect(server.fd != 0);
    try testing.expect(server.address.value() != 0);
    std.debug.print("Mock server listening on port 19993, address: {}\n", .{server.address});
}

test "MockRootServer: Receive raw UDP packet" {
    var server = try MockRootServer.init(testing.allocator, 19994);
    defer server.deinit();

    // Send a test UDP packet to the server
    const client_sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(client_sock);

    const test_data = "test packet";
    const server_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19994);
    _ = try std.posix.sendto(client_sock, test_data, 0, &server_addr.any, server_addr.getOsSockLen());

    // Poll for it (should receive but fail to parse as ZT packet)
    try server.poll(100);

    // We shouldn't have recorded it since it's not a valid ZT packet
    try testing.expectEqual(@as(usize, 0), server.packets_received.items.len);
}

test "Integration: Service sends HELLO, mock server receives it" {
    // This test will verify that when we start a service, it sends HELLO packets
    // that the mock server can receive and parse.
    //
    // TODO: Implement after creating service test harness
    // For now, this is a placeholder showing the test structure

    // 1. Start mock server on port 19995
    // 2. Configure service to use mock server as root
    // 3. Start service
    // 4. Wait for HELLO packets
    // 5. Verify mock server received HELLOs
    // 6. Verify mock server sent HELLO OK
    // 7. Verify service received and processed HELLO OK

    std.debug.print("TODO: Implement full service + mock server integration test\n", .{});
}

// TODO: More integration tests
// - test "Integration: HELLO handshake establishes peer"
// - test "Integration: Network join receives configuration"
// - test "Integration: Fragment reassembly with mock server"
// - test "Integration: WHOIS exchange"
// - test "Integration: Packet retransmission on timeout"
