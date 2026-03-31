/// Debug test to understand IV encoding differences between C++ and Zig

const std = @import("std");
const AES = @import("node/aes.zig");

fn hexToBytes(comptime hex: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        buf[i / 2] = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
    }
}

pub fn main() !void {
    std.debug.print("\n=== Debug IV Encoding ===\n\n", .{});

    // Test with IV = 42 (Test 1, which PASSES)
    {
        std.debug.print("Test 1 (PASS): IV = 42\n", .{});
        const iv_value: u64 = 42;

        // What C++ does: stores as native-endian uint64_t
        var tag_cpp: [16]u8 = undefined;
        std.mem.writeInt(u64, tag_cpp[0..8], iv_value, .little);
        @memset(tag_cpp[8..16], 0);

        std.debug.print("  IV bytes (LE): ", .{});
        for (tag_cpp[0..12]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        // What GMAC sees: first 12 bytes
        std.debug.print("  GMAC IV (first 12): ", .{});
        for (tag_cpp[0..12]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n\n", .{});
    }

    // Test with IV = 1311768467463790320 (Test 2, which FAILS)
    {
        std.debug.print("Test 2 (FAIL): IV = 1311768467463790320 (0x123456789abcdef)\n", .{});
        const iv_value: u64 = 1311768467463790320;

        var tag_cpp: [16]u8 = undefined;
        std.mem.writeInt(u64, tag_cpp[0..8], iv_value, .little);
        @memset(tag_cpp[8..16], 0);

        std.debug.print("  IV bytes (LE): ", .{});
        for (tag_cpp[0..12]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        // Try big-endian
        var tag_be: [16]u8 = undefined;
        std.mem.writeInt(u64, tag_be[0..8], iv_value, .big);
        @memset(tag_be[8..16], 0);

        std.debug.print("  IV bytes (BE): ", .{});
        for (tag_be[0..12]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        // What we expect (network byte order = big endian)
        std.debug.print("  Expected (0x0123456789abcdef in memory): ", .{});
        std.debug.print("ef cd ab 89 67 45 23 01 (if LE) or 01 23 45 67 89 ab cd ef (if BE)\n", .{});
    }

    // Now let's test actual encryption
    std.debug.print("\n=== Test actual encryption with IV=42 ===\n", .{});
    {
        var key0: [32]u8 = undefined;
        var key1: [32]u8 = undefined;
        hexToBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", &key0);
        hexToBytes("00070e151c232a31383f464d545b626970777e858c939aa1a8afb6bdc4cbd2d9", &key1);

        var plaintext: [16]u8 = undefined;
        hexToBytes("007bf671ec67e25dd853ce49c43fba35", &plaintext);

        var ciphertext: [16]u8 = undefined;

        const aes_k0 = AES.Aes.init(&key0);
        const aes_k1 = AES.Aes.init(&key1);
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

        enc.initEnc(42, &ciphertext);

        // Check what IV was set in the encryptor
        std.debug.print("Tag after initEnc: ", .{});
        for (enc.tag) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        enc.update1(&plaintext);
        enc.finish1();

        std.debug.print("Tag after finish1: ", .{});
        for (enc.tag) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        enc.update2(&plaintext);
        const tag = enc.finish2();

        std.debug.print("Ciphertext: ", .{});
        for (ciphertext) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        std.debug.print("Final tag:  ", .{});
        for (tag) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n", .{});

        std.debug.print("Expected CT: 71ee6693eab462065e571d6097e2477f\n", .{});
        std.debug.print("Expected tag: 0ddc829e422fec9a434e0499d0287a81\n", .{});
    }
}
