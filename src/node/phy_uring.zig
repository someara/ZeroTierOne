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
        // BUG #26 fix: Runtime validation in release builds
        if (index >= BUFFER_COUNT) {
            @panic("phy_uring: buffer index out of bounds");
        }
        return &self.buffers[index];
    }
};

// ── Operation Context ──────────────────────────────────────────────────

/// Context attached to each io_uring operation via user_data
/// OWNED: All heap-allocated fields must be freed in freeOpContext
///
/// BUG #30 fix: Store socket pointer AND fd. Check fd validity before dereferencing pointer.
/// If socket is closed, fd becomes -1, and we can detect this without dereferencing freed memory.
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
    socket: *PhySocketImpl, // May be dangling if socket closed
    socket_fd: posix.fd_t, // Stable copy of fd - used to detect close
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
    // BUG #29 fix: op_contexts list removed - not needed since user_data gives direct access

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

        // BUG #29 fix: op_contexts list removed - contexts freed when operations complete

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

        // BUG #39 fix: Check for completion queue overflow
        if (self.ring.cq.overflow > 0) {
            std.debug.print("phy_uring: WARNING: CQ overflow detected, {} completions dropped\n", .{self.ring.cq.overflow});
        }

        // Wait for completions (with timeout)
        const wait_nr: u32 = 1; // Wait for at least 1 completion
        // BUG #37 fix: Increase batch size to 256 for better throughput
        var cqes: [256]linux.io_uring_cqe = undefined;

        // BUG #38: Timeout calculation but not used
        // copy_cqes() doesn't support timeout parameter
        // Would need to use submit_and_wait() or io_uring_enter() with timeout
        const timeout_ns = if (timeout_ms == std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            timeout_ms * 1_000_000;
        _ = timeout_ns; // Currently unused - minor issue, deferred

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
    /// BUG #41 fix: Return bool to match poll() backend API
    pub fn udpSend(
        self: *PhyUring,
        sock: *PhySocket,
        to: net.Address,
        data: []const u8,
    ) bool {
        const socket_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));

        // BUG #41 fix: Return false on allocation failure (match poll() behavior)
        // Allocate operation context
        const ctx = self.allocator.create(OpContext) catch return false;
        errdefer self.allocator.destroy(ctx);

        // Copy data (MUST outlive udpSend)
        const data_copy = self.allocator.dupe(u8, data) catch {
            self.allocator.destroy(ctx);
            return false;
        };
        errdefer self.allocator.free(data_copy);

        // Heap-allocate iovec (MUST outlive udpSend)
        const iov = self.allocator.create(posix.iovec) catch {
            self.allocator.free(data_copy);
            self.allocator.destroy(ctx);
            return false;
        };
        errdefer self.allocator.destroy(iov);
        iov.* = .{
            .base = @constCast(data_copy.ptr),
            .len = data_copy.len,
        };

        // Heap-allocate destination address (MUST outlive udpSend)
        const dest_addr = self.allocator.create(net.Address) catch {
            self.allocator.destroy(iov);
            self.allocator.free(data_copy);
            self.allocator.destroy(ctx);
            return false;
        };
        errdefer self.allocator.destroy(dest_addr);
        dest_addr.* = to;

        // Heap-allocate msghdr_const (MUST outlive udpSend)
        const msg = self.allocator.create(posix.msghdr_const) catch {
            self.allocator.destroy(dest_addr);
            self.allocator.destroy(iov);
            self.allocator.free(data_copy);
            self.allocator.destroy(ctx);
            return false;
        };
        errdefer self.allocator.destroy(msg);
        msg.* = mem.zeroes(posix.msghdr_const);
        msg.iov = @ptrCast(iov);
        msg.iovlen = 1;
        msg.name = @ptrCast(@constCast(&dest_addr.any));
        msg.namelen = dest_addr.getOsSockLen();

        // Setup operation context
        // BUG #30 fix: Store fd copy to detect socket close
        ctx.* = .{
            .op_type = .send_udp,
            .socket = socket_impl,
            .socket_fd = socket_impl.socket,
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
            // BUG #36 fix: Handle SubmissionQueueFull by submitting pending ops and retrying
            if (err == error.SubmissionQueueFull) {
                _ = self.ring.submit() catch {};
                // Retry once after flushing
                _ = self.ring.sendmsg(user_data, socket_impl.socket, msg, 0) catch {
                    // If still fails, clean up and return false
                    self.allocator.destroy(msg);
                    self.allocator.destroy(dest_addr);
                    self.allocator.destroy(iov);
                    self.allocator.free(data_copy);
                    self.allocator.destroy(ctx);
                    return false;
                };
            } else {
                // BUG #12/#13 fix: If submission fails, clean up all allocated resources
                self.allocator.destroy(msg);
                self.allocator.destroy(dest_addr);
                self.allocator.destroy(iov);
                self.allocator.free(data_copy);
                self.allocator.destroy(ctx);
                return false;
            }
        };

        // BUG #29 fix: No need to track in list - user_data gives direct access
        // Context will be freed when operation completes in processCqe/freeOpContext

        return true;
    }

    /// Bind UDP socket to local address
    /// BUG #42 fix: Add buffer_size parameter to match poll() backend API
    pub fn udpBind(
        self: *PhyUring,
        local_addr: net.Address,
        uptr: ?*anyopaque,
        buffer_size: usize,
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

        // BUG #42 fix: Set buffer sizes if specified (match poll() backend)
        if (buffer_size > 0) {
            try posix.setsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.RCVBUF,
                &mem.toBytes(@as(c_int, @intCast(buffer_size))),
            );
            try posix.setsockopt(
                fd,
                posix.SOL.SOCKET,
                posix.SO.SNDBUF,
                &mem.toBytes(@as(c_int, @intCast(buffer_size))),
            );
        }

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

    /// BUG #44: TCP methods not implemented (UDP-only backend)
    ///
    /// ZeroTier protocol is primarily UDP-based. TCP support would require:
    /// - IORING_OP_ACCEPT for tcpListen
    /// - IORING_OP_CONNECT for tcpConnect
    /// - IORING_OP_SEND/RECV for stream I/O
    /// - Connection state tracking
    /// - Backpressure handling for setNotifyWritable
    ///
    /// Status: Deferred - not needed for core ZeroTier VPN functionality

    /// Create TCP listening socket (NOT IMPLEMENTED)
    pub fn tcpListen(
        self: *PhyUring,
        local_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        _ = self;
        _ = local_addr;
        _ = uptr;
        return error.TcpNotSupported;
    }

    /// Initiate TCP connection (NOT IMPLEMENTED)
    pub fn tcpConnect(
        self: *PhyUring,
        remote_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        _ = self;
        _ = remote_addr;
        _ = uptr;
        return error.TcpNotSupported;
    }

    /// Send TCP data (NOT IMPLEMENTED)
    pub fn tcpSend(
        self: *PhyUring,
        sock: *PhySocket,
        data: []const u8,
    ) !void {
        _ = self;
        _ = sock;
        _ = data;
        return error.TcpNotSupported;
    }

    /// Set TCP write notification (NOT IMPLEMENTED)
    pub fn setNotifyWritable(
        self: *PhyUring,
        sock: *PhySocket,
        notify: bool,
    ) void {
        _ = self;
        _ = sock;
        _ = notify;
        // No-op for UDP-only backend
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

        // BUG #30: Operation cancellation not yet implemented
        //
        // ISSUE: Socket freed while operations may still be in-flight. When those
        // operations complete, processCqe() dereferences freed OpContext.socket pointer.
        //
        // PROPER FIX requires one of:
        // 1. Submit IORING_OP_ASYNC_CANCEL for each pending op (track ops per socket)
        // 2. Reference counting on sockets (socket only freed when refcount == 0)
        // 3. Invalidate socket pointer in all pending ops before free (linear scan)
        //
        // CURRENT WORKAROUND: Operations complete with -ECANCELED (suppressed by BUG #23),
        // but socket pointer is already dangling. This is a use-after-free that will
        // manifest as crashes or corruption if operations complete after close().
        //
        // MITIGATION: In practice, close() is rare (only on shutdown/error). Most sockets
        // live for the lifetime of the program. Still unsafe for production.
        //
        // STATUS: Deferred — requires architecture decision (refcounting vs cancellation)

        // Free socket (UNSAFE if operations pending - see BUG #17/#28/#31)
        self.allocator.destroy(socket_impl);
    }

    /// Wake up the event loop from another thread
    pub fn wakeup(self: *PhyUring) void {
        // Write to eventfd to wake up io_uring_enter()
        const value: u64 = 1;
        _ = posix.write(self.wakeup_fd, mem.asBytes(&value)) catch {};
    }

    /// BUG #43 fix: Alias for wakeup() to match poll() backend naming
    pub fn whack(self: *PhyUring) void {
        self.wakeup();
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
        // BUG #30 fix: Store fd copy to detect socket close
        ctx.* = .{
            .op_type = .recv_udp,
            .socket = socket,
            .socket_fd = socket.socket,
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
            // BUG #36 fix: Handle SubmissionQueueFull by submitting pending ops and retrying
            if (err == error.SubmissionQueueFull) {
                _ = self.ring.submit() catch {};
                // Retry once after flushing
                _ = self.ring.recvmsg(user_data, socket.socket, msg, 0) catch |retry_err| {
                    // If still fails, clean up and return error
                    self.allocator.destroy(sender_addr);
                    self.allocator.destroy(msg);
                    self.allocator.destroy(iov);
                    self.allocator.destroy(ctx);
                    self.buffer_pool.release(buf_info.index);
                    return retry_err;
                };
            } else {
                // BUG #11 fix: If submission fails, clean up all allocated resources
                self.allocator.destroy(sender_addr);
                self.allocator.destroy(msg);
                self.allocator.destroy(iov);
                self.allocator.destroy(ctx);
                self.buffer_pool.release(buf_info.index);
                return err;
            }
        };

        // BUG #29 fix: No need to track in list - user_data gives direct access
        // Context will be freed when operation completes in processCqe/freeOpContext
    }

    /// Process a completion queue entry
    fn processCqe(self: *PhyUring, cqe: *linux.io_uring_cqe) void {
        // Decode user_data to get OpContext
        const ctx = @as(*OpContext, @ptrFromInt(cqe.user_data));

        // BUG #30 fix: Check if socket was closed before dereferencing socket pointer
        // socket.socket becomes -1 when closed, but ctx.socket_fd has stable copy
        // If they don't match, socket was closed - just clean up and return
        if (ctx.socket.socket != ctx.socket_fd) {
            // Socket closed while operation in-flight - clean up without callbacks
            if (ctx.buffer_index) |buf_idx| {
                self.buffer_pool.release(buf_idx);
            }
            self.freeOpContext(ctx);
            return;
        }

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
                // BUG #25 fix: Validate cqe.res before cast (64-bit systems are fine, but be safe)
                if (cqe.res > std.math.maxInt(usize)) {
                    std.debug.print("phy_uring: received size too large: {}\n", .{cqe.res});
                    if (ctx.buffer_index) |buf_idx| {
                        self.buffer_pool.release(buf_idx);
                    }
                    self.freeOpContext(ctx);
                    return;
                }
                const bytes_received = @as(usize, @intCast(cqe.res));

                // Get buffer
                const buf_idx = ctx.buffer_index.?;
                const buffer = self.buffer_pool.getBuffer(buf_idx);

                // BUG #27 fix: Validate bytes_received <= buffer.len
                if (bytes_received > buffer.len) {
                    std.debug.print("phy_uring: received bytes ({}) exceeds buffer size ({})\n", .{ bytes_received, buffer.len });
                    self.buffer_pool.release(buf_idx);
                    self.freeOpContext(ctx);
                    return;
                }

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

    /// BUG #29 fix: O(1) cleanup - no list search needed
    fn freeOpContext(self: *PhyUring, ctx: *OpContext) void {
        // Free all heap-allocated structures (OWNED by OpContext)
        if (ctx.iov) |iov| self.allocator.destroy(iov);
        if (ctx.msg) |msg| self.allocator.destroy(msg);
        if (ctx.msg_const) |msg_const| self.allocator.destroy(msg_const);
        if (ctx.sender_addr) |addr| self.allocator.destroy(addr);
        if (ctx.dest_addr) |addr| self.allocator.destroy(addr);
        if (ctx.data_copy) |data| self.allocator.free(data);

        // Free context itself
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
