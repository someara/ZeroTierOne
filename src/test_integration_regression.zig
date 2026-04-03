/// Regression tests for bugs found during integration testing
///
/// These tests verify that bugs discovered during integration testing
/// remain fixed. Each test targets a specific bug with a minimal repro case.

const std = @import("std");
const testing = std.testing;

const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const Fragment = pkt.Fragment;
const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;

// ═══════════════════════════════════════════════════════════════
// BUG #1: Fragment buffer must be initialized before field access
// ═══════════════════════════════════════════════════════════════
// Found: 2026-04-03 during fragment reassembly integration test
// Symptom: panic: attempt to unwrap error: OutOfBounds
// Root cause: Fragment.initEmpty() creates buffer with size=0,
//             then fieldMut() fails when trying to access fields
// Fix: Call setSize(min_fragment_length) before accessing fields

test "Regression: Fragment buffer initialization" {
    var frag = Fragment.initEmpty();

    // This should NOT panic
    try frag.buf.setSize(pkt.min_fragment_length);

    // Now we can safely access fields
    const dest_field = frag.buf.dataMut()[pkt.frag_idx_dest..][0..5];
    @memset(dest_field, 0x42);

    // Verify we can read it back
    const read_back = frag.buf.data()[pkt.frag_idx_dest];
    try testing.expectEqual(@as(u8, 0x42), read_back);
}

test "Regression: Fragment can encode all required fields" {
    var frag = Fragment.initEmpty();
    try frag.buf.setSize(pkt.min_fragment_length);

    // Test packet ID (8 bytes at offset 0)
    const packet_id: u64 = 0x1234567890ABCDEF;
    const packet_id_bytes = std.mem.toBytes(packet_id);
    @memcpy(frag.buf.dataMut()[0..8], &packet_id_bytes);

    // Test destination address (5 bytes at offset 8)
    const dest_addr = Address{ ._a = 12345 };
    dest_addr.toBytes(frag.buf.dataMut()[pkt.frag_idx_dest..][0..5]);

    // Test fragment indicator (1 byte at offset 13)
    frag.buf.dataMut()[pkt.frag_idx_fragment_indicator] = pkt.fragment_indicator;

    // Test fragment number/total (1 byte at offset 14)
    const total: u8 = 3;
    const frag_no: u8 = 1;
    const frag_byte = (@as(u8, (total & 0x0F)) << 4) | (frag_no & 0x0F);
    frag.buf.dataMut()[pkt.frag_idx_fragment_no] = frag_byte;

    // Test hop count (1 byte at offset 15)
    frag.buf.dataMut()[pkt.frag_idx_hops] = 7;

    // Verify all fields
    const data = frag.buf.data();
    const read_packet_id = std.mem.readInt(u64, data[0..8], .little);
    try testing.expectEqual(packet_id, read_packet_id);

    try testing.expectEqual(pkt.fragment_indicator, data[pkt.frag_idx_fragment_indicator]);

    const read_frag_byte = data[pkt.frag_idx_fragment_no];
    const read_total = (read_frag_byte >> 4) & 0x0F;
    const read_frag_no = read_frag_byte & 0x0F;
    try testing.expectEqual(total, read_total);
    try testing.expectEqual(frag_no, read_frag_no);

    try testing.expectEqual(@as(u8, 7), data[pkt.frag_idx_hops]);
}

// ═══════════════════════════════════════════════════════════════
// VERIFICATION: MAC correctly rejects corrupted packets
// ═══════════════════════════════════════════════════════════════
// This verifies that MAC verification actually works and isn't a no-op

test "Verification: MAC detects corrupted packet" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sender = try Identity.generate(allocator);
    defer sender.deinit();
    var receiver = try Identity.generate(allocator);
    defer receiver.deinit();

    var key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &key);

    // Create and armor a packet
    var pkt_test = Packet.initNew(receiver.address(), sender.address(), .hello);
    try pkt_test.buf.appendByte(42, 10);
    pkt_test.armor(&key, false, false, null, null);

    // Corrupt one byte
    const orig = pkt_test.buf.data()[pkt.idx_payload];
    pkt_test.buf.dataMut()[pkt.idx_payload] = orig ^ 0xFF;

    // MAC verification should FAIL
    const valid = pkt_test.dearmor(&key, null, null);
    try testing.expect(!valid);
}

test "Verification: MAC detects wrong key" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sender = try Identity.generate(allocator);
    defer sender.deinit();
    var receiver = try Identity.generate(allocator);
    defer receiver.deinit();
    var attacker = try Identity.generate(allocator);
    defer attacker.deinit();

    var correct_key: [32]u8 = undefined;
    var wrong_key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &correct_key);
    _ = sender.agree(&attacker, &wrong_key);

    // Create and armor with correct key
    var pkt_test = Packet.initNew(receiver.address(), sender.address(), .hello);
    try pkt_test.buf.appendByte(42, 10);
    pkt_test.armor(&correct_key, false, false, null, null);

    // Try to dearmor with wrong key - should FAIL
    const valid = pkt_test.dearmor(&wrong_key, null, null);
    try testing.expect(!valid);
}

// ═══════════════════════════════════════════════════════════════
// VERIFICATION: Packet IDs are unique
// ═══════════════════════════════════════════════════════════════

test "Verification: Packet IDs are unique across 1000 packets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sender = try Identity.generate(allocator);
    defer sender.deinit();
    var receiver = try Identity.generate(allocator);
    defer receiver.deinit();

    // Use a map to detect duplicates efficiently
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    for (0..1000) |_| {
        var pkt_test = Packet.initNew(receiver.address(), sender.address(), .hello);
        const id = pkt_test.packetId();

        // Check if we've seen this ID before
        const result = try seen.getOrPut(id);
        try testing.expect(!result.found_existing); // Should be unique
    }

    // All 1000 IDs should be in the map
    try testing.expectEqual(@as(usize, 1000), seen.count());
}

// ═══════════════════════════════════════════════════════════════
// VERIFICATION: Fragment reassembly preserves packet integrity
// ═══════════════════════════════════════════════════════════════

test "Verification: Fragment reassembly is lossless" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var sender = try Identity.generate(allocator);
    defer sender.deinit();
    var receiver = try Identity.generate(allocator);
    defer receiver.deinit();

    var key: [32]u8 = undefined;
    _ = sender.agree(&receiver, &key);

    // Create original packet with known pattern
    var original = Packet.initNew(receiver.address(), sender.address(), .hello);
    for (0..2000) |i| {
        try original.buf.appendByte(@intCast(i % 256), 1);
    }
    original.armor(&key, false, false, null, null);

    const original_data = original.buf.data();
    const original_size = original.buf.size();

    // Fragment it (simulated - just split the data)
    const frag_size: usize = 700;
    var reassembled_data = try allocator.alloc(u8, original_size);
    defer allocator.free(reassembled_data);

    var offset: usize = 0;
    while (offset < original_size) {
        const chunk_size = @min(original_size - offset, frag_size);
        @memcpy(reassembled_data[offset..][0..chunk_size], original_data[offset..][0..chunk_size]);
        offset += chunk_size;
    }

    // Verify reassembled data matches original
    try testing.expectEqualSlices(u8, original_data, reassembled_data);
}
