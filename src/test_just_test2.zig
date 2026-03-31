/// Test ONLY Test 2, isolated

const std = @import("std");
const AES = @import("node/aes.zig");

fn hexToBytes(comptime hex: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        buf[i / 2] = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
    }
}

pub fn main() !void {
    std.debug.print("\n=== Just Test 2 ===\n\n", .{});

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
    for (ciphertext) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("Tag: ", .{});
    for (tag) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("Expected ciphertext: 7d76beb188ae1f8d36da6389d5a481ce0ec6abad1ad1c36083fe7868bb443c4d7a354328ce1e551d747b8ccaa8c35b711f94b64dd52b36c5cd330c0805158734\n", .{});
    std.debug.print("Expected tag:        a2b508638436c16fedb4dcb9988f2d5b\n", .{});
}
