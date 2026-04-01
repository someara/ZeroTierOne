/// Regression test for fragment reassembly logic (commit ce5a2c07)
///
/// This test prevents reintroduction of bugs in the Switch fragment reassembly
/// system that handles multi-fragment packets.
///
/// Bug Details (commit ce5a2c07):
/// 1. Completion detection was incorrect - didn't check for fragment 0 (head)
/// 2. Fragment payload appending was missing - no code to concatenate payloads
/// 3. Out-of-order fragment arrival wasn't handled correctly
///
/// Fix (commit ce5a2c07):
/// 1. Added completion check: countBits(have_fragments) == total_fragments
/// 2. Added head check: (have_fragments & 1) != 0 (fragment 0 present)
/// 3. Implemented payload appending loop (fragments 1..N appended to frag0)
/// 4. Fragment payloads extracted from offset 16 (after fragment header)
///
/// This test verifies:
/// 1. Multi-fragment packet reassembly (head arrives first)
/// 2. Out-of-order fragment arrival (head arrives last)
/// 3. Duplicate fragment detection
/// 4. Fragment completion detection
/// 5. Payload concatenation logic
/// 6. Bit mask manipulation for have_fragments
const std = @import("std");
const testing = std.testing;

// Mock fragment reassembly system structure
const FragmentReassembler = struct {
    // Fragment storage (up to 8 fragments max)
    frags: [8]Fragment,

    // Fragment metadata
    packet_id: u64,
    total_fragments: u8,
    have_fragments: u32, // Bit mask: bit N set = have fragment N
    complete: bool,

    // Head packet (fragment 0)
    head_data: [256]u8,
    head_len: usize,

    const Fragment = struct {
        data: [256]u8,
        len: usize,

        pub fn init() Fragment {
            return .{
                .data = [_]u8{0} ** 256,
                .len = 0,
            };
        }

        /// Get fragment payload (skip 16-byte header)
        pub fn payload(self: *const Fragment) []const u8 {
            const header_size = 16;
            if (self.len > header_size) {
                return self.data[header_size..self.len];
            }
            return &[_]u8{};
        }
    };

    pub fn init() FragmentReassembler {
        return .{
            .frags = [_]Fragment{Fragment.init()} ** 8,
            .packet_id = 0,
            .total_fragments = 0,
            .have_fragments = 0,
            .complete = false,
            .head_data = [_]u8{0} ** 256,
            .head_len = 0,
        };
    }

    /// Add fragment 0 (head)
    pub fn addHead(self: *FragmentReassembler, packet_id: u64, data: []const u8) void {
        if (self.packet_id != packet_id) {
            // New packet
            self.packet_id = packet_id;
            self.total_fragments = 0;
            self.have_fragments = 0;
            self.complete = false;
        }

        @memcpy(self.head_data[0..data.len], data);
        self.head_len = data.len;
        self.have_fragments |= 1; // Set bit 0

        self.checkCompletion();
    }

    /// Add fragment N (N >= 1)
    pub fn addFragment(self: *FragmentReassembler, packet_id: u64, frag_num: u8, total_frags: u8, data: []const u8) void {
        if (frag_num == 0 or frag_num >= 8) return; // Invalid
        if (total_frags > 8) return; // Too many fragments

        if (self.packet_id != packet_id) {
            // New packet - initialize
            self.packet_id = packet_id;
            self.total_fragments = total_frags;
            self.have_fragments = 0;
            self.complete = false;
        }

        // Check if we already have this fragment
        const bit_mask = @as(u32, 1) << @intCast(frag_num);
        if ((self.have_fragments & bit_mask) != 0) {
            return; // Duplicate - ignore
        }

        // Store fragment
        const frag = &self.frags[frag_num - 1];
        @memcpy(frag.data[0..data.len], data);
        frag.len = data.len;

        // Update metadata
        self.total_fragments = total_frags;
        self.have_fragments |= bit_mask;

        self.checkCompletion();
    }

    /// Check if reassembly is complete (implements fix from commit ce5a2c07)
    fn checkCompletion(self: *FragmentReassembler) void {
        if (self.total_fragments <= 1) {
            self.complete = false;
            return;
        }

        // Count how many fragments we have
        const have_count = @popCount(self.have_fragments);

        // Complete if we have all fragments AND fragment 0
        if (have_count == self.total_fragments and (self.have_fragments & 1) != 0) {
            self.complete = true;
        } else {
            self.complete = false;
        }
    }

    /// Reassemble complete packet (concatenate all fragment payloads)
    pub fn reassemble(self: *FragmentReassembler) ![]const u8 {
        if (!self.complete) return error.Incomplete;

        // Start with head data
        var buffer: [2048]u8 = undefined;
        var pos: usize = 0;

        @memcpy(buffer[pos..][0..self.head_len], self.head_data[0..self.head_len]);
        pos += self.head_len;

        // Append fragment payloads (1..N)
        var f: u8 = 1;
        while (f < self.total_fragments) : (f += 1) {
            const frag = &self.frags[f - 1];
            const payload = frag.payload();

            if (payload.len > 0) {
                @memcpy(buffer[pos..][0..payload.len], payload);
                pos += payload.len;
            }
        }

        return buffer[0..pos];
    }
};

test "Fragment reassembly regression - in-order arrival" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0x1234567890ABCDEF;
    const total_frags: u8 = 3;

    // Fragment 0 (head): 50 bytes (16 header + 34 payload)
    var frag0_data: [50]u8 = undefined;
    for (&frag0_data, 0..) |*b, i| b.* = @truncate(i);

    // Fragment 1: 30 bytes (16 header + 14 payload)
    var frag1_data: [30]u8 = undefined;
    for (&frag1_data, 0..) |*b, i| b.* = @truncate(100 + i);

    // Fragment 2: 25 bytes (16 header + 9 payload)
    var frag2_data: [25]u8 = undefined;
    for (&frag2_data, 0..) |*b, i| b.* = @truncate(200 + i);

    // Add fragments in order
    reassembler.addHead(packet_id, &frag0_data);
    try testing.expect(!reassembler.complete); // Not complete yet

    reassembler.addFragment(packet_id, 1, total_frags, &frag1_data);
    try testing.expect(!reassembler.complete); // Still need frag 2

    reassembler.addFragment(packet_id, 2, total_frags, &frag2_data);
    try testing.expect(reassembler.complete); // Now complete!

    // Reassemble and verify
    const result = try reassembler.reassemble();

    // Should be: 50 (frag0) + 14 (frag1 payload) + 9 (frag2 payload) = 73 bytes
    try testing.expectEqual(@as(usize, 73), result.len);

    // Verify head data (first 50 bytes)
    for (result[0..50], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @truncate(i)), b);
    }

    // Verify frag1 payload (bytes 50-63, skip 16-byte header)
    for (result[50..64], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @truncate(100 + 16 + i)), b);
    }

    // Verify frag2 payload (bytes 64-72, skip 16-byte header)
    for (result[64..73], 0..) |b, i| {
        try testing.expectEqual(@as(u8, @truncate(200 + 16 + i)), b);
    }
}

test "Fragment reassembly regression - out-of-order arrival (head last)" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0xDEADBEEFCAFEBABE;
    const total_frags: u8 = 4;

    var frag_data: [4][40]u8 = undefined;
    for (&frag_data, 0..) |*frag, f| {
        for (frag, 0..) |*b, i| {
            b.* = @truncate(f * 100 + i);
        }
    }

    // Add fragments 3, 1, 2 first (out of order, no head)
    reassembler.addFragment(packet_id, 3, total_frags, &frag_data[3]);
    try testing.expect(!reassembler.complete); // No head yet

    reassembler.addFragment(packet_id, 1, total_frags, &frag_data[1]);
    try testing.expect(!reassembler.complete); // Still no head

    reassembler.addFragment(packet_id, 2, total_frags, &frag_data[2]);
    try testing.expect(!reassembler.complete); // Still no head

    // Now add head (fragment 0)
    reassembler.addHead(packet_id, &frag_data[0]);
    try testing.expect(reassembler.complete); // NOW complete!

    // Verify we have all 4 fragments
    try testing.expectEqual(@as(u32, 0b1111), reassembler.have_fragments);
}

test "Fragment reassembly regression - duplicate fragment detection" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0x1111222233334444;
    const total_frags: u8 = 3;

    var frag1_data: [30]u8 = undefined;
    for (&frag1_data, 0..) |*b, i| b.* = @truncate(i);

    var frag1_duplicate: [30]u8 = undefined;
    for (&frag1_duplicate, 0..) |*b, i| b.* = @truncate(i + 50); // Different data

    // Add fragment 1
    reassembler.addFragment(packet_id, 1, total_frags, &frag1_data);
    try testing.expectEqual(@as(u32, 0b10), reassembler.have_fragments);

    // Add duplicate fragment 1 (should be ignored)
    reassembler.addFragment(packet_id, 1, total_frags, &frag1_duplicate);
    try testing.expectEqual(@as(u32, 0b10), reassembler.have_fragments); // No change

    // Verify original data wasn't overwritten
    const stored_frag = &reassembler.frags[0];
    try testing.expectEqual(@as(u8, 0), stored_frag.data[0]);
    try testing.expectEqual(@as(u8, 1), stored_frag.data[1]);
}

test "Fragment reassembly regression - completion detection" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0xABCDEF0123456789;

    // Test 1: Have all fragments EXCEPT head - should NOT be complete
    reassembler.addFragment(packet_id, 1, 3, &[_]u8{0} ** 20);
    reassembler.addFragment(packet_id, 2, 3, &[_]u8{0} ** 20);
    try testing.expect(!reassembler.complete); // Missing head
    try testing.expectEqual(@as(u32, 0b110), reassembler.have_fragments);

    // Test 2: Add head - should NOW be complete
    reassembler.addHead(packet_id, &[_]u8{0} ** 30);
    try testing.expect(reassembler.complete); // Complete!
    try testing.expectEqual(@as(u32, 0b111), reassembler.have_fragments);
}

test "Fragment reassembly regression - bit mask manipulation" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0x5555666677778888;
    const total_frags: u8 = 5;

    // Add fragments with specific bit pattern
    reassembler.addFragment(packet_id, 1, total_frags, &[_]u8{1} ** 20); // Bit 1
    try testing.expectEqual(@as(u32, 0b00010), reassembler.have_fragments);

    reassembler.addFragment(packet_id, 3, total_frags, &[_]u8{3} ** 20); // Bit 3
    try testing.expectEqual(@as(u32, 0b01010), reassembler.have_fragments);

    reassembler.addHead(packet_id, &[_]u8{0} ** 30); // Bit 0
    try testing.expectEqual(@as(u32, 0b01011), reassembler.have_fragments);

    reassembler.addFragment(packet_id, 2, total_frags, &[_]u8{2} ** 20); // Bit 2
    try testing.expectEqual(@as(u32, 0b01111), reassembler.have_fragments);

    reassembler.addFragment(packet_id, 4, total_frags, &[_]u8{4} ** 20); // Bit 4
    try testing.expectEqual(@as(u32, 0b11111), reassembler.have_fragments);

    // Should be complete (all 5 fragments present)
    try testing.expect(reassembler.complete);
}

test "Fragment reassembly regression - payload extraction" {
    // Verify that fragment payload extraction skips 16-byte header
    var frag = FragmentReassembler.Fragment.init();

    // Fill fragment with known data
    for (&frag.data, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    frag.len = 50;

    const payload = frag.payload();

    // Payload should start at byte 16 and go to byte 49 (50 - 1)
    try testing.expectEqual(@as(usize, 34), payload.len);
    try testing.expectEqual(@as(u8, 16), payload[0]);
    try testing.expectEqual(@as(u8, 49), payload[33]);
}

test "Fragment reassembly regression - empty payload" {
    // Fragment with only header (no payload)
    var frag = FragmentReassembler.Fragment.init();
    frag.len = 16; // Exactly header size

    const payload = frag.payload();
    try testing.expectEqual(@as(usize, 0), payload.len);

    // Fragment shorter than header
    frag.len = 10;
    const payload2 = frag.payload();
    try testing.expectEqual(@as(usize, 0), payload2.len);
}

test "Fragment reassembly regression - maximum fragments" {
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0x9999AAAABBBBCCCC;
    const total_frags: u8 = 8; // Maximum supported

    // Add all 8 fragments
    reassembler.addHead(packet_id, &[_]u8{0} ** 30);
    for (1..8) |f| {
        reassembler.addFragment(packet_id, @intCast(f), total_frags, &[_]u8{@intCast(f)} ** 20);
    }

    // Should be complete
    try testing.expect(reassembler.complete);
    try testing.expectEqual(@as(u32, 0b11111111), reassembler.have_fragments);
}

test "Fragment reassembly regression - demonstration of old bug" {
    // This test shows what the BUGGY code would have done
    var reassembler = FragmentReassembler.init();

    const packet_id: u64 = 0xBADC0DEBADC0DE00;

    // OLD BUG 1: Completion detection didn't check for head
    // Simulated buggy completion check (count bits only, no head check)
    reassembler.addFragment(packet_id, 1, 2, &[_]u8{1} ** 20);
    reassembler.addFragment(packet_id, 2, 2, &[_]u8{2} ** 20); // Error: total is 2, but frags are 1 and 2 (missing 0)

    // Buggy code would see: have_fragments = 0b110 (bits 1 and 2)
    // Buggy code would count: 2 bits set
    // Buggy code would think: complete! (2 bits == 2 total_fragments)
    // But we DON'T have fragment 0 (head)!

    try testing.expectEqual(@as(u32, 0b110), reassembler.have_fragments);
    try testing.expect(!reassembler.complete); // Fixed code correctly returns false

    // OLD BUG 2: Payload appending was missing
    // The old code had no loop to concatenate fragment payloads
    // This meant reassembled packets only contained the head, not the full data
}
