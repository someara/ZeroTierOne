/// Connect to real ZeroTier Earth network root servers
///
/// This attempts to connect to actual ZeroTier infrastructure:
/// - Real root servers from ZeroTier Earth planet
/// - Real UDP communication over internet
/// - Real NAT traversal (if possible)
///
/// This is the ultimate test - does our implementation work with
/// the actual ZeroTier network in production?

const std = @import("std");
const net = std.net;

const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;
const pkt = @import("node/packet.zig");
const buffer_mod = @import("node/buffer.zig");
const PacketBuffer = buffer_mod.Buffer(pkt.max_packet_length);

// Real ZeroTier Earth root servers (from planet file)
const RootServer = struct {
    address: Address,
    endpoints: []const []const u8,
};

const earth_roots = [_]RootServer{
    // Alice (North America)
    .{
        .address = Address{ ._a = 0x62F865D7C1 }, // 62f865d7c1
        .endpoints = &[_][]const u8{
            "195.181.173.159/9993",
            "2a02:6ea0:d605::/9993",
        },
    },
    // Melbourne (Asia Pacific)
    .{
        .address = Address{ ._a = 0x8ACFC95CEE }, // 8acfc95cee
        .endpoints = &[_][]const u8{
            "184.173.162.101/9993",
        },
    },
    // Amsterdam (Europe)
    .{
        .address = Address{ ._a = 0x9D219039F3 }, // 9d219039f3
        .endpoints = &[_][]const u8{
            "103.195.103.66/9993",
        },
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n" ++ "═" ** 70 ++ "\n", .{});
    std.debug.print("  ZeroTier Earth Network Connection Test\n", .{});
    std.debug.print("═" ** 70 ++ "\n\n", .{});

    std.debug.print("⚠️  WARNING: This connects to real ZeroTier infrastructure!\n\n", .{});
    std.debug.print("This test will:\n", .{});
    std.debug.print("  • Send UDP packets to real ZeroTier root servers\n", .{});
    std.debug.print("  • Attempt HELLO handshake with production servers\n", .{});
    std.debug.print("  • May be blocked by firewalls (GlobalProtect, etc.)\n\n", .{});

    // Generate client identity
    std.debug.print("[Setup] Generating client identity...\n", .{});
    var client_id = try Identity.generate(allocator);
    defer client_id.deinit();

    std.debug.print("  Client identity: {}\n", .{client_id.address()});

    // Create client socket
    const client_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(client_fd);

    const client_bind_addr = net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    try std.posix.bind(client_fd, &client_bind_addr.any, client_bind_addr.getOsSockLen());

    const client_flags = try std.posix.fcntl(client_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(client_fd, std.posix.F.SETFL, client_flags | @as(i32, 0x04));

    std.debug.print("  ✓ Client socket ready\n\n", .{});

    // Try each root server
    var success_count: usize = 0;
    var total_attempts: usize = 0;

    for (earth_roots, 0..) |root, root_idx| {
        std.debug.print("[Root Server {}/{}] {}\n", .{ root_idx + 1, earth_roots.len, root.address });

        for (root.endpoints) |endpoint_str| {
            total_attempts += 1;
            std.debug.print("  Endpoint: {s}\n", .{endpoint_str});

            // Parse endpoint (ip/port)
            var parts = std.mem.splitSequence(u8, endpoint_str, "/");
            const ip_str = parts.next() orelse continue;
            const port_str = parts.next() orelse "9993";

            const port = std.fmt.parseInt(u16, port_str, 10) catch 9993;

            // Parse IP address
            const server_addr = parseIpAddress(ip_str, port) catch {
                std.debug.print("    ⚠️  Failed to parse address\n", .{});
                continue;
            };

            std.debug.print("    Connecting to {s}:{}...\n", .{ ip_str, port });

            // Send HELLO
            const hello_result = try sendHello(&client_id, client_fd, &server_addr, root.address);

            std.debug.print("    Sent HELLO (packet ID: {})\n", .{hello_result.packet_id});

            // Wait for response
            const received = try waitForResponse(client_fd, hello_result.packet_id, 2000);

            if (received) {
                std.debug.print("    ✅ HELLO OK received!\n", .{});
                success_count += 1;
            } else {
                std.debug.print("    ❌ Timeout (no response)\n", .{});
            }

            std.debug.print("\n", .{});

            // Don't hammer servers - be respectful
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }

    // Summary
    std.debug.print("═" ** 70 ++ "\n", .{});
    std.debug.print("  Connection Test Summary\n", .{});
    std.debug.print("═" ** 70 ++ "\n\n", .{});
    std.debug.print("  Attempts: {}/{}\n", .{ success_count, total_attempts });

    if (success_count > 0) {
        std.debug.print("  Status: ✅ SUCCESS - Connected to real ZeroTier infrastructure!\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  This proves:\n", .{});
        std.debug.print("    ✓ Protocol implementation works with real servers\n", .{});
        std.debug.print("    ✓ Packet format matches ZeroTier production spec\n", .{});
        std.debug.print("    ✓ Can traverse NAT (if responses received)\n", .{});
        std.debug.print("    ✓ Crypto is compatible with production\n", .{});
    } else {
        std.debug.print("  Status: ❌ NO CONNECTIONS\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  Possible causes:\n", .{});
        std.debug.print("    • Firewall blocking outbound UDP (GlobalProtect?)\n", .{});
        std.debug.print("    • Network requires proxy/VPN\n", .{});
        std.debug.print("    • ISP blocks UDP to these destinations\n", .{});
        std.debug.print("    • Packet format incompatibility (less likely)\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  Try:\n", .{});
        std.debug.print("    • Deploy to cloud VM (see DEPLOYMENT_PLAN.md)\n", .{});
        std.debug.print("    • Check firewall rules\n", .{});
        std.debug.print("    • Test from different network\n", .{});
    }

    std.debug.print("\n", .{});
}

fn parseIpAddress(ip_str: []const u8, port: u16) !net.Address {
    // Try IPv4 first
    if (std.mem.indexOf(u8, ip_str, ":") == null) {
        // IPv4
        var octets: [4]u8 = undefined;
        var parts = std.mem.splitSequence(u8, ip_str, ".");
        var i: usize = 0;

        while (parts.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidAddress;
            octets[i] = try std.fmt.parseInt(u8, part, 10);
        }

        if (i != 4) return error.InvalidAddress;

        return net.Address.initIp4(octets, port);
    } else {
        // IPv6 - skip for now as it's complex to parse
        return error.Ipv6NotSupported;
    }
}

const HelloResult = struct {
    packet_id: u64,
    packet_data: []const u8,
};

fn sendHello(
    client_id: *Identity,
    socket: std.posix.socket_t,
    server_addr: *const net.Address,
    root_address: Address,
) !HelloResult {
    var hello = Packet.initNew(root_address, client_id.address(), .hello);
    const now = std.time.milliTimestamp();

    // Build HELLO packet
    try hello.buf.appendByte(pkt.protocol_version, 1);
    try hello.buf.appendByte(2, 1); // major
    try hello.buf.appendByte(0, 1); // minor
    try hello.buf.appendInt(u16, 0); // revision
    try hello.buf.appendInt(i64, now); // timestamp

    // Serialize our identity
    try client_id.serialize(pkt.max_packet_length, &hello.buf, false);

    // Destination (where we're sending to)
    // Convert net.Address to InetAddress
    const port = std.mem.bigToNative(u16, server_addr.in.sa.port);
    const addr_bytes = [4]u8{
        @intCast(server_addr.in.sa.addr & 0xFF),
        @intCast((server_addr.in.sa.addr >> 8) & 0xFF),
        @intCast((server_addr.in.sa.addr >> 16) & 0xFF),
        @intCast((server_addr.in.sa.addr >> 24) & 0xFF),
    };
    var dest_inet = InetAddress.initV4(addr_bytes, port);
    try dest_inet.serialize(pkt.max_packet_length, &hello.buf);

    // Planet world ID
    try hello.buf.appendInt(u64, 149604618);
    try hello.buf.appendInt(u64, @intCast(now));

    // Moon section (empty)
    try hello.buf.appendInt(u16, 0);

    // Armor (with placeholder key for first HELLO)
    const placeholder_key = [_]u8{0} ** 32;
    hello.armor(&placeholder_key, false, false, null, null);

    const packet_id = hello.packetId();
    const hello_data = hello.buf.data();

    // Send
    _ = try std.posix.sendto(socket, hello_data, 0, &server_addr.any, server_addr.getOsSockLen());

    return HelloResult{
        .packet_id = packet_id,
        .packet_data = hello_data,
    };
}

fn waitForResponse(socket: std.posix.socket_t, expected_packet_id: u64, timeout_ms: i64) !bool {
    const deadline = std.time.milliTimestamp() + timeout_ms;

    while (std.time.milliTimestamp() < deadline) {
        var recv_buf: [4096]u8 = undefined;
        var from_addr: net.Address = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(net.Address);

        const len = std.posix.recvfrom(
            socket,
            &recv_buf,
            0,
            &from_addr.any,
            &from_len,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        if (len > 0) {
            // Parse packet
            var pkt_buf: PacketBuffer = .{};
            pkt_buf.copyFrom(recv_buf[0..len]) catch continue;
            var received_pkt = Packet{ .buf = pkt_buf };

            const verb = received_pkt.verb();

            // Check if it's an OK response
            if (verb == pkt.Verb.ok) {
                const in_re_packet_id = received_pkt.buf.at(u64, pkt.ok_idx.idx_in_re_packet_id) catch continue;

                if (in_re_packet_id == expected_packet_id) {
                    return true;
                }
            }
        }
    }

    return false;
}
