/// Hash table for the ZeroTier core.
///
/// Converted from `node/Hashtable.hpp`. The C++ version was a custom chained
/// hash table with hand-rolled hash functions. This Zig version wraps
/// `std.HashMap` with context-aware hashing that matches the C++ hash
/// behavior for integer key types.
///
/// Key differences from the C++ version:
///   - Uses an allocator explicitly (no hidden `new`/`delete`)
///   - Iterator API uses Zig's standard pattern
///   - No implicit auto-growth on `operator[]` — use `getOrPut` instead
const std = @import("std");

/// Create a Hashtable type for key type `K` and value type `V`.
///
/// Integer key types (u16, u32, u64, i32) use hash functions matching the
/// C++ originals. Other key types must provide a `hashCode() usize` method
/// and support `==` comparison.
pub fn Hashtable(comptime K: type, comptime V: type) type {
    const Context = HashContext(K);

    return struct {
        const Self = @This();

        pub const HashMap = std.HashMap(K, V, Context, 80);
        pub const Iterator = HashMap.Iterator;

        /// The underlying hash map.
        /// OWNED: allocated with `allocator`, freed in `deinit`.
        map: HashMap,

        /// Allocator used for all internal storage.
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .map = HashMap.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Look up a key and return a pointer to its value, or null.
        /// The returned pointer is BORROWED — valid until the next
        /// mutating operation on the table.
        pub fn get(self: *const Self, key: K) ?*V {
            return self.map.getPtr(key);
        }

        /// Look up a key and return a copy of its value, or null.
        pub fn getCopy(self: *const Self, key: K) ?V {
            return self.map.get(key);
        }

        /// Check if a key is present.
        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        /// Insert or update a key-value pair.
        /// If the key already exists, the old value is overwritten.
        /// Returns error.OutOfMemory if allocation fails during rehash.
        pub fn set(self: *Self, key: K, value: V) error{OutOfMemory}!void {
            try self.map.put(key, value);
        }

        /// Get or insert: return a pointer to the existing value, or insert
        /// a new entry with `default_value` and return a pointer to it.
        /// Returns error.OutOfMemory if allocation fails.
        pub fn getOrPut(self: *Self, key: K, default_value: V) error{OutOfMemory}!*V {
            const gop = try self.map.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = default_value;
            }
            return gop.value_ptr;
        }

        /// Remove a key. Returns true if the key was present.
        pub fn erase(self: *Self, key: K) bool {
            return self.map.fetchRemove(key) != null;
        }

        /// Remove a key and return the removed value, or null.
        pub fn fetchRemove(self: *Self, key: K) ?V {
            const kv = self.map.fetchRemove(key) orelse return null;
            return kv.value;
        }

        /// Remove all entries.
        pub fn clear(self: *Self) void {
            self.map.clearAndFree();
        }

        /// Return the number of entries.
        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        /// Return true if the table is empty.
        pub fn empty(self: *const Self) bool {
            return self.map.count() == 0;
        }

        /// Return an iterator over all entries.
        /// Do NOT mutate the table during iteration.
        pub fn iterator(self: *const Self) Iterator {
            return self.map.iterator();
        }
    };
}

/// Hash context that matches the C++ Hashtable's hash functions.
fn HashContext(comptime K: type) type {
    return struct {
        const Self = @This();

        pub fn hash(_: Self, key: K) u64 {
            return switch (@typeInfo(K)) {
                .int => hashInt(key),
                else => {
                    // For non-integer types, delegate to the key's hashCode method
                    if (@hasDecl(K, "hashCode")) {
                        return @as(u64, key.hashCode());
                    } else {
                        // Fall back to Zig's auto-hash
                        return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
                    }
                },
            };
        }

        pub fn eql(_: Self, a: K, b: K) bool {
            return a == b;
        }

        fn hashInt(key: K) u64 {
            const bits = @bitSizeOf(K);
            if (bits == 64) {
                // C++: (unsigned long)(i ^ (i >> 32))
                const k: u64 = @bitCast(key);
                return k ^ (k >> 32);
            } else if (bits == 32) {
                // C++: (unsigned long)i * 0x9e3779b1
                const k: u64 = @as(u64, @as(u32, @bitCast(key)));
                return k *% 0x9e3779b1;
            } else if (bits == 16) {
                // C++: (unsigned long)i * 0x9e3779b1
                const k: u64 = @as(u64, @as(u16, @bitCast(key)));
                return k *% 0x9e3779b1;
            } else {
                // Generic fallback
                return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            }
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "basic set and get" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u32).init(alloc);
    defer ht.deinit();

    try ht.set(100, 42);
    try ht.set(200, 99);

    try std.testing.expectEqual(@as(u32, 42), ht.getCopy(100).?);
    try std.testing.expectEqual(@as(u32, 99), ht.getCopy(200).?);
    try std.testing.expect(ht.getCopy(300) == null);
}

test "contains and count" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u32, bool).init(alloc);
    defer ht.deinit();

    try std.testing.expectEqual(@as(usize, 0), ht.count());
    try std.testing.expect(ht.empty());

    try ht.set(1, true);
    try ht.set(2, false);

    try std.testing.expectEqual(@as(usize, 2), ht.count());
    try std.testing.expect(!ht.empty());
    try std.testing.expect(ht.contains(1));
    try std.testing.expect(!ht.contains(3));
}

test "erase" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u32).init(alloc);
    defer ht.deinit();

    try ht.set(10, 100);
    try ht.set(20, 200);

    try std.testing.expect(ht.erase(10));
    try std.testing.expect(!ht.erase(10)); // already removed
    try std.testing.expect(!ht.contains(10));
    try std.testing.expectEqual(@as(usize, 1), ht.count());
}

test "fetchRemove returns value" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u32).init(alloc);
    defer ht.deinit();

    try ht.set(42, 123);

    const removed = ht.fetchRemove(42);
    try std.testing.expectEqual(@as(u32, 123), removed.?);
    try std.testing.expect(ht.fetchRemove(42) == null);
}

test "overwrite existing key" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u32).init(alloc);
    defer ht.deinit();

    try ht.set(1, 10);
    try ht.set(1, 20);

    try std.testing.expectEqual(@as(u32, 20), ht.getCopy(1).?);
    try std.testing.expectEqual(@as(usize, 1), ht.count());
}

test "getOrPut" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u32, u32).init(alloc);
    defer ht.deinit();

    // First call creates the entry
    const v1 = try ht.getOrPut(1, 100);
    try std.testing.expectEqual(@as(u32, 100), v1.*);

    // Second call returns existing
    v1.* = 200;
    const v2 = try ht.getOrPut(1, 999);
    try std.testing.expectEqual(@as(u32, 200), v2.*);
}

test "clear" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u32).init(alloc);
    defer ht.deinit();

    try ht.set(1, 10);
    try ht.set(2, 20);
    ht.clear();

    try std.testing.expectEqual(@as(usize, 0), ht.count());
    try std.testing.expect(ht.empty());
}

test "iterator" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u32, u32).init(alloc);
    defer ht.deinit();

    try ht.set(1, 10);
    try ht.set(2, 20);
    try ht.set(3, 30);

    var sum: u32 = 0;
    var iter_count: usize = 0;
    var it = ht.iterator();
    while (it.next()) |entry| {
        sum += entry.value_ptr.*;
        iter_count += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), iter_count);
    try std.testing.expectEqual(@as(u32, 60), sum);
}

test "many entries trigger rehash" {
    const alloc = std.testing.allocator;
    var ht = Hashtable(u64, u64).init(alloc);
    defer ht.deinit();

    // Insert enough entries to trigger multiple rehashes
    for (0..256) |i| {
        try ht.set(@as(u64, @intCast(i)), @as(u64, @intCast(i)) * 10);
    }

    try std.testing.expectEqual(@as(usize, 256), ht.count());

    // Verify all entries are intact
    for (0..256) |i| {
        const key = @as(u64, @intCast(i));
        try std.testing.expectEqual(key * 10, ht.getCopy(key).?);
    }
}
