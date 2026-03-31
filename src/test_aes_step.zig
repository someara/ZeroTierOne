/// Step-by-step debug of Test 2 to find where it diverges

const std = @import("std");
const AES = @import("node/aes.zig");

fn hexToBytes(comptime hex: []const u8, buf: []u8) void {
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        buf[i / 2] = std.fmt.parseInt(u8, hex[i..i+2], 16) catch unreachable;
    }
}

pub fn main() !void {
    std.debug.print("\n=== Step-by-step Test 2 Debug ===\n\n", .{});

    var key0: [32]u8 = undefined;
    var key1: [32]u8 = undefined;
    hexToBytes("000306090c0f1215181b1e2124272a2d303336393c3f4245484b4e5154575a5d", &key0);
    hexToBytes("000b16212c37424d58636e79848f9aa5b0bbc6d1dce7f2fd08131e29343f4a55", &key1);

    std.debug.print("Key0: ", .{});
    for (key0) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("Key1: ", .{});
    for (key1) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    var plaintext: [64]u8 = undefined;
    hexToBytes("00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f2031425364758697a8b9cadbecfd0e1f30415263748596a7b8c9daebfc0d1e2f", &plaintext);

    std.debug.print("Plaintext: ", .{});
    for (plaintext) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    const aes_k0 = AES.Aes.init(&key0);
    const aes_k1 = AES.Aes.init(&key1);

    // Test basic AES encryption
    {
        std.debug.print("--- Basic AES test ---\n", .{});
        const test_block: [16]u8 = [_]u8{0} ** 16;
        const encrypted = aes_k0.encrypt(&test_block);
        std.debug.print("AES_K0(zeros): ", .{});
        for (encrypted) |b| std.debug.print("{x:0>2}", .{b});
        std.debug.print("\n\n", .{});
    }

    var ciphertext: [64]u8 = undefined;
    var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

    const iv_value: u64 = 1311768467463790320; // 0x123456789abcdef

    std.debug.print("--- initEnc(IV={}) ---\n", .{iv_value});
    enc.initEnc(iv_value, &ciphertext);

    std.debug.print("Tag after initEnc: ", .{});
    for (enc.tag) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("--- update1(plaintext) ---\n", .{});
    enc.update1(&plaintext);

    std.debug.print("--- finish1() ---\n", .{});
    enc.finish1();

    std.debug.print("Tag after finish1: ", .{});
    for (enc.tag) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("CTR block after finish1: ", .{});
    for (enc.ctr.ctr_block) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("--- update2(plaintext) ---\n", .{});
    enc.update2(&plaintext);

    std.debug.print("Ciphertext after update2: ", .{});
    for (ciphertext) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("--- finish2() ---\n", .{});
    const tag = enc.finish2();

    std.debug.print("Final tag: ", .{});
    for (tag) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("Final ciphertext: ", .{});
    for (ciphertext) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("Expected ciphertext: 7d76beb188ae1f8d36da6389d5a481ce0ec6abad1ad1c36083fe7868bb443c4d7a354328ce1e551d747b8ccaa8c35b711f94b64dd52b36c5cd330c0805158734\n", .{});
    std.debug.print("Expected tag:        a2b508638436c16fedb4dcb9988f2d5b\n", .{});
}
