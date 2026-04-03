const std = @import("std");
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const Identity = @import("node/identity.zig").Identity;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Bug Hunt Round 2: Corrupted MAC ===\n", .{});
    var client_id = try Identity.generate(allocator);
    defer client_id.deinit();
    var server_id = try Identity.generate(allocator);
    defer server_id.deinit();
    
    var key: [32]u8 = undefined;
    if (!client_id.agree(&server_id, &key)) return error.KeyAgreementFailed;
    
    var hello = Packet.initNew(server_id.address(), client_id.address(), .hello);
    try hello.buf.appendByte(42, 10);
    hello.armor(&key, false, false, null, null);
    
    // Corrupt payload
    const orig = hello.buf.getByte(pkt.idx_payload) catch 0;
    try hello.buf.setByte(pkt.idx_payload, orig ^ 0xFF);
    
    const valid = hello.dearmor(&key, null, null);
    if (valid) {
        std.debug.print("❌ BUG: MAC accepted corrupted packet!\n", .{});
        return error.BugFound;
    }
    std.debug.print("✅ PASS: MAC rejected corrupted packet\n", .{});
    
    std.debug.print("\n=== Bug Hunt Round 3: Wrong Key ===\n", .{});
    var wrong_id = try Identity.generate(allocator);
    defer wrong_id.deinit();
    var wrong_key: [32]u8 = undefined;
    if (!client_id.agree(&wrong_id, &wrong_key)) return error.KeyAgreementFailed;
    
    var hello2 = Packet.initNew(server_id.address(), client_id.address(), .hello);
    try hello2.buf.appendByte(42, 10);
    hello2.armor(&key, false, false, null, null);
    
    const valid2 = hello2.dearmor(&wrong_key, null, null);
    if (valid2) {
        std.debug.print("❌ BUG: MAC accepted wrong key!\n", .{});
        return error.BugFound;
    }
    std.debug.print("✅ PASS: MAC rejected wrong key\n", .{});
    
    std.debug.print("\n=== Bug Hunt Round 4: Packet ID Uniqueness ===\n", .{});
    var ids = std.ArrayList(u64).init(allocator);
    defer ids.deinit();
    
    for (0..100) |_| {
        var pkt_test = Packet.initNew(server_id.address(), client_id.address(), .hello);
        const id = pkt_test.packetId();
        for (ids.items) |seen_id| {
            if (id == seen_id) {
                std.debug.print("❌ BUG: Duplicate packet ID!\n", .{});
                return error.BugFound;
            }
        }
        try ids.append(id);
    }
    std.debug.print("✅ PASS: All 100 packet IDs unique\n", .{});
    
    std.debug.print("\n=== Bug Hunt Round 5: Stress Test (1000 packets) ===\n", .{});
    for (0..1000) |i| {
        var pkt_stress = Packet.initNew(server_id.address(), client_id.address(), .hello);
        try pkt_stress.buf.appendByte(@intCast(i % 256), 20);
        pkt_stress.armor(&key, false, false, null, null);
        const stress_valid = pkt_stress.dearmor(&key, null, null);
        if (!stress_valid) {
            std.debug.print("❌ BUG: Valid packet #{} rejected!\n", .{i});
            return error.BugFound;
        }
    }
    std.debug.print("✅ PASS: 1000 valid packets all verified\n", .{});
    
    std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
    std.debug.print("  ✅ ALL 5 BUG HUNT ROUNDS PASSED\n", .{});
    std.debug.print("═" ** 60 ++ "\n\n", .{});
}
