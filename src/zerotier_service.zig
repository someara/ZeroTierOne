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
const TunDevice = @import("node/tun_device.zig").TunDevice;
const HttpApi = @import("node/http_api.zig").HttpApi;

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

    // TUN device for virtual network interface
    tun: ?TunDevice,

    // HTTP API server
    http_api: ?*HttpApi,
    auth_token: ?[]const u8,

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
            .tun = null,
            .http_api = null,
            .auth_token = null,
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
        if (self.http_api) |api| api.stop();
        if (self.tun) |*tun| tun.close();
        self.secondary_socks.deinit(self.allocator);
        self.node.deinit();
        self.phy.deinit();
        if (self.auth_token) |t| self.allocator.free(t);
        std.debug.print("  ✓ Service shutdown complete\n", .{});
    }

    /// Start the HTTP API server on the given port
    pub fn startHttpApi(self: *Service, port: u16, home_dir: ?[]const u8) !void {
        // Generate or read auth token
        const token = try self.loadOrGenerateAuthToken(home_dir);
        self.auth_token = token;

        std.debug.print("Starting HTTP API on 127.0.0.1:{d}...\n", .{port});
        self.http_api = try HttpApi.start(self.allocator, &self.node, port, token);
        std.debug.print("  ✓ HTTP API server running\n", .{});
    }

    fn loadOrGenerateAuthToken(self: *Service, home_dir: ?[]const u8) ![]const u8 {
        // Try to read existing token
        if (home_dir) |dir| {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/authtoken.secret", .{dir}) catch return self.generateAuthToken(home_dir);
            const file = std.fs.openFileAbsolute(path, .{}) catch return self.generateAuthToken(home_dir);
            defer file.close();
            const content = file.readToEndAlloc(self.allocator, 1024) catch return self.generateAuthToken(home_dir);
            const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                const token = try self.allocator.dupe(u8, trimmed);
                self.allocator.free(content);
                return token;
            }
            self.allocator.free(content);
        }
        return self.generateAuthToken(home_dir);
    }

    fn generateAuthToken(self: *Service, home_dir: ?[]const u8) ![]const u8 {
        // Generate 24-char random token
        var rand_bytes: [24]u8 = undefined;
        std.crypto.random.bytes(&rand_bytes);

        const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
        var token: [24]u8 = undefined;
        for (&token, 0..) |*c, i| {
            c.* = charset[rand_bytes[i] % charset.len];
        }

        const result = try self.allocator.dupe(u8, &token);

        // Write to file if we have a home dir
        if (home_dir) |dir| {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/authtoken.secret", .{dir}) catch return result;
            const file = std.fs.createFileAbsolute(path, .{}) catch return result;
            defer file.close();
            file.writeAll(result) catch {};
            std.debug.print("  ✓ Auth token written to {s}\n", .{path});
        }

        return result;
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

    /// Create and configure TUN device for a network
    pub fn createTunDevice(self: *Service) !void {
        std.debug.print("Creating TUN device...\n", .{});

        var tun = try TunDevice.open(self.allocator, "utun");
        errdefer tun.close();

        self.tun = tun;
        std.debug.print("  ✓ TUN device ready: {s}\n", .{tun.name});

        // Configure with a test IP address
        // In production, this would come from network configuration
        const test_ip = [4]u8{10, 147, 20, 1};
        const test_netmask = [4]u8{255, 255, 255, 0};

        std.debug.print("Configuring IP address...\n", .{});
        tun.setAddress(test_ip, test_netmask) catch |err| {
            std.debug.print("  ⚠ Failed to set IP address: {}\n", .{err});
            std.debug.print("  ⚠ You may need to run: sudo ifconfig {s} 10.147.20.1 netmask 255.255.255.0 up\n", .{tun.name});
            // Continue anyway - device is still usable
        };

        std.debug.print("  ✓ TUN device configured\n", .{});
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

            // Read from TUN device if available
            if (self.tun) |*tun| {
                var tun_buffer: [2800]u8 = undefined;
                const tun_len = tun.read(&tun_buffer) catch |err| blk: {
                    if (err != error.WouldBlock) {
                        std.debug.print("  ✗ TUN read error: {}\n", .{err});
                    }
                    break :blk 0;
                };

                if (tun_len > 0) {
                    std.debug.print("  ← Read {d} bytes from TUN device\n", .{tun_len});

                    // Parse IP packet to extract addresses and type
                    if (tun_len >= 20) { // Minimum IPv4 header
                        const ip_version = tun_buffer[0] >> 4;

                        if (ip_version == 4) {
                            // IPv4 packet - look up which network this TUN device belongs to
                            const network_list = self.node.listNetworks(self.allocator) catch {
                                std.debug.print("  ✗ Failed to get network list\n", .{});
                                continue;
                            };
                            defer self.allocator.free(network_list);

                            if (network_list.len == 0) {
                                std.debug.print("  ✗ No networks joined - cannot route TUN traffic\n", .{});
                                continue;
                            }

                            // Use the first network (in production, you'd map TUN device to network)
                            const nwid = network_list[0];
                            const network = self.node.getNetwork(nwid);

                            if (network == null) {
                                std.debug.print("  ✗ Network {x} not found\n", .{nwid});
                                continue;
                            }

                            // Get real network ID and MAC address
                            const real_nwid = network.?.id();
                            const my_mac = network.?.mac();
                            const src_mac: u64 = my_mac.toInt();
                            const dst_mac: u64 = 0xffffffffffff; // Broadcast (real routing would use ARP/NDP)
                            const ether_type: u32 = 0x0800; // IPv4
                            const vlan_id: u32 = 0;

                            std.debug.print("  → Routing via network {x} (MAC: {x:0>12})\n", .{real_nwid, src_mac});

                            // Process the frame with real network ID
                            self.node.processVirtualNetworkFrame(
                                null,
                                now,
                                real_nwid,
                                src_mac,
                                dst_mac,
                                ether_type,
                                vlan_id,
                                @ptrCast(&tun_buffer),
                                @intCast(tun_len),
                            ) catch |err| {
                                std.debug.print("  ✗ Failed to process frame: {}\n", .{err});
                            };
                        } else if (ip_version == 6) {
                            // IPv6 packet
                            std.debug.print("  → IPv6 packet (not yet supported)\n", .{});
                        }
                    }
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
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    nwid: u64,
    source_mac: u64,
    dest_mac: u64,
    ether_type: u32,
    vlan_id: u32,
    data: [*]const u8,
    len: u32,
) void {
    const service: *Service = @ptrCast(@alignCast(ctx.?));

    _ = nwid;
    _ = source_mac;
    _ = dest_mac;
    _ = ether_type;
    _ = vlan_id;

    // Write packet to TUN device
    if (service.tun) |*tun| {
        const packet = data[0..len];
        tun.write(packet) catch |err| {
            std.debug.print("  ✗ TUN write failed: {}\n", .{err});
            return;
        };
        std.debug.print("  → Injected {d} bytes to TUN device\n", .{len});
    } else {
        std.debug.print("  ⚠ No TUN device - dropping frame ({d} bytes)\n", .{len});
    }
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
