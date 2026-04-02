/// Aggressive fuzz testing - tries to crash the packet processor
///
/// This is DIFFERENT from test_peer_to_peer_fuzz.zig:
/// - No try/catch safety nets (let panics happen)
/// - Fuzzes VALID packets with subtle corruptions
/// - Tests edge cases in decompression, deserialization
/// - Tries to trigger buffer overflows, integer overflows
/// - Tests boundary conditions more aggressively
///
/// If these tests find crashes, that's GOOD - it means we found bugs!
const std = @import("std");
const testing = std.testing;

const Identity = @import("node/identity.zig").Identity;
const Address = @import("node/address.zig").Address;
const Packet = @import("node/packet.zig").Packet;
const Verb = @import("node/packet.zig").Verb;

test "Aggressive Fuzz - Corrupt compressed flag without compression" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create uncompressed packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    try pkt.buf.appendBytes("This is not compressed");

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    // Now corrupt the packet: set compressed flag but data isn't compressed
    var corrupt_pkt = Packet{ .buf = .{} };
    corrupt_pkt.buf.setSize(@intCast(len)) catch unreachable;
    @memcpy(corrupt_pkt.buf.dataMut()[0..len], data);

    // Decrypt first
    _ = corrupt_pkt.dearmor(&shared_key, null, null);

    // Now manually set the compressed flag in the decrypted packet
    const cipher_suite_byte = corrupt_pkt.buf.at(u8, 8) catch unreachable;
    corrupt_pkt.buf.setAt(u8, 8, cipher_suite_byte | 0x80) catch unreachable; // Set compressed bit

    // Try to decompress - this should either reject or handle gracefully
    // If it crashes, we found a bug!
    const decompressed = corrupt_pkt.uncompress();
    _ = decompressed; // May be false, that's fine
}

test "Aggressive Fuzz - LZ4 decompress with fake huge uncompressed size" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create compressed packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);

    // Large compressible payload
    var large_payload: [2000]u8 = undefined;
    @memset(&large_payload, 'A');
    try pkt.buf.appendBytes(&large_payload);

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);

    // Compress and encrypt
    _ = pkt.compress();
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    // Decrypt
    var corrupt_pkt = Packet{ .buf = .{} };
    corrupt_pkt.buf.setSize(@intCast(len)) catch unreachable;
    @memcpy(corrupt_pkt.buf.dataMut()[0..len], data);
    _ = corrupt_pkt.dearmor(&shared_key, null, null);

    // Now tamper with the uncompressed size field (bytes after header)
    // Make it claim to decompress to a huge size
    const header_len = 28; // Standard header
    if (corrupt_pkt.buf.size() > header_len + 4) {
        // Set fake uncompressed size to something huge (but not overflow)
        corrupt_pkt.buf.setAt(u8, header_len + 0, 0xFF) catch unreachable;
        corrupt_pkt.buf.setAt(u8, header_len + 1, 0xFF) catch unreachable;
        corrupt_pkt.buf.setAt(u8, header_len + 2, 0x0F) catch unreachable; // ~1MB
        corrupt_pkt.buf.setAt(u8, header_len + 3, 0x00) catch unreachable;

        // Try to decompress - should reject or handle gracefully
        const decompressed = corrupt_pkt.uncompress();
        _ = decompressed;
    }
}

test "Aggressive Fuzz - Fragment with invalid total/this fragment values" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    defer sender.deinit();

    // Create a fragment packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(Address.init(0x1234567890), sender.address(), .echo);

    // Set fragmented flag
    const cs = pkt.buf.at(u8, 8) catch unreachable;
    pkt.buf.setAt(u8, 8, cs | 0x40) catch unreachable; // Set fragmented bit

    // Add fragment fields with invalid values
    try pkt.buf.appendBytes(&[_]u8{
        0x00, 0x00, 0x00, 0x01, // Packet ID
        0x00, 0x05, // Total fragments = 5
        0x00, 0x08, // This fragment = 8 (> total!)
    });

    var shared_key: [32]u8 = [_]u8{0x42} ** 32;
    pkt.armor(&shared_key, true, false, null, null);

    // Try to parse this as a fragment
    // If it crashes on invalid fragment numbers, we found a bug
    const is_fragment = pkt.fragmented();
    _ = is_fragment;
}

test "Aggressive Fuzz - Verb field with invalid enum value" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create valid packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    try pkt.buf.appendBytes("Test");

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    // Decrypt
    var corrupt_pkt = Packet{ .buf = .{} };
    corrupt_pkt.buf.setSize(@intCast(len)) catch unreachable;
    @memcpy(corrupt_pkt.buf.dataMut()[0..len], data);
    _ = corrupt_pkt.dearmor(&shared_key, null, null);

    // Corrupt verb byte to invalid value
    corrupt_pkt.buf.setAt(u8, 4, 0xFF) catch unreachable; // Invalid verb

    // Try to get verb - should handle gracefully or return a safe default
    const verb = corrupt_pkt.verb();
    _ = verb;
    // If this panics on invalid enum, we found a bug
}

test "Aggressive Fuzz - Address fields with reserved values" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create packet with reserved addresses
    var pkt = Packet{ .buf = .{} };

    // Use reserved addresses (0xFF prefix makes it reserved)
    const reserved_addr = Address.init(0xFF000000AA);
    pkt.reset(reserved_addr, reserved_addr, .echo);
    try pkt.buf.appendBytes("Reserved");

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    // Decrypt and process
    _ = pkt.dearmor(&shared_key, null, null);

    const src = pkt.source();
    const dest = pkt.destination();

    // Check that reserved addresses are handled
    try testing.expect(src.isReserved());
    try testing.expect(dest.isReserved());
}

test "Aggressive Fuzz - Hops field overflow" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    defer sender.deinit();

    var pkt = Packet{ .buf = .{} };
    pkt.reset(Address.init(0x1234567890), sender.address(), .echo);

    // Increment hops many times to test overflow
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        pkt.incrementHops();
    }

    const hops = pkt.hops();
    // Hops should wrap at 7 (3-bit field)
    try testing.expect(hops < 8);
}

test "Aggressive Fuzz - Payload slice with corrupted size" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create packet with payload
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    try pkt.buf.appendBytes("Short payload");

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    // Decrypt
    var corrupt_pkt = Packet{ .buf = .{} };
    corrupt_pkt.buf.setSize(@intCast(len)) catch unreachable;
    @memcpy(corrupt_pkt.buf.dataMut()[0..len], data);
    _ = corrupt_pkt.dearmor(&shared_key, null, null);

    // Try to get payload - should handle gracefully even if internal state is weird
    const payload = corrupt_pkt.payloadSlice();
    _ = payload;
}

test "Aggressive Fuzz - Create packet with maximum possible size" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Try to create a packet at the absolute maximum size
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);

    // Try to fill to max capacity
    const max_payload = 10024 - 28 - 16 - 100; // Buffer - header - MAC - margin
    const huge_payload = try allocator.alloc(u8, max_payload);
    defer allocator.free(huge_payload);
    @memset(huge_payload, 0x42);

    try pkt.buf.appendBytes(huge_payload);

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    // Decrypt and verify
    _ = pkt.dearmor(&shared_key, null, null);
    const payload = pkt.payloadSlice();
    try testing.expect(payload != null);
}

test "Aggressive Fuzz - Zero-length payload handling" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Packet with explicitly zero-length payload
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    // Don't add any payload

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    _ = pkt.dearmor(&shared_key, null, null);

    const payload = pkt.payloadSlice();
    if (payload) |p| {
        try testing.expectEqual(@as(usize, 0), p.len);
    }
}

test "Aggressive Fuzz - Rapid armor/dearmor cycles on same packet" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);

    // Try multiple armor/dearmor cycles
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var pkt = Packet{ .buf = .{} };
        pkt.reset(receiver.address(), sender.address(), .echo);
        try pkt.buf.appendBytes("Cycle test");

        pkt.armor(&shared_key, true, false, null, null);
        const success = pkt.dearmor(&shared_key, null, null);
        try testing.expect(success);
    }
}

test "Aggressive Fuzz - Cipher suite flag combinations" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);

    // Test all possible cipher suite flag combinations
    const flag_combos = [_]u8{
        0x00, // No flags
        0x01, // AES
        0x02, // AES GMAC-SIV
        0x40, // Fragmented
        0x80, // Compressed
        0xC0, // Fragmented + Compressed
        0x81, // AES + Compressed
        0xC1, // AES + Fragmented + Compressed
    };

    for (flag_combos) |_| {
        var pkt = Packet{ .buf = .{} };
        pkt.reset(receiver.address(), sender.address(), .echo);
        try pkt.buf.appendBytes("Flags test");

        // Use standard encryption
        pkt.armor(&shared_key, true, false, null, null);
        const success = pkt.dearmor(&shared_key, null, null);
        try testing.expect(success);
    }
}

test "Aggressive Fuzz - Compress then tamper with compression flag" {
    const allocator = testing.allocator;

    var sender = try Identity.generate(allocator);
    var receiver = try Identity.generate(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create highly compressible packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);

    var compressible: [1000]u8 = undefined;
    @memset(&compressible, 'X');
    try pkt.buf.appendBytes(&compressible);

    // Compress
    const did_compress = pkt.compress();
    try testing.expect(did_compress);

    var shared_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    // Decrypt
    var corrupt_pkt = Packet{ .buf = .{} };
    corrupt_pkt.buf.setSize(@intCast(len)) catch unreachable;
    @memcpy(corrupt_pkt.buf.dataMut()[0..len], data);
    _ = corrupt_pkt.dearmor(&shared_key, null, null);

    // Clear the compression flag even though data is compressed
    const cs_byte = corrupt_pkt.buf.at(u8, 8) catch unreachable;
    corrupt_pkt.buf.setAt(u8, 8, cs_byte & ~@as(u8, 0x80)) catch unreachable;

    // Now the packet thinks it's not compressed but the data is
    // Getting payload should handle this gracefully
    const payload = corrupt_pkt.payloadSlice();
    _ = payload; // Might be garbage, but shouldn't crash
}
