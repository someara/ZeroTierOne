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
const World = @import("node/world.zig").World;
const Buffer = @import("node/buffer.zig").Buffer;

/// Service context - holds all state for the running service
pub const Service = struct {
    allocator: Allocator,
    node: *Node,
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

    // Home directory for state persistence
    home_dir: ?[]const u8,

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

        // Set home dir for state persistence callbacks (before Node.init)
        g_home_dir = home_dir;

        // Ensure home directory exists
        if (home_dir) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| {
                if (err != error.PathAlreadyExists) {
                    std.debug.print("  ✗ Failed to create home dir: {}\n", .{err});
                }
            };
        }

        // Initialize Node
        const config = Config{};
        const now = std.time.milliTimestamp();
        const node = try Node.init(allocator, null, null, &config, node_callbacks, now);
        errdefer node.deinit();
        // home_dir stored in service struct for state persistence

        std.debug.print("  ✓ Node initialized with address: {any}\n", .{node.identity.address()});

        const service = Service{
            .allocator = allocator,
            .node = node,
            .phy = phy,
            .primary_port = primary_port,
            .primary_sock = null,
            .secondary_socks = std.ArrayList(*PhySocket){ .items = &.{}, .capacity = 0 },
            .tun = null,
            .http_api = null,
            .auth_token = null,
            .home_dir = home_dir,
            .running = false,
            .terminate = false,
        };

        // NOTE: callbacks.ctx must be set by caller after init returns,
        // since the Service is returned by value (stack copy).
        return service;
    }

    /// Must be called after init to fix callback pointers (init returns by value).
    pub fn setup(self: *Service) void {
        self.node.callbacks.ctx = self;
        self.loadPlanet();
    }

    /// Clean up and shut down
    pub fn deinit(self: *Service) void {
        std.debug.print("Shutting down service...\n", .{});
        if (self.http_api) |api| api.stop();
        if (self.tun) |*tun| tun.close();

        // Close all sockets before freeing tracking structures
        for (self.secondary_socks.items) |sock| {
            self.phy.close(sock, false);
        }
        self.secondary_socks.deinit(self.allocator);
        if (self.primary_sock) |sock| {
            self.phy.close(sock, false);
        }

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
        self.http_api = try HttpApi.start(self.allocator, self.node, port, token);
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
            file.writeAll(result) catch |err| {
                std.debug.print("  ⚠ Failed to write auth token: {}\n", .{err});
            };
            std.debug.print("  ✓ Auth token written to {s}\n", .{path});
        }

        return result;
    }

    /// Load planet world (root servers) from home dir or use embedded default
    fn loadPlanet(self: *Service) void {
        // Try to load from {home_dir}/planet
        if (self.home_dir) |dir| {
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/planet", .{dir}) catch return;
            const file = std.fs.openFileAbsolute(path, .{}) catch {
                // No planet file — use embedded default
                self.loadEmbeddedPlanet();
                return;
            };
            defer file.close();

            var data: [4096]u8 = undefined;
            const n = file.read(&data) catch {
                self.loadEmbeddedPlanet();
                return;
            };

            if (n > 0) {
                var world = World.init();
                var buf = Buffer(4096).initFrom(data[0..n]) catch {
                    self.loadEmbeddedPlanet();
                    return;
                };
                _ = world.deserialize(4096, &buf, 0) catch {
                    std.debug.print("  ✗ Failed to parse planet file\n", .{});
                    self.loadEmbeddedPlanet();
                    return;
                };
                if (self.node.topology.addWorld(&world, true)) {
                    std.debug.print("  ✓ Planet loaded from {s} (world ID {d})\n", .{ path, world.id() });
                } else {
                    std.debug.print("  ✗ Planet rejected by topology\n", .{});
                    self.loadEmbeddedPlanet();
                }
                return;
            }
        }
        self.loadEmbeddedPlanet();
    }

    fn loadEmbeddedPlanet(self: *Service) void {
        // ZeroTier Earth planet (standard root servers)
        const planet_data = [_]u8{
            0x01, 0x00, 0x00, 0x00, 0x00, 0x08, 0xea, 0xc9, 0x0a, 0x00, 0x00, 0x01,
            0x94, 0xdb, 0x79, 0x5b, 0x4e, 0xb8, 0xb3, 0x88, 0xa4, 0x69, 0x22, 0x14,
            0x91, 0xaa, 0x9a, 0xcd, 0x66, 0xcc, 0x76, 0x4c, 0xde, 0xfd, 0x56, 0x03,
            0x9f, 0x10, 0x67, 0xae, 0x15, 0xe6, 0x9c, 0x6f, 0xb4, 0x2d, 0x7b, 0x55,
            0x33, 0x0e, 0x3f, 0xda, 0xac, 0x52, 0x9c, 0x07, 0x92, 0xfd, 0x73, 0x40,
            0xa6, 0xaa, 0x21, 0xab, 0xa8, 0xa4, 0x89, 0xfd, 0xae, 0xa4, 0x4a, 0x39,
            0xbf, 0x2d, 0x00, 0x65, 0x9a, 0xc9, 0xc8, 0x18, 0xeb, 0x5e, 0x6e, 0x69,
            0x7f, 0x9c, 0xb6, 0x62, 0xcd, 0x71, 0xdb, 0x83, 0xd3, 0x95, 0x61, 0x9f,
            0xbf, 0xed, 0x1a, 0x81, 0xe6, 0x5e, 0xf2, 0x2e, 0xeb, 0x4a, 0xb4, 0xb4,
            0x2f, 0x97, 0x8a, 0x22, 0x27, 0xaa, 0xb9, 0x34, 0x9d, 0xa3, 0x87, 0xa6,
            0x94, 0xb0, 0xd3, 0x41, 0x83, 0x9d, 0xc3, 0x94, 0x2a, 0xcf, 0x02, 0xf6,
            0xeb, 0x09, 0xd9, 0xad, 0xe6, 0x1c, 0x63, 0xa7, 0x56, 0xc7, 0xa9, 0xb7,
            0x0c, 0x59, 0xde, 0x1b, 0xfc, 0x93, 0x76, 0x9f, 0x10, 0x79, 0xc7, 0x2b,
            0x43, 0xa0, 0xdd, 0xde, 0x13, 0xbd, 0x42, 0x53, 0x38, 0x79, 0xe6, 0x2b,
            0xe6, 0x0d, 0x5d, 0x93, 0xe6, 0x96, 0x8b, 0xe6, 0x43, 0x04, 0xca, 0xfe,
            0x80, 0xed, 0x74, 0x00, 0x1e, 0x86, 0xa3, 0xff, 0x86, 0x17, 0xbe, 0xf5,
            0x37, 0xb9, 0x9b, 0xa7, 0x14, 0x40, 0x8b, 0xf0, 0xce, 0x0e, 0x14, 0x3f,
            0x8a, 0xcf, 0x6e, 0xc9, 0x3e, 0x94, 0xd4, 0x59, 0x7a, 0xaf, 0x16, 0x09,
            0x7d, 0x4f, 0x1c, 0xec, 0x69, 0xb4, 0x4f, 0xda, 0x99, 0x66, 0x5c, 0xa9,
            0x9c, 0x57, 0xf4, 0xa1, 0x66, 0x41, 0xb9, 0xe3, 0x9b, 0x2e, 0x6d, 0x31,
            0x80, 0xdc, 0x8f, 0x1a, 0xe8, 0xde, 0x89, 0xf8, 0x00, 0x02, 0x04, 0xb9,
            0x98, 0x43, 0x91, 0x27, 0x09, 0x06, 0x2a, 0x02, 0x6e, 0xa0, 0xc8, 0x7f,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x27, 0x09,
            0x77, 0x8c, 0xde, 0x71, 0x90, 0x00, 0x3f, 0x66, 0x81, 0xa9, 0x9e, 0x5a,
            0xd1, 0x89, 0x5e, 0x9f, 0xba, 0x33, 0xe6, 0x21, 0x2d, 0x44, 0x54, 0xe1,
            0x68, 0xbc, 0xec, 0x71, 0x12, 0x10, 0x1b, 0xf0, 0x00, 0x95, 0x6e, 0xd8,
            0xe9, 0x2e, 0x42, 0x89, 0x2c, 0xb6, 0xf2, 0xec, 0x41, 0x08, 0x81, 0xa8,
            0x4a, 0xb1, 0x9d, 0xa5, 0x0e, 0x12, 0x87, 0xba, 0x3d, 0x92, 0x6c, 0x3a,
            0x1f, 0x75, 0x5c, 0xcc, 0xf2, 0x99, 0xa1, 0x20, 0x70, 0x55, 0x00, 0x02,
            0x04, 0x67, 0xc3, 0x67, 0x42, 0x27, 0x09, 0x06, 0x26, 0x05, 0x98, 0x80,
            0x04, 0x00, 0x00, 0xc3, 0x02, 0x54, 0xf2, 0xbc, 0xa1, 0xf7, 0x00, 0x19,
            0x27, 0x09, 0xca, 0xfe, 0xfd, 0x67, 0x17, 0x00, 0x4c, 0x74, 0xed, 0xe0,
            0x18, 0x50, 0xe7, 0xe6, 0x45, 0xfb, 0x77, 0x9d, 0x70, 0x0c, 0x45, 0xb9,
            0xaf, 0x91, 0xa0, 0x48, 0xcc, 0x85, 0x8a, 0xd0, 0xc4, 0xf2, 0x51, 0x74,
            0xbf, 0x29, 0xb4, 0x60, 0xe5, 0xcc, 0x3e, 0x98, 0xcd, 0x84, 0xee, 0x30,
            0xfe, 0xa5, 0x7c, 0x14, 0xf1, 0x49, 0x5a, 0xdd, 0x0c, 0xc0, 0xe5, 0xb1,
            0x9d, 0x78, 0xaf, 0xcd, 0x14, 0x17, 0x0c, 0x57, 0x56, 0x18, 0x08, 0x00,
            0x00, 0x02, 0x04, 0x4f, 0x7f, 0x9f, 0xbb, 0x27, 0x09, 0x06, 0x2a, 0x02,
            0x6e, 0xa0, 0xd3, 0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x99, 0x93, 0x27, 0x09, 0xca, 0xfe, 0x04, 0xeb, 0xa9, 0x00, 0x6c, 0x6a,
            0x9d, 0x1d, 0xea, 0x55, 0xc1, 0x61, 0x6b, 0xfe, 0x2a, 0x2b, 0x8f, 0x0f,
            0xf9, 0xa8, 0xca, 0xca, 0xf7, 0x03, 0x74, 0xfb, 0x1f, 0x39, 0xe3, 0xbe,
            0xf8, 0x1c, 0xbf, 0xeb, 0xef, 0x17, 0xb7, 0x22, 0x82, 0x68, 0xa0, 0xa2,
            0xa2, 0x9d, 0x34, 0x88, 0xc7, 0x52, 0x56, 0x5c, 0x6c, 0x96, 0x5c, 0xbd,
            0x65, 0x06, 0xec, 0x24, 0x39, 0x7c, 0xc8, 0xa5, 0xd9, 0xd1, 0x52, 0x85,
            0xa8, 0x7f, 0x00, 0x02, 0x04, 0x54, 0x11, 0x35, 0x9b, 0x27, 0x09, 0x06,
            0x2a, 0x02, 0x6e, 0xa0, 0xd4, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x99, 0x93, 0x27, 0x09,
        };

        var world = World.init();
        var buf = Buffer(4096).initFrom(&planet_data) catch {
            std.debug.print("  ✗ Failed to create planet buffer\n", .{});
            return;
        };
        _ = world.deserialize(4096, &buf, 0) catch {
            std.debug.print("  ✗ Failed to parse embedded planet\n", .{});
            return;
        };
        if (self.node.topology.addWorld(&world, true)) {
            std.debug.print("  ✓ Planet loaded (embedded, world ID {d})\n", .{world.id()});
        } else {
            std.debug.print("  ✗ Embedded planet rejected\n", .{});
        }
    }

    /// Bind UDP sockets for ZeroTier protocol
    pub fn bindSockets(self: *Service) !void {
        // Bind primary port (IPv4)
        const bind_addr_v4 = net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, self.primary_port);
        std.debug.print("Binding UDP socket to 0.0.0.0:{d}...\n", .{self.primary_port});

        self.primary_sock = try self.phy.udpBind(bind_addr_v4, self, 0);
        std.debug.print("  ✓ IPv4 socket bound\n", .{});

        // Bind IPv6 socket
        const bind_addr_v6 = net.Address.initIp6([16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, self.primary_port, 0, 0);
        if (self.phy.udpBind(bind_addr_v6, self, 0)) |v6_sock| {
            // Fixed: STYLE.md 2.2 - OutOfMemory must propagate
            self.secondary_socks.append(self.allocator, v6_sock) catch |err| switch (err) {
                error.OutOfMemory => {
                    self.phy.close(v6_sock, false);
                    std.debug.print("  ⚠ Out of memory tracking IPv6 socket (closed)\n", .{});
                    return error.OutOfMemory;
                },
            };
            std.debug.print("  ✓ IPv6 socket bound\n", .{});
        } else |_| {
            std.debug.print("  ⚠ IPv6 socket bind failed (continuing with IPv4 only)\n", .{});
        }
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
        const test_ip = [4]u8{ 10, 147, 20, 1 };
        const test_netmask = [4]u8{ 255, 255, 255, 0 };

        std.debug.print("Configuring IP address...\n", .{});
        tun.setAddress(test_ip, test_netmask) catch |err| {
            std.debug.print("  ⚠ Failed to set IP address: {}\n", .{err});
            std.debug.print("  ⚠ You may need to run: sudo ifconfig {s} 10.147.20.1 netmask 255.255.255.0 up\n", .{tun.name});
            // Continue anyway - device is still usable
        };

        std.debug.print("  ✓ TUN device configured\n", .{});
    }

    /// Join a network by ID (reads from NETWORK_ID environment variable or takes explicit parameter)
    /// Fixed BUG #37: Implement network join logic
    pub fn joinNetworkFromEnv(self: *Service) !void {
        // Read NETWORK_ID from environment
        const network_id_str = std.process.getEnvVarOwned(self.allocator, "NETWORK_ID") catch |err| {
            std.debug.print("  ⚠ No NETWORK_ID environment variable set: {}\n", .{err});
            return;
        };
        defer self.allocator.free(network_id_str);

        // Parse network ID (format: 0x8056c2e21c000001 or 8056c2e21c000001)
        const trimmed = std.mem.trim(u8, network_id_str, &std.ascii.whitespace);
        const hex_str = if (std.mem.startsWith(u8, trimmed, "0x"))
            trimmed[2..]
        else
            trimmed;

        const network_id = std.fmt.parseInt(u64, hex_str, 16) catch |err| {
            std.debug.print("  ✗ Failed to parse NETWORK_ID '{s}': {}\n", .{ network_id_str, err });
            return;
        };

        std.debug.print("Joining network 0x{x}...\n", .{network_id});

        // Join the network
        _ = try self.node.joinNetwork(network_id);
        std.debug.print("  ✓ Network joined: 0x{x}\n", .{network_id});

        // The node will automatically request network configuration from the controller
        // via the NETWORK_CONFIG_REQUEST protocol
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

                            std.debug.print("  → Routing via network {x} (MAC: {x:0>12})\n", .{ real_nwid, src_mac });

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
    var from_zt = InetAddress.initV4([4]u8{ 127, 0, 0, 1 }, from_port);

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

    std.debug.print("→ Received {d} bytes from port {d}\n", .{ data.len, from_port });

    // Debug: print first 32 bytes of packet
    if (data.len >= 32) {
        std.debug.print("  → Raw packet hex: ", .{});
        for (0..32) |i| {
            std.debug.print("{x:0>2}", .{data[i]});
            if (i % 2 == 1) std.debug.print(" ", .{});
        }
        std.debug.print("\n", .{});
    }

    // Pass packet to Node for processing
    const now = std.time.milliTimestamp();
    const local_sock: i64 = 0; // Use socket 0 as identifier

    const pkt_len: u32 = std.math.cast(u32, data.len) orelse return;
    service.node.processWirePacket(
        null,
        now,
        local_sock,
        &from_zt,
        data.ptr,
        pkt_len,
    );
}

fn onPhyTcpConnect(_: *PhySocket, _: *?*anyopaque, _: bool) void {}
fn onPhyTcpAccept(_: *PhySocket, _: *PhySocket, _: *?*anyopaque, _: *?*anyopaque, _: net.Address) void {}
fn onPhyTcpClose(_: *PhySocket, _: *?*anyopaque) void {}
fn onPhyTcpData(_: *PhySocket, _: *?*anyopaque, _: []const u8) void {}
fn onPhyTcpWritable(_: *PhySocket, _: *?*anyopaque) void {}
fn onPhyFdActivity(_: *PhySocket, _: *?*anyopaque, _: bool, _: bool) void {}

// ── Node Callbacks ─────────────────────────────────────────────────────────

// Module-level home dir for state callbacks (set before Node.init)
var g_home_dir: ?[]const u8 = null;

/// Map state object type to filename
fn stateObjectPath(home_dir: []const u8, object_type: u32, buf: *[512]u8) ?[]const u8 {
    const name = switch (object_type) {
        0 => "identity.public",
        1 => "identity.secret",
        else => return null,
    };
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home_dir, name }) catch null;
}

/// Node callback: Get state object (identity, config, etc.)
fn nodeStateObjectGet(
    _: ?*anyopaque,
    _: ?*anyopaque,
    object_type: u32,
    _: [*]const u64,
    out_buf: [*]u8,
    buf_len: u32,
) i32 {
    const home_dir = g_home_dir orelse return 0;

    var path_buf: [512]u8 = undefined;
    const path = stateObjectPath(home_dir, object_type, &path_buf) orelse return 0;

    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();

    const bytes_read = file.read(out_buf[0..buf_len]) catch return 0;
    if (bytes_read > 0) {
        std.debug.print("  → Loaded state object type {d} ({d} bytes) from {s}\n", .{ object_type, bytes_read, path });
    }
    return std.math.cast(i32, bytes_read) orelse return 0;
}

/// Node callback: Store state object
fn nodeStateObjectPut(
    _: ?*anyopaque,
    _: ?*anyopaque,
    object_type: u32,
    _: [*]const u64,
    data: [*]const u8,
    len: u32,
) void {
    const home_dir = g_home_dir orelse return;

    var path_buf: [512]u8 = undefined;
    const path = stateObjectPath(home_dir, object_type, &path_buf) orelse return;

    const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
        std.debug.print("  ✗ Failed to save state object type {d}: {}\n", .{ object_type, err });
        return;
    };
    defer file.close();

    file.writeAll(data[0..len]) catch |err| {
        std.debug.print("  ✗ Failed to write state object type {d}: {}\n", .{ object_type, err });
        return;
    };
    std.debug.print("  → Saved state object type {d} ({d} bytes) to {s}\n", .{ object_type, len, path });
}

/// Node callback: Delete state object
fn nodeStateObjectDelete(
    _: ?*anyopaque,
    _: ?*anyopaque,
    object_type: u32,
    _: [*]const u64,
) void {
    const home_dir = g_home_dir orelse return;

    var path_buf: [512]u8 = undefined;
    const path = stateObjectPath(home_dir, object_type, &path_buf) orelse return;
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {}, // Expected for objects that don't exist yet
        else => std.debug.print("  ⚠ Failed to delete state object: {}\n", .{err}),
    };
}

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

    // Pick the right socket (IPv4 vs IPv6)
    const sock = if (remote_addr.isV4())
        service.primary_sock
    else blk: {
        // Use first secondary (IPv6) socket if available, else try primary
        if (service.secondary_socks.items.len > 0) {
            break :blk service.secondary_socks.items[0];
        }
        break :blk service.primary_sock;
    };

    if (sock) |s| {
        var ip_buf: [64]u8 = undefined;
        const addr_str = remote_addr.toString(&ip_buf);
        std.debug.print("  ← UDP {d}b to {s} (v{s})\n", .{
            len,                                  addr_str,
            if (remote_addr.isV4()) "4" else "6",
        });
        // Hex dump first packet for debugging
        if (len > 0 and len < 100) {
            std.debug.print("    HEX: ", .{});
            for (data[0..len]) |b| {
                std.debug.print("{x:0>2}", .{b});
            }
            std.debug.print("\n", .{});
        }
        const sent = service.phy.udpSend(s, dest_addr, data[0..len]);
        if (!sent) {
            std.debug.print("  ✗ udpSend failed!\n", .{});
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
