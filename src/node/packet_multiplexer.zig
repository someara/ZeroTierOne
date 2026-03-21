/// Thread-pool packet dispatcher for virtual network frame delivery.
///
/// Converted from `node/PacketMultiplexer.hpp` + `node/PacketMultiplexer.cpp`
/// (176 C++ lines). Distributes incoming decoded packets across N worker
/// threads by `flow_id % concurrency`. Each worker consumes from its own
/// blocking queue and calls the `put_frame` callback.
///
/// On macOS/OpenBSD/NetBSD the threaded path is compiled out (matching the
/// C++ `#if defined(__APPLE__)` guard) — `putFrame` calls through directly.
///
/// No heap allocation in the struct itself; worker threads and queues are
/// allocated via the provided allocator on `setUp`.
const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const MAC = @import("mac.zig").MAC;
const constants = @import("constants.zig");
const c_api = constants.c_api;

// ── Constants ──────────────────────────────────────────────────────

/// Maximum MTU size for packet data buffers.
pub const max_mtu: u32 = c_api.ZT_MAX_MTU;

/// Maximum number of concurrent worker threads.
pub const max_concurrency: u32 = 128;

/// Default queue depth limit per worker (matches C++ postLimit(2048)).
pub const default_queue_limit: u32 = 2048;

/// Whether the threaded path is available on this platform.
/// macOS, OpenBSD, and NetBSD bypass the thread pool (matching C++ behavior).
pub const threading_available: bool = switch (builtin.os.tag) {
    .macos, .openbsd, .netbsd => false,
    else => true,
};

// ── BlockingQueue ──────────────────────────────────────────────────

/// Thread-safe bounded queue with blocking get and bounded post.
///
/// Converted from `osdep/BlockingQueue.hpp`. Uses a mutex + two condition
/// variables: `not_empty` (for consumers) and `not_full` (for producers
/// blocked on `postLimit`).
pub fn BlockingQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Fixed-capacity ring buffer.
        const capacity = 4096;

        buf: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        running: bool = true,

        mutex: Mutex = .{},
        not_empty: Condition = .{},
        not_full: Condition = .{},

        pub fn init() Self {
            return .{};
        }

        /// Post an item, blocking if the queue has reached `limit` items.
        /// Returns false if the queue has been stopped.
        pub fn postLimit(self: *Self, item: T, limit: usize) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count >= limit) {
                if (!self.running) return false;
                self.not_full.wait(&self.mutex);
            }
            if (!self.running) return false;

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            self.not_empty.signal();
            return true;
        }

        /// Post an item without blocking (unbounded up to ring capacity).
        pub fn post(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.running) return;
            if (self.count >= capacity) return; // drop if full

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.count += 1;
            self.not_empty.signal();
        }

        /// Blocking get. Returns null if the queue has been stopped.
        pub fn get(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.count == 0) {
                if (!self.running) return null;
                self.not_empty.wait(&self.mutex);
            }
            if (!self.running and self.count == 0) return null;

            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.not_full.signal();
            return item;
        }

        /// Signal all waiting threads to stop.
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.running = false;
            self.not_empty.broadcast();
            self.not_full.broadcast();
        }

        /// Current number of items in the queue (racy outside of lock).
        pub fn size(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }
    };
}

// ── PacketRecord ───────────────────────────────────────────────────

/// A queued packet record for deferred delivery to the virtual network
/// frame callback. Corresponds to C++ `PacketRecord` struct.
pub const PacketRecord = struct {
    t_ptr: ?*anyopaque = null,
    nwid: u64 = 0,
    nuptr: ?*?*anyopaque = null,
    source: u64 = 0,
    dest: u64 = 0,
    ether_type: u32 = 0,
    vlan_id: u32 = 0,
    data: [max_mtu]u8 = undefined,
    len: u32 = 0,
    flow_id: u32 = 0,
};

// ── Callbacks ──────────────────────────────────────────────────────

/// Callback signature for delivering frames to the virtual network tap.
/// Matches the semantics of `Node::putFrame()`.
pub const PutFrameFn = *const fn (
    t_ptr: ?*anyopaque,
    nwid: u64,
    nuptr: ?*?*anyopaque,
    source: MAC,
    dest: MAC,
    ether_type: u32,
    vlan_id: u32,
    data: [*]const u8,
    len: u32,
) void;

// ── PacketMultiplexer ──────────────────────────────────────────────

/// Thread-pool packet dispatcher.
///
/// On platforms where threading is disabled (macOS, OpenBSD, NetBSD),
/// `putFrame` calls `put_frame_fn` directly. On Linux and other platforms,
/// `setUp` spawns N worker threads, each consuming from its own blocking
/// queue.
pub const PacketMultiplexer = struct {
    const Queue = BlockingQueue(*PacketRecord);

    allocator: Allocator,
    put_frame_fn: ?PutFrameFn,
    enabled: bool = false,
    concurrency: u32 = 0,

    /// Per-thread blocking queues. Allocated on setUp.
    queues: [max_concurrency]*Queue = undefined,

    /// Worker thread handles. Joined on deinit.
    threads: [max_concurrency]Thread = undefined,

    /// Pool of reusable PacketRecord objects (reduces allocation pressure).
    pool_mutex: Mutex = .{},
    pool: [default_queue_limit]*PacketRecord = undefined,
    pool_count: u32 = 0,

    /// Initialize the multiplexer. Does not start any threads.
    pub fn init(allocator: Allocator, put_frame_fn: ?PutFrameFn) PacketMultiplexer {
        return .{
            .allocator = allocator,
            .put_frame_fn = put_frame_fn,
        };
    }

    /// Set up worker threads for post-decode frame delivery.
    ///
    /// `concurrency_count` is the number of worker threads (clamped to
    /// `max_concurrency`). `cpu_pinning_enabled` is currently unused
    /// (reserved for future CPU affinity support).
    ///
    /// On macOS/OpenBSD/NetBSD this is a no-op (matching C++ behavior).
    pub fn setUp(
        self: *PacketMultiplexer,
        concurrency_count: u32,
        cpu_pinning_enabled: bool,
    ) !void {
        _ = cpu_pinning_enabled;

        if (!threading_available) return;

        const n = @min(concurrency_count, max_concurrency);
        if (n == 0) return;

        self.concurrency = n;

        // Allocate per-thread queues.
        for (0..n) |i| {
            self.queues[i] = try self.allocator.create(Queue);
            self.queues[i].* = Queue.init();
        }

        // Spawn worker threads.
        for (0..n) |i| {
            self.threads[i] = try Thread.spawn(.{}, workerThread, .{ self, @as(u32, @intCast(i)) });
        }

        self.enabled = true;
    }

    /// Shut down all worker threads and free resources.
    pub fn deinit(self: *PacketMultiplexer) void {
        if (!self.enabled) {
            // Free any pool records that might have been allocated
            self.drainPool();
            return;
        }

        // Signal all queues to stop.
        for (0..self.concurrency) |i| {
            self.queues[i].stop();
        }

        // Join all worker threads.
        for (0..self.concurrency) |i| {
            self.threads[i].join();
        }

        // Free queues.
        for (0..self.concurrency) |i| {
            self.allocator.destroy(self.queues[i]);
        }

        // Free pooled records.
        self.drainPool();

        self.enabled = false;
        self.concurrency = 0;
    }

    /// Deliver a frame. If threading is enabled, enqueues for async
    /// delivery by a worker thread (selected by `flow_id % concurrency`).
    /// Otherwise calls `put_frame_fn` directly (synchronous).
    pub fn putFrame(
        self: *PacketMultiplexer,
        t_ptr: ?*anyopaque,
        nwid: u64,
        nuptr: ?*?*anyopaque,
        source: MAC,
        dest: MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
        flow_id: u32,
    ) void {
        // On non-threading platforms or when not enabled, call through directly.
        if (!threading_available or !self.enabled) {
            if (self.put_frame_fn) |cb| {
                cb(t_ptr, nwid, nuptr, source, dest, ether_type, vlan_id, data, len);
            }
            return;
        }

        // Acquire a PacketRecord from the pool or allocate a new one.
        const record = self.acquireRecord() orelse return;

        record.t_ptr = t_ptr;
        record.nwid = nwid;
        record.nuptr = nuptr;
        record.source = source.toInt();
        record.dest = dest.toInt();
        record.ether_type = ether_type;
        record.vlan_id = vlan_id;
        record.flow_id = flow_id;

        const copy_len = @min(len, max_mtu);
        record.len = copy_len;
        @memcpy(record.data[0..copy_len], data[0..copy_len]);

        const bucket = flow_id % self.concurrency;
        if (!self.queues[bucket].postLimit(record, default_queue_limit)) {
            // Queue stopped — return record to pool.
            self.releaseRecord(record);
        }
    }

    // ── Internal ───────────────────────────────────────────────────

    fn workerThread(self: *PacketMultiplexer, thread_index: u32) void {
        while (true) {
            const record = self.queues[thread_index].get() orelse break;

            if (self.put_frame_fn) |cb| {
                cb(
                    record.t_ptr,
                    record.nwid,
                    record.nuptr,
                    MAC.init(record.source),
                    MAC.init(record.dest),
                    record.ether_type,
                    0, // vlanId always 0 in C++ worker path
                    @as([*]const u8, &record.data),
                    record.len,
                );
            }

            self.releaseRecord(record);
        }
    }

    fn acquireRecord(self: *PacketMultiplexer) ?*PacketRecord {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        if (self.pool_count > 0) {
            self.pool_count -= 1;
            return self.pool[self.pool_count];
        }

        // Pool empty — allocate a new record.
        return self.allocator.create(PacketRecord) catch return null;
    }

    fn releaseRecord(self: *PacketMultiplexer, record: *PacketRecord) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        if (self.pool_count < default_queue_limit) {
            self.pool[self.pool_count] = record;
            self.pool_count += 1;
        } else {
            // Pool full — deallocate.
            self.allocator.destroy(record);
        }
    }

    fn drainPool(self: *PacketMultiplexer) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        for (0..self.pool_count) |i| {
            self.allocator.destroy(self.pool[i]);
        }
        self.pool_count = 0;
    }
};

// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

test "BlockingQueue: post and get" {
    var q = BlockingQueue(u32).init();
    q.post(42);
    q.post(99);

    try testing.expectEqual(@as(usize, 2), q.size());
    try testing.expectEqual(@as(?u32, 42), q.get());
    try testing.expectEqual(@as(?u32, 99), q.get());
    try testing.expectEqual(@as(usize, 0), q.size());
}

test "BlockingQueue: stop unblocks get" {
    var q = BlockingQueue(u32).init();

    // Spawn a thread that will block on get, then check result after stop.
    const t = try Thread.spawn(.{}, struct {
        fn run(queue: *BlockingQueue(u32)) void {
            const result = queue.get();
            // After stop, get returns null.
            std.debug.assert(result == null);
        }
    }.run, .{&q});

    // Give the thread a moment to block.
    Thread.sleep(10 * std.time.ns_per_ms);
    q.stop();
    t.join();
}

test "BlockingQueue: postLimit respects limit" {
    var q = BlockingQueue(u32).init();

    // Fill to capacity 3 items.
    try testing.expect(q.postLimit(1, 3));
    try testing.expect(q.postLimit(2, 3));
    try testing.expect(q.postLimit(3, 3));

    // Queue has 3 items now. Next postLimit with limit=3 would block.
    // Instead, use a thread that stops the queue so postLimit returns false.
    const t = try Thread.spawn(.{}, struct {
        fn run(queue: *BlockingQueue(u32)) void {
            Thread.sleep(10 * std.time.ns_per_ms);
            queue.stop();
        }
    }.run, .{&q});

    // This should eventually return false when stop() is called.
    const result = q.postLimit(4, 3);
    try testing.expect(!result);
    t.join();
}

test "BlockingQueue: stop causes get to return null" {
    var q = BlockingQueue(u32).init();
    q.post(10);
    q.stop();

    // Even after stop, existing items should be retrievable.
    // (C++ behavior: get returns false if !running, but we check
    //  count == 0 after stopping.)
    // Our implementation: if running=false AND count==0, return null.
    // If running=false AND count>0, we still return the item.
    const val = q.get();
    try testing.expectEqual(@as(?u32, 10), val);
}

test "BlockingQueue: multiple producers and consumers" {
    var q = BlockingQueue(u32).init();
    const num_items: u32 = 100;

    // Producer thread.
    const producer = try Thread.spawn(.{}, struct {
        fn run(queue: *BlockingQueue(u32)) void {
            for (0..num_items) |i| {
                queue.post(@intCast(i));
            }
        }
    }.run, .{&q});

    // Consumer: drain all items.
    var received: u32 = 0;
    while (received < num_items) {
        if (q.get()) |_| {
            received += 1;
        }
    }
    try testing.expectEqual(num_items, received);
    producer.join();
}

test "PacketRecord: default initialization" {
    const rec = PacketRecord{};
    try testing.expectEqual(@as(u64, 0), rec.nwid);
    try testing.expectEqual(@as(u32, 0), rec.len);
    try testing.expectEqual(@as(u32, 0), rec.flow_id);
    try testing.expect(rec.t_ptr == null);
    try testing.expect(rec.nuptr == null);
}

test "PacketRecord: field assignment" {
    var rec = PacketRecord{};
    rec.nwid = 0xDEADBEEF;
    rec.source = 0x112233445566;
    rec.dest = 0xAABBCCDDEEFF;
    rec.ether_type = 0x0800;
    rec.len = 64;
    rec.flow_id = 42;

    try testing.expectEqual(@as(u64, 0xDEADBEEF), rec.nwid);
    try testing.expectEqual(@as(u64, 0x112233445566), rec.source);
    try testing.expectEqual(@as(u64, 0xAABBCCDDEEFF), rec.dest);
    try testing.expectEqual(@as(u32, 0x0800), rec.ether_type);
    try testing.expectEqual(@as(u32, 64), rec.len);
    try testing.expectEqual(@as(u32, 42), rec.flow_id);
}

test "PacketMultiplexer: init creates disabled multiplexer" {
    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, null);
    defer mux.deinit();

    try testing.expect(!mux.enabled);
    try testing.expectEqual(@as(u32, 0), mux.concurrency);
}

test "PacketMultiplexer: putFrame calls callback directly when not enabled" {
    const S = struct {
        var called: bool = false;
        var last_nwid: u64 = 0;
        var last_ether_type: u32 = 0;
        var last_len: u32 = 0;
        fn putFrameCb(
            _: ?*anyopaque,
            nwid: u64,
            _: ?*?*anyopaque,
            _: MAC,
            _: MAC,
            ether_type: u32,
            _: u32,
            _: [*]const u8,
            len: u32,
        ) void {
            called = true;
            last_nwid = nwid;
            last_ether_type = ether_type;
            last_len = len;
        }
    };

    S.called = false;
    S.last_nwid = 0;
    S.last_ether_type = 0;
    S.last_len = 0;

    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, &S.putFrameCb);
    defer mux.deinit();

    const frame = [_]u8{0xAA} ** 64;
    mux.putFrame(
        null,
        0x1234,
        null,
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        0x0800,
        0,
        &frame,
        64,
        0,
    );

    try testing.expect(S.called);
    try testing.expectEqual(@as(u64, 0x1234), S.last_nwid);
    try testing.expectEqual(@as(u32, 0x0800), S.last_ether_type);
    try testing.expectEqual(@as(u32, 64), S.last_len);
}

test "PacketMultiplexer: putFrame with no callback does nothing" {
    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, null);
    defer mux.deinit();

    const frame = [_]u8{0} ** 32;
    // Should not crash.
    mux.putFrame(null, 0, null, MAC.init(0), MAC.init(0), 0, 0, &frame, 32, 0);
}

test "PacketMultiplexer: setUp on macOS is a no-op" {
    if (threading_available) return error.SkipZigTest;

    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, null);
    try mux.setUp(4, false);
    defer mux.deinit();

    try testing.expect(!mux.enabled);
    try testing.expectEqual(@as(u32, 0), mux.concurrency);
}

test "PacketMultiplexer: record pool acquire and release" {
    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, null);
    defer mux.deinit();

    // Acquire a record (from allocator since pool is empty).
    const rec = mux.acquireRecord();
    try testing.expect(rec != null);

    // Release back to pool.
    mux.releaseRecord(rec.?);
    try testing.expectEqual(@as(u32, 1), mux.pool_count);

    // Acquire again (should come from pool).
    const rec2 = mux.acquireRecord();
    try testing.expect(rec2 != null);
    try testing.expectEqual(@as(u32, 0), mux.pool_count);

    // Clean up.
    allocator.destroy(rec2.?);
}

test "PacketMultiplexer: threading_available matches platform" {
    switch (builtin.os.tag) {
        .macos, .openbsd, .netbsd => try testing.expect(!threading_available),
        else => try testing.expect(threading_available),
    }
}

test "PacketMultiplexer: setUp with zero concurrency does nothing" {
    const allocator = testing.allocator;
    var mux = PacketMultiplexer.init(allocator, null);
    try mux.setUp(0, false);
    defer mux.deinit();

    try testing.expect(!mux.enabled);
    try testing.expectEqual(@as(u32, 0), mux.concurrency);
}

test "max_mtu matches C API ZT_MAX_MTU" {
    try testing.expectEqual(@as(u32, 10000), max_mtu);
}
