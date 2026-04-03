/// Debug version of Earth connection test - shows packet hex dump
///
/// This helps us compare our packets with what C++ zerotier-one sends

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const buffer_mod = @import("node/buffer.zig");
const PacketBuffer = buffer_mod.Buffer(pkt.max_packet_length);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "═" ** 70 ++ "\n", .{});
    std.debug.print("  ZeroTier Earth Debug Test\n", .{});
    std.debug.print("═" ** 70 ++ "\n\n", .{});

    // Generate client identity
    std.debug.print("[Setup] Generating client identity...\n", .{});
    var client_id = try Identity.generate(allocator);
    defer client_id.deinit();

    std.debug.print("  Client identity: {}\n", .{client_id.address()});
    std.debug.print("  Client address (hex): 0x{x}\n\n", .{client_id.address()._a});

    // Create socket
    const client_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(client_fd);

    const client_bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    try std.posix.bind(client_fd, &client_bind_addr.any, client_bind_addr.getOsSockLen());

    const client_flags = try std.posix.fcntl(client_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(client_fd, std.posix.F.SETFL, client_flags | @as(i32, 0x04));

    // Test with first root server
    const root_address = Address{ ._a = 0x62F865D7C1 }; // Alice
    const server_addr = net.Address.initIp4(.{ 195, 181, 173, 159 }, 9993);

    std.debug.print("[Test] Connecting to Alice (195.181.173.159:9993)\n", .{});
    std.debug.print("  Root address: {}\n", .{root_address});
    std.debug.print("  Root address (hex): 0x{x}\n\n", .{root_address._a});

    // Build HELLO packet
    var hello = Packet.initNew(root_address, client_id.address(), .hello);
    const now = std.time.milliTimestamp();

    try hello.buf.appendByte(pkt.protocol_version, 1);
    try hello.buf.appendByte(2, 1); // major
    try hello.buf.appendByte(0, 1); // minor
    try hello.buf.appendInt(u16, 0); // revision
    try hello.buf.appendInt(i64, now);

    // Serialize identity
    try client_id.serialize(pkt.max_packet_length, &hello.buf, false);

    // Destination
    const port = std.mem.bigToNative(u16, server_addr.in.sa.port);
    const addr_bytes = [4]u8{
        @intCast(server_addr.in.sa.addr & 0xFF),
        @intCast((server_addr.in.sa.addr >> 8) & 0xFF),
        @intCast((server_addr.in.sa.addr >> 16) & 0xFF),
        @intCast((server_addr.in.sa.addr >> 24) & 0xFF),
    };
    var dest_inet = InetAddress.initV4(addr_bytes, port);
    try dest_inet.serialize(pkt.max_packet_length, &hello.buf);

    // Planet
    try hello.buf.appendInt(u64, 149604618);
    try hello.buf.appendInt(u64, @intCast(now));

    // Moons
    try hello.buf.appendInt(u16, 0);

    // Armor
    const placeholder_key = [_]u8{0} ** 32;
    hello.armor(&placeholder_key, false, false, null, null);

    const packet_id = hello.packetId();
    const hello_data = hello.buf.data();

    std.debug.print("[Packet] Built HELLO\n", .{});
    std.debug.print("  Packet ID: {}\n", .{packet_id});
    std.debug.print("  Size: {} bytes\n", .{hello_data.len});
    std.debug.print("  Verb: {}\n", .{hello.verb()});
    std.debug.print("  Source: {}\n", .{hello.source()});
    std.debug.print("  Destination: {}\n\n", .{hello.destination()});

    // Hex dump
    std.debug.print("[Hex Dump] First 64 bytes:\n", .{});
    hexDump(hello_data[0..@min(64, hello_data.len)]);

    std.debug.print("\n[Hex Dump] Full packet:\n", .{});
    hexDump(hello_data);

    // Send
    std.debug.print("\n[Sending] UDP to 195.181.173.159:9993\n", .{});
    const sent = try std.posix.sendto(client_fd, hello_data, 0, &server_addr.any, server_addr.getOsSockLen());
    std.debug.print("  ✓ Sent {} bytes\n", .{sent});

    // Wait for response
    std.debug.print("\n[Waiting] 5 second timeout...\n", .{});
    const deadline = std.time.milliTimestamp() + 5000;

    while (std.time.milliTimestamp() < deadline) {
        var recv_buf: [4096]u8 = undefined;
        var from_addr: net.Address = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(net.Address);

        const len = std.posix.recvfrom(
            client_fd,
            &recv_buf,
            0,
            &from_addr.any,
            &from_len,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        if (len > 0) {
            std.debug.print("\n✅ RECEIVED RESPONSE!\n", .{});
            std.debug.print("  Size: {} bytes\n", .{len});
            std.debug.print("  From: {}:{}\n", .{
                from_addr.in.sa.addr,
                std.mem.bigToNative(u16, from_addr.in.sa.port),
            });

            std.debug.print("\n[Response Hex Dump]:\n", .{});
            hexDump(recv_buf[0..len]);

            // Try to parse
            var pkt_buf: PacketBuffer = .{};
            pkt_buf.copyFrom(recv_buf[0..len]) catch {
                std.debug.print("\n❌ Failed to parse response\n", .{});
                return;
            };

            var response = Packet{ .buf = pkt_buf };
            std.debug.print("\n[Response Parsed]:\n", .{});
            std.debug.print("  Verb: {}\n", .{response.verb()});
            std.debug.print("  Source: {}\n", .{response.source()});
            std.debug.print("  Dest: {}\n", .{response.destination()});

            return;
        }
    }

    std.debug.print("\n❌ TIMEOUT - No response\n", .{});
}

fn hexDump(data: []const u8) void {
    var i: usize = 0;
    while (i < data.len) : (i += 16) {
        std.debug.print("  {x:0>4}: ", .{i});

        // Hex bytes
        var j: usize = 0;
        while (j < 16) : (j += 1) {
            if (i + j < data.len) {
                std.debug.print("{x:0>2} ", .{data[i + j]});
            } else {
                std.debug.print("   ", .{});
            }
        }

        std.debug.print(" |", .{});

        // ASCII
        j = 0;
        while (j < 16 and i + j < data.len) : (j += 1) {
            const c = data[i + j];
            if (c >= 32 and c <= 126) {
                std.debug.print("{c}", .{c});
            } else {
                std.debug.print(".", .{});
            }
        }

        std.debug.print("|\n", .{});
    }
}
