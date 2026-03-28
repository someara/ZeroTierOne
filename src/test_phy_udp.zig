/// Test Phy module with real UDP sockets
///
/// This demonstrates:
/// - Creating UDP sockets with Phy
/// - Sending/receiving datagrams
/// - Event loop integration
///
/// Build: zig build-exe src/test_phy_udp.zig -I./src
/// Run:   ./test_phy_udp

const std = @import("std");
const net = std.net;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;

// Test context to track received packets
const TestContext = struct {
    received_count: u32 = 0,
    phy: ?*Phy = null,
    echo_sock: ?*PhySocket = null,
    test_complete: bool = false,
};

// Handler: UDP datagram received
fn onDatagram(
    sock: *PhySocket,
    uptr: *?*anyopaque,
    local_addr: net.Address,
    from: net.Address,
    data: []const u8,
) void {
    _ = sock;
    _ = local_addr;

    const ctx: *TestContext = @ptrCast(@alignCast(uptr.*));
    ctx.received_count += 1;

    // Format address manually
    const from_port = from.getPort();
    std.debug.print("✓ Received datagram #{d} from port {d}: \"{s}\"\n",
        .{ctx.received_count, from_port, data});

    // Echo back the data
    if (ctx.phy) |phy_ptr| {
        if (ctx.echo_sock) |echo_sock| {
            const sent = phy_ptr.udpSend(echo_sock, from, data);
            if (sent) {
                std.debug.print("  → Echoed back {d} bytes\n", .{data.len});
            }
        }
    }

    // Mark test complete after receiving packet
    ctx.test_complete = true;
}

// Dummy handlers for other events
fn onTcpConnect(_: *PhySocket, _: *?*anyopaque, _: bool) void {}
fn onTcpAccept(_: *PhySocket, _: *PhySocket, _: *?*anyopaque, _: *?*anyopaque, _: net.Address) void {}
fn onTcpClose(_: *PhySocket, _: *?*anyopaque) void {}
fn onTcpData(_: *PhySocket, _: *?*anyopaque, _: []const u8) void {}
fn onTcpWritable(_: *PhySocket, _: *?*anyopaque) void {}
fn onFdActivity(_: *PhySocket, _: *?*anyopaque, _: bool, _: bool) void {}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  ZeroTier Phy Module — UDP Socket Test\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n\n", .{});

    // Create handler
    const handler = PhyHandler{
        .on_datagram = onDatagram,
        .on_tcp_connect = onTcpConnect,
        .on_tcp_accept = onTcpAccept,
        .on_tcp_close = onTcpClose,
        .on_tcp_data = onTcpData,
        .on_tcp_writable = onTcpWritable,
        .on_fd_activity = onFdActivity,
    };

    // Initialize Phy
    std.debug.print("Initializing Phy...\n", .{});
    var phy = try Phy.init(allocator, handler, false, false);
    defer phy.deinit();
    std.debug.print("  ✓ Phy initialized\n\n", .{});

    // Create test context
    var ctx = TestContext{
        .phy = &phy,
    };

    // Bind UDP socket on port 9994 (just above ZeroTier's default 9993)
    const bind_addr = net.Address.initIp4([4]u8{127, 0, 0, 1}, 9994);
    std.debug.print("Binding UDP socket to 127.0.0.1:9994...\n", .{});
    const udp_sock = try phy.udpBind(bind_addr, &ctx, 0);
    ctx.echo_sock = udp_sock;
    std.debug.print("  ✓ UDP socket bound\n\n", .{});

    // Send test packet to ourselves
    const test_data = "Hello from ZeroTier Phy!";
    const dest_addr = net.Address.initIp4([4]u8{127, 0, 0, 1}, 9994);
    std.debug.print("Sending test datagram to ourselves...\n", .{});
    const sent = phy.udpSend(udp_sock, dest_addr, test_data);
    if (sent) {
        std.debug.print("  ✓ Sent {d} bytes\n\n", .{test_data.len});
    } else {
        std.debug.print("  ✗ Send failed\n\n", .{});
        return error.SendFailed;
    }

    // Run event loop until we receive the packet
    std.debug.print("Running event loop (waiting for datagram)...\n", .{});
    var iterations: u32 = 0;
    while (!ctx.test_complete and iterations < 10) : (iterations += 1) {
        try phy.poll(100); // Poll for 100ms
    }
    std.debug.print("\n", .{});

    // Print results
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Test Results\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("Poll iterations:   {d}\n", .{iterations});
    std.debug.print("Packets received:  {d}\n", .{ctx.received_count});
    std.debug.print("Test status:       {s}\n", .{if (ctx.test_complete) "✓ PASS" else "✗ FAIL"});
    std.debug.print("═══════════════════════════════════════════════════════\n\n", .{});

    if (!ctx.test_complete) {
        std.debug.print("⚠️  Test timed out - packet not received\n", .{});
        std.debug.print("    This might be a firewall or networking issue\n\n", .{});
        return error.TestTimeout;
    }

    std.debug.print("✓ All tests passed!\n", .{});
    std.debug.print("  Phy module is working correctly with real UDP sockets.\n\n", .{});
}
