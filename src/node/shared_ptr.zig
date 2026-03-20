/// Intrusive reference-counted smart pointer.
///
/// Converted from `node/SharedPtr.hpp`. This is a generic smart pointer that
/// requires the managed type `T` to embed a `RefCount` field. Unlike the C++
/// version which uses `new`/`delete`, this Zig version uses an explicit
/// allocator passed at creation time and stored in the pointer.
///
/// Objects managed by `SharedPtr` must have a public field:
///   `__ref_count: shared_ptr.RefCount`
/// initialized to `.{}` (default, starting at 0).
const std = @import("std");

const atomic_counter = @import("atomic_counter.zig");

/// The reference count type embedded in managed objects.
/// Objects that want to be managed by `SharedPtr` must include this as a field
/// named `__ref_count`.
pub const RefCount = atomic_counter;

/// Intrusive reference-counted pointer to `T`.
///
/// `T` must have a public field `__ref_count: shared_ptr.RefCount`.
/// The pointer is nullable: a default-initialized `SharedPtr` holds no object.
pub fn SharedPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: ?*T = null,
        allocator: ?std.mem.Allocator = null,

        /// Create a SharedPtr that takes ownership of an existing heap-allocated
        /// object. The reference count is incremented.
        ///
        /// Caller must ensure `obj` was allocated with `alloc`.
        /// SharedPtr takes shared ownership; the last release will free.
        pub fn initFromRaw(obj: *T, alloc: std.mem.Allocator) Self {
            _ = obj.__ref_count.increment();
            return .{ .ptr = obj, .allocator = alloc };
        }

        /// Allocate a new `T` on the heap (default-initialized) and return a
        /// SharedPtr owning it with ref count 1.
        ///
        /// Returns `error.OutOfMemory` if allocation fails.
        pub fn create(alloc: std.mem.Allocator) error{OutOfMemory}!Self {
            const obj = try alloc.create(T);
            obj.* = std.mem.zeroInit(T, .{});
            obj.__ref_count = .{};
            _ = obj.__ref_count.increment();
            return .{ .ptr = obj, .allocator = alloc };
        }

        /// Copy the shared pointer, incrementing the reference count.
        pub fn clone(self: Self) Self {
            if (self.ptr) |p| {
                _ = p.__ref_count.increment();
            }
            return .{ .ptr = self.ptr, .allocator = self.allocator };
        }

        /// Release this reference. If this was the last reference, the object
        /// is destroyed (its `deinit` is called if present) and freed.
        pub fn release(self: *Self) void {
            if (self.ptr) |p| {
                if (p.__ref_count.decrement() <= 0) {
                    if (self.allocator) |alloc| {
                        // Call deinit if the type has one
                        if (@hasDecl(T, "deinit")) {
                            p.deinit();
                        }
                        alloc.destroy(p);
                    }
                }
                self.ptr = null;
                self.allocator = null;
            }
        }

        /// Swap the contents of two SharedPtrs without touching ref counts.
        pub fn swap(self: *Self, other: *Self) void {
            const tmp_ptr = self.ptr;
            const tmp_alloc = self.allocator;
            self.ptr = other.ptr;
            self.allocator = other.allocator;
            other.ptr = tmp_ptr;
            other.allocator = tmp_alloc;
        }

        /// Return the raw pointer, or null.
        pub fn get(self: Self) ?*T {
            return self.ptr;
        }

        /// Return the current reference count, or 0 if null.
        pub fn references(self: Self) i32 {
            if (self.ptr) |p| {
                return p.__ref_count.load();
            }
            return 0;
        }

        /// Returns true if this pointer holds a non-null object.
        pub fn isSet(self: Self) bool {
            return self.ptr != null;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const TestObj = struct {
    value: u32 = 0,
    __ref_count: RefCount = .{},
};

test "create and release" {
    const alloc = std.testing.allocator;

    var sp = try SharedPtr(TestObj).create(alloc);
    try std.testing.expect(sp.isSet());
    try std.testing.expectEqual(@as(i32, 1), sp.references());

    sp.release();
    try std.testing.expect(!sp.isSet());
    try std.testing.expectEqual(@as(i32, 0), sp.references());
}

test "clone increments ref count" {
    const alloc = std.testing.allocator;

    var sp1 = try SharedPtr(TestObj).create(alloc);
    var sp2 = sp1.clone();

    try std.testing.expectEqual(@as(i32, 2), sp1.references());
    try std.testing.expectEqual(@as(i32, 2), sp2.references());

    sp1.release();
    try std.testing.expectEqual(@as(i32, 1), sp2.references());

    sp2.release();
}

test "swap" {
    const alloc = std.testing.allocator;

    var sp1 = try SharedPtr(TestObj).create(alloc);
    sp1.get().?.value = 42;

    var sp2 = try SharedPtr(TestObj).create(alloc);
    sp2.get().?.value = 99;

    sp1.swap(&sp2);

    try std.testing.expectEqual(@as(u32, 99), sp1.get().?.value);
    try std.testing.expectEqual(@as(u32, 42), sp2.get().?.value);

    sp1.release();
    sp2.release();
}

test "null pointer operations" {
    var sp = SharedPtr(TestObj){};
    try std.testing.expect(!sp.isSet());
    try std.testing.expectEqual(@as(i32, 0), sp.references());
    try std.testing.expect(sp.get() == null);

    // release on null is a no-op
    sp.release();
    try std.testing.expect(!sp.isSet());
}
