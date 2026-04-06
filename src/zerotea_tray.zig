/// ZeroTea macOS Tray Application
///
/// Native macOS menu bar app that communicates with zerotea via its
/// HTTP API at localhost:9993. Shows joined networks, allows joining/leaving,
/// and displays service status.
///
/// Build: zig build tray
/// Run:   ./zig-out/bin/ZeroTeaTray
const std = @import("std");
const cocoa = @import("macos/cocoa.zig");
const HttpClient = @import("http_client.zig").HttpClient;
const MenuDelegate = @import("macos/menu_delegate.zig").MenuDelegate;
const menu_delegate = @import("macos/menu_delegate.zig");
const tray = @import("tray_logic.zig");

// Tags for menu item dispatch (must match ObjC switch in menu_bridge_blocks.m)
const TAG_JOIN = 1;
const TAG_QUIT = 4;
const TAG_COPY_ID = 5;
// Tags 100-115 reserved for "Leave Network" (100 + network index)

// Global state (needed for menu callbacks dispatched from ObjC)
var g_allocator: std.mem.Allocator = undefined;
var g_client: *HttpClient = undefined;
var g_menu: ?cocoa.Menu = null;
var g_delegate: ?MenuDelegate = null;
var g_status_bar: ?cocoa.StatusBar = null;

// Parsed network state (refreshed on each menu open)
var g_networks: [tray.MAX_NETWORKS]tray.NetworkInfo = undefined;
var g_network_count: usize = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    g_allocator = allocator;

    // Initialize HTTP client
    var client = HttpClient.init(allocator, "127.0.0.1", 9993);
    defer client.deinit();
    g_client = &client;

    // Try to read auth token
    const token = readAuthToken(allocator) catch null;
    defer if (token) |t| allocator.free(t);
    if (token) |t| client.setAuthToken(t);

    // Create macOS menu bar app
    const app = cocoa.Application.sharedApplication();
    app.setActivationPolicy();

    var statusBar = try cocoa.StatusBar.create();
    g_status_bar = statusBar;

    // Set initial title
    const status = fetchStatus();
    statusBar.setTitle(tray.menuBarTitle(status != null and status.?.online));

    // Create menu delegate (ObjC MenuHandler)
    var delegate = try MenuDelegate.create();
    g_delegate = delegate;

    // Register callbacks
    delegate.setJoinNetworkWithIdCallback(joinNetworkWithIdHandler);
    delegate.setCopyNodeIdCallback(copyNodeIdHandler);
    delegate.setMenuNeedsUpdateCallback(menuNeedsUpdateHandler);
    delegate.setLeaveNetworkCallback(leaveNetworkHandler);

    // Create menu and wire delegate
    var menu = try cocoa.Menu.create();
    g_menu = menu;
    menu.setDelegate(delegate.native);

    // Build initial menu contents
    menuNeedsUpdateHandler();

    // Attach menu to status bar
    statusBar.setMenu(&menu);

    // Activate and run event loop
    app.activate();
    app.run();
}

/// Called by ObjC delegate every time the menu is about to open.
/// Rebuilds the entire menu from live API data.
fn menuNeedsUpdateHandler() void {
    var menu = g_menu orelse return;
    const delegate = g_delegate orelse return;

    menu.removeAllItems();

    // Fetch and parse status
    const status = fetchStatus();
    const online = status != null and status.?.online;

    // Update menu bar indicator
    if (g_status_bar) |*sb| sb.setTitle(tray.menuBarTitle(online));

    // Header
    menu.addItem(tray.menuHeaderText(online)) catch {};
    menu.addSeparator();

    // Fetch and display networks
    const net_response = g_client.get("/network") catch null;
    defer if (net_response) |r| g_allocator.free(r);

    if (net_response) |response| {
        g_network_count = tray.parseNetworks(g_allocator, response, &g_networks) catch 0;
    } else {
        g_network_count = 0;
        menu.addItem("  (cannot reach service)") catch {};
    }

    if (g_network_count == 0 and net_response != null) {
        menu.addItem("  No networks joined") catch {};
    }

    var i: usize = 0;
    while (i < g_network_count) : (i += 1) {
        const info = &g_networks[i];

        // Network title
        var title_buf: [256]u8 = undefined;
        menu.addItem(tray.formatNetworkTitle(info, &title_buf)) catch continue;

        // Status + IP detail
        var detail_buf: [256]u8 = undefined;
        menu.addItem(tray.formatNetworkDetail(info, &detail_buf)) catch continue;

        // Leave action
        const leave_tag: c_int = @intCast(@as(i32, @intCast(100 + i)));
        menu.addItemWithHandler("  Leave Network", leave_tag, delegate.native) catch {};

        menu.addSeparator();
    }

    // Action items
    menu.addItemWithHandler("Join Network...", TAG_JOIN, delegate.native) catch {};
    menu.addSeparator();
    menu.addItemWithHandler("Copy Node ID", TAG_COPY_ID, delegate.native) catch {};
    menu.addItemWithHandler("Quit", TAG_QUIT, delegate.native) catch {};
}

/// Join a network by ID (called from ObjC dialog)
fn joinNetworkWithIdHandler(networkId: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path = tray.formatNetworkPath(networkId, &path_buf) orelse return;
    const response = g_client.post(path, "{}") catch return;
    g_allocator.free(response);
}

/// Leave a network by stored index
fn leaveNetworkHandler(index: usize) void {
    if (index >= g_network_count) return;
    const id = g_networks[index].getId();
    if (id.len == 0) return;

    var path_buf: [256]u8 = undefined;
    const path = tray.formatNetworkPath(id, &path_buf) orelse return;
    const response = g_client.delete(path) catch return;
    g_allocator.free(response);
}

/// Copy node ID to clipboard
fn copyNodeIdHandler() void {
    const status = fetchStatus() orelse return;
    const addr = status.getAddress();
    if (addr.len == 0) return;

    var buf: [256:0]u8 = undefined;
    @memcpy(buf[0..addr.len], addr);
    buf[addr.len] = 0;
    menu_delegate.copyToClipboard(&buf);
}

/// Fetch and parse service status, returns null on any failure
fn fetchStatus() ?tray.ServiceStatus {
    const response = g_client.get("/status") catch return null;
    defer g_allocator.free(response);
    return tray.parseStatus(g_allocator, response) catch null;
}

/// Read auth token from standard ZeroTea/upstream paths
fn readAuthToken(allocator: std.mem.Allocator) ![]const u8 {
    const paths = [_][]const u8{
        "/tmp/zt-zig-home/authtoken.secret",
        "/tmp/zt-home/authtoken.secret",
        "/var/lib/zerotier-one/authtoken.secret",
        "/Library/Application Support/ZeroTier/One/authtoken.secret",
    };

    for (paths) |path| {
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return error.TokenNotFound;
}
