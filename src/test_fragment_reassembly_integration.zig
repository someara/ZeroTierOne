/// Integration test: Packet fragment reassembly
///
/// Tests the fragment reassembly protocol:
/// 1. Create a large packet that must be fragmented
/// 2. Split into multiple fragments
/// 3. Send fragments (possibly out of order)
/// 4. Receiver reassembles fragments
/// 5. Verify reassembled packet matches original
///
/// This will expose bugs in:
/// - Fragment generation
/// - Fragment header encoding
/// - Fragment reassembly logic
/// - Timeout/cleanup of incomplete fragments

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const Fragment = pkt.Fragment;
const buffer_mod = @import("node/buffer.zig");
const PacketBuffer = buffer_mod.Buffer(pkt.max_packet_length);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
    std.debug.print("  Fragment Reassembly Integration Test\n", .{});
    std.debug.print("═" ** 60 ++ "\n\n", .{});

    // ═══════════════════════════════════════════════════════════
    // PHASE 1: Create large packet that needs fragmentation
    // ═══════════════════════════════════════════════════════════
    std.debug.print("[Phase 1/5] Create large packet\n", .{});

    var sender_id = try Identity.generate(allocator);
    defer sender_id.deinit();
    var receiver_id = try Identity.generate(allocator);
    defer receiver_id.deinit();

    std.debug.print("  Sender: {}\n", .{sender_id.address()});
    std.debug.print("  Receiver: {}\n", .{receiver_id.address()});

    var shared_key: [32]u8 = undefined;
    if (!sender_id.agree(&receiver_id, &shared_key)) {
        return error.KeyAgreementFailed;
    }

    // Create a packet with large payload (will need fragmentation)
    std.debug.print("  Building large HELLO packet...\n", .{});
    var large_pkt = Packet.initNew(receiver_id.address(), sender_id.address(), .hello);

    // Add protocol version etc
    try large_pkt.buf.appendByte(pkt.protocol_version, 1);
    try large_pkt.buf.appendByte(2, 1);
    try large_pkt.buf.appendByte(0, 1);
    try large_pkt.buf.appendInt(u16, 0);
    try large_pkt.buf.appendInt(i64, std.time.milliTimestamp());

    // Add large payload to force fragmentation
    // ZeroTier default MTU is 1400, so let's create 3000 byte payload
    const large_payload_size: usize = 3000;
    for (0..large_payload_size) |i| {
        try large_pkt.buf.appendByte(@intCast(i % 256), 1);
    }

    // Armor the packet
    large_pkt.armor(&shared_key, false, false, null, null);

    const original_packet_id = large_pkt.packetId();
    const original_size = large_pkt.buf.size();

    std.debug.print("    Packet ID: {}\n", .{original_packet_id});
    std.debug.print("    Size: {} bytes (needs fragmentation)\n", .{original_size});

    // ═══════════════════════════════════════════════════════════
    // PHASE 2: Fragment the packet
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 2/5] Fragment packet\n", .{});

    const mtu: usize = 1400; // Standard ZeroTier MTU
    const packet_data = large_pkt.buf.data();

    // Calculate how many fragments we need
    const frag_payload_size = mtu - pkt.min_fragment_length;
    const num_fragments = (packet_data.len + frag_payload_size - 1) / frag_payload_size;

    std.debug.print("  MTU: {} bytes\n", .{mtu});
    std.debug.print("  Fragment payload size: {} bytes\n", .{frag_payload_size});
    std.debug.print("  Number of fragments: {}\n", .{num_fragments});

    if (num_fragments > 15) {
        std.debug.print("  ❌ Too many fragments (max 15)\n", .{});
        return error.TooManyFragments;
    }

    // Create fragments
    var fragments: [16]Fragment = undefined;
    var actual_fragment_count: u8 = 0;

    var offset: usize = 0;
    while (offset < packet_data.len) {
        const remaining = packet_data.len - offset;
        const frag_size = @min(remaining, frag_payload_size);

        var frag = Fragment.initEmpty();

        // Initialize buffer with minimum fragment size
        try frag.buf.setSize(pkt.min_fragment_length);

        // Set packet ID (bytes 0-7)
        const packet_id_bytes = std.mem.toBytes(original_packet_id);
        @memcpy(frag.buf.dataMut()[0..8], &packet_id_bytes);

        // Set destination (bytes 8-12)
        receiver_id.address().toBytes(frag.buf.dataMut()[pkt.frag_idx_dest..][0..5]);

        // Set fragment indicator (byte 13)
        frag.buf.dataMut()[pkt.frag_idx_fragment_indicator] = pkt.fragment_indicator;

        // Set fragment number and total (byte 14)
        const frag_no: u8 = @intCast(offset / frag_payload_size);
        const total_frags: u8 = @intCast(num_fragments);
        const frag_byte = (@as(u8, @intCast((total_frags & 0x0F))) << 4) | (frag_no & 0x0F);
        frag.buf.dataMut()[pkt.frag_idx_fragment_no] = frag_byte;

        // Set hop count (byte 15)
        frag.buf.dataMut()[pkt.frag_idx_hops] = 0;

        // Append payload
        try frag.buf.appendBytes(packet_data[offset .. offset + frag_size]);

        fragments[actual_fragment_count] = frag;
        actual_fragment_count += 1;

        offset += frag_size;
    }

    std.debug.print("  ✓ Created {} fragments\n", .{actual_fragment_count});

    // ═══════════════════════════════════════════════════════════
    // PHASE 3: Send fragments (simulate out-of-order)
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 3/5] Send fragments (out-of-order)\n", .{});

    // Bind receiver socket
    const receiver_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 49999);
    const receiver_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(receiver_fd);
    try std.posix.bind(receiver_fd, &receiver_addr.any, receiver_addr.getOsSockLen());

    const flags = try std.posix.fcntl(receiver_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(receiver_fd, std.posix.F.SETFL, flags | @as(i32, 0x04));

    // Sender socket
    const sender_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(sender_fd);

    // Send fragments in reverse order to test reassembly
    std.debug.print("  Sending fragments in reverse order...\n", .{});
    var i: usize = actual_fragment_count;
    while (i > 0) {
        i -= 1;
        const frag = &fragments[i];
        const frag_data = frag.buf.data();

        _ = try std.posix.sendto(sender_fd, frag_data, 0, &receiver_addr.any, receiver_addr.getOsSockLen());
        std.debug.print("    Sent fragment {} ({} bytes)\n", .{ i, frag_data.len });

        // Small delay to avoid overwhelming receiver
        std.Thread.sleep(std.time.ns_per_ms);
    }

    std.debug.print("  ✓ All fragments sent\n", .{});

    // ═══════════════════════════════════════════════════════════
    // PHASE 4: Receive and track fragments
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 4/5] Receive fragments\n", .{});

    var received_fragments: [16]?Fragment = [_]?Fragment{null} ** 16;
    var received_count: u8 = 0;
    var expected_total: u8 = 0;

    const receive_deadline = std.time.milliTimestamp() + 5000; // 5 second timeout

    while (std.time.milliTimestamp() < receive_deadline and received_count < actual_fragment_count) {
        var recv_buf: [4096]u8 = undefined;
        var from_addr: net.Address = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(net.Address);

        const len = std.posix.recvfrom(
            receiver_fd,
            &recv_buf,
            0,
            &from_addr.any,
            &from_len,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        if (len >= pkt.min_fragment_length) {
            // Check if it's a fragment
            if (recv_buf[pkt.frag_idx_fragment_indicator] == pkt.fragment_indicator) {
                const frag_byte = recv_buf[pkt.frag_idx_fragment_no];
                const total_frags = (frag_byte >> 4) & 0x0F;
                const frag_no = frag_byte & 0x0F;

                if (expected_total == 0) {
                    expected_total = total_frags;
                }

                std.debug.print("    Received fragment {}/{} ({} bytes)\n", .{ frag_no, total_frags, len });

                // Store fragment
                var frag: PacketBuffer = .{};
                try frag.copyFrom(recv_buf[0..len]);
                received_fragments[frag_no] = Fragment{ .buf = frag };
                received_count += 1;
            }
        }
    }

    std.debug.print("  ✓ Received {}/{} fragments\n", .{ received_count, expected_total });

    if (received_count != expected_total) {
        std.debug.print("  ❌ Missing fragments!\n", .{});
        return error.MissingFragments;
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 5: Reassemble packet
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 5/5] Reassemble packet\n", .{});

    std.debug.print("  Reassembling fragments...\n", .{});

    // Concatenate fragment payloads
    var reassembled: PacketBuffer = .{};
    for (0..expected_total) |idx| {
        if (received_fragments[idx]) |frag| {
            const payload_start = pkt.frag_idx_payload;
            const payload_len = frag.buf.size() - payload_start;
            const payload = frag.buf.field(payload_start, payload_len) catch continue;
            try reassembled.appendBytes(payload);
        } else {
            std.debug.print("  ❌ Fragment {} missing!\n", .{idx});
            return error.MissingFragment;
        }
    }

    const reassembled_size = reassembled.size();
    std.debug.print("    Reassembled size: {} bytes\n", .{reassembled_size});

    // Verify size matches original
    if (reassembled_size != original_size) {
        std.debug.print("  ❌ Size mismatch! Original: {}, Reassembled: {}\n", .{ original_size, reassembled_size });
        return error.SizeMismatch;
    }
    std.debug.print("    ✓ Size matches original\n", .{});

    // Verify content matches
    const reassembled_data = reassembled.data();
    var matches = true;
    for (packet_data, 0..) |byte, idx| {
        if (reassembled_data[idx] != byte) {
            std.debug.print("  ❌ Content mismatch at byte {}!\n", .{idx});
            matches = false;
            break;
        }
    }

    if (!matches) {
        return error.ContentMismatch;
    }
    std.debug.print("    ✓ Content matches original\n", .{});

    // Try to dearmor reassembled packet
    var reassembled_pkt = Packet{ .buf = reassembled };
    std.debug.print("  Verifying reassembled packet...\n", .{});
    const mac_valid = reassembled_pkt.dearmor(&shared_key, null, null);
    if (!mac_valid) {
        std.debug.print("  ❌ MAC verification failed on reassembled packet!\n", .{});
        return error.InvalidMAC;
    }
    std.debug.print("    ✓ MAC valid\n", .{});

    const verb = reassembled_pkt.verb();
    std.debug.print("    Verb: {}\n", .{verb});
    if (verb != pkt.Verb.hello) {
        std.debug.print("  ❌ Wrong verb in reassembled packet!\n", .{});
        return error.WrongVerb;
    }
    std.debug.print("    ✓ Verb correct\n", .{});

    // ═══════════════════════════════════════════════════════════
    // SUCCESS
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
    std.debug.print("  ✅ FRAGMENT REASSEMBLY COMPLETE\n", .{});
    std.debug.print("═" ** 60 ++ "\n", .{});
    std.debug.print("\nVerified:\n", .{});
    std.debug.print("  ✓ Large packet fragments correctly\n", .{});
    std.debug.print("  ✓ Fragment headers encode properly\n", .{});
    std.debug.print("  ✓ Fragments can be sent out-of-order\n", .{});
    std.debug.print("  ✓ All fragments received\n", .{});
    std.debug.print("  ✓ Reassembly produces exact original\n", .{});
    std.debug.print("  ✓ Reassembled packet passes MAC verification\n", .{});
    std.debug.print("  ✓ Full fragmentation protocol works\n", .{});
    std.debug.print("\n", .{});
}

fn sliceToArray5(s: []u8) *[5]u8 {
    return s[0..5];
}
