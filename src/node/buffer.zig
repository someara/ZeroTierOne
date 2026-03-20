/// Fixed-capacity stack-allocated byte buffer with bounds checking.
///
/// Converted from `node/Buffer.hpp`. This is the fundamental packet buffer
/// used throughout the ZeroTier protocol implementation. All integer
/// encode/decode operations use big-endian (network) byte order.
///
/// Unlike the C++ version which throws exceptions on bounds violations,
/// this version returns errors. No heap allocation is performed.
///
/// @param C Total capacity in bytes
const std = @import("std");
const mem = std.mem;
const native_endian = @import("builtin").cpu.arch.endian();

pub fn Buffer(comptime C: u32) type {
    if (C == 0) @compileError("Buffer capacity must be > 0");

    return struct {
        const Self = @This();

        pub const capacity = C;

        /// Error returned on any bounds violation.
        pub const Error = error{OutOfBounds};

        _b: [C]u8 = undefined,
        _l: u32 = 0,

        /// Create a buffer initialized with data from a slice.
        pub fn initFrom(src: []const u8) Error!Self {
            if (src.len > C) return error.OutOfBounds;
            var self = Self{};
            const len: u32 = @intCast(src.len);
            @memcpy(self._b[0..len], src);
            self._l = len;
            return self;
        }

        /// Create a buffer with a given logical size (contents undefined).
        pub fn initWithSize(len: u32) Error!Self {
            if (len > C) return error.OutOfBounds;
            return .{ ._l = len };
        }

        // ── Element access ─────────────────────────────────────────

        /// Read a single byte at index `i`.
        pub fn getByte(self: *const Self, i: u32) Error!u8 {
            if (i >= self._l) return error.OutOfBounds;
            return self._b[i];
        }

        /// Write a single byte at index `i`.
        pub fn setByte(self: *Self, i: u32, v: u8) Error!void {
            if (i >= self._l) return error.OutOfBounds;
            self._b[i] = v;
        }

        /// Get a pointer to a field of `len` bytes starting at index `i`.
        /// The field must be within the current data length.
        pub fn field(self: *const Self, i: u32, len: u32) Error![]const u8 {
            if (i + len > self._l) return error.OutOfBounds;
            return self._b[i..][0..len];
        }

        /// Get a mutable pointer to a field of `len` bytes.
        pub fn fieldMut(self: *Self, i: u32, len: u32) Error![]u8 {
            if (i + len > self._l) return error.OutOfBounds;
            return self._b[i..][0..len];
        }

        // ── Big-endian integer access ──────────────────────────────

        /// Read a big-endian integer of type `T` at position `i`.
        pub fn at(self: *const Self, comptime T: type, i: u32) Error!T {
            const type_size = @sizeOf(T);
            if (i + type_size > self._l) return error.OutOfBounds;
            return mem.readInt(T, self._b[i..][0..type_size], .big);
        }

        /// Write a big-endian integer of type `T` at position `i`.
        pub fn setAt(self: *Self, comptime T: type, i: u32, v: T) Error!void {
            const type_size = @sizeOf(T);
            if (i + type_size > self._l) return error.OutOfBounds;
            mem.writeInt(T, self._b[i..][0..type_size], v, .big);
        }

        // ── Append operations ──────────────────────────────────────

        /// Append a big-endian integer of type `T`.
        pub fn appendInt(self: *Self, comptime T: type, v: T) Error!void {
            const type_size: u32 = @sizeOf(T);
            if (self._l + type_size > C) return error.OutOfBounds;
            mem.writeInt(T, self._b[self._l..][0..type_size], v, .big);
            self._l += type_size;
        }

        /// Append raw bytes from a slice.
        pub fn appendBytes(self: *Self, src: []const u8) Error!void {
            const len: u32 = std.math.cast(u32, src.len) orelse return error.OutOfBounds;
            if (self._l + len > C) return error.OutOfBounds;
            @memcpy(self._b[self._l..][0..len], src);
            self._l += len;
        }

        /// Append a single byte repeated `n` times.
        pub fn appendByte(self: *Self, byte: u8, n: u32) Error!void {
            if (self._l + n > C) return error.OutOfBounds;
            @memset(self._b[self._l..][0..n], byte);
            self._l += n;
        }

        /// Append a C string including its null terminator.
        pub fn appendCString(self: *Self, s: [*:0]const u8) Error!void {
            var i: usize = 0;
            while (true) {
                if (self._l >= C) return error.OutOfBounds;
                self._b[self._l] = s[i];
                self._l += 1;
                if (s[i] == 0) break;
                i += 1;
            }
        }

        /// Increment size by `n` and return a mutable slice to the new space.
        /// The contents of the new space are undefined.
        pub fn appendField(self: *Self, n: u32) Error![]u8 {
            if (self._l + n > C) return error.OutOfBounds;
            const start = self._l;
            self._l += n;
            return self._b[start..self._l];
        }

        /// Append from another Buffer (possibly of different capacity).
        pub fn appendBuffer(self: *Self, comptime C2: u32, other: *const Buffer(C2)) Error!void {
            try self.appendBytes(other.data());
        }

        // ── Size manipulation ──────────────────────────────────────

        /// Increase the logical size by `n` bytes.
        pub fn addSize(self: *Self, n: u32) Error!void {
            if (self._l + n > C) return error.OutOfBounds;
            self._l += n;
        }

        /// Set the logical size to `new_size`.
        pub fn setSize(self: *Self, new_size: u32) Error!void {
            if (new_size > C) return error.OutOfBounds;
            self._l = new_size;
        }

        /// Move everything after position `pos` to the front, truncating.
        pub fn behead(self: *Self, pos: u32) Error!void {
            if (pos == 0) return;
            if (pos > self._l) return error.OutOfBounds;
            self._l -= pos;
            // memmove: regions may overlap
            const dest = self._b[0..self._l];
            const src = self._b[pos..][0..self._l];
            mem.copyForwards(u8, dest, src);
        }

        /// Erase `length` bytes starting at position `start`.
        pub fn erase(self: *Self, start: u32, length: u32) Error!void {
            const end_pos = start + length;
            if (end_pos > self._l) return error.OutOfBounds;
            const remaining = self._l - end_pos;
            mem.copyForwards(u8, self._b[start..][0..remaining], self._b[end_pos..][0..remaining]);
            self._l -= length;
        }

        /// Set data length to zero.
        pub fn clear(self: *Self) void {
            self._l = 0;
        }

        /// Zero all bytes up to the current logical size.
        pub fn zero(self: *Self) void {
            @memset(self._b[0..self._l], 0);
        }

        /// Zero unused capacity area.
        pub fn zeroUnused(self: *Self) void {
            @memset(self._b[self._l..C], 0);
        }

        /// Securely zero the entire underlying buffer (for crypto key material).
        pub fn burn(self: *Self) void {
            std.crypto.secureZero(u8, &self._b);
        }

        // ── Accessors ──────────────────────────────────────────────

        /// Return a const slice of the valid data.
        pub fn data(self: *const Self) []const u8 {
            return self._b[0..self._l];
        }

        /// Return a mutable slice of the valid data.
        pub fn dataMut(self: *Self) []u8 {
            return self._b[0..self._l];
        }

        /// Return the current logical size.
        pub fn size(self: *const Self) u32 {
            return self._l;
        }

        /// Copy data from a slice into the buffer, replacing current contents.
        pub fn copyFrom(self: *Self, src: []const u8) Error!void {
            const len: u32 = std.math.cast(u32, src.len) orelse return error.OutOfBounds;
            if (len > C) return error.OutOfBounds;
            @memcpy(self._b[0..len], src);
            self._l = len;
        }

        // ── Comparison ─────────────────────────────────────────────

        /// Check equality with another buffer (possibly of different capacity).
        pub fn eql(self: *const Self, comptime C2: u32, other: *const Buffer(C2)) bool {
            return self._l == other._l and
                mem.eql(u8, self._b[0..self._l], other._b[0..other._l]);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "create and access" {
    var buf = Buffer(64){};
    try std.testing.expectEqual(@as(u32, 0), buf.size());

    try buf.appendBytes("hello");
    try std.testing.expectEqual(@as(u32, 5), buf.size());
    try std.testing.expectEqualSlices(u8, "hello", buf.data());
}

test "big-endian integer round-trip" {
    var buf = Buffer(64){};

    try buf.appendInt(u16, 0x1234);
    try buf.appendInt(u32, 0xDEADBEEF);
    try buf.appendInt(u64, 0x0102030405060708);

    try std.testing.expectEqual(@as(u16, 0x1234), try buf.at(u16, 0));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try buf.at(u32, 2));
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), try buf.at(u64, 6));

    // Verify big-endian byte order
    try std.testing.expectEqual(@as(u8, 0x12), try buf.getByte(0));
    try std.testing.expectEqual(@as(u8, 0x34), try buf.getByte(1));
}

test "setAt overwrites" {
    var buf = try Buffer(64).initWithSize(4);
    try buf.setAt(u32, 0, 0xCAFEBABE);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), try buf.at(u32, 0));

    try buf.setAt(u16, 0, 0x0000);
    try std.testing.expectEqual(@as(u32, 0x0000BABE), try buf.at(u32, 0));
}

test "bounds checking" {
    var buf = Buffer(4){};
    try buf.appendBytes("abcd");

    // Cannot append past capacity
    try std.testing.expectError(error.OutOfBounds, buf.appendBytes("e"));
    try std.testing.expectError(error.OutOfBounds, buf.appendInt(u8, 0));

    // Cannot read past logical size
    try std.testing.expectError(error.OutOfBounds, buf.getByte(4));
    try std.testing.expectError(error.OutOfBounds, buf.at(u16, 3));
}

test "behead" {
    var buf = Buffer(64){};
    try buf.appendBytes("abcdef");

    try buf.behead(2);
    try std.testing.expectEqualSlices(u8, "cdef", buf.data());
    try std.testing.expectEqual(@as(u32, 4), buf.size());
}

test "erase" {
    var buf = Buffer(64){};
    try buf.appendBytes("abcdef");

    try buf.erase(2, 2); // remove "cd"
    try std.testing.expectEqualSlices(u8, "abef", buf.data());
    try std.testing.expectEqual(@as(u32, 4), buf.size());
}

test "field" {
    var buf = Buffer(64){};
    try buf.appendBytes("hello world");

    const slice = try buf.field(6, 5);
    try std.testing.expectEqualSlices(u8, "world", slice);

    // Out of bounds
    try std.testing.expectError(error.OutOfBounds, buf.field(8, 5));
}

test "appendCString" {
    var buf = Buffer(64){};
    try buf.appendCString("test");
    try std.testing.expectEqual(@as(u32, 5), buf.size()); // includes null
    try std.testing.expectEqual(@as(u8, 0), try buf.getByte(4));
}

test "burn securely zeros" {
    var buf = Buffer(16){};
    try buf.appendBytes("secret");
    buf.burn();
    for (buf._b) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "equality" {
    var a = Buffer(64){};
    try a.appendBytes("test");

    var b = Buffer(128){};
    try b.appendBytes("test");

    var c = Buffer(64){};
    try c.appendBytes("other");

    try std.testing.expect(a.eql(128, &b));
    try std.testing.expect(!a.eql(64, &c));
}

test "initFrom" {
    const buf = try Buffer(64).initFrom("hello");
    try std.testing.expectEqualSlices(u8, "hello", buf.data());

    // Too large
    try std.testing.expectError(error.OutOfBounds, Buffer(4).initFrom("toolong"));
}

test "appendField returns mutable slice" {
    var buf = Buffer(64){};
    try buf.appendBytes("ab");
    const new_area = try buf.appendField(3);
    new_area[0] = 'c';
    new_area[1] = 'd';
    new_area[2] = 'e';
    try std.testing.expectEqualSlices(u8, "abcde", buf.data());
}
