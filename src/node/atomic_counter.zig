/// Atomic reference counter for intrusive reference counting.
///
/// Converted from `node/AtomicCounter.hpp`. Used by `SharedPtr` to track
/// reference counts on shared objects. Thread-safe via atomic operations
/// with sequentially-consistent ordering.
const std = @import("std");

const AtomicCounter = @This();

/// The underlying atomic value. Initialized to zero.
value: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

/// Atomically load the current count.
pub fn load(self: *const AtomicCounter) i32 {
    // SeqCst matches the full-barrier semantics of __sync_or_and_fetch
    return self.value.load(.seq_cst);
}

/// Atomically increment and return the new value.
pub fn increment(self: *AtomicCounter) i32 {
    return self.value.fetchAdd(1, .seq_cst) + 1;
}

/// Atomically decrement and return the new value.
pub fn decrement(self: *AtomicCounter) i32 {
    return self.value.fetchSub(1, .seq_cst) - 1;
}

// ── Tests ──────────────────────────────────────────────────────────

test "init is zero" {
    const counter = AtomicCounter{};
    try std.testing.expectEqual(@as(i32, 0), counter.load());
}

test "increment and decrement" {
    var counter = AtomicCounter{};

    try std.testing.expectEqual(@as(i32, 1), counter.increment());
    try std.testing.expectEqual(@as(i32, 2), counter.increment());
    try std.testing.expectEqual(@as(i32, 3), counter.increment());
    try std.testing.expectEqual(@as(i32, 3), counter.load());

    try std.testing.expectEqual(@as(i32, 2), counter.decrement());
    try std.testing.expectEqual(@as(i32, 1), counter.decrement());
    try std.testing.expectEqual(@as(i32, 0), counter.decrement());
    try std.testing.expectEqual(@as(i32, 0), counter.load());
}

test "decrement below zero" {
    var counter = AtomicCounter{};

    try std.testing.expectEqual(@as(i32, -1), counter.decrement());
    try std.testing.expectEqual(@as(i32, -1), counter.load());
}
