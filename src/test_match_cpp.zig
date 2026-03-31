/// Test with the SAME generation logic as test_single_vector.cpp

const std = @import("std");
const AES = @import("node/aes.zig");

pub fn main() !void {
    std.debug.print("\n=== Zig Test (matching C++ generation logic) ===\n\n", .{});

    var key0: [32]u8 = undefined;
    var key1: [32]u8 = undefined;

    // Generate keys EXACTLY as in test_single_vector.cpp
    for (&key0, 0..) |*b, i| {
        b.* = @intCast((i * 3) & 0xff);
    }
    for (&key1, 0..) |*b, i| {
        b.* = @intCast((i * 11) & 0xff);
    }

    var plaintext: [64]u8 = undefined;
    for (&plaintext, 0..) |*b, i| {
        b.* = @intCast((i * 17) & 0xff);
    }

    std.debug.print("Key0: ", .{});
    for (key0) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("Key1: ", .{});
    for (key1) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});

    std.debug.print("Plaintext: ", .{});
    for (plaintext) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    var ciphertext: [64]u8 = undefined;

    const aes_k0 = AES.Aes.init(&key0);
    const aes_k1 = AES.Aes.init(&key1);
    var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

    const iv_value: u64 = 0x123456789abcdef;

    enc.initEnc(iv_value, &ciphertext);
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

    std.debug.print("C++ Expected:\n", .{});
    std.debug.print("ciphertext: 7d76beb188ae1f8d36da6389d5a481ce0ec6abad1ad1c36083fe7868bb443c4d7a354328ce1e551d747b8ccaa8c35b711f94b64dd52b36c5cd330c0805158734\n", .{});
    std.debug.print("tag:        a2b508638436c16fedb4dcb9988f2d5b\n", .{});
}
