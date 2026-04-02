/// Fuzz testing for phy_uring.zig
///
/// Tests the io_uring backend with randomized inputs to find edge cases,
/// race conditions, and resource leaks.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Only run on Linux
const phy_uring = if (builtin.os.tag == .linux) @import("node/phy_uring.zig") else struct {};

test "fuzz: BufferPool stress test - rapid acquire/release" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pool = try phy_uring.BufferPool.init(testing.allocator);
    defer pool.deinit();

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // Track acquired buffers
    var acquired = std.ArrayList(usize).init(testing.allocator);
    defer acquired.deinit();

    // Fuzz for 10000 iterations
    for (0..10000) |_| {
        const action = random.intRangeAtMost(u8, 0, 1);

        if (action == 0 and acquired.items.len < 256) {
            // Try to acquire
            if (pool.acquire()) |buf| {
                try acquired.append(buf.index);
            }
        } else if (acquired.items.len > 0) {
            // Release random buffer
            const idx = random.intRangeAtMost(usize, 0, acquired.items.len - 1);
            const buf_idx = acquired.swapRemove(idx);
            pool.release(buf_idx);
        }
    }

    // Clean up remaining
    for (acquired.items) |buf_idx| {
        pool.release(buf_idx);
    }

    // Verify all buffers returned
    try testing.expectEqual(@as(usize, 256), pool.free_list.items.len);
}

test "fuzz: BufferPool concurrent access" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pool = try phy_uring.BufferPool.init(testing.allocator);
    defer pool.deinit();

    const ThreadContext = struct {
        pool: *phy_uring.BufferPool,
        iterations: usize,
    };

    const workerFn = struct {
        fn run(ctx: ThreadContext) void {
            var prng = std.rand.DefaultPrng.init(@intFromPtr(ctx.pool));
            const random = prng.random();

            for (0..ctx.iterations) |_| {
                // Acquire
                if (ctx.pool.acquire()) |buf| {
                    // Hold for random time (simulate work)
                    const hold_time = random.intRangeAtMost(u32, 1, 100);
                    std.time.sleep(hold_time);

                    // Release
                    ctx.pool.release(buf.index);
                }
            }
        }
    }.run;

    // Spawn multiple threads
    const num_threads = 4;
    var threads: [num_threads]std.Thread = undefined;

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, workerFn, .{ThreadContext{
            .pool = &pool,
            .iterations = 1000,
        }});
    }

    for (threads) |thread| {
        thread.join();
    }

    // All buffers should be back in pool
    try testing.expectEqual(@as(usize, 256), pool.free_list.items.len);
}

test "fuzz: Random UDP send sizes and destinations" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    var prng = std.rand.DefaultPrng.init(67890);
    const random = prng.random();

    // Mock handler that does nothing
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

    // Bind a socket
    const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const sock = try phy.udpBind(local, null, 0);

    // Send random-sized packets to random destinations
    for (0..100) |_| {
        // Random size (0 to 1500 bytes)
        const size = random.intRangeAtMost(usize, 0, 1500);
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);

        // Fill with random data
        random.bytes(data);

        // Random destination
        const port = random.intRangeAtMost(u16, 10000, 60000);
        const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

        // Send (may fail, that's ok for fuzz test)
        _ = phy.udpSend(sock, dest, data);

        // Poll to process completions
        phy.poll(0) catch {};
    }

    phy.close(sock);
}

test "fuzz: Rapid socket open/close" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    var prng = std.rand.DefaultPrng.init(11111);
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

    // Rapidly create and destroy sockets
    for (0..100) |_| {
        const port = random.intRangeAtMost(u16, 20000, 60000);
        const local = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

        const sock = phy.udpBind(local, null, 0) catch continue;

        // Maybe send a packet
        if (random.boolean()) {
            const data = "test";
            const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
            _ = phy.udpSend(sock, dest, data);
        }

        // Poll randomly
        if (random.boolean()) {
            phy.poll(0) catch {};
        }

        // Close immediately (may have pending operations!)
        phy.close(sock);

        // Poll after close to process completions
        phy.poll(0) catch {};
    }
}

test "fuzz: BufferPool exhaustion handling" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pool = try phy_uring.BufferPool.init(testing.allocator);
    defer pool.deinit();

    // Acquire all 256 buffers
    var buffers: [256]usize = undefined;
    for (&buffers, 0..) |*buf, i| {
        const acquired = pool.acquire() orelse {
            try testing.expect(false); // Should not fail before 256
            return;
        };
        buf.* = acquired.index;
        try testing.expectEqual(i, acquired.index);
    }

    // Pool should be exhausted
    try testing.expect(pool.acquire() == null);
    try testing.expect(pool.acquire() == null);

    // Release half
    for (buffers[0..128]) |buf_idx| {
        pool.release(buf_idx);
    }

    // Should be able to acquire 128 more
    for (0..128) |_| {
        try testing.expect(pool.acquire() != null);
    }

    // Exhausted again
    try testing.expect(pool.acquire() == null);

    // Release all remaining
    for (buffers[128..]) |buf_idx| {
        pool.release(buf_idx);
    }
}

test "fuzz: Invalid buffer indices are caught" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pool = try phy_uring.BufferPool.init(testing.allocator);
    defer pool.deinit();

    // getBuffer with out-of-bounds index should panic
    const result = std.testing.expectPanic(struct {
        fn panicFn(p: *phy_uring.BufferPool) void {
            _ = p.getBuffer(999); // Way out of bounds
        }
    }.panicFn, .{&pool});

    try testing.expect(result);
}

test "fuzz: Maximum packet size handling" {
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

    // Test various sizes
    const sizes = [_]usize{ 0, 1, 64, 512, 1024, 1472, 2048, 8192, 65535 };

    for (sizes) |size| {
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);

        @memset(data, 0xAA);

        const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
        _ = phy.udpSend(sock, dest, data);

        phy.poll(1) catch {};
    }
}

test "fuzz: Concurrent sends on same socket" {
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

    // Fire off many sends without waiting
    const dest = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9999);
    for (0..1000) |i| {
        var buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "packet {d}", .{i});
        _ = phy.udpSend(sock, dest, data);
    }

    // Process all completions
    for (0..100) |_| {
        phy.poll(10) catch {};
    }
}

test "fuzz: Zero-length packets" {
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
    const empty: []const u8 = &.{};

    // Send many zero-length packets
    for (0..100) |_| {
        _ = phy.udpSend(sock, dest, empty);
    }

    phy.poll(100) catch {};
}

test "fuzz: Random wakeup calls during operation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const net = std.net;
    var prng = std.rand.DefaultPrng.init(99999);
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

    for (0..500) |_| {
        // Random action
        const action = random.intRangeAtMost(u8, 0, 2);

        switch (action) {
            0 => _ = phy.udpSend(sock, dest, "data"),
            1 => phy.wakeup(),
            2 => phy.poll(1) catch {},
        }
    }
}
