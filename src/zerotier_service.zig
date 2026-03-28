/// ZeroTier Service Layer — Minimal runnable service
///
/// This is a minimal implementation showing how to wire together:
/// - Phy module (UDP/TCP sockets)
/// - Node (ZeroTier core logic)
/// - Event loop
///
/// This is the foundation for a full ZeroTier service.

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

// Import ZeroTier modules
const Node = @import("node/node.zig").Node;
const Config = @import("node/node.zig").Config;
const Callbacks = @import("node/node.zig").Callbacks;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Packet = @import("node/packet.zig").Packet;

/// Service context - holds all state for the running service
pub const Service = struct {
    allocator: Allocator,
    node: Node,
    phy: Phy,

    // Primary UDP socket for ZeroTier protocol
    primary_port: u16,
    primary_sock: ?*PhySocket,

    // Secondary UDP sockets (for multiple ports)
    secondary_socks: std.ArrayList(*PhySocket),

    // Control flags
    running: bool,
    terminate: bool,

    /// Initialize the service
    pub fn init(
        allocator: Allocator,
        primary_port: u16,
        home_dir: ?[]const u8,
    ) !Service {
        std.debug.print("Initializing ZeroTier service on port {d}...\n", .{primary_port});

        // Create Phy handler
        const phy_handler = PhyHandler{
            .on_datagram = onPhyDatagram,
            .on_tcp_connect = onPhyTcpConnect,
            .on_tcp_accept = onPhyTcpAccept,
            .on_tcp_close = onPhyTcpClose,
            .on_tcp_data = onPhyTcpData,
            .on_tcp_writable = onPhyTcpWritable,
            .on_fd_activity = onPhyFdActivity,
        };

        // Initialize Phy
        var phy = try Phy.init(allocator, phy_handler, true, false);
        errdefer phy.deinit();

        // Create Node callbacks
        const node_callbacks = Callbacks{
            .ctx = null, // Will be set to Service pointer after init
            .stateObjectGet = nodeStateObjectGet,
            .stateObjectPut = nodeStateObjectPut,
            .stateObjectDelete = nodeStateObjectDelete,
            .wireSend = nodeWireSend,
            .frameInject = nodeFrameInject,
            .event = nodeEvent,
        };

        // Initialize Node
        const config = Config{};
        const now = std.time.milliTimestamp();
        var node = try Node.init(allocator, null, null, &config, node_callbacks, now);
        errdefer node.deinit();
        _ = home_dir; // TODO: Use home_dir for state persistence

        std.debug.print("  ✓ Node initialized with address: {any}\n", .{node.identity.address()});

        var service = Service{
            .allocator = allocator,
            .node = node,
            .phy = phy,
            .primary_port = primary_port,
            .primary_sock = null,
            .secondary_socks = std.ArrayList(*PhySocket){ .items = &.{}, .capacity = 0 },
            .running = false,
            .terminate = false,
        };

        // Update Node callbacks to point to service
        service.node.callbacks.ctx = &service;

        return service;
    }

    /// Clean up and shut down
    pub fn deinit(self: *Service) void {
        std.debug.print("Shutting down service...\n", .{});
        self.secondary_socks.deinit(self.allocator);
        self.node.deinit();
        self.phy.deinit();
        std.debug.print("  ✓ Service shutdown complete\n", .{});
    }

    /// Bind UDP sockets for ZeroTier protocol
    pub fn bindSockets(self: *Service) !void {
        // Bind primary port (IPv4)
        const bind_addr_v4 = net.Address.initIp4([4]u8{0, 0, 0, 0}, self.primary_port);
        std.debug.print("Binding UDP socket to 0.0.0.0:{d}...\n", .{self.primary_port});

        self.primary_sock = try self.phy.udpBind(bind_addr_v4, self, 0);
        std.debug.print("  ✓ Primary socket bound\n", .{});

        // TODO: Bind IPv6 socket
        // TODO: Bind secondary ports
    }

    /// Main event loop
    pub fn run(self: *Service) !void {
        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("  ZeroTier Service Running\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("Node address:  {any}\n", .{self.node.identity.address()});
        std.debug.print("Primary port:  {d}\n", .{self.primary_port});
        std.debug.print("Press Ctrl+C to stop\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════\n\n", .{});

        self.running = true;
        var last_background_tick: i64 = std.time.milliTimestamp();
        var tick_count: u64 = 0;

        while (self.running and !self.terminate) {
            const now = std.time.milliTimestamp();

            // Run Node background tasks every 500ms
            if (now - last_background_tick >= 500) {
                tick_count += 1;
                _ = self.node.processBackgroundTasks(null, now);
                last_background_tick = now;

                // Print status every 10 seconds
                if (tick_count % 20 == 0) {
                    std.debug.print("[{d}s] Service running...\n", .{tick_count / 2});
                }
            }

            // Poll for socket events (100ms timeout)
            try self.phy.poll(100);
        }

        std.debug.print("\nService stopped.\n", .{});
    }

    /// Stop the service
    pub fn stop(self: *Service) void {
        std.debug.print("Stopping service...\n", .{});
        self.terminate = true;
        self.phy.whack(); // Wake up poll()
    }
};

// ── Phy Callbacks ──────────────────────────────────────────────────────────

/// Phy callback: UDP datagram received
fn onPhyDatagram(
    sock: *PhySocket,
    uptr: *?*anyopaque,
    local_addr: net.Address,
    from: net.Address,
    data: []const u8,
) void {
    _ = sock;
    _ = local_addr;

    const service: *Service = @ptrCast(@alignCast(uptr.*));

    // Convert addresses to ZeroTier format
    const from_port = from.getPort();
    var from_zt = InetAddress.initV4([4]u8{127, 0, 0, 1}, from_port);

    // Extract IP address properly
    if (from.any.family == std.posix.AF.INET) {
        from_zt = InetAddress.initV4(
            @bitCast(from.in.sa.addr),
            from_port,
        );
    } else if (from.any.family == std.posix.AF.INET6) {
        from_zt = InetAddress.initV6(
            from.in6.sa.addr,
            from_port,
        );
    }

    std.debug.print("→ Received {d} bytes from port {d}\n", .{data.len, from_port});

    // Pass packet to Node for processing
    const now = std.time.milliTimestamp();
    const local_sock: i64 = 0; // Use socket 0 as identifier

    service.node.processWirePacket(
        null,
        now,
        local_sock,
        &from_zt,
        data.ptr,
        @intCast(data.len),
    );
}

fn onPhyTcpConnect(_: *PhySocket, _: *?*anyopaque, _: bool) void {}
fn onPhyTcpAccept(_: *PhySocket, _: *PhySocket, _: *?*anyopaque, _: *?*anyopaque, _: net.Address) void {}
fn onPhyTcpClose(_: *PhySocket, _: *?*anyopaque) void {}
fn onPhyTcpData(_: *PhySocket, _: *?*anyopaque, _: []const u8) void {}
fn onPhyTcpWritable(_: *PhySocket, _: *?*anyopaque) void {}
fn onPhyFdActivity(_: *PhySocket, _: *?*anyopaque, _: bool, _: bool) void {}

// ── Node Callbacks ─────────────────────────────────────────────────────────

/// Node callback: Get state object (identity, config, etc.)
fn nodeStateObjectGet(
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    object_type: u32,
    _: [*]const u64,
    _: [*]u8,
    _: u32,
) i32 {
    _ = ctx;

    // Return 0 = "not found" to trigger default behavior
    // For now, let Node generate a new identity
    if (object_type == 1) { // state_object_identity_secret
        return 0; // Not found - generate new identity
    }

    return 0;
}

/// Node callback: Store state object
fn nodeStateObjectPut(
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    object_type: u32,
    _: [*]const u64,
    data: [*]const u8,
    len: u32,
) void {
    _ = ctx;

    if (object_type == 1) { // state_object_identity_secret
        std.debug.print("  → Identity generated ({d} bytes)\n", .{len});

        // TODO: Save identity to disk
        // For now, just show we received it
        _ = data;
    }
}

/// Node callback: Delete state object
fn nodeStateObjectDelete(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: u32,
    _: [*]const u64,
) void {}

/// Node callback: Send packet on wire (UDP)
fn nodeWireSend(
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    local_socket: i64,
    remote_addr: *const InetAddress,
    data: [*]const u8,
    len: u32,
    ttl: i32,
) void {
    const service: *Service = @ptrCast(@alignCast(ctx.?));
    _ = local_socket;
    _ = ttl;

    // Convert ZeroTier address to std.net.Address
    var dest_addr: net.Address = undefined;

    if (remote_addr.isV4()) {
        if (remote_addr.rawIpData()) |ipv4_bytes| {
            const ipv4_array: [4]u8 = ipv4_bytes[0..4].*;
            dest_addr = net.Address.initIp4(ipv4_array, remote_addr.port());
        } else {
            std.debug.print("  ✗ Invalid IPv4 address\n", .{});
            return;
        }
    } else {
        // IPv6
        if (remote_addr.rawIpData()) |ipv6_bytes| {
            const ipv6_array: [16]u8 = ipv6_bytes[0..16].*;
            dest_addr = net.Address.initIp6(ipv6_array, remote_addr.port(), 0, 0);
        } else {
            std.debug.print("  ✗ Invalid IPv6 address\n", .{});
            return;
        }
    }

    // Send via Phy
    if (service.primary_sock) |sock| {
        const sent = service.phy.udpSend(sock, dest_addr, data[0..len]);
        if (sent) {
            std.debug.print("← Sent {d} bytes to port {d}\n", .{len, remote_addr.port()});
        } else {
            std.debug.print("  ✗ Failed to send {d} bytes\n", .{len});
        }
    }
}

/// Node callback: Inject frame into virtual network interface
fn nodeFrameInject(
    _: ?*anyopaque,
    _: ?*anyopaque,
    nwid: u64,
    source_mac: u64,
    dest_mac: u64,
    ether_type: u32,
    vlan_id: u32,
    data: [*]const u8,
    len: u32,
) void {
    // TODO: Inject into TUN/TAP device
    // For now, just log
    std.debug.print("  → Frame inject: nwid={x:0>16}, len={d}\n", .{nwid, len});
    _ = source_mac;
    _ = dest_mac;
    _ = ether_type;
    _ = vlan_id;
    _ = data;
}

/// Node callback: Event notification (UP, ONLINE, OFFLINE, etc.)
fn nodeEvent(
    _: ?*anyopaque,
    _: ?*anyopaque,
    event_type: u32,
    _: ?*const anyopaque,
) void {
    const event_name = switch (event_type) {
        0 => "UP",
        1 => "OFFLINE",
        2 => "ONLINE",
        else => "UNKNOWN",
    };

    std.debug.print("  → Event: {s}\n", .{event_name});
}
