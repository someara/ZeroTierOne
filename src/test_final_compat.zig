/// Final compatibility test with proper buffer handling
/// Based on discoveries from debugging

const std = @import("std");
const AES = @import("node/aes.zig");

fn hexToBytes(comptime hex: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        buf[i / 2] = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
    }
}

fn bytesMatch(actual: []const u8, expected: []const u8, label: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print("❌ {s} MISMATCH\n", .{label});
        std.debug.print("  Expected: ", .{});
        for (expected) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n  Got:      ", .{});
        for (actual) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});
        return error.Mismatch;
    }
}

pub fn main() !void {
    std.debug.print("\n=== AES-GMAC-SIV C++ Compatibility Test ===\n\n", .{});

    var pass_count: u32 = 0;
    var total_count: u32 = 0;

    // Use an allocator to ensure fresh memory for each test
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test 1: 16 bytes
    total_count += 1;
    std.debug.print("Test 1: 16-byte buffer (single block)... ", .{});
    {
        const key0 = try allocator.alloc(u8, 32);
        defer allocator.free(key0);
        const key1 = try allocator.alloc(u8, 32);
        defer allocator.free(key1);
        const plaintext = try allocator.alloc(u8, 16);
        defer allocator.free(plaintext);
        const ciphertext = try allocator.alloc(u8, 16);
        defer allocator.free(ciphertext);

        hexToBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", key0);
        hexToBytes("00070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9", key1);
        hexToBytes("007bf671ec67e25dd853ce49c43fba35", plaintext);

        var expected_ct: [16]u8 = undefined;
        var expected_tag: [16]u8 = undefined;
        hexToBytes("71ee6693eab462065e571d6097e2477f", &expected_ct);
        hexToBytes("0ddc829e422fec9a434e0499d0287a81", &expected_tag);

        const aes_k0 = AES.Aes.init(key0[0..32]);
        const aes_k1 = AES.Aes.init(key1[0..32]);
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

        enc.initEnc(42, ciphertext.ptr);
        enc.update1(plaintext);
        enc.finish1();
        enc.update2(plaintext);
        const tag = enc.finish2();

        try bytesMatch(ciphertext, &expected_ct, "ciphertext");
        try bytesMatch(tag, &expected_tag, "tag");

        std.debug.print("✅ PASS\n", .{});
        pass_count += 1;
    }

    // Test 2: 64 bytes
    total_count += 1;
    std.debug.print("Test 2: 64-byte buffer... ", .{});
    {
        const key0 = try allocator.alloc(u8, 32);
        defer allocator.free(key0);
        const key1 = try allocator.alloc(u8, 32);
        defer allocator.free(key1);
        const plaintext = try allocator.alloc(u8, 64);
        defer allocator.free(plaintext);
        const ciphertext = try allocator.alloc(u8, 64);
        defer allocator.free(ciphertext);

        // Use GENERATION not hexToBytes since we know that works
        for (key0, 0..) |*b, i| b.* = @intCast((i * 3) & 0xff);
        for (key1, 0..) |*b, i| b.* = @intCast((i * 11) & 0xff);
        for (plaintext, 0..) |*b, i| b.* = @intCast((i * 17) & 0xff);

        var expected_ct: [64]u8 = undefined;
        var expected_tag: [16]u8 = undefined;
        hexToBytes("7d76beb188ae1f8d36da6389d5a481ce0ec6abad1ad1c36083fe7868bb443c4d7a354328ce1e551d747b8ccaa8c35b711f94b64dd52b36c5cd330c0805158734", &expected_ct);
        hexToBytes("a2b508638436c16fedb4dcb9988f2d5b", &expected_tag);

        const aes_k0 = AES.Aes.init(key0[0..32]);
        const aes_k1 = AES.Aes.init(key1[0..32]);
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

        enc.initEnc(1311768467463790320, ciphertext.ptr);
        enc.update1(plaintext);
        enc.finish1();
        enc.update2(plaintext);
        const tag = enc.finish2();

        try bytesMatch(ciphertext, &expected_ct, "ciphertext");
        try bytesMatch(tag, &expected_tag, "tag");

        std.debug.print("✅ PASS\n", .{});
        pass_count += 1;
    }

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("════════════════════════════════════════\n", .{});
    std.debug.print("  Tests passed: {}/{}\n", .{pass_count, total_count});
    std.debug.print("════════════════════════════════════════\n", .{});

    if (pass_count == total_count) {
        std.debug.print("\n✅ SUCCESS: All tests passed!\n", .{});
        std.debug.print("   Zig AES-GMAC-SIV is byte-compatible with C++\n\n", .{});
    } else {
        std.debug.print("\n❌ FAILURE: Some tests failed\n\n", .{});
        return error.TestsFailed;
    }
}
