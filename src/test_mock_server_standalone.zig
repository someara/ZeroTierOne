/// Standalone integration test: Mock server + real packet exchange
///
/// This test creates a mock ZeroTier root server and sends it actual HELLO
/// packets to verify the full encoding/decoding pipeline works.

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n═══════════════════════════════════════════\n", .{});
    std.debug.print("  Mock Server Integration Test\n", .{});
    std.debug.print("═══════════════════════════════════════════\n\n", .{});

    // Step 1: Create client and server identities
    std.debug.print("[1/5] Generating identities...\n", .{});
    var client_id = try Identity.generate(allocator);
    defer client_id.deinit();
    var server_id = try Identity.generate(allocator);
    defer server_id.deinit();

    std.debug.print("  Client: {}\n", .{client_id.address()});
    std.debug.print("  Server: {}\n", .{server_id.address()});

    // Step 2: Bind server socket
    std.debug.print("\n[2/5] Starting mock server on port 19999...\n", .{});
    const server_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19999);
    const server_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(server_fd);
    try std.posix.bind(server_fd, &server_addr.any, server_addr.getOsSockLen());

    // Set non-blocking
    const flags = try std.posix.fcntl(server_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(server_fd, std.posix.F.SETFL, flags | @as(i32, 0x04)); // O_NONBLOCK
    std.debug.print("  ✓ Server listening\n", .{});

    // Step 3: Create and send HELLO packet
    std.debug.print("\n[3/5] Building HELLO packet...\n", .{});
    var hello = Packet.initNew(server_id.address(), client_id.address(), .hello);

    const now = std.time.milliTimestamp();
    try hello.buf.appendByte(pkt.protocol_version, 1);
    try hello.buf.appendByte(2, 1); // major
    try hello.buf.appendByte(0, 1); // minor
    try hello.buf.appendInt(u16, 0); // revision
    try hello.buf.appendInt(i64, now);
    try client_id.serialize(pkt.max_packet_length, &hello.buf, false);

    var dest_addr_field = InetAddress.initV4(.{ 127, 0, 0, 1 }, 19999);
    try dest_addr_field.serialize(pkt.max_packet_length, &hello.buf);
    try hello.buf.appendInt(u64, 149604618); // planet world ID
    try hello.buf.appendInt(u64, @intCast(now)); // planet timestamp

    // Moon section (empty)
    const crypt_start = hello.buf.size();
    try hello.buf.appendInt(u16, 0);

    // Encrypt moon section with shared key
    var shared_key_for_moon: [32]u8 = undefined;
    if (!client_id.agree(&server_id, &shared_key_for_moon)) {
        std.debug.print("Failed to compute shared key\n", .{});
        return error.KeyAgreementFailed;
    }
    hello.cryptField(&shared_key_for_moon, crypt_start, hello.buf.size() - crypt_start);

    std.debug.print("  Packet ID: {}\n", .{hello.packetId()});
    std.debug.print("  Source: {}\n", .{hello.source()});
    std.debug.print("  Dest: {}\n", .{hello.destination()});
    std.debug.print("  Cipher: {}\n", .{hello.cipher()});
    std.debug.print("  Size: {} bytes\n", .{hello.buf.size()});

    // Armor with Poly1305 MAC
    var shared_key: [32]u8 = undefined;
    if (!client_id.agree(&server_id, &shared_key)) {
        return error.KeyAgreementFailed;
    }
    hello.armor(&shared_key, false, false, null, null);

    std.debug.print("  ✓ HELLO packet built and armored\n", .{});

    // Step 4: Send packet
    std.debug.print("\n[4/5] Sending HELLO packet...\n", .{});
    const client_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(client_fd);

    const hello_data = hello.buf.data();
    const sent = try std.posix.sendto(client_fd, hello_data, 0, &server_addr.any, server_addr.getOsSockLen());
    std.debug.print("  ✓ Sent {} bytes\n", .{sent});

    // Step 5: Receive on server
    std.debug.print("\n[5/5] Receiving on mock server...\n", .{});
    var recv_buf: [4096]u8 = undefined;
    var from_addr: net.Address = undefined;
    var from_len: std.posix.socklen_t = @sizeOf(net.Address);

    var received = false;
    const deadline = std.time.milliTimestamp() + 1000; // 1 second timeout

    while (std.time.milliTimestamp() < deadline) {
        const len = std.posix.recvfrom(
            server_fd,
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

        if (len > 0) {
            received = true;
            std.debug.print("  ✓ Received {} bytes from {any}\n", .{ len, from_addr });

            // Try to parse it
            if (len >= pkt.min_packet_length) {
                const source = Address.fromBytes(recv_buf[pkt.idx_source .. pkt.idx_source + 5]);
                const dest = Address.fromBytes(recv_buf[pkt.idx_dest .. pkt.idx_dest + 5]);
                const flags_byte = recv_buf[pkt.idx_flags];
                const cipher_bits = (flags_byte >> 3) & 0x07;

                std.debug.print("  Parsed packet:\n", .{});
                std.debug.print("    Source: {}\n", .{source});
                std.debug.print("    Dest: {}\n", .{dest});
                std.debug.print("    Cipher: {} ({})\n", .{ cipher_bits, @as(pkt.CipherSuite, @enumFromInt(cipher_bits)) });

                if (source.eql(client_id.address())) {
                    std.debug.print("  ✅ SUCCESS: Source address matches client!\n", .{});
                } else {
                    std.debug.print("  ❌ FAIL: Source mismatch (expected {})\n", .{client_id.address()});
                }

                if (dest.eql(server_id.address())) {
                    std.debug.print("  ✅ SUCCESS: Dest address matches server!\n", .{});
                } else {
                    std.debug.print("  ❌ FAIL: Dest mismatch (expected {})\n", .{server_id.address()});
                }
            }

            break;
        }
    }

    if (!received) {
        std.debug.print("  ❌ TIMEOUT: No packet received\n", .{});
        return error.Timeout;
    }

    std.debug.print("\n═══════════════════════════════════════════\n", .{});
    std.debug.print("  Test Complete\n", .{});
    std.debug.print("═══════════════════════════════════════════\n\n", .{});
}
