const std = @import("std");
const Identity = @import("node/identity.zig").Identity;
const identity_mod = @import("node/identity.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // C++ identity: 859e9836d8:0:<pubkey>
    const id_str = "859e9836d8:0:c45fd54865ed77d4a0576e07efcc1947d52910386023c8375f59f09d3c17b56b57188b8ce6e3081465a901f8ddb2ba3495dfd8fedff2249d552f65c9329ce021";

    const identity = Identity.fromString(id_str) orelse {
        std.debug.print("FAIL: fromString returned null\n", .{});
        return;
    };

    std.debug.print("Parsed address: {x:0>10}\n", .{identity._address.toInt()});
    std.debug.print("Expected:       859e9836d8\n\n", .{});

    // Run memory-hard hash
    const genmem = try allocator.alloc(u8, 2097152);
    defer allocator.free(genmem);

    var digest: [64]u8 = undefined;
    identity_mod.computeMemoryHardHash(&identity._public_key, &digest, genmem);

    std.debug.print("Memory-hard hash digest[0]:    {x:0>2}\n", .{digest[0]});
    std.debug.print("  (must be < 0x11 for valid)   {s}\n", .{if (digest[0] < 0x11) "OK" else "FAIL"});
    std.debug.print("Memory-hard hash digest[59..64]: ", .{});
    for (digest[59..64]) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n", .{});
    std.debug.print("Expected (address):              859e9836d8\n", .{});
    std.debug.print("Match: {s}\n", .{
        if (std.mem.eql(u8, digest[59..64], &[_]u8{ 0x85, 0x9e, 0x98, 0x36, 0xd8 })) "YES" else "NO",
    });
}
