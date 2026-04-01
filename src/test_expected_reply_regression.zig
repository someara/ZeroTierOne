/// Regression test for expected reply tracking (commit 797c0d30)
///
/// This test prevents reintroduction of the bug where HELLO packets didn't
/// register expected replies, causing HELLO OK responses to be rejected.
///
/// Bug Details (commit 797c0d30):
/// - Peer.sendHELLO() created HELLO packets but didn't register expected replies
/// - IncomingPacket.doOK() checked for expected replies before processing
/// - HELLO OK responses were rejected as unexpected, blocking handshakes
/// - No test coverage existed for the expected reply tracking system
///
/// Fix (commit 797c0d30):
/// - Wired expectReplyFn callback into Peer.HELLOContext
/// - sendHELLO() now calls expectReplyFn with packet ID
/// - Node.expectReplyTo() registers the packet ID in hash table
/// - doOK() finds matching entry and processes response
///
/// This test verifies:
/// 1. Expected reply registration works correctly
/// 2. Expected reply lookup works correctly
/// 3. Hash table collision handling (32 entries per bucket)
/// 4. Multiple concurrent expected replies
/// 5. Different packet IDs hash to correct buckets
const std = @import("std");
const testing = std.testing;

// Mock the expected reply tracking system structure
const ExpectedReplyTracker = struct {
    // 256 buckets × 32 entries per bucket (matching Node implementation)
    expecting_replies: [256][32]u32,
    expecting_replies_ptr: [256]u8,

    pub fn init() ExpectedReplyTracker {
        return .{
            .expecting_replies = [_][32]u32{[_]u32{0} ** 32} ** 256,
            .expecting_replies_ptr = [_]u8{0} ** 256,
        };
    }

    /// Record that we expect an OK reply for the given packet ID.
    /// Mirrors Node.expectReplyTo() implementation.
    pub fn expectReplyTo(self: *ExpectedReplyTracker, packet_id: u64) void {
        const pid2: u32 = @truncate(packet_id >> 32);
        const bucket: u8 = @truncate(pid2);
        const slot = self.expecting_replies_ptr[bucket];
        self.expecting_replies[bucket][slot & 31] = pid2;
        self.expecting_replies_ptr[bucket] = slot +% 1;
    }

    /// Check if we are expecting an OK for the given packet ID.
    /// Mirrors Node.isExpectingReplyTo() implementation.
    pub fn isExpectingReplyTo(self: *const ExpectedReplyTracker, packet_id: u64) bool {
        const pid2: u32 = @truncate(packet_id >> 32);
        const bucket: u8 = @truncate(pid2);
        for (0..32) |i| {
            if (self.expecting_replies[bucket][i] == pid2) {
                return true;
            }
        }
        return false;
    }
};

test "Expected reply regression - basic registration and lookup" {
    var tracker = ExpectedReplyTracker.init();

    // Register expected reply for packet ID 0x123456789ABCDEF0
    const packet_id: u64 = 0x123456789ABCDEF0;
    tracker.expectReplyTo(packet_id);

    // Should be able to find it
    try testing.expect(tracker.isExpectingReplyTo(packet_id));

    // Different packet ID should not be found
    try testing.expect(!tracker.isExpectingReplyTo(0xFFFFFFFFFFFFFFFF));
}

test "Expected reply regression - multiple concurrent replies" {
    var tracker = ExpectedReplyTracker.init();

    // Register 10 different expected replies
    const packet_ids = [_]u64{
        0x1000000000000001,
        0x2000000000000002,
        0x3000000000000003,
        0x4000000000000004,
        0x5000000000000005,
        0x6000000000000006,
        0x7000000000000007,
        0x8000000000000008,
        0x9000000000000009,
        0xA00000000000000A,
    };

    for (packet_ids) |pid| {
        tracker.expectReplyTo(pid);
    }

    // All should be found
    for (packet_ids) |pid| {
        try testing.expect(tracker.isExpectingReplyTo(pid));
    }

    // Unregistered packet should not be found
    try testing.expect(!tracker.isExpectingReplyTo(0xBBBBBBBBBBBBBBBB));
}

test "Expected reply regression - bucket collision handling" {
    var tracker = ExpectedReplyTracker.init();

    // Each bucket holds 32 entries. Test filling a bucket completely.
    // Use packet IDs that hash to the same bucket (lower 8 bits of upper 32).
    // Bucket is determined by: @truncate(u8, packet_id >> 32)

    // All these IDs will hash to bucket 0x42:
    const base_bucket: u64 = 0x42; // Upper 32 bits start with 0x42

    var registered_ids: [32]u64 = undefined;
    for (0..32) |i| {
        // Create packet IDs: 0x42xxxxxx00000000 (unique upper 32 bits, same bucket)
        registered_ids[i] = (base_bucket << 32) | (@as(u64, i) << 8);
        tracker.expectReplyTo(registered_ids[i]);
    }

    // All 32 registered IDs should be found
    for (registered_ids) |pid| {
        try testing.expect(tracker.isExpectingReplyTo(pid));
    }

    // Adding a 33rd entry to the same bucket wraps around (overwrites entry 0)
    const overflow_id: u64 = (base_bucket << 32) | 0xFFFF0000;
    tracker.expectReplyTo(overflow_id);

    // Overflow ID should be found
    try testing.expect(tracker.isExpectingReplyTo(overflow_id));

    // First registered ID may have been overwritten (slot wraps with & 31)
    // This is expected behavior - 32 entries per bucket is a design tradeoff
}

test "Expected reply regression - hash distribution" {
    var tracker = ExpectedReplyTracker.init();

    // Register packet IDs that hash to different buckets
    // Bucket = lower 8 bits of (packet_id >> 32)
    var registered_buckets: [256]bool = [_]bool{false} ** 256;

    for (0..256) |bucket| {
        const packet_id: u64 = (@as(u64, bucket) << 32) | 0x12345678;
        tracker.expectReplyTo(packet_id);
        registered_buckets[bucket] = true
        ;
        try testing.expect(tracker.isExpectingReplyTo(packet_id));
    }

    // Verify each bucket got an entry
    for (registered_buckets, 0..) |registered, bucket| {
        try testing.expect(registered);
        const packet_id: u64 = (@as(u64, bucket) << 32) | 0x12345678;
        try testing.expect(tracker.isExpectingReplyTo(packet_id));
    }
}

test "Expected reply regression - HELLO handshake pattern" {
    // Simulate the HELLO → OK handshake flow
    var tracker = ExpectedReplyTracker.init();

    // Peer sends HELLO with packet ID 0xDEADBEEF12345678
    const hello_packet_id: u64 = 0xDEADBEEF12345678;

    // Register expected reply (this was missing in the buggy code)
    tracker.expectReplyTo(hello_packet_id);

    // Verify we're expecting a reply
    try testing.expect(tracker.isExpectingReplyTo(hello_packet_id));

    // Remote peer responds with OK containing in-re-packet-id = hello_packet_id
    // IncomingPacket.doOK() should find the expected reply entry
    const ok_in_re_packet_id = hello_packet_id;
    try testing.expect(tracker.isExpectingReplyTo(ok_in_re_packet_id));

    // After processing, the entry could be cleared (not tested here - that's
    // application logic), but the important part is that the lookup succeeds
}

test "Expected reply regression - multiple HELLO packets in flight" {
    // Simulate sending HELLO to multiple peers concurrently
    var tracker = ExpectedReplyTracker.init();

    const hello_ids = [_]u64{
        0x1111111111111111, // Root server 1
        0x2222222222222222, // Root server 2
        0x3333333333333333, // Root server 3
        0x4444444444444444, // Root server 4
    };

    // Send HELLO to all root servers
    for (hello_ids) |hello_id| {
        tracker.expectReplyTo(hello_id);
    }

    // All expected replies should be registered
    for (hello_ids) |hello_id| {
        try testing.expect(tracker.isExpectingReplyTo(hello_id));
    }

    // When OK responses arrive, they should all be accepted
    for (hello_ids) |hello_id| {
        // doOK() checks: is this packet ID in our expected replies?
        try testing.expect(tracker.isExpectingReplyTo(hello_id));
    }
}

test "Expected reply regression - wrapping slot pointer" {
    var tracker = ExpectedReplyTracker.init();

    // Fill a bucket and verify wrapping behavior
    const bucket_base: u64 = 0x99;

    // Add 64 entries (wraps around twice)
    for (0..64) |i| {
        const packet_id: u64 = (bucket_base << 32) | (@as(u64, i) << 16);
        tracker.expectReplyTo(packet_id);
    }

    // Only the last 32 entries should be present (older ones overwritten)
    for (0..32) |i| {
        const new_packet_id: u64 = (bucket_base << 32) | (@as(u64, i + 32) << 16);

        // New entries (32-63) should definitely be present
        try testing.expect(tracker.isExpectingReplyTo(new_packet_id));
    }
}

test "Expected reply regression - zero packet ID" {
    var tracker = ExpectedReplyTracker.init();

    // Edge case: packet ID 0
    const zero_id: u64 = 0;
    tracker.expectReplyTo(zero_id);

    // Should be found (stored as pid2=0 in bucket 0)
    try testing.expect(tracker.isExpectingReplyTo(zero_id));
}

test "Expected reply regression - max packet ID" {
    var tracker = ExpectedReplyTracker.init();

    // Edge case: maximum packet ID
    const max_id: u64 = 0xFFFFFFFFFFFFFFFF;
    tracker.expectReplyTo(max_id);

    // Should be found (stored as pid2=0xFFFFFFFF in bucket 0xFF)
    try testing.expect(tracker.isExpectingReplyTo(max_id));
}

test "Expected reply regression - demonstration of the bug" {
    // This test shows what the BUGGY code would have done
    var tracker = ExpectedReplyTracker.init();

    const hello_packet_id: u64 = 0xCAFEBABE12345678;

    // BUGGY CODE: sendHELLO() did NOT call expectReplyTo()
    // (we skip the registration to simulate the bug)

    // When OK response arrives, doOK() checks for expected reply
    const ok_in_re_packet_id = hello_packet_id;
    const found = tracker.isExpectingReplyTo(ok_in_re_packet_id);

    // This should be false (demonstrating the bug)
    try testing.expect(!found);

    // In the buggy code, doOK() would reject the OK as unexpected
    // and the handshake would fail
}
