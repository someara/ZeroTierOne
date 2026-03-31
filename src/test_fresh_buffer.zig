/// Test with explicit buffer allocation

const std = @import("std");
const AES = @import("node/aes.zig");

pub fn main() !void {
    std.debug.print("\n=== Test with explicit fresh buffer ===\n\n", .{});

    // Allocate everything on the heap to avoid any stack reuse issues
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const key0 = try allocator.alloc(u8, 32);
    defer allocator.free(key0);
    const key1 = try allocator.alloc(u8, 32);
    defer allocator.free(key1);
    const plaintext = try allocator.alloc(u8, 64);
    defer allocator.free(plaintext);
    const ciphertext = try allocator.alloc(u8, 64);
    defer allocator.free(ciphertext);

    // Generate keys
    for (key0, 0..) |*b, i| b.* = @intCast((i * 3) & 0xff);
    for (key1, 0..) |*b, i| b.* = @intCast((i * 11) & 0xff);
    for (plaintext, 0..) |*b, i| b.* = @intCast((i * 17) & 0xff);

    const aes_k0 = AES.Aes.init(key0[0..32]);
    const aes_k1 = AES.Aes.init(key1[0..32]);
    var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);

    enc.initEnc(0x123456789abcdef, ciphertext.ptr);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    const tag = enc.finish2();

    std.debug.print("Ciphertext: ", .{});
    for (ciphertext[0..32]) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("...\n", .{});
    std.debug.print("Tag:        ", .{});
    for (tag) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    std.debug.print("Expected:\n", .{});
    std.debug.print("Ciphertext: 7d76beb188ae1f8d36da6389d5a481ce...\n", .{});
    std.debug.print("Tag:        a2b508638436c16fedb4dcb9988f2d5b\n", .{});
}
