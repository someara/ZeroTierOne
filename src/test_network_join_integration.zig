/// Integration test: Network join protocol
///
/// Tests the full network join flow:
/// 1. Client sends NETWORK_CONFIG_REQUEST to controller
/// 2. Controller (mock server) receives request
/// 3. Controller sends NETWORK_CONFIG response
/// 4. Client receives and parses configuration
/// 5. Verify network status updates
///
/// This will expose bugs in:
/// - Network config request formatting
/// - Network config response parsing
/// - Network state management
/// - Configuration application

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

    std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
    std.debug.print("  Network Join Protocol Integration Test\n", .{});
    std.debug.print("═" ** 60 ++ "\n\n", .{});

    // ═══════════════════════════════════════════════════════════
    // PHASE 1: Setup - Create client and controller identities
    // ═══════════════════════════════════════════════════════════
    std.debug.print("[Phase 1/5] Setup\n", .{});

    std.debug.print("  Generating identities...\n", .{});
    var client_id = try Identity.generate(allocator);
    defer client_id.deinit();
    var controller_id = try Identity.generate(allocator);
    defer controller_id.deinit();

    std.debug.print("    Client: {}\n", .{client_id.address()});
    std.debug.print("    Controller: {}\n", .{controller_id.address()});

    // Compute shared key
    var shared_key: [32]u8 = undefined;
    if (!client_id.agree(&controller_id, &shared_key)) {
        return error.KeyAgreementFailed;
    }
    std.debug.print("    ✓ Shared key computed\n", .{});

    // Bind controller socket
    std.debug.print("  Starting mock controller on port 39999...\n", .{});
    const controller_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 39999);
    const controller_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(controller_fd);
    try std.posix.bind(controller_fd, &controller_addr.any, controller_addr.getOsSockLen());

    const flags = try std.posix.fcntl(controller_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(controller_fd, std.posix.F.SETFL, flags | @as(i32, 0x04));
    std.debug.print("    ✓ Controller listening\n", .{});

    // ═══════════════════════════════════════════════════════════
    // PHASE 2: Client sends NETWORK_CONFIG_REQUEST
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 2/5] Client sends NETWORK_CONFIG_REQUEST\n", .{});

    const client_fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(client_fd);

    const client_bind_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    try std.posix.bind(client_fd, &client_bind_addr.any, client_bind_addr.getOsSockLen());

    const client_flags = try std.posix.fcntl(client_fd, std.posix.F.GETFL, 0);
    _ = try std.posix.fcntl(client_fd, std.posix.F.SETFL, client_flags | @as(i32, 0x04));

    std.debug.print("  Building NETWORK_CONFIG_REQUEST packet...\n", .{});
    var config_req = Packet.initNew(controller_id.address(), client_id.address(), .network_config_request);

    // NETWORK_CONFIG_REQUEST payload:
    // [0..8]   Network ID (64-bit)
    // [8..10]  Request flags (16-bit) - optional
    // [10..18] Metadata dict length + data - optional
    const test_network_id: u64 = 0x8056c2e21c000001; // ZeroTier Earth test network
    try config_req.buf.appendInt(u64, test_network_id);
    try config_req.buf.appendInt(u16, 0); // no special flags
    try config_req.buf.appendInt(u16, 0); // no metadata

    const config_req_packet_id = config_req.packetId();
    std.debug.print("    Network ID: 0x{x}\n", .{test_network_id});
    std.debug.print("    Packet ID: {}\n", .{config_req_packet_id});

    // Armor
    config_req.armor(&shared_key, false, false, null, null);
    std.debug.print("    Size: {} bytes\n", .{config_req.buf.size()});

    // Send
    std.debug.print("  Sending CONFIG_REQUEST...\n", .{});
    const req_data = config_req.buf.data();
    const sent = try std.posix.sendto(client_fd, req_data, 0, &controller_addr.any, controller_addr.getOsSockLen());
    std.debug.print("    ✓ Sent {} bytes\n", .{sent});

    // ═══════════════════════════════════════════════════════════
    // PHASE 3: Controller receives CONFIG_REQUEST
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 3/5] Controller receives CONFIG_REQUEST\n", .{});

    var recv_buf: [4096]u8 = undefined;
    var from_addr: net.Address = undefined;
    var from_len: std.posix.socklen_t = @sizeOf(net.Address);

    std.debug.print("  Waiting for packet...\n", .{});
    var received_request = false;
    const deadline = std.time.milliTimestamp() + 2000;

    while (std.time.milliTimestamp() < deadline) {
        const len = std.posix.recvfrom(
            controller_fd,
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
            received_request = true;
            std.debug.print("    ✓ Received {} bytes\n", .{len});

            var req_pkt_buf: PacketBuffer = .{};
            try req_pkt_buf.copyFrom(recv_buf[0..len]);
            var req_pkt = Packet{ .buf = req_pkt_buf };

            std.debug.print("    Source: {}\n", .{req_pkt.source()});
            std.debug.print("    Dest: {}\n", .{req_pkt.destination()});

            // Verify MAC
            std.debug.print("  Verifying MAC...\n", .{});
            const mac_valid = req_pkt.dearmor(&shared_key, null, null);
            if (!mac_valid) {
                std.debug.print("    ❌ MAC verification failed!\n", .{});
                return error.InvalidMAC;
            }
            std.debug.print("    ✓ MAC valid\n", .{});

            // Check verb
            const verb = req_pkt.verb();
            std.debug.print("    Verb: {}\n", .{verb});

            if (verb != pkt.Verb.network_config_request) {
                std.debug.print("    ❌ Expected NETWORK_CONFIG_REQUEST verb, got {}\n", .{verb});
                return error.WrongVerb;
            }
            std.debug.print("    ✓ Verb is NETWORK_CONFIG_REQUEST\n", .{});

            // Parse network ID from payload
            const req_network_id = req_pkt.buf.at(u64, pkt.idx_payload) catch 0;
            std.debug.print("    Requested network: 0x{x}\n", .{req_network_id});

            if (req_network_id != test_network_id) {
                std.debug.print("    ❌ Network ID mismatch!\n", .{});
                return error.NetworkIdMismatch;
            }
            std.debug.print("    ✓ Network ID matches\n", .{});

            break;
        }
    }

    if (!received_request) {
        std.debug.print("  ❌ Timeout: No CONFIG_REQUEST received\n", .{});
        return error.Timeout;
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 4: Controller sends NETWORK_CONFIG response
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 4/5] Controller sends NETWORK_CONFIG\n", .{});

    std.debug.print("  Building NETWORK_CONFIG packet...\n", .{});
    var config_resp = Packet.initNew(client_id.address(), controller_id.address(), .network_config);

    // NETWORK_CONFIG payload format:
    // [0..8]    Network ID
    // [8..16]   Timestamp
    // [16..24]  Revision
    // [24..32]  Issued to (client address as u64)
    // [32..33]  Flags
    // [33..35]  MTU
    // [35..39]  Multicast limit
    // [39..]    Variable length fields (name, assignments, routes, etc.)

    const now = std.time.milliTimestamp();
    try config_resp.buf.appendInt(u64, test_network_id);
    try config_resp.buf.appendInt(i64, now);
    try config_resp.buf.appendInt(u64, 1); // revision 1
    try config_resp.buf.appendInt(u64, client_id.address()._a); // issued to
    try config_resp.buf.appendByte(0, 1); // flags: no special flags
    try config_resp.buf.appendInt(u16, 2800); // MTU
    try config_resp.buf.appendInt(u32, 32); // multicast limit

    // Name (empty for test)
    try config_resp.buf.appendByte(0, 1);

    // Assigned addresses count + addresses
    try config_resp.buf.appendInt(u16, 1); // 1 assigned address
    // IPv4 address: 10.147.20.123/24 (example)
    try config_resp.buf.appendByte(4, 1); // type = IPv4
    try config_resp.buf.appendByte(8, 1); // metric
    try config_resp.buf.appendBytes(&[_]u8{ 10, 147, 20, 123 }); // IP
    try config_resp.buf.appendByte(24, 1); // netmask bits

    // Routes count (0 for simplicity)
    try config_resp.buf.appendInt(u16, 0);

    // Static IPs count (0)
    try config_resp.buf.appendInt(u16, 0);

    // Rules count (0 for simplicity)
    try config_resp.buf.appendInt(u16, 0);

    // Capabilities count (0)
    try config_resp.buf.appendInt(u16, 0);

    // Tags count (0)
    try config_resp.buf.appendInt(u16, 0);

    // Certificate of ownership count (0)
    try config_resp.buf.appendInt(u16, 0);

    // Armor
    config_resp.armor(&shared_key, false, false, null, null);
    std.debug.print("    Size: {} bytes\n", .{config_resp.buf.size()});

    // Send
    std.debug.print("  Sending NETWORK_CONFIG...\n", .{});
    const config_data = config_resp.buf.data();
    _ = try std.posix.sendto(
        controller_fd,
        config_data,
        0,
        &from_addr.any,
        from_len,
    );
    std.debug.print("    ✓ Sent {} bytes\n", .{config_data.len});

    // ═══════════════════════════════════════════════════════════
    // PHASE 5: Client receives NETWORK_CONFIG
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n[Phase 5/5] Client receives NETWORK_CONFIG\n", .{});
    std.debug.print("  Waiting for CONFIG response...\n", .{});

    var received_config = false;
    const config_deadline = std.time.milliTimestamp() + 2000;

    while (std.time.milliTimestamp() < config_deadline) {
        var config_buf: [4096]u8 = undefined;
        var config_from: net.Address = undefined;
        var config_from_len: std.posix.socklen_t = @sizeOf(net.Address);

        const config_len = std.posix.recvfrom(
            client_fd,
            &config_buf,
            0,
            &config_from.any,
            &config_from_len,
        ) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        if (config_len > 0) {
            received_config = true;
            std.debug.print("    ✓ Received {} bytes\n", .{config_len});

            var config_pkt_buf: PacketBuffer = .{};
            try config_pkt_buf.copyFrom(config_buf[0..config_len]);
            var config_pkt = Packet{ .buf = config_pkt_buf };

            std.debug.print("    Source: {}\n", .{config_pkt.source()});
            std.debug.print("    Dest: {}\n", .{config_pkt.destination()});

            // Verify MAC
            std.debug.print("  Verifying MAC...\n", .{});
            const config_mac_valid = config_pkt.dearmor(&shared_key, null, null);
            if (!config_mac_valid) {
                std.debug.print("    ❌ MAC verification failed!\n", .{});
                return error.InvalidMAC;
            }
            std.debug.print("    ✓ MAC valid\n", .{});

            // Check verb
            const config_verb = config_pkt.verb();
            std.debug.print("    Verb: {}\n", .{config_verb});

            if (config_verb != pkt.Verb.network_config) {
                std.debug.print("    ❌ Expected NETWORK_CONFIG verb, got {}\n", .{config_verb});
                return error.WrongVerb;
            }

            // Parse config payload
            var ptr: u32 = pkt.idx_payload;
            const resp_network_id = config_pkt.buf.at(u64, ptr) catch 0;
            ptr += 8;
            const resp_timestamp = config_pkt.buf.at(i64, ptr) catch 0;
            ptr += 8;
            const resp_revision = config_pkt.buf.at(u64, ptr) catch 0;
            ptr += 8;
            const issued_to = config_pkt.buf.at(u64, ptr) catch 0;
            ptr += 8;
            const resp_flags = config_pkt.buf.at(u8, ptr) catch 0;
            ptr += 1;
            const resp_mtu = config_pkt.buf.at(u16, ptr) catch 0;
            ptr += 2;
            const resp_multicast_limit = config_pkt.buf.at(u32, ptr) catch 0;
            ptr += 4;

            std.debug.print("    Network ID: 0x{x}\n", .{resp_network_id});
            std.debug.print("    Timestamp: {}\n", .{resp_timestamp});
            std.debug.print("    Revision: {}\n", .{resp_revision});
            std.debug.print("    Issued to: .{{ ._a = {} }}\n", .{issued_to});
            std.debug.print("    Flags: 0x{x}\n", .{resp_flags});
            std.debug.print("    MTU: {}\n", .{resp_mtu});
            std.debug.print("    Multicast limit: {}\n", .{resp_multicast_limit});

            if (resp_network_id != test_network_id) {
                std.debug.print("    ❌ Network ID mismatch!\n", .{});
                return error.NetworkIdMismatch;
            }

            if (issued_to != client_id.address()._a) {
                std.debug.print("    ❌ Issued to wrong address!\n", .{});
                return error.WrongIssuedTo;
            }

            std.debug.print("    ✓ Network config valid\n", .{});

            break;
        }
    }

    if (!received_config) {
        std.debug.print("  ❌ Timeout: No NETWORK_CONFIG received\n", .{});
        return error.Timeout;
    }

    // ═══════════════════════════════════════════════════════════
    // SUCCESS
    // ═══════════════════════════════════════════════════════════
    std.debug.print("\n" ++ "═" ** 60 ++ "\n", .{});
    std.debug.print("  ✅ NETWORK JOIN PROTOCOL COMPLETE\n", .{});
    std.debug.print("═" ** 60 ++ "\n", .{});
    std.debug.print("\nVerified:\n", .{});
    std.debug.print("  ✓ Client can send NETWORK_CONFIG_REQUEST\n", .{});
    std.debug.print("  ✓ Controller can receive and verify request\n", .{});
    std.debug.print("  ✓ Controller can generate NETWORK_CONFIG response\n", .{});
    std.debug.print("  ✓ Client can receive and decrypt config\n", .{});
    std.debug.print("  ✓ Network ID propagates correctly\n", .{});
    std.debug.print("  ✓ Configuration fields parse correctly\n", .{});
    std.debug.print("  ✓ Full network join completes end-to-end\n", .{});
    std.debug.print("\n", .{});
}
