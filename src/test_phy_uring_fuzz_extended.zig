/// Extended fuzz testing for phy_uring.zig
///
/// Additional adversarial scenarios and stress tests to uncover
/// edge cases, race conditions, and resource exhaustion bugs.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const phy_uring = if (builtin.os.tag == .linux) @import("node/phy_uring.zig") else struct {};

test "fuzz: Interleaved socket operations - chaos test" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    var prng = std.rand.DefaultPrng.init(88888);
    const random = prng.random();

    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    // Track open sockets
    var sockets = std.ArrayList(*phy_uring.PhySocket).init(testing.allocator);
    defer sockets.deinit();

    // Chaos: randomly create sockets, send packets, close sockets, poll
    for (0..1000) |_| {
        const action = random.intRangeAtMost(u8, 0, 4);

        switch (action) {
            0 => {
                // Create new socket
                if (sockets.items.len < 50) {
                    const port = random.intRangeAtMost(u16, 30000, 50000);
                    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
                    if (phy.udpBind(local, null, 0)) |sock| {
                        sockets.append(sock) catch {};
                    } else |_| {}
                }
            },
            1 => {
                // Send on random socket
                if (sockets.items.len > 0) {
                    const idx = random.intRangeAtMost(usize, 0, sockets.items.len - 1);
                    const sock = sockets.items[idx];
                    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
                    _ = phy.udpSend(sock, dest, "fuzz");
                }
            },
            2 => {
                // Close random socket
                if (sockets.items.len > 0) {
                    const idx = random.intRangeAtMost(usize, 0, sockets.items.len - 1);
                    const sock = sockets.swapRemove(idx);
                    phy.close(sock);
                }
            },
            3 => {
                // Poll
                phy.poll(0) catch {};
            },
            4 => {
                // Wakeup
                phy.wakeup();
            },
        }
    }

    // Clean up remaining sockets
    for (sockets.items) |sock| {
        phy.close(sock);
    }
}

test "fuzz: Memory pressure - allocator fails randomly" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;

    // Failing allocator that randomly fails
    const FailingAllocator = struct {
        backing: std.mem.Allocator,
        fail_rate: u8, // 0-255, higher = more failures
        prng: std.rand.DefaultPrng,

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.prng.random().int(u8) < self.fail_rate) {
                return null; // Simulate OOM
            }
            return self.backing.rawAlloc(len, ptr_align, ret_addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.backing.rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(buf, buf_align, ret_addr);
        }
    };

    var failing = FailingAllocator{
        .backing = testing.allocator,
        .fail_rate = 20, // 20/255 ~= 8% failure rate
        .prng = std.rand.DefaultPrng.init(55555),
    };

    const allocator = std.mem.Allocator{
        .ptr = &failing,
        .vtable = &.{
            .alloc = FailingAllocator.alloc,
            .resize = FailingAllocator.resize,
            .free = FailingAllocator.free,
        },
    };

    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    // Try to init with failing allocator
    var phy = phy_uring.PhyUring.init(allocator, handler, false, false) catch |err| {
        std.debug.print("Expected failure with OOM: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    // Try operations that might hit OOM
    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = phy.udpBind(local, null, 0) catch return; // May fail
    defer phy.close(sock);

    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);

    // Send many packets - some will fail due to OOM
    for (0..100) |_| {
        _ = phy.udpSend(sock, dest, "test data");
        phy.poll(0) catch {};
    }
}

test "fuzz: BufferPool double-free detection" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pool = try phy_uring.BufferPool.init(testing.allocator);
    defer pool.deinit();

    const buf = pool.acquire().?;

    // Release once
    pool.release(buf.index);

    // Release again - should not crash (append to free_list is safe)
    pool.release(buf.index);

    // Pool might have duplicates now, but shouldn't crash
    // This tests resilience to user error
}

test "fuzz: Submission queue exhaustion" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try phy.udpBind(local, null, 0);
    defer phy.close(sock);

    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);

    // Fire off way more operations than SQ can hold (256 entries)
    // Should trigger SQ full handling
    for (0..500) |_| {
        _ = phy.udpSend(sock, dest, "data");
    }

    // Process in batches
    for (0..10) |_| {
        phy.poll(10) catch {};
    }
}

test "fuzz: Socket close with pending operations stress" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    // Repeat: create socket, queue many ops, close immediately
    for (0..50) |_| {
        const port = 40000 + @as(u16, @intCast(@mod(@as(usize, @intCast(std.time.milliTimestamp())), 10000)));
        const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const sock = phy.udpBind(local, null, 0) catch continue;

        const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);

        // Queue many operations
        for (0..20) |_| {
            _ = phy.udpSend(sock, dest, "pending");
        }

        // Close immediately without waiting for completions
        phy.close(sock);

        // Operations should complete with fd mismatch detection
        phy.poll(1) catch {};
    }
}

test "fuzz: Large packet fragmentation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, data: []const u8) void {
                _ = data;
            }
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try phy.udpBind(local, null, 0);
    defer phy.close(sock);

    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);

    // Send packets of various large sizes
    // UDP max is 65507 bytes (65535 - 8 UDP header - 20 IP header)
    const sizes = [_]usize{ 8192, 16384, 32768, 65000, 65507 };

    for (sizes) |size| {
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);

        @memset(data, 0xFF);

        _ = phy.udpSend(sock, dest, data);
        phy.poll(10) catch {};
    }
}

test "fuzz: Rapid poll with no operations" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    // Poll repeatedly with no pending operations
    // Should not crash or leak
    for (0..1000) |_| {
        phy.poll(0) catch {};
    }
}

test "fuzz: Mixed IPv4/IPv6 addresses" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    // Try IPv4
    const local_v4 = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock_v4 = phy.udpBind(local_v4, null, 0) catch return;
    defer phy.close(sock_v4);

    // Try IPv6 (might not work on all systems)
    const local_v6 = net.Address.initIp6([_]u8{0} ** 15 ++ [_]u8{1}, 0, 0, 0);
    const sock_v6 = phy.udpBind(local_v6, null, 0) catch {
        std.debug.print("IPv6 not available, skipping\n", .{});
        return;
    };
    defer phy.close(sock_v6);

    // Send on both
    const dest_v4 = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
    _ = phy.udpSend(sock_v4, dest_v4, "ipv4");

    const dest_v6 = net.Address.initIp6([_]u8{0} ** 15 ++ [_]u8{1}, 9999, 0, 0);
    _ = phy.udpSend(sock_v6, dest_v6, "ipv6");

    phy.poll(10) catch {};
}

test "fuzz: Pathological poll patterns" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    var prng = std.rand.DefaultPrng.init(77777);
    const random = prng.random();

    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try phy.udpBind(local, null, 0);
    defer phy.close(sock);

    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);

    // Send some packets
    for (0..100) |_| {
        _ = phy.udpSend(sock, dest, "data");
    }

    // Poll with pathological patterns
    for (0..500) |_| {
        const timeout = random.intRangeAtMost(u64, 0, 100);
        phy.poll(timeout) catch {};

        // Sometimes send more
        if (random.boolean()) {
            _ = phy.udpSend(sock, dest, "more");
        }
    }
}

test "fuzz: All buffers exhausted scenario" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    const handler = phy_uring.PhyHandler{
        .on_datagram = struct {
            fn f(_: *phy_uring.PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {
                // Never release buffer - simulate slow consumer
                std.time.sleep(std.time.ns_per_ms * 10);
            }
        }.f,
        .on_tcp_connect = undefined,
        .on_tcp_accept = undefined,
        .on_tcp_close = undefined,
        .on_tcp_data = undefined,
        .on_tcp_writable = undefined,
        .on_fd_activity = undefined,
    };

    var phy = phy_uring.PhyUring.init(testing.allocator, handler, false, false) catch |err| {
        std.debug.print("io_uring not available: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer phy.deinit();

    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try phy.udpBind(local, null, 0);
    defer phy.close(sock);

    // Try to exhaust buffers by queuing receives
    // Buffer pool has 256 buffers, each socket has pending recv
    for (0..300) |_| {
        phy.poll(1) catch {};
    }

    // Should handle buffer exhaustion gracefully
}
