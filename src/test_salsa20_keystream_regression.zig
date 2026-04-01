/// Regression test for Salsa20 keystream offset bug (commit 344d4961)
///
/// This test prevents reintroduction of a critical bug where packet dearmor
/// was using the wrong keystream offset for payload decryption, causing all
/// packets to fail decompression.
///
/// Bug Summary:
/// - MAC key generation correctly used bytes 0-63 of keystream (block 0)
/// - After MAC key, code incorrectly skipped another 64 bytes
/// - Payload decryption started at byte 128 instead of byte 64
/// - This caused decryption to produce garbage, breaking LZ4 decompression
///
/// Fix (commit 344d4961):
/// - Removed the extra skip operation
/// - After crypt12(&mac_key, 32 bytes), block_counter is already at 1
/// - Next crypt12() starts at byte 64, which is correct
///
/// This test verifies:
/// 1. MAC key uses bytes 0-31 of keystream (first 32 of block 0)
/// 2. Payload decryption uses bytes 64+ of keystream (block 1+)
/// 3. No extra keystream bytes are skipped between MAC and payload
const std = @import("std");
const testing = std.testing;
const Salsa20 = @import("node/salsa20.zig").Salsa20;

test "Salsa20 keystream offset regression - MAC key then payload" {
    // Reproduce the exact pattern used in packet.zig dearmor()
    const key = [_]u8{0x42} ** 32;
    const iv = [_]u8{0x99} ** 8;
    const zero_key = [_]u8{0} ** 32;

    // Initialize Salsa20 cipher
    var s20 = Salsa20.init(&key, &iv);
    try testing.expectEqual(@as(u64, 0), s20.block_counter);

    // Step 1: Generate MAC key (first 32 bytes of keystream)
    // This consumes bytes 0-63 of keystream (one full 64-byte block)
    var mac_key: [32]u8 = undefined;
    s20.crypt12(&mac_key, &zero_key);

    // After generating 32-byte MAC key, block_counter should be at 1
    // (crypt12 with 32 bytes consumes 1 full 64-byte block and advances counter)
    try testing.expectEqual(@as(u64, 1), s20.block_counter);

    // Step 2: Decrypt payload starting immediately at byte 64
    // NO extra skip should occur - we're positioned at byte 64 already
    var payload: [100]u8 = undefined;
    for (&payload, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    const original_payload = payload;
    s20.crypt12(&payload, &payload); // Encrypt

    // Block counter should now be at 3 (100 bytes = 2 blocks)
    try testing.expectEqual(@as(u64, 3), s20.block_counter);

    // Verify encryption changed the data
    try testing.expect(!std.mem.eql(u8, &original_payload, &payload));

    // Decrypt: re-init, generate MAC key again, then decrypt
    s20.reinit(&key, &iv);
    var mac_key2: [32]u8 = undefined;
    s20.crypt12(&mac_key2, &zero_key); // Position at byte 64
    s20.crypt12(&payload, &payload); // Decrypt

    // MAC keys should match
    try testing.expectEqualSlices(u8, &mac_key, &mac_key2);

    // Payload should be recovered
    try testing.expectEqualSlices(u8, &original_payload, &payload);
}

test "Salsa20 keystream offset regression - verify byte positions" {
    // This test verifies the exact byte positions of keystream consumption
    const key = [_]u8{0xAB} ** 32;
    const iv = [_]u8{0xCD} ** 8;

    // Generate reference keystream (256 bytes)
    var reference: [256]u8 = undefined;
    var ctx = Salsa20.init(&key, &iv);
    ctx.crypt12(&reference, &([_]u8{0} ** 256));

    // Now test the MAC key + payload pattern
    ctx.reinit(&key, &iv);

    // MAC key should use bytes 0-31 of keystream
    var mac_key: [32]u8 = undefined;
    ctx.crypt12(&mac_key, &([_]u8{0} ** 32));
    try testing.expectEqualSlices(u8, reference[0..32], &mac_key);

    // Payload should use bytes 64-127 (NOT 128+)
    // This is the critical fix - no gap between byte 32 and 64
    var payload: [64]u8 = undefined;
    ctx.crypt12(&payload, &([_]u8{0} ** 64));

    // CRITICAL: Payload decryption must use bytes 64-127, not 128-191
    try testing.expectEqualSlices(u8, reference[64..128], &payload);

    // This is what the OLD buggy code produced (wrong offset):
    // It would have used reference[128..192] due to extra skip
}

test "Salsa20 keystream offset regression - block counter behavior" {
    // Verify block counter advances correctly without extra skips
    const key = [_]u8{0x11} ** 32;
    const iv = [_]u8{0x22} ** 8;

    var ctx = Salsa20.init(&key, &iv);

    // Start at block 0
    try testing.expectEqual(@as(u64, 0), ctx.block_counter);

    // Generate 32-byte MAC key - consumes block 0 (bytes 0-63)
    var mac_key: [32]u8 = undefined;
    ctx.crypt12(&mac_key, &([_]u8{0} ** 32));

    // Now at block 1 (byte 64)
    try testing.expectEqual(@as(u64, 1), ctx.block_counter);

    // CRITICAL TEST: Next operation should use block 1, not block 2
    // The buggy code had an extra crypt12() here that advanced to block 2
    var small_payload: [16]u8 = undefined;
    ctx.crypt12(&small_payload, &([_]u8{0} ** 16));

    // Should be at block 2 now (consumed block 1)
    try testing.expectEqual(@as(u64, 2), ctx.block_counter);

    // Decrypt and verify we used the correct keystream position
    ctx.reinit(&key, &iv);
    ctx.crypt12(&mac_key, &([_]u8{0} ** 32)); // Re-generate MAC key
    ctx.crypt12(&small_payload, &small_payload); // Decrypt

    // Should recover all zeros
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 16), &small_payload);
}

test "Salsa20 keystream offset regression - real packet pattern" {
    // Simulate the exact pattern from packet.zig dearmor() with realistic sizes
    const key = [_]u8{0xDE} ** 32;
    const iv = [_]u8{0xAD} ** 8;

    // Typical packet: 8-byte MAC + 100-byte payload
    var packet_payload: [100]u8 = undefined;
    for (&packet_payload, 0..) |*b, i| {
        b.* = @truncate(i * 3 + 7);
    }
    const original = packet_payload;

    // Encrypt (sender side)
    var s20_send = Salsa20.init(&key, &iv);
    var mac_key_send: [32]u8 = undefined;
    s20_send.crypt12(&mac_key_send, &([_]u8{0} ** 32));
    s20_send.crypt12(&packet_payload, &packet_payload);

    // Decrypt (receiver side - the pattern that was buggy)
    var s20_recv = Salsa20.init(&key, &iv);
    var mac_key_recv: [32]u8 = undefined;
    s20_recv.crypt12(&mac_key_recv, &([_]u8{0} ** 32));

    // CRITICAL: Do NOT skip extra bytes here (this was the bug)
    // The buggy code had: s20_recv.crypt12(&skip_buf, &([_]u8{0} ** 32));

    // Decrypt payload immediately
    s20_recv.crypt12(&packet_payload, &packet_payload);

    // MAC keys should match
    try testing.expectEqualSlices(u8, &mac_key_send, &mac_key_recv);

    // Payload should be recovered
    try testing.expectEqualSlices(u8, &original, &packet_payload);
}

test "Salsa20 keystream offset regression - demonstrate the bug" {
    // This test shows what the BUGGY code would have produced
    const key = [_]u8{0xFF} ** 32;
    const iv = [_]u8{0x00} ** 8;

    var original: [64]u8 = undefined;
    for (&original, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    // Correct encryption (what we do now)
    var s20_correct = Salsa20.init(&key, &iv);
    var mac_key_correct: [32]u8 = undefined;
    s20_correct.crypt12(&mac_key_correct, &([_]u8{0} ** 32));
    var encrypted_correct = original;
    s20_correct.crypt12(&encrypted_correct, &encrypted_correct);

    // Buggy decryption (with extra skip)
    var s20_buggy = Salsa20.init(&key, &iv);
    var mac_key_buggy: [32]u8 = undefined;
    s20_buggy.crypt12(&mac_key_buggy, &([_]u8{0} ** 32));

    // THE BUG: Skip another 32 bytes (consuming another block)
    var skip_buf: [32]u8 = undefined;
    s20_buggy.crypt12(&skip_buf, &([_]u8{0} ** 32));

    // Now decrypt with wrong keystream offset
    var decrypted_buggy = encrypted_correct;
    s20_buggy.crypt12(&decrypted_buggy, &decrypted_buggy);

    // This should NOT match the original (proving the bug)
    try testing.expect(!std.mem.eql(u8, &original, &decrypted_buggy));

    // The buggy decryption produces garbage because it uses
    // keystream bytes 128+ instead of 64+
}
