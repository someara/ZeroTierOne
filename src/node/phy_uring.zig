/// io_uring-based Physical Layer I/O (Linux 5.1+ only)
///
/// High-performance async I/O backend using io_uring for Linux systems.
/// Provides significant performance improvements over poll() for high packet rates
/// through batched submission/completion and reduced syscall overhead.
///
/// Falls back gracefully to poll() backend if io_uring is unavailable.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = mem.Allocator;

const phy_mod = @import("phy.zig");
const PhySocket = phy_mod.PhySocket;
const PhySocketImpl = phy_mod.PhySocketImpl;
const PhyHandler = phy_mod.PhyHandler;

// Only compile on Linux
comptime {
    if (builtin.os.tag != .linux) {
        @compileError("phy_uring is only supported on Linux");
    }
}

const IoUring = linux.IoUring;

// ── Buffer Pool ────────────────────────────────────────────────────────

/// Pre-allocated buffer pool for receive operations
/// Using a ring buffer approach to recycle buffers efficiently
/// Thread-safe: All operations protected by mutex
const BufferPool = struct {
    const BUFFER_SIZE = 2048; // Size for each receive buffer
    const BUFFER_COUNT = 256; // Number of pre-allocated buffers

    buffers: []align(std.mem.page_size) [BUFFER_SIZE]u8,
    free_list: std.ArrayList(usize), // Indices of free buffers
    allocator: Allocator,
    lock: std.Thread.Mutex,

    fn init(allocator: Allocator) !BufferPool {
        const buffers = try allocator.alignedAlloc(
            [BUFFER_SIZE]u8,
            std.mem.page_size,
            BUFFER_COUNT,
        );
        errdefer allocator.free(buffers);

        var free_list = try std.ArrayList(usize).initCapacity(allocator, BUFFER_COUNT);
        errdefer free_list.deinit();

        // Initially all buffers are free
        for (0..BUFFER_COUNT) |i| {
            try free_list.append(i);
        }

        return BufferPool{
            .buffers = buffers,
            .free_list = free_list,
            .allocator = allocator,
            .lock = .{},
        };
    }

    fn deinit(self: *BufferPool) void {
        self.free_list.deinit();
        self.allocator.free(self.buffers);
    }

    /// Get a free buffer, returns null if all buffers are in use
    /// Thread-safe: Protected by mutex
    fn acquire(self: *BufferPool) ?struct { index: usize, buffer: []u8 } {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.free_list.items.len == 0) return null;
        const index = self.free_list.pop();
        return .{
            .index = index,
            .buffer = &self.buffers[index],
        };
    }

    /// Return a buffer to the pool
    /// Thread-safe: Protected by mutex
    fn release(self: *BufferPool, index: usize) void {
        std.debug.assert(index < BUFFER_COUNT);

        self.lock.lock();
        defer self.lock.unlock();

        self.free_list.append(index) catch {
            // If append fails, we just lose the buffer (shouldn't happen)
            std.debug.print("phy_uring: WARNING: failed to return buffer to pool\n", .{});
        };
    }

    fn getBuffer(self: *BufferPool, index: usize) []u8 {
        std.debug.assert(index < BUFFER_COUNT);
        return &self.buffers[index];
    }
};

// ── Operation Context ──────────────────────────────────────────────────

/// Context attached to each io_uring operation via user_data
/// OWNED: All heap-allocated fields must be freed in freeOpContext
const OpContext = struct {
    const OpType = enum {
        recv_udp,
        send_udp,
        recv_tcp,
        send_tcp,
        accept,
        connect,
    };

    op_type: OpType,
    socket: *PhySocketImpl,
    buffer_index: ?usize, // For recv operations

    // Heap-allocated structures for io_uring (OWNED)
    // These must remain valid until operation completes
    iov: ?*posix.iovec, // OWNED: heap-allocated for send operations
    msg: ?*posix.msghdr, // OWNED: heap-allocated for recvmsg
    msg_const: ?*posix.msghdr_const, // OWNED: heap-allocated for sendmsg
    sender_addr: ?*posix.sockaddr_storage, // OWNED: for recvmsg sender address
    dest_addr: ?*net.Address, // OWNED: for sendmsg destination address
    data_copy: ?[]u8, // OWNED: for sendmsg data buffer
};

// ── Main PhyUring Structure ────────────────────────────────────────────

/// io_uring-based physical layer I/O manager
/// Thread-safe: sockets and op_contexts protected by mutex
pub const PhyUring = struct {
    allocator: Allocator,
    handler: PhyHandler,
    ring: IoUring,
    sockets: std.ArrayList(*PhySocketImpl),
    buffer_pool: BufferPool,
    op_contexts: std.ArrayList(*OpContext), // Active operations

    // Wake-up eventfd for interrupting from another thread
    wakeup_fd: posix.fd_t,

    // Thread safety (STYLE.md Rule 8.2: Lock discipline)
    state_lock: std.Thread.Mutex, // Protects sockets and op_contexts

    // Configuration
    no_delay: bool, // TCP_NODELAY
    no_check: bool, // SO_NO_CHECK

    const RING_ENTRIES = 256; // Submission queue size

    /// Initialize PhyUring with io_uring support
    /// Returns error if io_uring is not available (kernel < 5.1)
    pub fn init(
        allocator: Allocator,
        handler: PhyHandler,
        no_delay: bool,
        no_check: bool,
    ) !PhyUring {
        // Try to initialize io_uring
        // This will fail on older kernels
        var ring = IoUring.init(RING_ENTRIES, 0) catch |err| {
            std.debug.print("phy_uring: io_uring initialization failed: {}\n", .{err});
            return err;
        };
        errdefer ring.deinit();

        // Create eventfd for wakeup mechanism
        const wakeup_fd = try posix.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
        errdefer posix.close(wakeup_fd);

        // Initialize buffer pool
        var buffer_pool = try BufferPool.init(allocator);
        errdefer buffer_pool.deinit();

        return PhyUring{
            .allocator = allocator,
            .handler = handler,
            .ring = ring,
            .sockets = std.ArrayList(*PhySocketImpl).init(allocator),
            .buffer_pool = buffer_pool,
            .op_contexts = std.ArrayList(*OpContext).init(allocator),
            .wakeup_fd = wakeup_fd,
            .state_lock = .{},
            .no_delay = no_delay,
            .no_check = no_check,
        };
    }

    /// Clean up PhyUring resources
    pub fn deinit(self: *PhyUring) void {
        // Clean up all sockets
        for (self.sockets.items) |socket| {
            if (socket.socket >= 0) {
                posix.close(socket.socket);
            }
            self.allocator.destroy(socket);
        }
        self.sockets.deinit();

        // Clean up operation contexts
        for (self.op_contexts.items) |ctx| {
            self.allocator.destroy(ctx);
        }
        self.op_contexts.deinit();

        // Clean up buffer pool
        self.buffer_pool.deinit();

        // Close wakeup fd
        posix.close(self.wakeup_fd);

        // Deinitialize io_uring
        self.ring.deinit();
    }

    /// Main event loop - processes io_uring completions
    /// timeout_ms: timeout in milliseconds (0 = don't wait, ~0 = wait forever)
    pub fn poll(self: *PhyUring, timeout_ms: u64) !void {
        // Submit any pending operations
        const submitted = try self.ring.submit();
        _ = submitted;

        // Wait for completions (with timeout)
        const wait_nr: u32 = 1; // Wait for at least 1 completion
        var cqes: [32]linux.io_uring_cqe = undefined;

        // Calculate timeout in nanoseconds for io_uring
        const timeout_ns = if (timeout_ms == std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            timeout_ms * 1_000_000;

        _ = timeout_ns; // TODO: Use timeout in submit_and_wait

        // Get completions
        const count = try self.ring.copy_cqes(&cqes, wait_nr);

        // Process each completion
        for (cqes[0..count]) |*cqe| {
            self.processCqe(cqe);
        }

        // Advance completion queue
        self.ring.cq_advance(count);
    }

    /// Send UDP datagram (non-blocking)
    pub fn udpSend(
        self: *PhyUring,
        sock: *PhySocket,
        to: net.Address,
        data: []const u8,
    ) !void {
        const socket_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));

        // Allocate operation context
        const ctx = try self.allocator.create(OpContext);
        errdefer self.allocator.destroy(ctx);

        // Copy data (MUST outlive udpSend)
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        // Heap-allocate iovec (MUST outlive udpSend)
        const iov = try self.allocator.create(posix.iovec);
        errdefer self.allocator.destroy(iov);
        iov.* = .{
            .base = @constCast(data_copy.ptr),
            .len = data_copy.len,
        };

        // Heap-allocate destination address (MUST outlive udpSend)
        const dest_addr = try self.allocator.create(net.Address);
        errdefer self.allocator.destroy(dest_addr);
        dest_addr.* = to;

        // Heap-allocate msghdr_const (MUST outlive udpSend)
        const msg = try self.allocator.create(posix.msghdr_const);
        errdefer self.allocator.destroy(msg);
        msg.* = mem.zeroes(posix.msghdr_const);
        msg.iov = @ptrCast(iov);
        msg.iovlen = 1;
        msg.name = @ptrCast(@constCast(&dest_addr.any));
        msg.namelen = dest_addr.getOsSockLen();

        // Setup operation context
        ctx.* = .{
            .op_type = .send_udp,
            .socket = socket_impl,
            .buffer_index = null,
            .iov = iov,
            .msg = null,
            .msg_const = msg,
            .sender_addr = null,
            .dest_addr = dest_addr,
            .data_copy = data_copy,
        };

        // Submit sendmsg operation first (before adding to list)
        const user_data = @intFromPtr(ctx);
        _ = self.ring.sendmsg(user_data, socket_impl.socket, msg, 0) catch |err| {
            // BUG #12/#13 fix: If submission fails, clean up all allocated resources
            self.allocator.destroy(msg);
            self.allocator.destroy(dest_addr);
            self.allocator.destroy(iov);
            self.allocator.free(data_copy);
            self.allocator.destroy(ctx);
            return err;
        };

        // Add to list after successful submission
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.op_contexts.append(ctx) catch |err| {
            // BUG #12/#13 fix: If append fails, all resources are leaked
            self.allocator.destroy(msg);
            self.allocator.destroy(dest_addr);
            self.allocator.destroy(iov);
            self.allocator.free(data_copy);
            self.allocator.destroy(ctx);
            return err;
        };
    }

    /// Bind UDP socket to local address
    pub fn udpBind(
        self: *PhyUring,
        local_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        // Create UDP socket
        const fd = try posix.socket(
            local_addr.any.family,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        // Set SO_REUSEADDR
        try posix.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &mem.toBytes(@as(c_int, 1)),
        );

        // Set SO_NO_CHECK if requested (disable UDP checksums)
        if (self.no_check) {
            try posix.setsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.NO_CHECK,
                &mem.toBytes(@as(c_int, 1)),
            );
        }

        // Bind to local address
        try posix.bind(fd, &local_addr.any, local_addr.getOsSockLen());

        // Create socket implementation
        const socket_impl = try self.allocator.create(PhySocketImpl);
        errdefer self.allocator.destroy(socket_impl);

        socket_impl.* = .{
            .type = .udp,
            .socket = fd,
            .uptr = uptr,
            .local_port = local_addr.getPort(),
            .remote_addr = local_addr,
        };

        // Submit initial receive operation first
        // BUG #24 fix: Must succeed before adding socket to list
        self.submitUdpRecv(socket_impl) catch |err| {
            posix.close(fd);
            self.allocator.destroy(socket_impl);
            return err;
        };

        // Add to sockets list after successful setup
        self.state_lock.lock();
        defer self.state_lock.unlock();
        try self.sockets.append(socket_impl);

        return @ptrCast(socket_impl);
    }

    /// Create TCP listening socket
    pub fn tcpListen(
        self: *PhyUring,
        local_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        // TODO: Create TCP listening socket
        _ = self;
        _ = local_addr;
        _ = uptr;
        return error.NotImplementedYet;
    }

    /// Initiate TCP connection (non-blocking)
    pub fn tcpConnect(
        self: *PhyUring,
        remote_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        // TODO: Create TCP socket and initiate connection
        _ = self;
        _ = remote_addr;
        _ = uptr;
        return error.NotImplementedYet;
    }

    /// Send TCP data (non-blocking)
    pub fn tcpSend(
        self: *PhyUring,
        sock: *PhySocket,
        data: []const u8,
    ) !void {
        // TODO: Implement TCP send via IORING_OP_SEND
        _ = self;
        _ = sock;
        _ = data;
        return error.NotImplementedYet;
    }

    /// Close socket
    /// Thread-safe: Protected by state_lock
    pub fn close(self: *PhyUring, sock: *PhySocket) void {
        const socket_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));

        // Close file descriptor
        if (socket_impl.socket >= 0) {
            posix.close(socket_impl.socket);
            socket_impl.socket = -1;
        }

        self.state_lock.lock();
        defer self.state_lock.unlock();

        // Remove from socket list
        for (self.sockets.items, 0..) |item, i| {
            if (item == socket_impl) {
                _ = self.sockets.swapRemove(i);
                break;
            }
        }

        // TODO BUG #30: Should cancel pending operations with IORING_OP_ASYNC_CANCEL
        // For now, pending operations will complete with -ECANCELED
        // They reference freed socket (BUG #17/#28/#31) - needs refcounting

        // Free socket (UNSAFE if operations pending - see BUG #17/#28/#31)
        self.allocator.destroy(socket_impl);
    }

    /// Wake up the event loop from another thread
    pub fn wakeup(self: *PhyUring) void {
        // Write to eventfd to wake up io_uring_enter()
        const value: u64 = 1;
        _ = posix.write(self.wakeup_fd, mem.asBytes(&value)) catch {};
    }

    // ── Internal Helpers ───────────────────────────────────────────────

    /// Submit a receive operation for a UDP socket
    fn submitUdpRecv(self: *PhyUring, socket: *PhySocketImpl) !void {
        // Get a buffer from the pool
        const buf_info = self.buffer_pool.acquire() orelse return error.NoBuffersAvailable;
        errdefer self.buffer_pool.release(buf_info.index);

        // Allocate operation context
        const ctx = try self.allocator.create(OpContext);
        errdefer self.allocator.destroy(ctx);

        // Heap-allocate iovec (MUST outlive submitUdpRecv)
        const iov = try self.allocator.create(posix.iovec);
        errdefer self.allocator.destroy(iov);
        iov.* = .{
            .base = buf_info.buffer.ptr,
            .len = buf_info.buffer.len,
        };

        // Heap-allocate msghdr (MUST outlive submitUdpRecv)
        const msg = try self.allocator.create(posix.msghdr);
        errdefer self.allocator.destroy(msg);
        msg.* = mem.zeroes(posix.msghdr);
        msg.iov = @ptrCast(iov);
        msg.iovlen = 1;

        // Heap-allocate sender address storage
        const sender_addr = try self.allocator.create(posix.sockaddr_storage);
        errdefer self.allocator.destroy(sender_addr);
        msg.name = @ptrCast(sender_addr);
        msg.namelen = @sizeOf(posix.sockaddr_storage);

        // Setup operation context
        ctx.* = .{
            .op_type = .recv_udp,
            .socket = socket,
            .buffer_index = buf_info.index,
            .iov = iov,
            .msg = msg,
            .msg_const = null,
            .sender_addr = sender_addr,
            .dest_addr = null,
            .data_copy = null,
        };

        // Submit recvmsg operation first (before adding to list)
        const user_data = @intFromPtr(ctx);
        _ = self.ring.recvmsg(user_data, socket.socket, msg, 0) catch |err| {
            // BUG #11 fix: If submission fails, clean up all allocated resources
            self.allocator.destroy(sender_addr);
            self.allocator.destroy(msg);
            self.allocator.destroy(iov);
            self.allocator.destroy(ctx);
            self.buffer_pool.release(buf_info.index);
            return err;
        };

        // Add to list after successful submission
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.op_contexts.append(ctx) catch |err| {
            // BUG #11 fix: If append fails, ctx and buffer are leaked
            // Clean up ctx and buffer
            self.allocator.destroy(sender_addr);
            self.allocator.destroy(msg);
            self.allocator.destroy(iov);
            self.allocator.destroy(ctx);
            self.buffer_pool.release(buf_info.index);
            return err;
        };
    }

    /// Process a completion queue entry
    fn processCqe(self: *PhyUring, cqe: *linux.io_uring_cqe) void {
        // Decode user_data to get OpContext
        const ctx = @as(*OpContext, @ptrFromInt(cqe.user_data));

        // Check for errors
        if (cqe.res < 0) {
            const err = linux.E.init(-cqe.res);

            // BUG #23 fix: Don't print error for ECANCELED (expected on socket close)
            if (err != .CANCELED) {
                std.debug.print("phy_uring: operation failed with error: {}\n", .{err});
            }

            // Clean up context
            if (ctx.buffer_index) |buf_idx| {
                self.buffer_pool.release(buf_idx);
            }
            self.freeOpContext(ctx);
            return;
        }

        // Process based on operation type
        switch (ctx.op_type) {
            .recv_udp => {
                const bytes_received = @as(usize, @intCast(cqe.res));

                // Get buffer
                const buf_idx = ctx.buffer_index.?;
                const buffer = self.buffer_pool.getBuffer(buf_idx);
                const data = buffer[0..bytes_received];

                // Extract source address from sender_addr
                const from = if (ctx.sender_addr) |addr_storage| blk: {
                    const sockaddr = @as(*posix.sockaddr, @ptrCast(addr_storage));
                    break :blk net.Address.initPosix(sockaddr);
                } else net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

                // Call handler
                self.handler.on_datagram(
                    @ptrCast(ctx.socket),
                    &ctx.socket.uptr,
                    ctx.socket.remote_addr, // Local address stored in remote_addr field
                    from,
                    data,
                );

                // Return buffer to pool
                self.buffer_pool.release(buf_idx);

                // Submit another receive operation for this socket
                // BUG #22 fix: If resubmit fails, buffer was already released above
                self.submitUdpRecv(ctx.socket) catch |err| {
                    std.debug.print("phy_uring: failed to resubmit recv: {}\n", .{err});
                };
            },
            .send_udp => {
                // Send completed - cleanup handled in freeOpContext
            },
            .recv_tcp, .send_tcp, .accept, .connect => {
                // TODO: Implement TCP operations
                std.debug.print("phy_uring: TCP operation not yet implemented\n", .{});
            },
        }

        // Free operation context
        self.freeOpContext(ctx);
    }

    fn freeOpContext(self: *PhyUring, ctx: *OpContext) void {
        // Free all heap-allocated structures (OWNED by OpContext)
        if (ctx.iov) |iov| self.allocator.destroy(iov);
        if (ctx.msg) |msg| self.allocator.destroy(msg);
        if (ctx.msg_const) |msg_const| self.allocator.destroy(msg_const);
        if (ctx.sender_addr) |addr| self.allocator.destroy(addr);
        if (ctx.dest_addr) |addr| self.allocator.destroy(addr);
        if (ctx.data_copy) |data| self.allocator.free(data);

        // Remove from list (thread-safe)
        self.state_lock.lock();
        defer self.state_lock.unlock();

        for (self.op_contexts.items, 0..) |item, i| {
            if (item == ctx) {
                _ = self.op_contexts.swapRemove(i);
                break;
            }
        }

        self.allocator.destroy(ctx);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "BufferPool: init and deinit" {
    var pool = try BufferPool.init(testing.allocator);
    defer pool.deinit();

    try testing.expectEqual(BufferPool.BUFFER_COUNT, pool.free_list.items.len);
}

test "BufferPool: acquire and release" {
    var pool = try BufferPool.init(testing.allocator);
    defer pool.deinit();

    const initial_free = pool.free_list.items.len;

    // Acquire a buffer
    const acquired = pool.acquire().?;
    try testing.expectEqual(initial_free - 1, pool.free_list.items.len);

    // Release it back
    pool.release(acquired.index);
    try testing.expectEqual(initial_free, pool.free_list.items.len);
}

test "PhyUring: init fails gracefully on non-Linux or old kernel" {
    // This test will pass if we're on Linux >= 5.1 or fail gracefully otherwise
    const result = PhyUring.init(
        testing.allocator,
        .{
            .on_datagram = undefined,
            .on_tcp_connect = undefined,
            .on_tcp_accept = undefined,
            .on_tcp_close = undefined,
            .on_tcp_data = undefined,
            .on_tcp_writable = undefined,
            .on_fd_activity = undefined,
        },
        false,
        false,
    );

    if (result) |*phy| {
        defer phy.deinit();
        // Success - we have io_uring support
        try testing.expect(phy.ring.fd >= 0);
    } else |err| {
        // Expected on old kernels
        std.debug.print("io_uring not available: {}\n", .{err});
    }
}
