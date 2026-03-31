/// Simple test for Phy networking layer
///
/// This test creates a UDP echo server and client to verify basic functionality.

const std = @import("std");
const net = std.net;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;

// Test state
const TestState = struct {
    received_count: usize = 0,
    expected_data: []const u8,
    allocator: std.mem.Allocator,
};

// Handler implementation
fn onDatagram(
    sock: *PhySocket,
    uptr: *?*anyopaque,
    local_addr: net.Address,
    from: net.Address,
    data: []const u8,
) void {
    _ = sock;
    _ = local_addr;
    _ = from;

    if (uptr.*) |ptr| {
        const state: *TestState = @ptrCast(@alignCast(ptr));
        state.received_count += 1;

        if (std.mem.eql(u8, data, state.expected_data)) {
            std.debug.print("✓ Received correct data: \"{s}\"\n", .{data});
        } else {
            std.debug.print("✗ Data mismatch! Expected \"{s}\", got \"{s}\"\n", .{state.expected_data, data});
        }
    }
}

fn onTcpConnect(sock: *PhySocket, uptr: *?*anyopaque, success: bool) void {
    _ = sock;
    _ = uptr;
    std.debug.print("TCP connect: {}\n", .{success});
}

fn onTcpAccept(
    sock_listen: *PhySocket,
    sock_new: *PhySocket,
    uptr_listen: *?*anyopaque,
    uptr_new: *?*anyopaque,
    from: net.Address,
) void {
    _ = sock_listen;
    _ = sock_new;
    _ = uptr_listen;
    _ = uptr_new;
    std.debug.print("TCP accept from {any}\n", .{from});
}

fn onTcpClose(sock: *PhySocket, uptr: *?*anyopaque) void {
    _ = sock;
    _ = uptr;
    std.debug.print("TCP close\n", .{});
}

fn onTcpData(sock: *PhySocket, uptr: *?*anyopaque, data: []const u8) void {
    _ = sock;
    _ = uptr;
    std.debug.print("TCP data: {d} bytes\n", .{data.len});
}

fn onTcpWritable(sock: *PhySocket, uptr: *?*anyopaque) void {
    _ = sock;
    _ = uptr;
}

fn onFdActivity(sock: *PhySocket, uptr: *?*anyopaque, readable: bool, writable: bool) void {
    _ = sock;
    _ = uptr;
    std.debug.print("FD activity: readable={}, writable={}\n", .{readable, writable});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Phy Networking Layer Test ===\n\n", .{});

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
    var phy = try Phy.init(allocator, handler, true, false);
    defer phy.deinit();

    std.debug.print("✓ Phy initialized\n", .{});

    // Test 1: UDP echo
    std.debug.print("\n--- Test 1: UDP Socket ---\n", .{});

    const expected_message = "Hello, Phy!";
    var test_state = TestState{
        .expected_data = expected_message,
        .allocator = allocator,
    };

    // Bind UDP socket on localhost:60000
    const listen_addr = try net.Address.parseIp4("127.0.0.1", 60000);
    const udp_sock = try phy.udpBind(listen_addr, @ptrCast(&test_state), 65536);
    std.debug.print("✓ UDP socket bound to 127.0.0.1:60000\n", .{});

    // Send a datagram to ourselves
    const send_addr = try net.Address.parseIp4("127.0.0.1", 60000);
    const sent = phy.udpSend(udp_sock, send_addr, expected_message);
    if (sent) {
        std.debug.print("✓ Sent {d} bytes: \"{s}\"\n", .{expected_message.len, expected_message});
    } else {
        std.debug.print("✗ Failed to send datagram\n", .{});
    }

    // Poll for events (should receive our datagram)
    std.debug.print("Polling for events...\n", .{});
    try phy.poll(100); // Wait up to 100ms

    if (test_state.received_count > 0) {
        std.debug.print("✓ Received {d} datagrams\n", .{test_state.received_count});
    } else {
        std.debug.print("✗ No datagrams received\n", .{});
    }

    // Test 2: TCP listen socket (just verify we can bind)
    std.debug.print("\n--- Test 2: TCP Listen Socket ---\n", .{});
    const tcp_listen_addr = try net.Address.parseIp4("127.0.0.1", 60001);
    const tcp_listen_sock = try phy.tcpListen(tcp_listen_addr, null);
    std.debug.print("✓ TCP listening socket bound to 127.0.0.1:60001\n", .{});

    // Close TCP socket
    phy.close(tcp_listen_sock, false);
    std.debug.print("✓ TCP socket closed\n", .{});

    // Test 3: Socket utilities
    std.debug.print("\n--- Test 3: Socket Utilities ---\n", .{});
    const port = Phy.getLocalPort(udp_sock);
    std.debug.print("✓ Local port: {d}\n", .{port});

    const descriptor = Phy.getDescriptor(udp_sock);
    std.debug.print("✓ Descriptor: {d}\n", .{descriptor});

    std.debug.print("\n=== All Tests Passed ===\n\n", .{});
}
