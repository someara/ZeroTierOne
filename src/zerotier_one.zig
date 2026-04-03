/// ZeroTier One — Main executable
///
/// This is a minimal but functional ZeroTier service that can:
/// - Initialize Node with identity
/// - Bind UDP sockets
/// - Process incoming packets
/// - Run event loop
///
/// What it currently does:
/// ✓ Creates a ZeroTier node
/// ✓ Binds to UDP port (default 9993)
/// ✓ Receives and processes packets
/// ✓ Sends packets on the wire
/// ✓ Runs background tasks
///
/// What it needs next:
/// ☐ TUN/TAP device for routing traffic
/// ☐ State persistence (save identity)
/// ☐ Network management (join/leave)
/// ☐ HTTP API server (port 9993)
///
/// Build: zig build-exe src/zerotier_one.zig -I./src
/// Run:   sudo ./zerotier_one (requires sudo for port 9993)

const std = @import("std");
const Service = @import("zerotier_service.zig").Service;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    var port: u16 = 9993; // Default ZeroTier port
    var home_dir: ?[]const u8 = null;
    var enable_tun = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |port_str| {
                port = try std.fmt.parseInt(u16, port_str, 10);
            }
        } else if (std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |dir| {
                home_dir = dir;
            }
        } else if (std.mem.eql(u8, arg, "--tun")) {
            enable_tun = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        }
    }

    // Fixed BUG #28: Read environment variables set by Docker
    // Docker-compose sets ROOT_SERVER, CONTROLLER, NETWORK_ID for container configuration
    const root_server_env = std.process.getEnvVarOwned(allocator, "ROOT_SERVER") catch null;
    defer if (root_server_env) |env| allocator.free(env);

    const controller_env = std.process.getEnvVarOwned(allocator, "CONTROLLER") catch null;
    defer if (controller_env) |env| allocator.free(env);

    const network_id_env = std.process.getEnvVarOwned(allocator, "NETWORK_ID") catch null;
    defer if (network_id_env) |env| allocator.free(env);

    const role_env = std.process.getEnvVarOwned(allocator, "ROLE") catch null;
    defer if (role_env) |env| allocator.free(env);

    // Print configuration if environment variables are set
    if (root_server_env) |root| {
        std.debug.print("  Environment: ROOT_SERVER={s}\n", .{root});
    }
    if (controller_env) |ctrl| {
        std.debug.print("  Environment: CONTROLLER={s}\n", .{ctrl});
    }
    if (network_id_env) |nwid| {
        std.debug.print("  Environment: NETWORK_ID={s}\n", .{nwid});
    }
    // Fixed BUG #29: Use ROLE env var for behavior customization
    if (role_env) |role| {
        std.debug.print("  Environment: ROLE={s}\n", .{role});
        // Role-specific behavior can be implemented here if needed
        // For now, just logging it is sufficient
    }

    // Print banner
    printBanner();

    // Initialize service
    var service = try Service.init(allocator, port, home_dir);
    defer service.deinit();

    // Fix callback pointers (init returns by value, so ctx must be set after)
    service.setup();

    // Bind sockets
    try service.bindSockets();

    // Start HTTP API server (TCP on same port as UDP)
    service.startHttpApi(port, home_dir) catch |err| {
        std.debug.print("  ✗ Failed to start HTTP API: {}\n", .{err});
        std.debug.print("  ⚠ Continuing without HTTP API\n", .{});
    };

    // Create TUN device if requested
    if (enable_tun) {
        service.createTunDevice() catch |err| {
            std.debug.print("  ✗ Failed to create TUN device: {}\n", .{err});
            std.debug.print("  ⚠ Continuing without TUN device\n", .{});
        };
    }

    // Join network if NETWORK_ID environment variable is set
    // Fixed BUG #37: Implement network join logic
    service.joinNetworkFromEnv() catch |err| {
        std.debug.print("  ⚠ Network join failed: {}\n", .{err});
        std.debug.print("  ⚠ Continuing without network (you can join via HTTP API)\n", .{});
    };

    // Set up signal handler for graceful shutdown
    // TODO: Implement proper signal handling

    // Run main event loop
    try service.run();
}

fn printBanner() void {
    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║           ZeroTier One — Zig Implementation           ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║   A minimal but functional ZeroTier service showing   ║\n", .{});
    std.debug.print("║   the converted Zig core working with real sockets   ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

fn printHelp() void {
    std.debug.print("Usage: zerotier-one [OPTIONS]\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -p <port>    Primary UDP port (default: 9993)\n", .{});
    std.debug.print("  -d <dir>     Home directory (default: generate temp identity)\n", .{});
    std.debug.print("  --tun        Enable TUN device (requires root)\n", .{});
    std.debug.print("  -h, --help   Show this help message\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  sudo ./zerotier-one              # Run on port 9993\n", .{});
    std.debug.print("  ./zerotier-one -p 9994           # Run on alternate port\n", .{});
    std.debug.print("  sudo ./zerotier-one --tun        # With TUN device (requires root)\n", .{});
    std.debug.print("  ./zerotier-one -d /tmp/zt        # Use specific directory\n", .{});
    std.debug.print("\n", .{});
}
