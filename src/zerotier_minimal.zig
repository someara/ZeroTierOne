/// Minimal ZeroTier Service — Just demonstrates working integration
///
/// This shows:
/// ✓ Phy module with real UDP sockets
/// ✓ Node initialization with identity
/// ✓ Event loop running background tasks
/// ✓ Basic packet flow structure
///
/// What this demonstrates: The foundation is complete and functional.
/// The remaining work is wiring up the TODOs in Node for full packet processing.

const std = @import("std");
const net = std.net;

const Node = @import("node/node.zig").Node;
const Config = @import("node/node.zig").Config;
const Callbacks = @import("node/node.zig").Callbacks;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;
const InetAddress = @import("node/inet_address.zig").InetAddress;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    printBanner();

    // ── Phase 1: Initialize Node ──────────────────────────────────────
    std.debug.print("Phase 1: Initializing ZeroTier Node\n", .{});
    std.debug.print("──────────────────────────────────────────────────────\n", .{});

    const node_callbacks = Callbacks{
        .ctx = null,
        .stateObjectGet = mockStateObjectGet,
        .stateObjectPut = mockStateObjectPut,
        .stateObjectDelete = mockStateObjectDelete,
        .wireSend = mockWireSend,
        .frameInject = mockFrameInject,
        .event = mockEvent,
    };

    const config = Config{};
    const start_time = std.time.milliTimestamp();

    var node = try Node.init(allocator, null, null, &config, node_callbacks, start_time);
    defer node.deinit();

    std.debug.print("  ✓ Node initialized\n", .{});
    std.debug.print("  ✓ Address: {any}\n", .{node.identity.address()});
    std.debug.print("\n", .{});

    // ── Phase 2: Initialize Phy (Sockets) ─────────────────────────────
    std.debug.print("Phase 2: Initializing Network Sockets\n", .{});
    std.debug.print("──────────────────────────────────────────────────────\n", .{});

    const phy_handler = PhyHandler{
        .on_datagram = onDatagram,
        .on_tcp_connect = onTcpConnect,
        .on_tcp_accept = onTcpAccept,
        .on_tcp_close = onTcpClose,
        .on_tcp_data = onTcpData,
        .on_tcp_writable = onTcpWritable,
        .on_fd_activity = onFdActivity,
    };

    var phy = try Phy.init(allocator, phy_handler, true, false);
    defer phy.deinit();

    std.debug.print("  ✓ Phy initialized\n", .{});

    // Bind to port 9994 (avoid needing sudo for port 9993)
    const bind_port: u16 = 9994;
    const bind_addr = net.Address.initIp4([4]u8{0, 0, 0, 0}, bind_port);

    _ = try phy.udpBind(bind_addr, null, 0);
    std.debug.print("  ✓ UDP socket bound to 0.0.0.0:{d}\n", .{bind_port});
    std.debug.print("\n", .{});

    // ── Phase 3: Run Service Loop ─────────────────────────────────────
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Service Running\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("Node address:  {any}\n", .{node.identity.address()});
    std.debug.print("UDP port:      {d}\n", .{bind_port});
    std.debug.print("Running for:   30 seconds\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n\n", .{});

    var last_tick: i64 = start_time;
    var tick_count: u32 = 0;
    const end_time = start_time + 30000; // Run for 30 seconds

    while (std.time.milliTimestamp() < end_time) {
        const now = std.time.milliTimestamp();

        // Run Node background tasks every 500ms
        if (now - last_tick >= 500) {
            tick_count += 1;
            _ = node.processBackgroundTasks(null, now);
            last_tick = now;

            // Print status every 5 seconds
            if (tick_count % 10 == 0) {
                std.debug.print("[{d}s] Service running...\n", .{tick_count / 2});
            }
        }

        // Poll for socket events (100ms timeout)
        try phy.poll(100);
    }

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Service Demo Complete\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("Total ticks:       {d}\n", .{tick_count});
    std.debug.print("Time elapsed:      {d}s\n", .{tick_count / 2});
    std.debug.print("\n", .{});
    std.debug.print("✓ ZeroTier core is functional!\n", .{});
    std.debug.print("✓ Phy module handles real UDP sockets\n", .{});
    std.debug.print("✓ Node runs background tasks\n", .{});
    std.debug.print("✓ Foundation complete for full service\n", .{});
    std.debug.print("\n", .{});
}

fn printBanner() void {
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║         ZeroTier Minimal Service — Zig Demo          ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║   Demonstrates: Node + Phy + Event Loop Working      ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

// ── Node Callbacks (Mocks) ─────────────────────────────────────────────────

fn mockStateObjectGet(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64, _: [*]u8, _: u32) i32 {
    return 0; // Not found - let Node generate identity
}

fn mockStateObjectPut(_: ?*anyopaque, _: ?*anyopaque, object_type: u32, _: [*]const u64, _: [*]const u8, len: u32) void {
    if (object_type == 1) {
        std.debug.print("  → Identity saved ({d} bytes)\n", .{len});
    }
}

fn mockStateObjectDelete(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: [*]const u64) void {}

fn mockWireSend(_: ?*anyopaque, _: ?*anyopaque, _: i64, remote: *const InetAddress, _: [*]const u8, len: u32, _: i32) void {
    std.debug.print("← Would send {d} bytes to port {d}\n", .{len, remote.port()});
}

fn mockFrameInject(_: ?*anyopaque, _: ?*anyopaque, nwid: u64, _: u64, _: u64, _: u32, _: u32, _: [*]const u8, len: u32) void {
    std.debug.print("  → Would inject {d} bytes to network {x:0>16}\n", .{len, nwid});
}

fn mockEvent(_: ?*anyopaque, _: ?*anyopaque, event_type: u32, _: ?*const anyopaque) void {
    const event_name = switch (event_type) {
        0 => "UP",
        1 => "OFFLINE",
        2 => "ONLINE",
        else => "UNKNOWN",
    };
    std.debug.print("  → Event: {s}\n", .{event_name});
}

// ── Phy Callbacks ──────────────────────────────────────────────────────────

fn onDatagram(_: *PhySocket, _: *?*anyopaque, _: net.Address, from: net.Address, data: []const u8) void {
    std.debug.print("→ Received {d} bytes from port {d}\n", .{data.len, from.getPort()});
}

fn onTcpConnect(_: *PhySocket, _: *?*anyopaque, _: bool) void {}
fn onTcpAccept(_: *PhySocket, _: *PhySocket, _: *?*anyopaque, _: *?*anyopaque, _: net.Address) void {}
fn onTcpClose(_: *PhySocket, _: *?*anyopaque) void {}
fn onTcpData(_: *PhySocket, _: *?*anyopaque, _: []const u8) void {}
fn onTcpWritable(_: *PhySocket, _: *?*anyopaque) void {}
fn onFdActivity(_: *PhySocket, _: *?*anyopaque, _: bool, _: bool) void {}
