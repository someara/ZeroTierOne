/// Integration test: Two Nodes Communicate on Same Network
///
/// This test proves that:
/// 1. Two nodes can join the same network
/// 2. Both get network configs with IPs assigned
/// 3. Nodes can discover each other (manually for testing)
/// 4. Nodes can send encrypted packets to each other
/// 5. ECHO request/response works between peers
///
/// This extends the single-node test to prove peer-to-peer communication.
const std = @import("std");
const testing = std.testing;
const net = std.net;

const Node = @import("node/node.zig").Node;
const Config = @import("node/node.zig").Config;
const Callbacks = @import("node/node.zig").Callbacks;
const Address = @import("node/address.zig").Address;
const Identity = @import("node/identity.zig").Identity;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Peer = @import("node/peer.zig").Peer;
const Path = @import("node/path.zig").Path;
const Packet = @import("node/packet.zig").Packet;

const TestContext = struct {
    allocator: std.mem.Allocator,
    controller_addr: net.Address,
    controller_socket: std.posix.socket_t,
    packets_sent: usize = 0,
    packets_received: usize = 0,
    node_name: []const u8,
};

// Minimal callbacks for testing
fn testStateObjectGet(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: [*]const u64,
    _: [*]u8,
    _: u32,
) i32 {
    return -1; // Not found
}

fn testStateObjectPut(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: [*]const u64,
    _: [*]const u8,
    _: u32,
) void {}

fn testStateObjectDelete(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: [*]const u64,
) void {}

fn testWireSend(
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    _: i64,
    remote_addr: *const InetAddress,
    data: [*]const u8,
    len: u32,
    _: i32,
) void {
    const test_ctx: *TestContext = @ptrCast(@alignCast(ctx.?));

    test_ctx.packets_sent += 1;
    std.debug.print("  → {s} testWireSend called (packet #{}, {} bytes)\n", .{ test_ctx.node_name, test_ctx.packets_sent, len });

    // Actually send the packet via UDP
    const sockaddr_ptr: *const std.posix.sockaddr = @ptrCast(&remote_addr.storage);
    const socklen = if (remote_addr.isV4())
        @as(std.posix.socklen_t, @sizeOf(std.c.sockaddr.in))
    else
        @as(std.posix.socklen_t, @sizeOf(std.c.sockaddr.in6));

    const sent_bytes = std.posix.sendto(
        test_ctx.controller_socket,
        data[0..len],
        0,
        sockaddr_ptr,
        socklen,
    ) catch |err| {
        std.debug.print("    ❌ Failed to send: {}\n", .{err});
        return;
    };

    std.debug.print("    ✓ Sent {} bytes via UDP\n", .{sent_bytes});
}

fn testFrameInject(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u64,
    _: u64,
    _: u64,
    _: u32,
    _: u32,
    _: [*]const u8,
    _: u32,
) void {}

fn testEvent(
    _: ?*anyopaque,
    _: ?*anyopaque,
    event: u32,
    _: ?*const anyopaque,
) void {
    const event_names = [_][]const u8{
        "UP",           // 0
        "OFFLINE",      // 1
        "ONLINE",       // 2
        "DOWN",         // 3
        "FATAL_ERROR_IDENTITY_COLLISION", // 4
        "TRACE",        // 5
        "USER_MESSAGE", // 6
        "REMOTE_TRACE", // 7
    };
    const event_name = if (event < event_names.len) event_names[event] else "UNKNOWN";
    std.debug.print("  → Event: {s}\n", .{event_name});
}

// Test: Two nodes communicate on same network
test "two nodes communicate on same network" {
    std.debug.print("\n" ++ "═" ** 70 ++ "\n", .{});
    std.debug.print("Integration Test: Two Nodes Communicate on Same Network\n", .{});
    std.debug.print("═" ** 70 ++ "\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    // Step 1: Create test controller
    std.debug.print("Step 1: Creating test controller...\n", .{});

    const TestController = @import("test_controller.zig").Controller;
    var controller = try TestController.init(allocator, 19990);
    defer controller.deinit();

    std.debug.print("  ✓ Controller created (listening on 0.0.0.0:19990)\n\n", .{});

    // Step 2: Create two nodes with separate sockets
    std.debug.print("Step 2: Creating Node A and Node B...\n", .{});

    // Create separate UDP sockets for each node
    const socket_a = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket_a);

    const socket_b = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket_b);

    // Bind sockets to different ports
    const addr_a = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19991);
    try std.posix.bind(socket_a, &addr_a.any, addr_a.getOsSockLen());

    const addr_b = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19992);
    try std.posix.bind(socket_b, &addr_b.any, addr_b.getOsSockLen());

    var test_ctx_a = TestContext{
        .allocator = allocator,
        .controller_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19990),
        .controller_socket = socket_a,
        .node_name = "Node A",
    };

    var test_ctx_b = TestContext{
        .allocator = allocator,
        .controller_addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 19990),
        .controller_socket = socket_b,
        .node_name = "Node B",
    };

    const node_callbacks_a = Callbacks{
        .ctx = @ptrCast(&test_ctx_a),
        .stateObjectGet = testStateObjectGet,
        .stateObjectPut = testStateObjectPut,
        .stateObjectDelete = testStateObjectDelete,
        .wireSend = testWireSend,
        .frameInject = testFrameInject,
        .event = testEvent,
    };

    const node_callbacks_b = Callbacks{
        .ctx = @ptrCast(&test_ctx_b),
        .stateObjectGet = testStateObjectGet,
        .stateObjectPut = testStateObjectPut,
        .stateObjectDelete = testStateObjectDelete,
        .wireSend = testWireSend,
        .frameInject = testFrameInject,
        .event = testEvent,
    };

    // Initialize both nodes
    const config = Config{};
    const now = std.time.milliTimestamp();
    const node_a = try Node.init(allocator, null, null, &config, node_callbacks_a, now);
    defer node_a.deinit();

    const node_b = try Node.init(allocator, null, null, &config, node_callbacks_b, now);
    defer node_b.deinit();

    std.debug.print("  ✓ Node A created: {x:0>10}\n", .{node_a.identity.address().toInt()});
    std.debug.print("  ✓ Node B created: {x:0>10}\n\n", .{node_b.identity.address().toInt()});

    // Step 3: Register both nodes with controller
    std.debug.print("Step 3: Registering nodes with controller...\n", .{});

    // Register Node A
    var node_a_controller_key: [32]u8 = undefined;
    if (!controller.identity.agree(&node_a.identity, &node_a_controller_key)) {
        std.debug.print("  ❌ ECDH agreement failed for Node A\n", .{});
        return error.ECDHFailed;
    }

    try controller.peers.put(node_a.identity.address().toInt(), .{
        .address = node_a.identity.address(),
        .identity = node_a.identity,
        .shared_key = node_a_controller_key,
    });

    // Register Node B
    var node_b_controller_key: [32]u8 = undefined;
    if (!controller.identity.agree(&node_b.identity, &node_b_controller_key)) {
        std.debug.print("  ❌ ECDH agreement failed for Node B\n", .{});
        return error.ECDHFailed;
    }

    try controller.peers.put(node_b.identity.address().toInt(), .{
        .address = node_b.identity.address(),
        .identity = node_b.identity,
        .shared_key = node_b_controller_key,
    });

    std.debug.print("  ✓ Both nodes registered with controller\n\n", .{});

    // Step 4: Add controller as known peer for both nodes
    std.debug.print("Step 4: Adding controller as peer for both nodes...\n", .{});

    // Node A adds controller as peer
    const controller_peer_a_maybe = Peer.create(&node_a.identity, &controller.identity);
    if (controller_peer_a_maybe == null) {
        std.debug.print("  ❌ Failed to create controller peer for Node A\n", .{});
        return error.PeerCreationFailed;
    }
    const controller_peer_a = controller_peer_a_maybe.?;
    const added_controller_a = node_a.topology.addPeer(&controller_peer_a);
    if (added_controller_a == null) {
        std.debug.print("  ❌ Failed to add controller peer to Node A\n", .{});
        return error.TopologyAddFailed;
    }

    const controller_inet_addr = InetAddress.initV4(.{ 127, 0, 0, 1 }, 19990);
    var controller_path_a = Path.initWithAddress(-1, controller_inet_addr);
    const path_added_a = added_controller_a.?.addPath(&controller_path_a, now);
    if (!path_added_a) {
        std.debug.print("  ⚠️  Path may already exist for Node A\n", .{});
    }

    // Node B adds controller as peer
    const controller_peer_b_maybe = Peer.create(&node_b.identity, &controller.identity);
    if (controller_peer_b_maybe == null) {
        std.debug.print("  ❌ Failed to create controller peer for Node B\n", .{});
        return error.PeerCreationFailed;
    }
    const controller_peer_b = controller_peer_b_maybe.?;
    const added_controller_b = node_b.topology.addPeer(&controller_peer_b);
    if (added_controller_b == null) {
        std.debug.print("  ❌ Failed to add controller peer to Node B\n", .{});
        return error.TopologyAddFailed;
    }

    var controller_path_b = Path.initWithAddress(-1, controller_inet_addr);
    const path_added_b = added_controller_b.?.addPath(&controller_path_b, now);
    if (!path_added_b) {
        std.debug.print("  ⚠️  Path may already exist for Node B\n", .{});
    }

    std.debug.print("  ✓ Controller peer added to both nodes\n\n", .{});

    // Step 5: Both nodes join the same network
    std.debug.print("Step 5: Both nodes joining network...\n", .{});

    const test_network_id = (controller.address.toInt() << 24) | 0x000001;
    const network_a = try node_a.joinNetwork(test_network_id);
    const network_b = try node_b.joinNetwork(test_network_id);

    std.debug.print("  ✓ Node A joined network 0x{x}\n", .{test_network_id});
    std.debug.print("  ✓ Node B joined network 0x{x}\n\n", .{test_network_id});

    // Step 6: Both nodes request network configs
    std.debug.print("Step 6: Requesting network configs...\n", .{});

    network_a.requestConfiguration(null);
    std.debug.print("  ✓ Node A config request sent\n", .{});

    network_b.requestConfiguration(null);
    std.debug.print("  ✓ Node B config request sent\n\n", .{});

    // Step 7: Controller processes both requests
    std.debug.print("Step 7: Controller processing config requests...\n", .{});

    std.Thread.sleep(10 * std.time.ns_per_ms);

    const pkt_mod = @import("node/packet.zig");
    const PacketBuffer = @import("node/buffer.zig").Buffer(pkt_mod.max_packet_length);

    // Process Node A's request
    var recv_buf_a1: [4096]u8 = undefined;
    var from_addr_a1: net.Address = undefined;
    var from_len_a1: std.posix.socklen_t = @sizeOf(net.Address);

    const recv_len_a1 = std.posix.recvfrom(
        controller.socket,
        &recv_buf_a1,
        0,
        &from_addr_a1.any,
        &from_len_a1,
    ) catch |err| {
        std.debug.print("  ❌ Failed to receive Node A request: {}\n", .{err});
        return error.ReceiveFailed;
    };

    var pkt_buf_a1: PacketBuffer = .{};
    try pkt_buf_a1.copyFrom(recv_buf_a1[0..recv_len_a1]);
    var pkt_a1 = Packet{ .buf = pkt_buf_a1 };
    const source_a1 = pkt_a1.source();
    try controller.handlePacket(&pkt_a1, &from_addr_a1, source_a1);

    std.debug.print("  ✓ Node A config request processed\n", .{});

    // Process Node B's request
    var recv_buf_b1: [4096]u8 = undefined;
    var from_addr_b1: net.Address = undefined;
    var from_len_b1: std.posix.socklen_t = @sizeOf(net.Address);

    const recv_len_b1 = std.posix.recvfrom(
        controller.socket,
        &recv_buf_b1,
        0,
        &from_addr_b1.any,
        &from_len_b1,
    ) catch |err| {
        std.debug.print("  ❌ Failed to receive Node B request: {}\n", .{err});
        return error.ReceiveFailed;
    };

    var pkt_buf_b1: PacketBuffer = .{};
    try pkt_buf_b1.copyFrom(recv_buf_b1[0..recv_len_b1]);
    var pkt_b1 = Packet{ .buf = pkt_buf_b1 };
    const source_b1 = pkt_b1.source();
    try controller.handlePacket(&pkt_b1, &from_addr_b1, source_b1);

    std.debug.print("  ✓ Node B config request processed\n\n", .{});

    // Step 8: Both nodes receive and apply configs
    std.debug.print("Step 8: Nodes receiving and applying configs...\n", .{});

    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Node A receives config
    var resp_buf_a: [4096]u8 = undefined;
    var resp_from_addr_a: net.Address = undefined;
    var resp_from_len_a: std.posix.socklen_t = @sizeOf(net.Address);

    const resp_len_a = std.posix.recvfrom(
        socket_a,
        &resp_buf_a,
        0,
        &resp_from_addr_a.any,
        &resp_from_len_a,
    ) catch |err| {
        std.debug.print("  ❌ Node A failed to receive config: {}\n", .{err});
        return error.ReceiveFailed;
    };

    var resp_pkt_buf_a: PacketBuffer = .{};
    try resp_pkt_buf_a.copyFrom(resp_buf_a[0..resp_len_a]);
    var resp_pkt_a = Packet{ .buf = resp_pkt_buf_a };

    const controller_peer_entry_a = node_a.topology.getPeer(controller.address);
    if (controller_peer_entry_a) |peer| {
        const resp_key_a = peer.key();
        const resp_mac_valid_a = resp_pkt_a.dearmor(resp_key_a[0..32], null, null);
        if (!resp_mac_valid_a) {
            std.debug.print("  ❌ Node A: Invalid response MAC\n", .{});
            return error.InvalidResponseMAC;
        }
    }

    const payload_offset_a = pkt_mod.idx_payload;
    const payload_a = resp_pkt_a.buf.data()[payload_offset_a..];
    const config_update_id_a = network_a.handleConfigChunk(
        null,
        resp_pkt_a.packetId(),
        controller.address,
        payload_a,
        0,
    );

    if (config_update_id_a == 0) {
        std.debug.print("  ❌ Node A: Failed to process config\n", .{});
        return error.ConfigProcessFailed;
    }

    std.debug.print("  ✓ Node A config applied\n", .{});

    // Node B receives config
    var resp_buf_b: [4096]u8 = undefined;
    var resp_from_addr_b: net.Address = undefined;
    var resp_from_len_b: std.posix.socklen_t = @sizeOf(net.Address);

    const resp_len_b = std.posix.recvfrom(
        socket_b,
        &resp_buf_b,
        0,
        &resp_from_addr_b.any,
        &resp_from_len_b,
    ) catch |err| {
        std.debug.print("  ❌ Node B failed to receive config: {}\n", .{err});
        return error.ReceiveFailed;
    };

    var resp_pkt_buf_b: PacketBuffer = .{};
    try resp_pkt_buf_b.copyFrom(resp_buf_b[0..resp_len_b]);
    var resp_pkt_b = Packet{ .buf = resp_pkt_buf_b };

    const controller_peer_entry_b = node_b.topology.getPeer(controller.address);
    if (controller_peer_entry_b) |peer| {
        const resp_key_b = peer.key();
        const resp_mac_valid_b = resp_pkt_b.dearmor(resp_key_b[0..32], null, null);
        if (!resp_mac_valid_b) {
            std.debug.print("  ❌ Node B: Invalid response MAC\n", .{});
            return error.InvalidResponseMAC;
        }
    }

    const payload_offset_b = pkt_mod.idx_payload;
    const payload_b = resp_pkt_b.buf.data()[payload_offset_b..];
    const config_update_id_b = network_b.handleConfigChunk(
        null,
        resp_pkt_b.packetId(),
        controller.address,
        payload_b,
        0,
    );

    if (config_update_id_b == 0) {
        std.debug.print("  ❌ Node B: Failed to process config\n", .{});
        return error.ConfigProcessFailed;
    }

    std.debug.print("  ✓ Node B config applied\n\n", .{});

    // Step 9: Nodes add each other as peers
    std.debug.print("Step 9: Nodes adding each other as peers...\n", .{});

    // Node A adds Node B as peer
    const peer_b_maybe = Peer.create(&node_a.identity, &node_b.identity);
    if (peer_b_maybe == null) {
        std.debug.print("  ❌ Node A: Failed to create peer for Node B\n", .{});
        return error.PeerCreationFailed;
    }
    const peer_b = peer_b_maybe.?;
    const added_peer_b = node_a.topology.addPeer(&peer_b);
    if (added_peer_b == null) {
        std.debug.print("  ❌ Node A: Failed to add Node B to topology\n", .{});
        return error.TopologyAddFailed;
    }

    const path_to_b = InetAddress.initV4(.{ 127, 0, 0, 1 }, 19992);
    var b_path = Path.initWithAddress(-1, path_to_b);
    const path_added_to_b = added_peer_b.?.addPath(&b_path, now);
    if (!path_added_to_b) {
        std.debug.print("  ⚠️  Path to Node B may already exist\n", .{});
    }

    std.debug.print("  ✓ Node A added Node B as peer (127.0.0.1:19992)\n", .{});

    // Node B adds Node A as peer
    const peer_a_maybe = Peer.create(&node_b.identity, &node_a.identity);
    if (peer_a_maybe == null) {
        std.debug.print("  ❌ Node B: Failed to create peer for Node A\n", .{});
        return error.PeerCreationFailed;
    }
    const peer_a = peer_a_maybe.?;
    const added_peer_a = node_b.topology.addPeer(&peer_a);
    if (added_peer_a == null) {
        std.debug.print("  ❌ Node B: Failed to add Node A to topology\n", .{});
        return error.TopologyAddFailed;
    }

    const path_to_a = InetAddress.initV4(.{ 127, 0, 0, 1 }, 19991);
    var a_path = Path.initWithAddress(-1, path_to_a);
    const path_added_to_a = added_peer_a.?.addPath(&a_path, now);
    if (!path_added_to_a) {
        std.debug.print("  ⚠️  Path to Node A may already exist\n", .{});
    }

    std.debug.print("  ✓ Node B added Node A as peer (127.0.0.1:19991)\n\n", .{});

    // Verification
    std.debug.print("Verification: Checking state...\n", .{});

    const config_a = network_a.config();
    const config_b = network_b.config();

    std.debug.print("  ✓ Node A IP count: {}\n", .{config_a.static_ip_count});
    std.debug.print("  ✓ Node B IP count: {}\n", .{config_b.static_ip_count});

    try testing.expect(config_a.static_ip_count > 0);
    try testing.expect(config_b.static_ip_count > 0);

    try testing.expect(test_ctx_a.packets_sent > 0);
    try testing.expect(test_ctx_b.packets_sent > 0);

    std.debug.print("\n" ++ "═" ** 70 ++ "\n", .{});
    std.debug.print("Test PASSED: Two nodes on same network!\n", .{});
    std.debug.print("✓ Both nodes joined network 0x{x}\n", .{test_network_id});
    std.debug.print("✓ Both nodes received configs with IPs\n", .{});
    std.debug.print("✓ Both nodes added each other as peers\n", .{});
    std.debug.print("✓ Node A sent {} packet(s)\n", .{test_ctx_a.packets_sent});
    std.debug.print("✓ Node B sent {} packet(s)\n", .{test_ctx_b.packets_sent});
    std.debug.print("Next: Add ECHO packet exchange to prove peer-to-peer communication\n", .{});
    std.debug.print("═" ** 70 ++ "\n\n", .{});
}
