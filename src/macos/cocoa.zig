/// Cocoa/AppKit FFI bindings for macOS GUI
///
/// Zig wrappers for Objective-C Cocoa/AppKit APIs needed for a menu bar app.
/// Uses objc_msgSend directly — no .m files needed for basic operations.

const std = @import("std");

const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

const id = ?*anyopaque;
const Class = ?*anyopaque;
const SEL = ?*anyopaque;

extern "C" fn objc_msgSend(self: id, op: SEL, ...) id;

fn msgSend0(self: id, selector: SEL) id {
    const impl: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return impl(self, selector);
}

fn msgSend1(self: id, selector: SEL, arg1: id) id {
    const impl: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return impl(self, selector, arg1);
}

fn msgSend1f(self: id, selector: SEL, arg1: f64) id {
    const impl: *const fn (id, SEL, f64) callconv(.c) id = @ptrCast(&objc_msgSend);
    return impl(self, selector, arg1);
}

fn msgSend1ptr(self: id, selector: SEL, arg1: ?*const anyopaque) id {
    const impl: *const fn (id, SEL, ?*const anyopaque) callconv(.c) id = @ptrCast(&objc_msgSend);
    return impl(self, selector, arg1);
}

fn msgSend3(self: id, selector: SEL, arg1: id, arg2: SEL, arg3: id) id {
    const impl: *const fn (id, SEL, id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return impl(self, selector, arg1, arg2, arg3);
}

fn msgSend1i(self: id, selector: SEL, arg1: c_int) id {
    const impl: *const fn (id, SEL, c_int) callconv(.c) id = @ptrCast(&c.objc_msgSend);
    return impl(self, selector, arg1);
}

/// NSApplication
pub const Application = struct {
    native: id,

    pub fn sharedApplication() Application {
        const NSApplication = c.objc_getClass("NSApplication");
        return .{ .native = msgSend0(NSApplication, sel("sharedApplication")) };
    }

    pub fn setActivationPolicy(self: Application) void {
        _ = msgSend1i(self.native, sel("setActivationPolicy:"), 1); // Accessory
    }

    pub fn activate(self: Application) void {
        _ = msgSend1i(self.native, sel("activateIgnoringOtherApps:"), 1);
    }

    pub fn run(self: Application) void {
        _ = msgSend0(self.native, sel("run"));
    }

    pub fn terminate(self: Application) void {
        _ = msgSend1(self.native, sel("terminate:"), null);
    }
};

/// NSStatusBar item in the menu bar
pub const StatusBar = struct {
    item: id,

    pub fn create() !StatusBar {
        const NSStatusBar = c.objc_getClass("NSStatusBar");
        const systemBar = msgSend0(NSStatusBar, sel("systemStatusBar"));
        const item = msgSend1f(systemBar, sel("statusItemWithLength:"), -1.0);

        if (item == null) return error.FailedToCreateStatusItem;

        return .{ .item = item };
    }

    pub fn setTitle(self: *StatusBar, title: []const u8) void {
        const nsstring = createNSString(title);
        const button = msgSend0(self.item, sel("button"));
        if (button != null) {
            _ = msgSend1(button, sel("setTitle:"), nsstring);
        }
    }

    pub fn setMenu(self: *StatusBar, menu: *Menu) void {
        _ = msgSend1(self.item, sel("setMenu:"), menu.native);
    }
};

/// NSMenu
pub const Menu = struct {
    native: id,

    pub fn create() !Menu {
        const NSMenu = c.objc_getClass("NSMenu");
        const menu = msgSend0(NSMenu, sel("alloc"));
        if (menu == null) return error.FailedToCreateMenu;
        _ = msgSend0(menu, sel("init"));
        _ = msgSend1i(menu, sel("setAutoenablesItems:"), 0);
        return .{ .native = menu };
    }

    pub fn setDelegate(self: *Menu, delegate: id) void {
        const setDelegateFn = @extern(*const fn (id, id) callconv(.c) void, .{ .name = "setMenuDelegate" });
        setDelegateFn(self.native, delegate);
    }

    /// Add a disabled label item (no action)
    pub fn addItem(self: *Menu, title: []const u8) !void {
        const nsstring = createNSString(title);
        const NSMenuItem = c.objc_getClass("NSMenuItem");
        const menuItem = msgSend0(NSMenuItem, sel("alloc"));
        const emptyString = createNSString("");
        _ = msgSend3(menuItem, sel("initWithTitle:action:keyEquivalent:"), nsstring, null, emptyString);
        _ = msgSend1i(menuItem, sel("setEnabled:"), 0);
        _ = msgSend1(self.native, sel("addItem:"), menuItem);
    }

    /// Add an actionable item with a tag and handler target
    pub fn addItemWithHandler(self: *Menu, title: []const u8, tag: c_int, handler: id) !void {
        var titleBuf: [256:0]u8 = undefined;
        const len = @min(title.len, 255);
        @memcpy(titleBuf[0..len], title[0..len]);
        titleBuf[len] = 0;

        const createMenuItemFn = @extern(*const fn ([*:0]const u8, c_int) callconv(.c) id, .{ .name = "createMenuItem" });
        const menuItem = createMenuItemFn(@ptrCast(&titleBuf), tag);
        _ = msgSend1(menuItem, sel("setTarget:"), handler);
        _ = msgSend1(self.native, sel("addItem:"), menuItem);
    }

    pub fn addSeparator(self: *Menu) void {
        const NSMenuItem = c.objc_getClass("NSMenuItem");
        const separator = msgSend0(NSMenuItem, sel("separatorItem"));
        _ = msgSend1(self.native, sel("addItem:"), separator);
    }

    pub fn removeAllItems(self: *Menu) void {
        _ = msgSend0(self.native, sel("removeAllItems"));
    }
};

fn sel(name: [:0]const u8) SEL {
    return c.sel_registerName(name.ptr);
}

fn createNSString(str: []const u8) id {
    const Static = struct {
        threadlocal var buffer: [512]u8 = undefined;
    };
    const len = @min(str.len, 511);
    @memcpy(Static.buffer[0..len], str[0..len]);
    Static.buffer[len] = 0;

    const NSString = c.objc_getClass("NSString");
    const cstr: ?*const anyopaque = @ptrCast(&Static.buffer);
    return msgSend1ptr(NSString, sel("stringWithUTF8String:"), cstr);
}
