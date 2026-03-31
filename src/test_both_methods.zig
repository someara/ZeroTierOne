/// Test both hex parsing and generation in the same program

const std = @import("std");
const AES = @import("node/aes.zig");

fn hexToBytes(comptime hex: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        buf[i / 2] = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
    }
}

pub fn main() !void {
    // Method 1: Generate keys/plaintext
    std.debug.print("\n=== Method 1: Generated ===\n", .{});
    {
        var key0: [32]u8 = undefined;
        var key1: [32]u8 = undefined;
        for (&key0, 0..) |*b, i| b.* = @intCast((i * 3) & 0xff);
        for (&key1, 0..) |*b, i| b.* = @intCast((i * 11) & 0xff);

        var plaintext: [64]u8 = undefined;
        for (&plaintext, 0..) |*b, i| b.* = @intCast((i * 17) & 0xff);

        var ciphertext: [64]u8 = undefined;

        const aes_k0 = AES.Aes.init(&key0);
        const aes_k1 = AES.Aes.init(&key1);
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

        enc.initEnc(0x123456789abcdef, &ciphertext);
        enc.update1(&plaintext);
        enc.finish1();
        enc.update2(&plaintext);
        const tag = enc.finish2();

        std.debug.print("Ciphertext: ", .{});
        for (ciphertext[0..32]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("...\n", .{});
        std.debug.print("Tag:        ", .{});
        for (tag) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n\n", .{});
    }

    // Method 2: Parse from hex
    std.debug.print("=== Method 2: Parsed from hex ===\n", .{});
    {
        var key0: [32]u8 = undefined;
        var key1: [32]u8 = undefined;
        hexToBytes("000306090c0f1215181b1e2124272a2d303336393c3f4245484b4e5154575a5d", &key0);
        hexToBytes("000b16212c37424d58636e79848f9aa5b0bbc6d1dce7f2fd08131e29343f4a55", &key1);

        var plaintext: [64]u8 = undefined;
        hexToBytes("00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f2031425364758697a8b9cadbecfd0e1f30415263748596a7b8c9daebfc0d1e2f", &plaintext);

        var ciphertext: [64]u8 = undefined;

        const aes_k0 = AES.Aes.init(&key0);
        const aes_k1 = AES.Aes.init(&key1);
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

        enc.initEnc(1311768467463790320, &ciphertext);
        enc.update1(&plaintext);
        enc.finish1();
        enc.update2(&plaintext);
        const tag = enc.finish2();

        std.debug.print("Ciphertext: ", .{});
        for (ciphertext[0..32]) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("...\n", .{});
        std.debug.print("Tag:        ", .{});
        for (tag) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n\n", .{});
    }

    std.debug.print("Expected:\n", .{});
    std.debug.print("Ciphertext: 7d76beb188ae1f8d36da6389d5a481ce...\n", .{});
    std.debug.print("Tag:        a2b508638436c16fedb4dcb9988f2d5b\n", .{});
}
