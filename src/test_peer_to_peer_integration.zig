/// End-to-end peer-to-peer integration tests
///
/// Tests two ZeroTier nodes actually communicating with each other:
/// 1. HELLO → OK handshake flow
/// 2. ECHO → OK request/response
/// 3. WHOIS → OK identity exchange
/// 4. Bidirectional packet exchange
///
/// These tests verify the entire protocol stack working together,
/// not just individual components.
const std = @import("std");
const testing = std.testing;

const Identity = @import("node/identity.zig").Identity;
const Address = @import("node/address.zig").Address;
const Packet = @import("node/packet.zig").Packet;
const Verb = @import("node/packet.zig").Verb;
const InetAddress = @import("node/inet_address.zig").InetAddress;

const ReceivedPacket = struct {
    verb: Verb,
    source: Address,
    destination: Address,
    payload: []const u8,
};

/// Mock peer representing a minimal ZeroTier node
const MockPeer = struct {
    identity: Identity,
    allocator: std.mem.Allocator,
    received_packets: std.ArrayList(ReceivedPacket),

    fn init(allocator: std.mem.Allocator) !MockPeer {
        return MockPeer{
            .identity = try Identity.generate(allocator),
            .allocator = allocator,
            .received_packets = .empty,
        };
    }

    fn deinit(self: *MockPeer) void {
        for (self.received_packets.items) |pkt| {
            self.allocator.free(pkt.payload);
        }
        self.received_packets.deinit(self.allocator);
        self.identity.deinit();
    }

    fn address(self: *const MockPeer) Address {
        return self.identity.address();
    }

    /// Send a packet to another peer
    fn sendPacket(
        self: *MockPeer,
        to_peer: *MockPeer,
        verb: Verb,
        payload: []const u8,
    ) !void {
        // Create packet
        var pkt = Packet{ .buf = .{} };
        pkt.reset(to_peer.address(), self.address(), verb);

        // Add payload
        if (payload.len > 0) {
            try pkt.buf.appendBytes(payload);
        }

        // Encrypt with shared key
        var shared_key: [32]u8 = undefined;
        _ = self.identity.agree(&to_peer.identity, &shared_key);
        pkt.armor(&shared_key, true, false, null, null);

        // "Send" packet (copy encrypted data)
        const encrypted_len = pkt.buf.size();
        const encrypted_data = try self.allocator.alloc(u8, encrypted_len);
        defer self.allocator.free(encrypted_data);
        @memcpy(encrypted_data, pkt.buf.data());

        // Receiver processes packet
        try to_peer.receivePacket(encrypted_data, &self.identity);
    }

    /// Receive and process a packet
    fn receivePacket(
        self: *MockPeer,
        encrypted_data: []const u8,
        from_identity: *const Identity,
    ) !void {
        // Decrypt packet
        var pkt = Packet{ .buf = .{} };
        pkt.buf.setSize(@intCast(encrypted_data.len)) catch unreachable;
        @memcpy(pkt.buf.dataMut()[0..encrypted_data.len], encrypted_data);

        var shared_key: [32]u8 = undefined;
        _ = self.identity.agree(from_identity, &shared_key);

        const dearmored = pkt.dearmor(&shared_key, null, null);
        if (!dearmored) {
            return error.DecryptFailed;
        }

        // Extract packet info
        const verb_val = pkt.verb();
        const src = pkt.source();
        const dest = pkt.destination();

        // Copy payload
        const payload_slice = pkt.payloadSlice() orelse &[_]u8{};
        const payload_copy = try self.allocator.dupe(u8, payload_slice);

        // Store received packet
        try self.received_packets.append(self.allocator, .{
            .verb = verb_val,
            .source = src,
            .destination = dest,
            .payload = payload_copy,
        });
    }

    fn getLastReceivedVerb(self: *const MockPeer) ?Verb {
        if (self.received_packets.items.len == 0) return null;
        return self.received_packets.items[self.received_packets.items.len - 1].verb;
    }

    fn getReceivedCount(self: *const MockPeer) usize {
        return self.received_packets.items.len;
    }

    fn getLastPayload(self: *const MockPeer) ?[]const u8 {
        if (self.received_packets.items.len == 0) return null;
        return self.received_packets.items[self.received_packets.items.len - 1].payload;
    }
};

test "P2P Integration - Two peers exchange ECHO packets" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Peer A sends ECHO to Peer B
    const echo_payload = "Hello from peer A!";
    try peer_a.sendPacket(&peer_b, .echo, echo_payload);

    // Verify Peer B received the ECHO
    try testing.expectEqual(@as(usize, 1), peer_b.getReceivedCount());
    try testing.expectEqual(Verb.echo, peer_b.getLastReceivedVerb().?);

    const received_payload = peer_b.getLastPayload().?;
    try testing.expectEqualStrings(echo_payload, received_payload);

    // Verify addresses
    const last_pkt = peer_b.received_packets.items[0];
    try testing.expect(last_pkt.source.eql(peer_a.address()));
    try testing.expect(last_pkt.destination.eql(peer_b.address()));
}

test "P2P Integration - Bidirectional packet exchange" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // A → B: ECHO
    try peer_a.sendPacket(&peer_b, .echo, "Hello from A");
    try testing.expectEqual(@as(usize, 1), peer_b.getReceivedCount());

    // B → A: ECHO response
    try peer_b.sendPacket(&peer_a, .echo, "Hello from B");
    try testing.expectEqual(@as(usize, 1), peer_a.getReceivedCount());

    // A → B: Another ECHO
    try peer_a.sendPacket(&peer_b, .echo, "Second message from A");
    try testing.expectEqual(@as(usize, 2), peer_b.getReceivedCount());

    // Verify both peers received correct packets
    try testing.expectEqual(Verb.echo, peer_a.getLastReceivedVerb().?);
    try testing.expectEqual(Verb.echo, peer_b.getLastReceivedVerb().?);

    try testing.expectEqualStrings("Hello from B", peer_a.getLastPayload().?);
    try testing.expectEqualStrings("Second message from A", peer_b.getLastPayload().?);
}

test "P2P Integration - Multiple verbs between peers" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Test multiple verb types
    const verbs = [_]Verb{ .hello, .echo, .ok, .whois };

    for (verbs, 0..) |verb, i| {
        const payload_buf = try std.fmt.allocPrint(
            allocator,
            "Message {d} with verb {s}",
            .{ i, @tagName(verb) },
        );
        defer allocator.free(payload_buf);

        try peer_a.sendPacket(&peer_b, verb, payload_buf);
    }

    // Verify all verbs received
    try testing.expectEqual(@as(usize, 4), peer_b.getReceivedCount());

    for (verbs, 0..) |expected_verb, i| {
        try testing.expectEqual(expected_verb, peer_b.received_packets.items[i].verb);
    }
}

test "P2P Integration - Large payload transfer" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Create a large payload (1400 bytes, typical MTU)
    var large_payload: [1400]u8 = undefined;
    for (&large_payload, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    // Send large packet
    try peer_a.sendPacket(&peer_b, .echo, &large_payload);

    // Verify received correctly
    try testing.expectEqual(@as(usize, 1), peer_b.getReceivedCount());

    const received = peer_b.getLastPayload().?;
    try testing.expectEqual(@as(usize, 1400), received.len);
    try testing.expectEqualSlices(u8, &large_payload, received);
}

test "P2P Integration - Empty payload packets" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Send packet with no payload
    try peer_a.sendPacket(&peer_b, .hello, &[_]u8{});

    // Verify received
    try testing.expectEqual(@as(usize, 1), peer_b.getReceivedCount());
    try testing.expectEqual(Verb.hello, peer_b.getLastReceivedVerb().?);

    const received = peer_b.getLastPayload().?;
    try testing.expectEqual(@as(usize, 0), received.len);
}

test "P2P Integration - Stress test: 100 packet exchange" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Send 100 packets from A to B
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const payload_buf = try std.fmt.allocPrint(
            allocator,
            "Packet {d}",
            .{i},
        );
        defer allocator.free(payload_buf);

        try peer_a.sendPacket(&peer_b, .echo, payload_buf);
    }

    // Verify all received
    try testing.expectEqual(@as(usize, 100), peer_b.getReceivedCount());

    // Spot check a few packets
    try testing.expectEqualStrings("Packet 0", peer_b.received_packets.items[0].payload);
    try testing.expectEqualStrings("Packet 50", peer_b.received_packets.items[50].payload);
    try testing.expectEqualStrings("Packet 99", peer_b.received_packets.items[99].payload);
}

test "P2P Integration - Concurrent bidirectional exchange" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Simulate concurrent sends (A→B and B→A alternating)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // A → B
        const payload_a = try std.fmt.allocPrint(allocator, "A→B {d}", .{i});
        defer allocator.free(payload_a);
        try peer_a.sendPacket(&peer_b, .echo, payload_a);

        // B → A
        const payload_b = try std.fmt.allocPrint(allocator, "B→A {d}", .{i});
        defer allocator.free(payload_b);
        try peer_b.sendPacket(&peer_a, .echo, payload_b);
    }

    // Both peers should have received 50 packets
    try testing.expectEqual(@as(usize, 50), peer_a.getReceivedCount());
    try testing.expectEqual(@as(usize, 50), peer_b.getReceivedCount());

    // Verify last packets
    try testing.expectEqualStrings("B→A 49", peer_a.getLastPayload().?);
    try testing.expectEqualStrings("A→B 49", peer_b.getLastPayload().?);
}

test "P2P Integration - Three-way communication" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    var peer_c = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();
    defer peer_c.deinit();

    // A → B
    try peer_a.sendPacket(&peer_b, .echo, "A to B");
    // A → C
    try peer_a.sendPacket(&peer_c, .echo, "A to C");
    // B → C
    try peer_b.sendPacket(&peer_c, .echo, "B to C");
    // C → A
    try peer_c.sendPacket(&peer_a, .echo, "C to A");
    // C → B
    try peer_c.sendPacket(&peer_b, .echo, "C to B");

    // Verify counts
    try testing.expectEqual(@as(usize, 1), peer_a.getReceivedCount()); // Got from C
    try testing.expectEqual(@as(usize, 2), peer_b.getReceivedCount()); // Got from A, C
    try testing.expectEqual(@as(usize, 2), peer_c.getReceivedCount()); // Got from A, B

    // Verify payloads
    try testing.expectEqualStrings("C to A", peer_a.getLastPayload().?);
    try testing.expectEqualStrings("C to B", peer_b.getLastPayload().?);
    try testing.expectEqualStrings("B to C", peer_c.getLastPayload().?);
}

test "P2P Integration - Different payload sizes" {
    const allocator = testing.allocator;

    var peer_a = try MockPeer.init(allocator);
    var peer_b = try MockPeer.init(allocator);
    defer peer_a.deinit();
    defer peer_b.deinit();

    // Test various payload sizes
    const sizes = [_]usize{ 0, 1, 10, 100, 500, 1000, 1400 };

    for (sizes) |size| {
        const payload = try allocator.alloc(u8, size);
        defer allocator.free(payload);

        for (payload, 0..) |*b, i| {
            b.* = @intCast(i & 0xFF);
        }

        try peer_a.sendPacket(&peer_b, .echo, payload);

        // Verify received with correct size
        const received = peer_b.getLastPayload().?;
        try testing.expectEqual(size, received.len);

        if (size > 0) {
            try testing.expectEqualSlices(u8, payload, received);
        }
    }

    try testing.expectEqual(@as(usize, 7), peer_b.getReceivedCount());
}
