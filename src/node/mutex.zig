/// Mutual exclusion lock with RAII-style held lock scope.
///
/// Converted from `node/Mutex.hpp`. A thin wrapper around `std.Thread.Mutex`
/// that provides a `Held` scope guard matching the C++ `Mutex::Lock` RAII
/// pattern. On Linux/macOS this is backed by pthreads (same as the original).
const std = @import("std");

const Mutex = @This();

/// The underlying platform mutex.
inner: std.Thread.Mutex = .{},

/// Acquire the lock.
pub fn lock(self: *Mutex) void {
    self.inner.lock();
}

/// Release the lock.
pub fn unlock(self: *Mutex) void {
    self.inner.unlock();
}

/// RAII scope guard equivalent to C++ `Mutex::Lock`.
///
/// Usage:
///   var m = Mutex{};
///   {
///       const held = m.acquire();
///       defer held.release();
///       // ... critical section ...
///   }
pub const Held = struct {
    mutex: *Mutex,

    pub fn release(self: Held) void {
        self.mutex.unlock();
    }
};

/// Lock and return a scope guard. Call `release()` (typically via `defer`)
/// to unlock.
pub fn acquire(self: *Mutex) Held {
    self.lock();
    return .{ .mutex = self };
}

// ── Tests ──────────────────────────────────────────────────────────

test "basic lock/unlock" {
    var m = Mutex{};
    m.lock();
    m.unlock();
}

test "held scope guard" {
    var m = Mutex{};
    {
        const held = m.acquire();
        defer held.release();
    }
    // Lock should be free now — verify we can re-acquire
    m.lock();
    m.unlock();
}
