/// Fixed-size circular buffer with statistical analysis.
///
/// Converted from `node/RingBuffer.hpp`. Used for path quality metrics
/// (latency, throughput, jitter) where a sliding window of recent values
/// must be maintained efficiently. All storage is inline (no heap allocation).
///
/// @param T Element type (must support arithmetic for statistical methods)
/// @param S Buffer capacity (number of elements)
const std = @import("std");
const math = std.math;

pub fn RingBuffer(comptime T: type, comptime S: usize) type {
    if (S == 0) @compileError("RingBuffer capacity must be > 0");

    return struct {
        const Self = @This();

        buf: [S]T = [_]T{0} ** S,
        begin: usize = 0,
        end: usize = 0,
        wrap: bool = false,

        /// Return the number of elements currently in the buffer.
        pub fn count(self: *const Self) usize {
            if (self.end == self.begin) {
                return if (self.wrap) S else 0;
            } else if (self.end > self.begin) {
                return self.end - self.begin;
            } else {
                return S + self.end - self.begin;
            }
        }

        /// Return the number of unused slots.
        pub fn getFree(self: *const Self) usize {
            return S - self.count();
        }

        /// Push a single value. If the buffer is full, the oldest value is
        /// consumed first to make room.
        pub fn push(self: *Self, value: T) void {
            if (self.count() == S) {
                _ = self.consume(1);
            }
            self.buf[self.end] = value;
            self.end = (self.end + 1) % S;
            if (self.begin == self.end) {
                self.wrap = true;
            }
        }

        /// Write multiple values from a slice into the buffer.
        /// Returns the number of elements actually written (limited by free space).
        pub fn write(self: *Self, data: []const T) usize {
            const n = @min(data.len, self.getFree());
            if (n == 0) return 0;

            const first_chunk = @min(n, S - self.end);
            @memcpy(self.buf[self.end..][0..first_chunk], data[0..first_chunk]);
            self.end = (self.end + first_chunk) % S;

            if (first_chunk < n) {
                const second_chunk = n - first_chunk;
                @memcpy(self.buf[self.end..][0..second_chunk], data[first_chunk..][0..second_chunk]);
                self.end = (self.end + second_chunk) % S;
            }

            if (self.begin == self.end) {
                self.wrap = true;
            }
            return n;
        }

        /// Read and consume elements into a destination buffer.
        /// Returns the number of elements actually read.
        pub fn read(self: *Self, dest: []T) usize {
            const n = @min(dest.len, self.count());
            if (n == 0) return 0;

            if (self.wrap) self.wrap = false;

            const first_chunk = @min(n, S - self.begin);
            @memcpy(dest[0..first_chunk], self.buf[self.begin..][0..first_chunk]);
            self.begin = (self.begin + first_chunk) % S;

            if (first_chunk < n) {
                const second_chunk = n - first_chunk;
                @memcpy(dest[first_chunk..][0..second_chunk], self.buf[self.begin..][0..second_chunk]);
                self.begin = (self.begin + second_chunk) % S;
            }
            return n;
        }

        /// Consume (discard) up to `n` elements. Returns the number actually
        /// consumed (limited by current count).
        pub fn consume(self: *Self, n_requested: usize) usize {
            const n = @min(n_requested, self.count());
            if (n == 0) return 0;

            if (self.wrap) self.wrap = false;

            const first_chunk = @min(n, S - self.begin);
            self.begin = (self.begin + first_chunk) % S;

            if (first_chunk < n) {
                const second_chunk = n - first_chunk;
                self.begin = (self.begin + second_chunk) % S;
            }
            return n;
        }

        /// Fast reset — moves pointers without clearing memory.
        pub fn reset(self: *Self) void {
            _ = self.consume(self.count());
        }

        /// Return the most recently pushed element (undefined if empty).
        pub fn getMostRecent(self: *const Self) T {
            if (self.end == 0) {
                return self.buf[S - 1];
            }
            return self.buf[self.end - 1];
        }

        // ── Statistical methods ────────────────────────────────────

        /// Iterate over all elements in insertion order, calling `func` for each.
        fn forEach(self: *const Self, func: *const fn (T) f32) f32 {
            var total: f32 = 0;
            const cnt = self.count();
            var idx = self.begin;
            for (0..cnt) |_| {
                total += func(self.buf[idx]);
                idx = (idx + 1) % S;
            }
            return total;
        }

        /// Return the arithmetic mean of all elements, or 0 if empty.
        pub fn mean(self: *const Self) f32 {
            const cnt = self.count();
            if (cnt == 0) return 0;

            var subtotal: f32 = 0;
            var idx = self.begin;
            for (0..cnt) |_| {
                subtotal += toFloat(self.buf[idx]);
                idx = (idx + 1) % S;
            }
            return subtotal / @as(f32, @floatFromInt(cnt));
        }

        /// Return the sum of all elements.
        pub fn sum(self: *const Self) f32 {
            const cnt = self.count();
            var total: f32 = 0;
            var idx = self.begin;
            for (0..cnt) |_| {
                total += toFloat(self.buf[idx]);
                idx = (idx + 1) % S;
            }
            return total;
        }

        /// Return the sample variance (using n-1 denominator for unbiased estimate).
        pub fn variance(self: *const Self) f32 {
            const cnt = self.count();
            if (cnt <= 1) return 0;

            const cached_mean = self.mean();
            var sum_sq: f32 = 0;
            var idx = self.begin;
            for (0..cnt) |_| {
                const deviation = toFloat(self.buf[idx]) - cached_mean;
                sum_sq += deviation * deviation;
                idx = (idx + 1) % S;
            }
            // BUG FIX: Use cnt-1 (number of samples), not S-1 (buffer capacity)
            return sum_sq / @as(f32, @floatFromInt(cnt - 1));
        }

        /// Return the sample standard deviation.
        pub fn stddev(self: *const Self) f32 {
            return @sqrt(self.variance());
        }

        /// Count elements with value equal to zero.
        pub fn zeroCount(self: *const Self) usize {
            const cnt = self.count();
            var zeros: usize = 0;
            var idx = self.begin;
            for (0..cnt) |_| {
                if (self.buf[idx] == 0) zeros += 1;
                idx = (idx + 1) % S;
            }
            return zeros;
        }

        /// Count elements matching a given value.
        pub fn countValue(self: *const Self, value: T) usize {
            const cnt = self.count();
            var matching: usize = 0;
            var idx = self.begin;
            for (0..cnt) |_| {
                if (self.buf[idx] == value) matching += 1;
                idx = (idx + 1) % S;
            }
            return matching;
        }

        /// Convert element to f32 for statistical calculations.
        fn toFloat(v: T) f32 {
            return switch (@typeInfo(T)) {
                .int, .comptime_int => @floatFromInt(v),
                .float, .comptime_float => @floatCast(v),
                else => @compileError("RingBuffer statistical methods require numeric type"),
            };
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "empty buffer" {
    const RB = RingBuffer(i32, 4);
    const rb = RB{};
    try std.testing.expectEqual(@as(usize, 0), rb.count());
    try std.testing.expectEqual(@as(usize, 4), rb.getFree());
}

test "push and count" {
    const RB = RingBuffer(i32, 4);
    var rb = RB{};

    rb.push(10);
    try std.testing.expectEqual(@as(usize, 1), rb.count());

    rb.push(20);
    rb.push(30);
    rb.push(40);
    try std.testing.expectEqual(@as(usize, 4), rb.count());
    try std.testing.expectEqual(@as(usize, 0), rb.getFree());

    // Push when full should evict oldest
    rb.push(50);
    try std.testing.expectEqual(@as(usize, 4), rb.count());
    try std.testing.expectEqual(@as(i32, 50), rb.getMostRecent());
}

test "write and read" {
    const RB = RingBuffer(i32, 8);
    var rb = RB{};

    const data = [_]i32{ 1, 2, 3, 4, 5 };
    const written = rb.write(&data);
    try std.testing.expectEqual(@as(usize, 5), written);
    try std.testing.expectEqual(@as(usize, 5), rb.count());

    var out: [8]i32 = undefined;
    const n_read = rb.read(&out);
    try std.testing.expectEqual(@as(usize, 5), n_read);
    try std.testing.expectEqual(@as(i32, 1), out[0]);
    try std.testing.expectEqual(@as(i32, 5), out[4]);
    try std.testing.expectEqual(@as(usize, 0), rb.count());
}

test "mean and sum" {
    const RB = RingBuffer(i32, 8);
    var rb = RB{};

    rb.push(10);
    rb.push(20);
    rb.push(30);

    try std.testing.expectApproxEqAbs(@as(f32, 60.0), rb.sum(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), rb.mean(), 0.001);
}

test "reset" {
    const RB = RingBuffer(i32, 4);
    var rb = RB{};

    rb.push(1);
    rb.push(2);
    rb.push(3);
    try std.testing.expectEqual(@as(usize, 3), rb.count());

    rb.reset();
    try std.testing.expectEqual(@as(usize, 0), rb.count());
}

test "zeroCount and countValue" {
    const RB = RingBuffer(i32, 8);
    var rb = RB{};

    rb.push(0);
    rb.push(5);
    rb.push(0);
    rb.push(5);
    rb.push(3);

    try std.testing.expectEqual(@as(usize, 2), rb.zeroCount());
    try std.testing.expectEqual(@as(usize, 2), rb.countValue(5));
    try std.testing.expectEqual(@as(usize, 1), rb.countValue(3));
    try std.testing.expectEqual(@as(usize, 0), rb.countValue(99));
}

test "wrap around" {
    const RB = RingBuffer(i32, 4);
    var rb = RB{};

    // Fill and overflow
    rb.push(1);
    rb.push(2);
    rb.push(3);
    rb.push(4);
    rb.push(5); // evicts 1
    rb.push(6); // evicts 2

    try std.testing.expectEqual(@as(usize, 4), rb.count());

    // Read should give 3,4,5,6
    var out: [4]i32 = undefined;
    _ = rb.read(&out);
    try std.testing.expectEqual(@as(i32, 3), out[0]);
    try std.testing.expectEqual(@as(i32, 6), out[3]);
}
