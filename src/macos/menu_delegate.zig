/// Menu Delegate — bridges ObjC menu actions to Zig callbacks
///
/// Exports functions that the ObjC MenuHandler calls, and stores
/// Zig-side callback function pointers set by the main app.

const std = @import("std");

const id = ?*anyopaque;

// C functions from menu_bridge_blocks.m
extern "C" fn createMenuHandler() id;
extern "C" fn createMenuItem(title: [*:0]const u8, tag: c_int) id;
pub extern "C" fn copyToClipboard(text: [*:0]const u8) void;
pub extern "C" fn showJoinNetworkDialog() void;
pub extern "C" fn setMenuDelegate(menu: id, handler: id) void;

// Callback storage
var g_join_network_callback: ?*const fn () void = null;
var g_join_network_with_id_callback: ?*const fn ([]const u8) void = null;
var g_show_networks_callback: ?*const fn () void = null;
var g_show_status_callback: ?*const fn () void = null;
var g_quit_callback: ?*const fn () void = null;
var g_copy_node_id_callback: ?*const fn () void = null;
var g_menu_needs_update_callback: ?*const fn () void = null;
var g_leave_network_callback: ?*const fn (usize) void = null;

// Exports called from ObjC
export fn zig_menuJoinNetwork() void {
    if (g_join_network_callback) |cb| cb();
}

export fn zig_menuJoinNetwork_withId(networkIdPtr: [*:0]const u8) void {
    const networkId = std.mem.span(networkIdPtr);
    if (g_join_network_with_id_callback) |cb| cb(networkId);
}

export fn zig_menuShowNetworks() void {
    if (g_show_networks_callback) |cb| cb();
}

export fn zig_menuShowStatus() void {
    if (g_show_status_callback) |cb| cb();
}

export fn zig_menuQuit() void {
    if (g_quit_callback) |cb| cb();
}

export fn zig_menuCopyNodeId() void {
    if (g_copy_node_id_callback) |cb| cb();
}

export fn zig_menuNeedsUpdate() void {
    if (g_menu_needs_update_callback) |cb| cb();
}

export fn zig_leaveNetwork(index: c_int) void {
    if (g_leave_network_callback) |cb| cb(@intCast(index));
}

/// MenuDelegate wraps the ObjC MenuHandler object
pub const MenuDelegate = struct {
    native: id,

    pub fn create() !MenuDelegate {
        const obj = createMenuHandler();
        if (obj == null) return error.FailedToCreateHandler;
        return .{ .native = obj };
    }

    pub fn setJoinNetworkCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_join_network_callback = cb;
    }

    pub fn setJoinNetworkWithIdCallback(_: *MenuDelegate, cb: *const fn ([]const u8) void) void {
        g_join_network_with_id_callback = cb;
    }

    pub fn setShowNetworksCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_show_networks_callback = cb;
    }

    pub fn setShowStatusCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_show_status_callback = cb;
    }

    pub fn setQuitCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_quit_callback = cb;
    }

    pub fn setCopyNodeIdCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_copy_node_id_callback = cb;
    }

    pub fn setMenuNeedsUpdateCallback(_: *MenuDelegate, cb: *const fn () void) void {
        g_menu_needs_update_callback = cb;
    }

    pub fn setLeaveNetworkCallback(_: *MenuDelegate, cb: *const fn (usize) void) void {
        g_leave_network_callback = cb;
    }
};
