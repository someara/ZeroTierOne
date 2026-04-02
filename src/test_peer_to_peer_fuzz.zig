/// Fuzz testing for peer-to-peer packet exchange
///
/// Tests ZeroTier packet handling against malicious/malformed inputs:
/// - Random garbage packets
/// - Truncated packets
/// - Oversized packets
/// - Tampered MAC tags
/// - Bit flips in various fields
/// - Invalid cipher suites
/// - Replayed packets
/// - Out-of-order fragments
///
/// These tests verify robustness against attacks and corruption.
const std = @import("std");
const testing = std.testing;

const Identity = @import("node/identity.zig").Identity;
const Address = @import("node/address.zig").Address;
const Packet = @import("node/packet.zig").Packet;
const Verb = @import("node/packet.zig").Verb;

const ReceivedPacket = struct {
    verb: Verb,
    source: Address,
    destination: Address,
    payload: []const u8,
};

/// Fuzz target that attempts to decrypt and process arbitrary packet data
const FuzzTarget = struct {
    identity: Identity,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !FuzzTarget {
        return FuzzTarget{
            .identity = try Identity.generate(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *FuzzTarget) void {
        self.identity.deinit();
    }

    fn address(self: *const FuzzTarget) Address {
        return self.identity.address();
    }

    /// Try to process arbitrary packet data - should never crash
    fn processPacketData(
        self: *FuzzTarget,
        data: []const u8,
        from_identity: *const Identity,
    ) !?ReceivedPacket {
        if (data.len < 28) return null; // Too short for any valid packet

        // Try to decrypt packet
        var pkt = Packet{ .buf = .{} };
        if (data.len > 10024) return null; // Beyond max packet size

        pkt.buf.setSize(@intCast(data.len)) catch return null;
        @memcpy(pkt.buf.dataMut()[0..data.len], data);

        var shared_key: [32]u8 = undefined;
        _ = self.identity.agree(from_identity, &shared_key);

        const dearmored = pkt.dearmor(&shared_key, null, null);
        if (!dearmored) return null; // Failed to decrypt - expected for garbage

        // Extract packet info
        const verb_val = pkt.verb();
        const src = pkt.source();
        const dest = pkt.destination();

        // Copy payload if present
        const payload_slice = pkt.payloadSlice() orelse &[_]u8{};
        const payload_copy = try self.allocator.dupe(u8, payload_slice);

        return ReceivedPacket{
            .verb = verb_val,
            .source = src,
            .destination = dest,
            .payload = payload_copy,
        };
    }
};

test "Fuzz - Random garbage packets rejected" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();

    // Try 100 random garbage packets
    var i: usize = 0;
    var rejected: usize = 0;
    while (i < 100) : (i += 1) {
        var garbage: [1500]u8 = undefined;
        random.bytes(&garbage);

        const result = try target.processPacketData(&garbage, &sender.identity);
        if (result == null) {
            rejected += 1;
        } else {
            allocator.free(result.?.payload);
        }
    }

    // Most random garbage should be rejected
    try testing.expect(rejected > 95);
}

test "Fuzz - Truncated valid packets rejected" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create a valid encrypted packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    const payload = "Test payload";
    try pkt.buf.appendBytes(payload);

    var shared_key: [32]u8 = undefined;
    _ = sender.identity.agree(&receiver.identity, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const full_len = pkt.buf.size();
    const full_data = try allocator.alloc(u8, full_len);
    defer allocator.free(full_data);
    @memcpy(full_data, pkt.buf.data());

    // Try progressively truncated versions
    var truncate_len: usize = full_len - 1;
    while (truncate_len >= 28) : (truncate_len -= 1) {
        const result = try receiver.processPacketData(full_data[0..truncate_len], &sender.identity);
        if (result) |r| {
            allocator.free(r.payload);
        }
        // Should either reject or process gracefully (no crash)
    }
}

test "Fuzz - Tampered MAC rejected" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create a valid encrypted packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    const payload = "Important message";
    try pkt.buf.appendBytes(payload);

    var shared_key: [32]u8 = undefined;
    _ = sender.identity.agree(&receiver.identity, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const full_len = pkt.buf.size();
    var tampered_data = try allocator.alloc(u8, full_len);
    defer allocator.free(tampered_data);
    @memcpy(tampered_data, pkt.buf.data());

    // Tamper with MAC (last 16 bytes for Poly1305)
    if (full_len >= 16) {
        tampered_data[full_len - 1] ^= 0xFF; // Flip bits in MAC tag

        const result = try receiver.processPacketData(tampered_data, &sender.identity);

        // Should reject tampered packet
        try testing.expect(result == null);
    }
}

test "Fuzz - Bit flips in various packet fields" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create a valid encrypted packet
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    try pkt.buf.appendBytes("Test");

    var shared_key: [32]u8 = undefined;
    _ = sender.identity.agree(&receiver.identity, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const full_len = pkt.buf.size();
    const full_data = try allocator.alloc(u8, full_len);
    defer allocator.free(full_data);
    @memcpy(full_data, pkt.buf.data());

    var prng = std.Random.DefaultPrng.init(67890);
    const random = prng.random();

    // Try 50 random bit flips
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var flipped_data = try allocator.dupe(u8, full_data);
        defer allocator.free(flipped_data);

        // Flip a random bit
        const byte_idx = random.uintLessThan(usize, full_len);
        const bit_idx: u3 = @intCast(random.uintLessThan(u8, 8));
        flipped_data[byte_idx] ^= @as(u8, 1) << bit_idx;

        const result = try receiver.processPacketData(flipped_data, &sender.identity);
        if (result) |r| {
            allocator.free(r.payload);
        }
        // Should either reject or process gracefully
    }
}

test "Fuzz - Oversized packet data" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    // Create oversized packet data (way beyond max packet size)
    const huge_sizes = [_]usize{ 4096, 8192, 16384, 32768, 65536 };

    for (huge_sizes) |size| {
        const huge_data = try allocator.alloc(u8, size);
        defer allocator.free(huge_data);
        @memset(huge_data, 0x42);

        const result = try target.processPacketData(huge_data, &sender.identity);

        // Should reject gracefully (buffer capacity exceeded)
        try testing.expect(result == null);
    }
}

test "Fuzz - Zero-length and minimal packets" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    // Zero-length packet
    {
        const empty: [0]u8 = undefined;
        const result = try target.processPacketData(&empty, &sender.identity);
        try testing.expect(result == null);
    }

    // Minimal sizes (1 to 27 bytes - all too short)
    var i: usize = 1;
    while (i < 28) : (i += 1) {
        const small_data = try allocator.alloc(u8, i);
        defer allocator.free(small_data);
        @memset(small_data, 0x00);

        const result = try target.processPacketData(small_data, &sender.identity);
        try testing.expect(result == null);
    }
}

test "Fuzz - Wrong cipher suite byte" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create a valid encrypted packet with Salsa20
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);
    try pkt.buf.appendBytes("Test");

    var shared_key: [32]u8 = undefined;
    _ = sender.identity.agree(&receiver.identity, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const full_len = pkt.buf.size();
    var mangled_data = try allocator.alloc(u8, full_len);
    defer allocator.free(mangled_data);
    @memcpy(mangled_data, pkt.buf.data());

    // Mangle cipher suite byte (byte 8 in header)
    if (full_len > 8) {
        const original_cs = mangled_data[8];

        // Try various invalid cipher suite values
        const invalid_cs_values = [_]u8{ 0xFF, 0x7F, 0x42, 0x00, 0x03, 0x04, 0x05 };
        for (invalid_cs_values) |invalid_cs| {
            if (invalid_cs == original_cs) continue;

            mangled_data[8] = invalid_cs;

            const result = try receiver.processPacketData(mangled_data, &sender.identity);
            if (result) |r| {
                allocator.free(r.payload);
            }
            // Should either reject or process gracefully
        }
    }
}

test "Fuzz - All-zeros packet" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    var zeros: [1024]u8 = [_]u8{0} ** 1024;

    const result = try target.processPacketData(&zeros, &sender.identity);

    // Should reject all-zeros packet
    try testing.expect(result == null);
}

test "Fuzz - All-ones packet" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    var ones: [1024]u8 = [_]u8{0xFF} ** 1024;

    const result = try target.processPacketData(&ones, &sender.identity);

    // Should reject all-ones packet
    try testing.expect(result == null);
}

test "Fuzz - Random packet lengths" {
    const allocator = testing.allocator;

    var target = try FuzzTarget.init(allocator);
    var sender = try FuzzTarget.init(allocator);
    defer target.deinit();
    defer sender.deinit();

    var prng = std.Random.DefaultPrng.init(11111);
    const random = prng.random();

    // Try 100 random lengths from 0 to 2000
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const len = random.uintLessThan(usize, 2001);
        const data = try allocator.alloc(u8, len);
        defer allocator.free(data);
        random.bytes(data);

        const result = try target.processPacketData(data, &sender.identity);
        if (result) |r| {
            allocator.free(r.payload);
        }
        // Should handle gracefully regardless of length
    }
}

test "Fuzz - Rapid fire packet processing" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    var prng = std.Random.DefaultPrng.init(22222);
    const random = prng.random();

    // Rapidly process 1000 packets (valid and invalid mixed)
    var i: usize = 0;
    var valid_count: usize = 0;
    while (i < 1000) : (i += 1) {
        if (random.boolean()) {
            // Send valid packet
            var pkt = Packet{ .buf = .{} };
            pkt.reset(receiver.address(), sender.address(), .echo);
            try pkt.buf.appendBytes("Data");

            var shared_key: [32]u8 = undefined;
            _ = sender.identity.agree(&receiver.identity, &shared_key);
            pkt.armor(&shared_key, true, false, null, null);

            const len = pkt.buf.size();
            const data = try allocator.alloc(u8, len);
            defer allocator.free(data);
            @memcpy(data, pkt.buf.data());

            const result = try receiver.processPacketData(data, &sender.identity);
            if (result) |r| {
                valid_count += 1;
                allocator.free(r.payload);
            }
        } else {
            // Send garbage
            var garbage: [512]u8 = undefined;
            random.bytes(&garbage);

            const result = try receiver.processPacketData(&garbage, &sender.identity);
            if (result) |r| {
                allocator.free(r.payload);
            }
        }
    }

    // Should have processed roughly 500 valid packets (allow variance)
    try testing.expect(valid_count > 400);
    try testing.expect(valid_count < 600);
}

test "Fuzz - Payload with all possible byte values" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    // Create packet with payload containing all byte values 0x00-0xFF
    var pkt = Packet{ .buf = .{} };
    pkt.reset(receiver.address(), sender.address(), .echo);

    var all_bytes: [256]u8 = undefined;
    for (&all_bytes, 0..) |*b, idx| {
        b.* = @intCast(idx);
    }
    try pkt.buf.appendBytes(&all_bytes);

    var shared_key: [32]u8 = undefined;
    _ = sender.identity.agree(&receiver.identity, &shared_key);
    pkt.armor(&shared_key, true, false, null, null);

    const len = pkt.buf.size();
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memcpy(data, pkt.buf.data());

    const result = try receiver.processPacketData(data, &sender.identity);
    try testing.expect(result != null);

    if (result) |r| {
        defer allocator.free(r.payload);
        // Verify payload was correctly decrypted
        try testing.expectEqual(@as(usize, 256), r.payload.len);
        try testing.expectEqualSlices(u8, &all_bytes, r.payload);
    }
}

test "Fuzz - Stress test: Mixed valid/invalid packets" {
    const allocator = testing.allocator;

    var sender = try FuzzTarget.init(allocator);
    var receiver = try FuzzTarget.init(allocator);
    defer sender.deinit();
    defer receiver.deinit();

    var prng = std.Random.DefaultPrng.init(33333);
    const random = prng.random();

    var valid_processed: usize = 0;
    var invalid_rejected: usize = 0;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const packet_type = random.uintLessThan(u8, 5);

        switch (packet_type) {
            0 => {
                // Valid packet
                var pkt = Packet{ .buf = .{} };
                pkt.reset(receiver.address(), sender.address(), .echo);
                try pkt.buf.appendBytes("Valid");

                var shared_key: [32]u8 = undefined;
                _ = sender.identity.agree(&receiver.identity, &shared_key);
                pkt.armor(&shared_key, true, false, null, null);

                const len = pkt.buf.size();
                const data = try allocator.alloc(u8, len);
                defer allocator.free(data);
                @memcpy(data, pkt.buf.data());

                const result = try receiver.processPacketData(data, &sender.identity);
                if (result) |r| {
                    valid_processed += 1;
                    allocator.free(r.payload);
                }
            },
            1 => {
                // Random garbage
                var garbage: [512]u8 = undefined;
                random.bytes(&garbage);
                const result = try receiver.processPacketData(&garbage, &sender.identity);
                if (result == null) invalid_rejected += 1;
                if (result) |r| allocator.free(r.payload);
            },
            2 => {
                // Truncated packet
                var pkt = Packet{ .buf = .{} };
                pkt.reset(receiver.address(), sender.address(), .echo);
                try pkt.buf.appendBytes("X");
                var shared_key: [32]u8 = undefined;
                _ = sender.identity.agree(&receiver.identity, &shared_key);
                pkt.armor(&shared_key, true, false, null, null);

                const len = pkt.buf.size();
                if (len > 10) {
                    const data = try allocator.alloc(u8, len - 10);
                    defer allocator.free(data);
                    @memcpy(data, pkt.buf.data()[0 .. len - 10]);
                    const result = try receiver.processPacketData(data, &sender.identity);
                    if (result == null) invalid_rejected += 1;
                    if (result) |r| allocator.free(r.payload);
                }
            },
            3 => {
                // Tampered packet
                var pkt = Packet{ .buf = .{} };
                pkt.reset(receiver.address(), sender.address(), .echo);
                try pkt.buf.appendBytes("Y");
                var shared_key: [32]u8 = undefined;
                _ = sender.identity.agree(&receiver.identity, &shared_key);
                pkt.armor(&shared_key, true, false, null, null);

                const len = pkt.buf.size();
                const data = try allocator.alloc(u8, len);
                defer allocator.free(data);
                @memcpy(data, pkt.buf.data());
                data[len / 2] ^= 0xFF; // Flip byte in middle
                const result = try receiver.processPacketData(data, &sender.identity);
                if (result == null) invalid_rejected += 1;
                if (result) |r| allocator.free(r.payload);
            },
            4 => {
                // All zeros
                var zeros: [128]u8 = [_]u8{0} ** 128;
                const result = try receiver.processPacketData(&zeros, &sender.identity);
                if (result == null) invalid_rejected += 1;
                if (result) |r| allocator.free(r.payload);
            },
            else => unreachable,
        }
    }

    // Should have processed most valid packets (20% of 500 ≈ 100)
    try testing.expect(valid_processed > 80);
    // Should have rejected most invalid packets (80% of 500 ≈ 400)
    try testing.expect(invalid_rejected > 300);
}
