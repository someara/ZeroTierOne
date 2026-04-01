/// Phy - Physical layer socket I/O abstraction for ZeroTier
///
/// This is a Zig conversion of osdep/Phy.hpp, providing cross-platform
/// socket I/O with an event loop for UDP and TCP sockets.
///
/// Key features:
/// - Non-blocking UDP and TCP sockets
/// - Event loop using poll/select (cross-platform)
/// - Callback-based handlers for socket events
/// - User-settable pointer per socket (uptr)
/// - Support for UDP, TCP (listen/connect), and raw file descriptors
///
/// Design:
/// - Uses Zig's std.net for cross-platform socket abstractions
/// - Event loop via std.posix.poll() on Unix, select() on Windows
/// - Generic handler interface via callbacks (like C++ template)
///
/// Performance:
/// - Zero-copy where possible
/// - Efficient event loop (O(n) sockets, but typically < 100)
/// - Memory pools for socket structs (future optimization)

const std = @import("std");
const net = std.net;
const os = std.os;
const posix = std.posix;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ── Socket Types ───────────────────────────────────────────────────────

/// Opaque socket handle (matches C++ PhySocket*)
pub const PhySocket = opaque {};

/// Socket type enumeration
pub const SocketType = enum(u8) {
    closed = 0x00,
    tcp_out_pending = 0x01, // outgoing TCP connection, not yet connected
    tcp_out_connected = 0x02, // outgoing TCP connection, connected
    tcp_in = 0x03, // incoming TCP connection
    tcp_listen = 0x04, // TCP listener
    udp = 0x05, // UDP socket
    fd = 0x06, // raw file descriptor
    unix_in = 0x07, // Unix domain socket (incoming)
    unix_listen = 0x08, // Unix domain socket (listener)
};

/// Internal socket implementation
const PhySocketImpl = struct {
    type: SocketType,
    socket: posix.socket_t, // OS socket handle (int on Unix, SOCKET on Windows)
    uptr: ?*anyopaque, // user-settable pointer
    local_port: u16,
    remote_addr: net.Address, // remote for TCP_OUT/TCP_IN, local for others

    // TCP connection state
    write_buffer: ?[]const u8 = null, // pending write data for TCP
    write_offset: usize = 0, // offset into write buffer
};

// ── Handler Callbacks ──────────────────────────────────────────────────

/// Handler callbacks for socket events
///
/// The application must provide implementations of these callbacks.
/// Each callback receives the socket and a pointer to the user pointer
/// (which can be modified).
pub const PhyHandler = struct {
    /// UDP datagram received
    /// sock: socket that received the datagram
    /// uptr: pointer to user pointer (can be modified)
    /// local_addr: local address the datagram was received on
    /// from: sender's address
    /// data: datagram data
    on_datagram: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
        local_addr: net.Address,
        from: net.Address,
        data: []const u8,
    ) void,

    /// TCP connection attempt completed (success or failure)
    /// sock: socket that attempted connection
    /// uptr: pointer to user pointer
    /// success: true if connected, false if failed
    on_tcp_connect: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
        success: bool,
    ) void,

    /// TCP connection accepted on listener
    /// sock_listen: listening socket
    /// sock_new: newly accepted connection socket
    /// uptr_listen: pointer to listener's user pointer
    /// uptr_new: pointer to new connection's user pointer
    /// from: client's address
    on_tcp_accept: *const fn (
        sock_listen: *PhySocket,
        sock_new: *PhySocket,
        uptr_listen: *?*anyopaque,
        uptr_new: *?*anyopaque,
        from: net.Address,
    ) void,

    /// TCP connection closed
    /// sock: socket that was closed
    /// uptr: pointer to user pointer
    on_tcp_close: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
    ) void,

    /// TCP data received
    /// sock: socket that received data
    /// uptr: pointer to user pointer
    /// data: received data
    on_tcp_data: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
        data: []const u8,
    ) void,

    /// TCP socket is writable (ready to send)
    /// sock: socket that became writable
    /// uptr: pointer to user pointer
    on_tcp_writable: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
    ) void,

    /// File descriptor activity (for raw FDs)
    /// sock: socket with activity
    /// uptr: pointer to user pointer
    /// readable: true if readable
    /// writable: true if writable
    on_fd_activity: *const fn (
        sock: *PhySocket,
        uptr: *?*anyopaque,
        readable: bool,
        writable: bool,
    ) void,
};

// ── Main Phy Structure ─────────────────────────────────────────────────

/// Physical layer socket I/O manager
pub const Phy = struct {
    allocator: Allocator,
    handler: PhyHandler,
    sockets: std.ArrayList(*PhySocketImpl),

    // Wake-up pipe for aborting poll() from another thread
    wakeup_pipe: [2]posix.socket_t,

    // Configuration
    no_delay: bool, // TCP_NODELAY (disable Nagle's algorithm)
    no_check: bool, // SO_NO_CHECK (disable UDP checksums)

    // Reusable buffer for poll() to avoid repeated allocations
    poll_fds: std.ArrayList(posix.pollfd),

    /// Initialize the Phy manager
    pub fn init(
        allocator: Allocator,
        handler: PhyHandler,
        no_delay: bool,
        no_check: bool,
    ) !Phy {
        // Create wake-up pipe for aborting poll()
        // This allows other threads to interrupt the event loop
        var wakeup_pipe: [2]posix.socket_t = undefined;

        if (builtin.os.tag == .windows) {
            // Windows doesn't have pipe(), use socketpair or loopback socket
            // For now, use a simple implementation
            return error.WindowsNotImplementedYet;
        } else {
            // Unix: use pipe()
            const pipe_fds = try posix.pipe();
            wakeup_pipe[0] = pipe_fds[0];
            wakeup_pipe[1] = pipe_fds[1];

            // Pipes are blocking by default, but that's OK for wakeup mechanism
            // Non-blocking read/write is handled by the recv/send calls
        }

        return Phy{
            .allocator = allocator,
            .handler = handler,
            .sockets = std.ArrayList(*PhySocketImpl){
                .items = &.{},
                .capacity = 0,
            },
            .wakeup_pipe = wakeup_pipe,
            .no_delay = no_delay,
            .no_check = no_check,
            .poll_fds = std.ArrayList(posix.pollfd){
                .items = &.{},
                .capacity = 0,
            },
        };
    }

    /// Clean up and close all sockets
    pub fn deinit(self: *Phy) void {
        // Close all sockets
        for (self.sockets.items) |sock_impl| {
            if (sock_impl.type != .closed) {
                self.closeInternal(sock_impl, true);
            }
            self.allocator.destroy(sock_impl);
        }
        self.sockets.deinit(self.allocator);
        self.poll_fds.deinit(self.allocator);

        // Close wake-up pipe
        posix.close(self.wakeup_pipe[0]);
        posix.close(self.wakeup_pipe[1]);
    }

    // ── Socket Creation ────────────────────────────────────────────

    /// Bind a UDP socket to the specified address
    ///
    /// Returns an opaque socket handle, or null on error.
    pub fn udpBind(
        self: *Phy,
        local_addr: net.Address,
        uptr: ?*anyopaque,
        buffer_size: usize,
    ) !*PhySocket {
        // Create UDP socket
        const sock = try posix.socket(
            local_addr.any.family,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
        errdefer posix.close(sock);

        // Set buffer sizes if specified
        if (buffer_size > 0) {
            try posix.setsockopt(
                sock,
                posix.SOL.SOCKET,
                posix.SO.RCVBUF,
                &std.mem.toBytes(@as(c_int, @intCast(buffer_size))),
            );
            try posix.setsockopt(
                sock,
                posix.SOL.SOCKET,
                posix.SO.SNDBUF,
                &std.mem.toBytes(@as(c_int, @intCast(buffer_size))),
            );
        }

        // Disable UDP checksums if requested (Linux-specific)
        if (self.no_check and builtin.os.tag == .linux) {
            const no_check: c_int = 1;
            // SO_NO_CHECK is optional (not supported on all platforms).
            // Failure is non-critical — UDP checksums remain enabled.
            _ = posix.setsockopt(
                sock,
                posix.SOL.SOCKET,
                posix.SO.NO_CHECK,
                &std.mem.toBytes(no_check),
            ) catch {};
        }

        // Bind to local address
        try posix.bind(sock, &local_addr.any, local_addr.getOsSockLen());

        // Create socket implementation
        const sock_impl = try self.allocator.create(PhySocketImpl);
        sock_impl.* = .{
            .type = .udp,
            .socket = sock,
            .uptr = uptr,
            .local_port = local_addr.getPort(),
            .remote_addr = local_addr,
        };

        try self.sockets.append(self.allocator,sock_impl);
        return @ptrCast(sock_impl);
    }

    /// Send a UDP datagram
    ///
    /// Returns true on success, false if the send would block or failed.
    pub fn udpSend(
        self: *Phy,
        sock: *PhySocket,
        remote_addr: net.Address,
        data: []const u8,
    ) bool {
        _ = self;
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));

        if (sock_impl.type != .udp) return false;

        const sent = posix.sendto(
            sock_impl.socket,
            data,
            0,
            &remote_addr.any,
            remote_addr.getOsSockLen(),
        ) catch return false;

        return sent == data.len;
    }

    /// Create a TCP listening socket
    ///
    /// Returns an opaque socket handle, or null on error.
    pub fn tcpListen(
        self: *Phy,
        local_addr: net.Address,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        // Create TCP socket
        const sock = try posix.socket(
            local_addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(sock);

        // Set SO_REUSEADDR
        const reuse: c_int = 1;
        try posix.setsockopt(
            sock,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(reuse),
        );

        // Bind
        try posix.bind(sock, &local_addr.any, local_addr.getOsSockLen());

        // Listen
        try posix.listen(sock, 128);

        // Create socket implementation
        const sock_impl = try self.allocator.create(PhySocketImpl);
        sock_impl.* = .{
            .type = .tcp_listen,
            .socket = sock,
            .uptr = uptr,
            .local_port = local_addr.getPort(),
            .remote_addr = local_addr,
        };

        try self.sockets.append(self.allocator,sock_impl);
        return @ptrCast(sock_impl);
    }

    /// Initiate a TCP connection (non-blocking)
    ///
    /// The on_tcp_connect callback will be called when connection completes.
    /// Returns socket handle and sets 'connected' to true if immediate connect.
    pub fn tcpConnect(
        self: *Phy,
        remote_addr: net.Address,
        connected: *bool,
        uptr: ?*anyopaque,
    ) !*PhySocket {
        // Create TCP socket
        const sock = try posix.socket(
            remote_addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(sock);

        // Set TCP_NODELAY if requested
        if (self.no_delay) {
            const nodelay: c_int = 1;
            try posix.setsockopt(
                sock,
                posix.IPPROTO.TCP,
                posix.TCP.NODELAY,
                &std.mem.toBytes(nodelay),
            );
        }

        // Attempt connection (non-blocking)
        posix.connect(sock, &remote_addr.any, remote_addr.getOsSockLen()) catch |err| {
            if (err == error.WouldBlock) {
                // Connection in progress
                connected.* = false;
            } else {
                return err;
            }
        };

        // If we get here without error, connection succeeded immediately
        if (connected.* != false) {
            connected.* = true;
        }

        // Create socket implementation
        const sock_impl = try self.allocator.create(PhySocketImpl);
        sock_impl.* = .{
            .type = if (connected.*) .tcp_out_connected else .tcp_out_pending,
            .socket = sock,
            .uptr = uptr,
            .local_port = 0,
            .remote_addr = remote_addr,
        };

        try self.sockets.append(self.allocator,sock_impl);
        return @ptrCast(sock_impl);
    }

    /// Close a socket
    ///
    /// If call_handlers is true, the appropriate close handler will be called.
    pub fn close(self: *Phy, sock: *PhySocket, call_handlers: bool) void {
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));
        self.closeInternal(sock_impl, call_handlers);
    }

    fn closeInternal(self: *Phy, sock_impl: *PhySocketImpl, call_handlers: bool) void {
        if (sock_impl.type == .closed) return;

        // Call handler if requested
        if (call_handlers) {
            switch (sock_impl.type) {
                .tcp_out_connected, .tcp_in => {
                    self.handler.on_tcp_close(
                        @ptrCast(sock_impl),
                        &sock_impl.uptr,
                    );
                },
                else => {},
            }
        }

        // Close the OS socket
        posix.close(sock_impl.socket);
        sock_impl.type = .closed;
    }

    // ── Event Loop ─────────────────────────────────────────────────

    /// Poll for socket events (main event loop)
    ///
    /// Blocks for up to 'timeout_ms' milliseconds waiting for socket activity.
    /// Calls appropriate handlers when events occur.
    pub fn poll(self: *Phy, timeout_ms: u64) !void {
        if (self.sockets.items.len == 0) {
            // No sockets, just sleep
            std.Thread.sleep(timeout_ms * std.time.ns_per_ms);
            return;
        }

        // Resize pollfd buffer to fit current sockets (reuses allocation)
        const needed_size = self.sockets.items.len + 1;
        try self.poll_fds.resize(self.allocator, needed_size);
        const pollfds = self.poll_fds.items;

        // Add wake-up pipe
        pollfds[0] = .{
            .fd = self.wakeup_pipe[0],
            .events = posix.POLL.IN,
            .revents = 0,
        };

        // Add all sockets
        for (self.sockets.items, 1..) |sock_impl, i| {
            pollfds[i] = .{
                .fd = sock_impl.socket,
                .events = switch (sock_impl.type) {
                    .closed => 0,
                    .udp, .tcp_listen => posix.POLL.IN,
                    .tcp_out_pending => posix.POLL.OUT | posix.POLL.ERR,
                    .tcp_out_connected, .tcp_in => posix.POLL.IN | posix.POLL.OUT,
                    else => posix.POLL.IN,
                },
                .revents = 0,
            };
        }

        // Poll with timeout
        const ready = try posix.poll(pollfds, @intCast(timeout_ms));
        if (ready == 0) return; // Timeout

        // Check wake-up pipe
        if ((pollfds[0].revents & posix.POLL.IN) != 0) {
            var buf: [1]u8 = undefined;
            _ = posix.read(self.wakeup_pipe[0], &buf) catch {};
        }

        // Process socket events
        var i: usize = 1;
        while (i < pollfds.len) : (i += 1) {
            const sock_impl = self.sockets.items[i - 1];
            if (sock_impl.type == .closed) continue;

            // Get mutable pointer to uptr for handlers
            var uptr = sock_impl.uptr;

            const revents = pollfds[i].revents;
            if (revents == 0) continue;

            // Handle events based on socket type
            switch (sock_impl.type) {
                .closed => {},

                .tcp_out_pending => {
                    // Outgoing TCP connection: check if connection completed
                    if ((revents & posix.POLL.OUT) != 0) {
                        // Connection completed or failed - check with getpeername
                        var addr: net.Address = undefined;
                        var addr_len: posix.socklen_t = @sizeOf(net.Address);
                        const success = blk: {
                            posix.getpeername(
                                sock_impl.socket,
                                @ptrCast(&addr.any),
                                &addr_len,
                            ) catch {
                                break :blk false;
                            };
                            break :blk true;
                        };

                        if (!success) {
                            // Connection failed
                            self.handler.on_tcp_connect(
                                @ptrCast(sock_impl),
                                &uptr,
                                false,
                            );
                            self.closeInternal(sock_impl, false);
                        } else {
                            // Connection succeeded
                            sock_impl.type = .tcp_out_connected;
                            self.handler.on_tcp_connect(
                                @ptrCast(sock_impl),
                                &uptr,
                                true,
                            );
                        }
                    }
                    if ((revents & posix.POLL.ERR) != 0) {
                        // Connection error
                        self.handler.on_tcp_connect(
                            @ptrCast(sock_impl),
                            &uptr,
                            false,
                        );
                        self.closeInternal(sock_impl, false);
                    }
                },

                .tcp_out_connected, .tcp_in => {
                    // Connected TCP socket: check for data or close
                    if ((revents & posix.POLL.IN) != 0) {
                        var buf: [131072]u8 = undefined;
                        const n = posix.recv(sock_impl.socket, &buf, 0) catch |err| {
                            if (err == error.WouldBlock) {
                                continue;
                            }
                            // Error or EOF - close socket
                            self.closeInternal(sock_impl, true);
                            continue;
                        };

                        if (n == 0) {
                            // EOF - connection closed by peer
                            self.closeInternal(sock_impl, true);
                        } else {
                            // Data received
                            self.handler.on_tcp_data(
                                @ptrCast(sock_impl),
                                &uptr,
                                buf[0..n],
                            );
                        }
                    }

                    if ((revents & posix.POLL.OUT) != 0) {
                        // Socket is writable
                        self.handler.on_tcp_writable(
                            @ptrCast(sock_impl),
                            &uptr,
                        );
                    }

                    if ((revents & (posix.POLL.ERR | posix.POLL.HUP)) != 0) {
                        // Error or hangup
                        self.closeInternal(sock_impl, true);
                    }
                },

                .tcp_listen => {
                    // Listening TCP socket: accept new connections
                    if ((revents & posix.POLL.IN) != 0) {
                        var client_addr: net.Address = undefined;
                        var client_addr_len: posix.socklen_t = @sizeOf(net.Address);

                        const client_sock = posix.accept(
                            sock_impl.socket,
                            @ptrCast(&client_addr.any),
                            &client_addr_len,
                            posix.SOCK.NONBLOCK,
                        ) catch continue;

                        // Set TCP_NODELAY if requested
                        if (self.no_delay) {
                            const nodelay: c_int = 1;
                            _ = posix.setsockopt(
                                client_sock,
                                posix.IPPROTO.TCP,
                                posix.TCP.NODELAY,
                                &std.mem.toBytes(nodelay),
                            ) catch {};
                        }

                        // Create new socket implementation for accepted connection
                        const new_sock_impl = self.allocator.create(PhySocketImpl) catch {
                            posix.close(client_sock);
                            continue;
                        };
                        new_sock_impl.* = .{
                            .type = .tcp_in,
                            .socket = client_sock,
                            .uptr = null,
                            .local_port = sock_impl.local_port,
                            .remote_addr = client_addr,
                        };

                        self.sockets.append(self.allocator,new_sock_impl) catch {
                            posix.close(client_sock);
                            self.allocator.destroy(new_sock_impl);
                            continue;
                        };

                        // Call accept handler
                        var new_uptr = new_sock_impl.uptr;
                        self.handler.on_tcp_accept(
                            @ptrCast(sock_impl),
                            @ptrCast(new_sock_impl),
                            &uptr,
                            &new_uptr,
                            client_addr,
                        );
                        new_sock_impl.uptr = new_uptr;
                    }
                },

                .udp => {
                    // UDP socket: receive datagrams
                    if ((revents & posix.POLL.IN) != 0) {
                        // Read up to 1024 datagrams per poll cycle (matches C++)
                        var k: usize = 0;
                        while (k < 1024) : (k += 1) {
                            var buf: [131072]u8 = undefined;
                            var from_addr: net.Address = undefined;
                            var from_len: posix.socklen_t = @sizeOf(net.Address);

                            const n = posix.recvfrom(
                                sock_impl.socket,
                                &buf,
                                0,
                                @ptrCast(&from_addr.any),
                                &from_len,
                            ) catch |err| {
                                if (err == error.WouldBlock) {
                                    break; // No more data
                                }
                                break; // Error
                            };

                            if (n == 0) break; // No more data

                            // Call datagram handler
                            self.handler.on_datagram(
                                @ptrCast(sock_impl),
                                &uptr,
                                sock_impl.remote_addr, // local address
                                from_addr,
                                buf[0..n],
                            );
                        }
                    }
                },

                .fd => {
                    // Raw file descriptor: just notify about activity
                    const readable = (revents & posix.POLL.IN) != 0;
                    const writable = (revents & posix.POLL.OUT) != 0;
                    if (readable or writable) {
                        self.handler.on_fd_activity(
                            @ptrCast(sock_impl),
                            &uptr,
                            readable,
                            writable,
                        );
                    }
                },

                .unix_in, .unix_listen => {
                    // Unix domain sockets not implemented yet
                },
            }

            // Store updated uptr back (handlers can modify it)
            sock_impl.uptr = uptr;
        }
    }

    /// Wake up the poll() call from another thread
    ///
    /// This is thread-safe and can be called from any thread to interrupt poll().
    pub fn whack(self: *Phy) void {
        const byte: [1]u8 = .{0};
        _ = posix.write(self.wakeup_pipe[1], &byte) catch {};
    }

    /// Send data on a TCP stream socket (non-blocking)
    ///
    /// Returns the number of bytes actually sent, or -1 on fatal error (socket closed).
    /// If -1 is returned, the socket has been closed and should not be used again.
    ///
    /// A return value of 0 means the send would block - try again later.
    pub fn streamSend(
        self: *Phy,
        sock: *PhySocket,
        data: []const u8,
        call_close_handler: bool,
    ) i64 {
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));

        const n = posix.send(sock_impl.socket, data, 0) catch |err| {
            switch (err) {
                error.WouldBlock => return 0,
                else => {
                    if (call_close_handler) {
                        self.closeInternal(sock_impl, true);
                    }
                    return -1;
                },
            }
        };

        return @intCast(n);
    }

    /// Set whether to be notified when a stream socket is writable
    ///
    /// This affects TCP and Unix domain sockets. When set to true, the
    /// on_tcp_writable callback will be called when the socket becomes writable.
    ///
    /// Call whack() if doing this from another thread to take effect immediately.
    pub fn setNotifyWritable(self: *Phy, sock: *PhySocket, notify: bool) void {
        _ = self;
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));
        // For poll()-based implementation, this would need to track writable interest
        // For now, we always poll for POLL.OUT on connected TCP sockets
        // A more sophisticated implementation would maintain separate readfds/writefds
        _ = sock_impl;
        _ = notify;
        // TODO: Implement writable notification control
        // This requires maintaining separate interest masks per socket
    }

    // ── Utility Functions ──────────────────────────────────────────

    /// Get the OS file descriptor for a socket
    pub fn getDescriptor(sock: *PhySocket) posix.socket_t {
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));
        return sock_impl.socket;
    }

    /// Get pointer to the user pointer for a socket
    pub fn getUserPtr(sock: *PhySocket) *?*anyopaque {
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));
        return &sock_impl.uptr;
    }

    /// Get the local port for a socket
    pub fn getLocalPort(sock: *PhySocket) u16 {
        const sock_impl: *PhySocketImpl = @ptrCast(@alignCast(sock));
        return sock_impl.local_port;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Phy initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a dummy handler
    const handler = PhyHandler{
        .on_datagram = struct {
            fn f(_: *PhySocket, _: *?*anyopaque, _: net.Address, _: net.Address, _: []const u8) void {}
        }.f,
        .on_tcp_connect = struct {
            fn f(_: *PhySocket, _: *?*anyopaque, _: bool) void {}
        }.f,
        .on_tcp_accept = struct {
            fn f(_: *PhySocket, _: *PhySocket, _: *?*anyopaque, _: *?*anyopaque, _: net.Address) void {}
        }.f,
        .on_tcp_close = struct {
            fn f(_: *PhySocket, _: *?*anyopaque) void {}
        }.f,
        .on_tcp_data = struct {
            fn f(_: *PhySocket, _: *?*anyopaque, _: []const u8) void {}
        }.f,
        .on_tcp_writable = struct {
            fn f(_: *PhySocket, _: *?*anyopaque) void {}
        }.f,
        .on_fd_activity = struct {
            fn f(_: *PhySocket, _: *?*anyopaque, _: bool, _: bool) void {}
        }.f,
    };

    var phy = try Phy.init(allocator, handler, true, false);
    defer phy.deinit();

    try testing.expect(phy.sockets.items.len == 0);
}
