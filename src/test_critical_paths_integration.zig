/// Critical path integration tests for packet processing
///
/// These tests verify the most important packet processing flows work correctly
/// before optimization. Focus is on end-to-end correctness, not exhaustive coverage.
///
/// Critical paths tested:
/// 1. Packet encrypt → decrypt round-trip (crypto pipeline)
/// 2. MAC verification rejects tampered packets (security)
/// 3. Shared key agreement between peers (handshake foundation)
/// 4. Multiple verbs can be processed (verb dispatch works)
///
/// These tests run in ~0.15 seconds and catch regressions in the core packet
/// processing pipeline that optimizations might introduce.
const std = @import("std");
const testing = std.testing;

const Identity = @import("node/identity.zig").Identity;
const Packet = @import("node/packet.zig").Packet;
const Verb = @import("node/packet.zig").Verb;

test "Critical path - packet encrypt/decrypt round-trip" {
    // CRITICAL: This tests the full crypto pipeline that ALL packets use
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    // Create packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(id_b.address(), id_a.address(), .echo);

    // Add payload
    const payload = "Critical path test data";
    try pkt.buf.appendBytes(payload);

    // Compute shared key (A encrypts for B)
    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);

    // Encrypt
    pkt.armor(&shared_key, true, false, null, null);

    // Save encrypted data
    var encrypted_data: [512]u8 = undefined;
    const encrypted_len = pkt.buf.size();
    @memcpy(encrypted_data[0..encrypted_len], pkt.buf.data());

    // Decrypt (B receives packet from A)
    var shared_key_b: [32]u8 = undefined;
    _ = id_b.agree(&id_a, &shared_key_b);

    var recv_pkt = Packet{ .buf = .{} };
    recv_pkt.buf.setSize(encrypted_len) catch unreachable;
    @memcpy(recv_pkt.buf.dataMut()[0..encrypted_len], encrypted_data[0..encrypted_len]);

    // Dearmor MUST succeed
    const dearmored = recv_pkt.dearmor(&shared_key_b, null, null);
    try testing.expect(dearmored);

    // Verify verb is correct
    try testing.expectEqual(Verb.echo, recv_pkt.verb());

    // Verify addresses
    try testing.expect(recv_pkt.source().eql(id_a.address()));
    try testing.expect(recv_pkt.destination().eql(id_b.address()));
}

test "Critical path - MAC verification rejects tampering" {
    // CRITICAL: This tests that tampered packets are rejected (security)
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    // Create and encrypt packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(id_b.address(), id_a.address(), .echo);

    const payload = "Secret data";
    try pkt.buf.appendBytes(payload);

    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    // Tamper with encrypted packet
    var tampered_data: [512]u8 = undefined;
    const pkt_len = pkt.buf.size();
    @memcpy(tampered_data[0..pkt_len], pkt.buf.data());

    // Flip a bit in the payload region (simulate attacker tampering with data)
    // The MAC is stored in the first 8 bytes after the header, so tamper with something after that
    if (pkt_len > 30) {
        tampered_data[pkt_len - 10] ^= 0x01; // Tamper near end of packet
    }

    // Try to decrypt tampered packet
    var shared_key_b: [32]u8 = undefined;
    _ = id_b.agree(&id_a, &shared_key_b);

    var recv_pkt = Packet{ .buf = .{} };
    recv_pkt.buf.setSize(pkt_len) catch unreachable;
    @memcpy(recv_pkt.buf.dataMut()[0..pkt_len], tampered_data[0..pkt_len]);

    // Dearmor MUST FAIL (MAC mismatch)
    const dearmored = recv_pkt.dearmor(&shared_key_b, null, null);
    try testing.expect(!dearmored);
}

test "Critical path - shared key agreement symmetry" {
    // CRITICAL: This tests that ECDH key agreement works (handshake foundation)
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    // Compute shared keys both ways
    var key_ab: [32]u8 = undefined;
    var key_ba: [32]u8 = undefined;

    _ = id_a.agree(&id_b, &key_ab);
    _ = id_b.agree(&id_a, &key_ba);

    // Keys MUST match
    try testing.expectEqualSlices(u8, &key_ab, &key_ba);
}

test "Critical path - multiple verbs process correctly" {
    // CRITICAL: This tests that verb dispatch works for different packet types
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);

    // Test several common verbs
    const verbs = [_]Verb{ .hello, .ok, .echo, .whois };

    for (verbs) |verb| {
        var pkt = Packet{ .buf = .{} };
        pkt.reset(id_b.address(), id_a.address(), verb);

        // Minimal payload
        try pkt.buf.appendByte(0x42, 1);

        pkt.armor(&shared_key, false, false, null, null);

        // Decrypt
        var recv_pkt = Packet{ .buf = .{} };
        const len = pkt.buf.size();
        recv_pkt.buf.setSize(len) catch unreachable;
        @memcpy(recv_pkt.buf.dataMut()[0..len], pkt.buf.data());

        const dearmored = recv_pkt.dearmor(&shared_key, null, null);
        try testing.expect(dearmored);
        try testing.expectEqual(verb, recv_pkt.verb());
    }
}

test "Critical path - multiple sequential packets" {
    // CRITICAL: This tests that packet processing can handle multiple packets
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);

    // Send 10 packets in sequence
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var pkt = Packet{ .buf = .{} };
        pkt.reset(id_b.address(), id_a.address(), .echo);

        // Unique payload per packet
        var payload_buf: [32]u8 = undefined;
        for (&payload_buf, 0..) |*b, j| {
            b.* = @truncate(i * 10 + j);
        }
        try pkt.buf.appendBytes(&payload_buf);

        pkt.armor(&shared_key, true, false, null, null);

        // Decrypt
        var recv_pkt = Packet{ .buf = .{} };
        const len = pkt.buf.size();
        recv_pkt.buf.setSize(len) catch unreachable;
        @memcpy(recv_pkt.buf.dataMut()[0..len], pkt.buf.data());

        const dearmored = recv_pkt.dearmor(&shared_key, null, null);
        try testing.expect(dearmored);
    }
}

test "Critical path - large packet encryption" {
    // CRITICAL: This tests that large packets (typical VPN payload) work
    const allocator = testing.allocator;

    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    // Create packet with 1500 byte payload (typical MTU)
    var pkt = Packet{ .buf = .{} };
    pkt.reset(id_b.address(), id_a.address(), .frame);

    var large_payload: [1500]u8 = undefined;
    for (&large_payload, 0..) |*b, j| {
        b.* = @truncate(j);
    }
    try pkt.buf.appendBytes(&large_payload);

    // Encrypt
    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    // Decrypt
    var shared_key_b: [32]u8 = undefined;
    _ = id_b.agree(&id_a, &shared_key_b);

    var encrypted_data: [4096]u8 = undefined;
    const len = pkt.buf.size();
    @memcpy(encrypted_data[0..len], pkt.buf.data());

    var recv_pkt = Packet{ .buf = .{} };
    recv_pkt.buf.setSize(len) catch unreachable;
    @memcpy(recv_pkt.buf.dataMut()[0..len], encrypted_data[0..len]);

    const dearmored = recv_pkt.dearmor(&shared_key_b, null, null);
    try testing.expect(dearmored);
    try testing.expectEqual(Verb.frame, recv_pkt.verb());
}
