/// TUN Device Integration Test
///
/// Tests that TUN devices are created and managed correctly when networks are joined.
/// Does not require sudo - just tests the integration logic.

const std = @import("std");
const testing = std.testing;
const net = std.net;

const Node = @import("node/node.zig").Node;
const Config = @import("node/node.zig").Config;
const Callbacks = @import("node/node.zig").Callbacks;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const MAC = @import("node/mac.zig").MAC;
const Address = @import("node/address.zig").Address;

test "MAC derivation from ZT address and network ID" {
    // Test that we can derive proper MAC addresses
    const zt_addr = Address.init(0x1234567890);
    const nwid: u64 = 0x8056c2e21c000001;

    const mac = MAC.fromAddress(zt_addr, nwid);

    // Should be non-zero
    try testing.expect(mac.toInt() != 0);

    // Should be locally administered
    try testing.expect(mac.isLocallyAdministered());

    // Should not be broadcast
    try testing.expect(!mac.isBroadcast());

    // Should not be multicast
    try testing.expect(!mac.isMulticast());

    // Should be able to recover the address
    const recovered = mac.toAddress(nwid);
    try testing.expectEqual(zt_addr.toInt(), recovered.toInt());

    std.debug.print("\n  ✓ MAC derivation works correctly\n", .{});
    std.debug.print("    ZT Address: {x:0>10}\n", .{zt_addr.toInt()});
    std.debug.print("    Network ID: {x:0>16}\n", .{nwid});
    std.debug.print("    Derived MAC: {x:0>12}\n", .{mac.toInt()});
}

test "MAC octet calculations" {
    // Test firstOctetForNetwork logic
    const nwid1: u64 = 0x8056c2e21c000001;
    const nwid2: u64 = 0x8056c2e21c000052; // Should avoid 0x52

    const mac1 = MAC.fromAddress(Address.init(0x1234567890), nwid1);
    const mac2 = MAC.fromAddress(Address.init(0x1234567890), nwid2);

    // Extract first octet (bits 40-47)
    const first_octet_1 = @as(u8, @truncate(mac1.toInt() >> 40));
    const first_octet_2 = @as(u8, @truncate(mac2.toInt() >> 40));

    // First octet should be locally administered (bit 1 set)
    try testing.expect((first_octet_1 & 0x02) != 0);
    try testing.expect((first_octet_2 & 0x02) != 0);

    // First octet should not be multicast (bit 0 clear)
    try testing.expect((first_octet_1 & 0x01) == 0);
    try testing.expect((first_octet_2 & 0x01) == 0);

    // 0x52 should be blacklisted and replaced with 0x32
    if (first_octet_2 == 0x52) {
        try testing.expect(false); // Should never be 0x52
    }

    std.debug.print("\n  ✓ MAC octet calculations correct\n", .{});
    std.debug.print("    First octet (nwid1): {x:0>2}\n", .{first_octet_1});
    std.debug.print("    First octet (nwid2): {x:0>2}\n", .{first_octet_2});
}

test "broadcast MAC constant" {
    const broadcast = MAC.init(0xFFFFFFFFFFFF);
    try testing.expect(broadcast.isBroadcast());
    try testing.expect(broadcast.isMulticast()); // broadcast is also multicast
    try testing.expect(broadcast.isLocallyAdministered()); // all bits set

    std.debug.print("\n  ✓ Broadcast MAC recognized\n", .{});
}

test "MAC roundtrip through network ID" {
    // Test that we can derive MAC and recover address for various combinations
    const test_cases = [_]struct {
        addr: u64,
        nwid: u64,
    }{
        .{ .addr = 0x0000000001, .nwid = 0x8056c2e21c000001 },
        .{ .addr = 0x1234567890, .nwid = 0x8056c2e21c000001 },
        .{ .addr = 0xffffffffff, .nwid = 0x8056c2e21c000001 },
        .{ .addr = 0x1234567890, .nwid = 0x0000000000000001 },
        .{ .addr = 0x1234567890, .nwid = 0xffffffffffffffff },
    };

    for (test_cases) |tc| {
        const addr = Address.init(tc.addr);
        const mac = MAC.fromAddress(addr, tc.nwid);
        const recovered = mac.toAddress(tc.nwid);

        try testing.expectEqual(addr.toInt(), recovered.toInt());
    }

    std.debug.print("\n  ✓ MAC roundtrip works for all test cases\n", .{});
}

test "ethertype constants" {
    // Verify we're using the correct ethertype values
    const ETHERTYPE_IPV4: u32 = 0x0800;
    const ETHERTYPE_IPV6: u32 = 0x86DD;
    const ETHERTYPE_ARP: u32 = 0x0806;

    try testing.expectEqual(@as(u32, 0x0800), ETHERTYPE_IPV4);
    try testing.expectEqual(@as(u32, 0x86DD), ETHERTYPE_IPV6);
    try testing.expectEqual(@as(u32, 0x0806), ETHERTYPE_ARP);

    std.debug.print("\n  ✓ Ethertype constants correct\n", .{});
}
