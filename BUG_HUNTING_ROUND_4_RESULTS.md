# Bug Hunting Round 4: Race Conditions and Concurrency Issues

**Date**: 2026-04-02
**Branch**: zerotea
**Focus**: Thread safety, race conditions, deadlocks, and atomic operation correctness

---

## Executive Summary

**Round 4 Status**: ✅ Complete

**Bugs Found**: 3 new concurrency issues
- **BUG #5**: Race condition on `last_checked_queues` field
- **BUG #6**: TOCTOU race in `findRXQueueEntry` search
- **BUG #7**: TOCTOU race in `Network.setConfiguration` duplicate check

**Validated Correct**: Lock ordering, mutex patterns, atomic counter usage

---

## Methodology

Systematic concurrency analysis:
1. **Lock ordering analysis** - Check for potential deadlocks
2. **Shared state access** - Verify all shared data is protected
3. **Atomic operations** - Ensure correct memory ordering
4. **TOCTOU patterns** - Time-Of-Check-Time-Of-Use races
5. **Callback reentrancy** - Nested callback safety
6. **Data races** - Unsynchronized read/write to shared variables

---

## Findings

### BUG #5: Race Condition on last_checked_queues ⚠️

**File**: `src/node/switch.zig:563,567`
**Severity**: Low
**Category**: Data race

**Description**: `last_checked_queues` is read and written without synchronization

**Code**:
```zig
// Line 563 - READ without lock
const time_since_last_check = now - self.last_checked_queues;
if (time_since_last_check < constants.whois_retry_delay) {
    return @intCast(constants.whois_retry_delay - time_since_last_check);
}
// Line 567 - WRITE without lock
self.last_checked_queues = now;
```

**Problem**: If `doTimerTasks` is called concurrently from multiple threads:
- Thread A reads `last_checked_queues`
- Thread B writes `last_checked_queues`
- Thread A continues with stale value
- **Result**: Timing calculations become incorrect, tasks may run more/less frequently than intended

**Race Scenario**:
1. Thread A: Reads `last_checked_queues = 1000`
2. Thread B: Writes `last_checked_queues = 2000`
3. Thread A: Calculates `time_since_last_check` with stale `1000`
4. Both threads may proceed when only one should

**Recommended Fix**:
```zig
// Option 1: Make field atomic
last_checked_queues: std.atomic.Atomic(i64),

// Usage:
const current = self.last_checked_queues.load(.Monotonic);
const time_since_last_check = now - current;
if (time_since_last_check < constants.whois_retry_delay) {
    return @intCast(constants.whois_retry_delay - time_since_last_check);
}
self.last_checked_queues.store(now, .Monotonic);

// Option 2: Use mutex
if (!self.timer_mutex.tryLock()) return;
defer self.timer_mutex.unlock();
// ... rest of doTimerTasks
```

**Impact**:
- **Timing drift**: Tasks may run at incorrect intervals
- **Performance**: No crash, but potential inefficiency
- **Correctness**: Queue processing timing becomes unpredictable

**Mitigation Priority**: Low (timing drift is minor, no memory corruption)

---

### BUG #6: TOCTOU Race in findRXQueueEntry 🔴

**File**: `src/node/switch.zig:681-694`
**Severity**: Medium-High
**Category**: Time-Of-Check-Time-Of-Use race

**Description**: RX queue search reads unprotected fields, then allocates without re-checking under lock

**Code**:
```zig
fn findRXQueueEntry(self: *Self, packet_id: u64) *RXQueueEntry {
    const current = self.rx_queue_ptr.load();  // Atomic load
    // Look for existing entry with this packet ID
    var k: i32 = 1;
    while (k <= rx_queue_size) : (k += 1) {
        const idx: usize = @intCast(@mod((current -% k), rx_queue_size));
        const rq = &self.rx_queue[idx];
        // BUG: Reading packet_id and timestamp WITHOUT lock!
        if (rq.packet_id == packet_id and rq.timestamp != 0) {
            return rq;
        }
    }
    // Allocate new entry
    _ = self.rx_queue_ptr.increment();
    return &self.rx_queue[@intCast(@mod(current, rx_queue_size))];
}
```

**Problem**: Race between check and use:
1. Thread A checks `rq.packet_id` and `rq.timestamp` **without lock** (line 688)
2. Thread B acquires `rq.lock` and modifies `rq.packet_id` to 0 (clears entry)
3. Thread A returns stale pointer to now-cleared entry
4. Thread A operates on wrong entry → **data corruption**

**Race Scenario**:
```
Time    Thread A                        Thread B
----    --------                        --------
T0      Load current = 5
T1      Search: rq[4].packet_id = 123
T2                                       rq[4].lock.lock()
T3      Check: packet_id == 123 ✓       rq[4].timestamp = 0  // Clear entry
T4      Return &rq[4]                   rq[4].lock.unlock()
T5      rq.lock.lock()  // Too late!
T6      Read rq.packet_id (now 0!)
```

**Impact**:
- **Fragment corruption**: Fragments assigned to wrong packet ID
- **Data loss**: Completed fragments overwritten
- **Stale data**: Operating on cleared entries
- **Memory corruption**: Writing to wrong queue slot

**Recommended Fix**:
```zig
fn findRXQueueEntry(self: *Self, packet_id: u64) *RXQueueEntry {
    const current = self.rx_queue_ptr.load();

    // Search with locks held
    var k: i32 = 1;
    while (k <= rx_queue_size) : (k += 1) {
        const idx: usize = @intCast(@mod((current -% k), rx_queue_size));
        const rq = &self.rx_queue[idx];

        rq.lock.lock();
        const matches = (rq.packet_id == packet_id and rq.timestamp != 0);
        rq.lock.unlock();

        if (matches) return rq;
    }

    // Allocate new entry
    _ = self.rx_queue_ptr.increment();
    return &self.rx_queue[@intCast(@mod(current, rx_queue_size))];
}
```

**Mitigation Priority**: High (data corruption possible)

---

### BUG #7: TOCTOU Race in Network.setConfiguration 🔴

**File**: `src/node/network.zig:1540,1549`
**Severity**: Medium
**Category**: Time-Of-Check-Time-Of-Use race

**Description**: Duplicate check reads `_config` without lock, then acquires lock to update

**Code**:
```zig
pub fn setConfiguration(self: *Network, t_ptr: ?*anyopaque, nconf: *const NetworkConfig, save_to_disk: bool) i32 {
    // ... validation ...

    // BUG: Read _config WITHOUT lock (line 1540)
    if (mem.eql(u8, mem.asBytes(&self._config), mem.asBytes(nconf))) return 1;

    var ec: VirtualNetworkConfig = undefined;
    var old_port_initialized: bool = undefined;

    {
        self._lock.lock();  // Lock acquired AFTER check!
        defer self._lock.unlock();

        // Update _config under lock (line 1549)
        self._config = nconf.*;
        // ...
    }
}
```

**Problem**: Classic TOCTOU race:
1. Thread A checks if `_config` equals `nconf` at line 1540 (**no lock**)
2. Thread B acquires lock and updates `_config`
3. Thread A proceeds thinking config is duplicate, but it's now stale
4. Thread A **skips configuration update** that should have been applied

**Race Scenario**:
```
Time    Thread A                          Thread B
----    --------                          --------
T0      Read _config (old value)
T1      Check: _config == nconf? (false)
T2                                        _lock.lock()
T3                                        _config = new_config
T4                                        _lock.unlock()
T5      Continue to lock section
T6      _lock.lock()
T7      _config = nconf (overwrites B's update!)
```

**Alternative race**:
```
Time    Thread A                          Thread B
----    --------                          --------
T0      Read _config (old)
T1                                        _lock.lock()
T2                                        _config = nconf
T3                                        _lock.unlock()
T4      Check: _config == nconf? (true!)
T5      Return 1 (skip update)
T6      // Never applies callback!
```

**Impact**:
- **Lost updates**: Configuration changes silently ignored
- **Inconsistent state**: Network config out of sync
- **Callback not fired**: Port configuration callback skipped
- **Persistence failure**: Config not saved to disk

**Recommended Fix**:
```zig
pub fn setConfiguration(self: *Network, t_ptr: ?*anyopaque, nconf: *const NetworkConfig, save_to_disk: bool) i32 {
    if (self._destroyed) return 0;

    // Validate: config must be for this network and for us.
    if (nconf.issued_to.toInt() != self._my_address.toInt()) return 0;
    if (nconf.network_id != self._id) return 0;

    var ec: VirtualNetworkConfig = undefined;
    var old_port_initialized: bool = undefined;
    var is_duplicate: bool = false;

    {
        self._lock.lock();
        defer self._lock.unlock();

        // Check for duplicate UNDER LOCK
        if (mem.eql(u8, mem.asBytes(&self._config), mem.asBytes(nconf))) {
            is_duplicate = true;
        } else {
            self._config = nconf.*;
            self._last_config_update = if (self._callbacks.now) |now_fn| now_fn(self._callbacks.ctx) else 0;
            self._netconf_failure = .none;
            old_port_initialized = self._port_initialized;
            self._port_initialized = true;
            self.externalConfigInternal(&ec);
        }
    }

    if (is_duplicate) return 1;

    // Fire callback outside the lock (unchanged)
    // ...
}
```

**Mitigation Priority**: Medium (lost config updates, but rare race window)

---

## Validated Correct Implementations

### Lock Ordering ✅

**Analysis**: No deadlock potential found

All lock acquisitions follow consistent patterns:
- Individual RX queue entry locks are independent (no nesting)
- `tx_queue_mutex` acquired independently (lines 439, 536, 575)
- `last_sent_whois_request_mutex` acquired independently (line 629)
- `last_unite_attempt_mutex` acquired independently (line 654)

**Sequential pattern in doTimerTasks**:
```zig
// Line 526-533: RX queue locks (loop, defer unlock)
for (&self.rx_queue) |*rq| {
    rq.lock.lock();
    defer rq.lock.unlock();  // Released before next lock
}

// Line 536: TX queue lock (after RX locks released)
self.tx_queue_mutex.lock();
defer self.tx_queue_mutex.unlock();

// Line 629: WHOIS mutex (after TX lock released)
self.last_sent_whois_request_mutex.lock();
defer self.last_sent_whois_request_mutex.unlock();

// Line 654: UNITE mutex (after WHOIS lock released)
self.last_unite_attempt_mutex.lock();
defer self.last_unite_attempt_mutex.unlock();
```

**Verdict**: ✅ No deadlocks (locks acquired sequentially, never nested)

---

### Mutex Usage Pattern ✅

**Analysis**: All mutex usage follows safe `defer` pattern

**Pattern**:
```zig
rq.lock.lock();
defer rq.lock.unlock();
// ... critical section ...
```

**Verified locations**:
- `switch.zig:526,608,739,834` - RX queue entry locks
- `switch.zig:439,536,575` - TX queue mutex
- `switch.zig:519,629` - WHOIS mutex
- `switch.zig:654` - UNITE mutex
- `network.zig:1546` - Network config lock

**Verdict**: ✅ No missing unlocks, no double-locks

---

### Atomic Counter Usage ✅

**Analysis**: `rx_queue_ptr` uses `AtomicCounter` correctly

**Declaration**: `src/node/switch.zig:254`
```zig
rx_queue_ptr: AtomicCounter,
```

**Usage**:
- Line 682: `const current = self.rx_queue_ptr.load();` ✅ Atomic load
- Line 693: `_ = self.rx_queue_ptr.increment();` ✅ Atomic increment
- Line 699: `const idx = self.rx_queue_ptr.increment() - 1;` ✅ Atomic increment

**Verdict**: ✅ Atomic operations used correctly (but BUG #6 still exists due to racy field reads)

---

## Summary Statistics

**Files Analyzed**: 6 core modules (switch, network, topology, peer, node, phy)
**Concurrency Patterns Checked**: 30+ lock sites, 10+ shared state access
**Bugs Found**: 3 new race conditions
**Validated Correct**: Lock ordering, mutex patterns, atomic operations

### Bug Breakdown

| Bug # | Severity | Category | File | Impact |
|-------|----------|----------|------|--------|
| #5 | Low | Data race | switch.zig:563 | Timing drift |
| #6 | High | TOCTOU | switch.zig:688 | Data corruption |
| #7 | Medium | TOCTOU | network.zig:1540 | Lost updates |

---

## Recommendations

### Immediate Actions

1. **Fix BUG #6 (HIGH PRIORITY)**:
   - Add lock acquisition during RX queue search
   - Test fragment reassembly under concurrent load
   - Verify no performance regression from lock contention

2. **Fix BUG #7 (MEDIUM PRIORITY)**:
   - Move duplicate check inside lock
   - Add test for concurrent setConfiguration calls

3. **Fix BUG #5 (LOW PRIORITY)**:
   - Make `last_checked_queues` atomic
   - Or add mutex around doTimerTasks entry

### Long-term Improvements

1. **Concurrency testing**:
   - Add multi-threaded stress tests
   - Use Thread Sanitizer (TSan) to detect races
   - Fuzz concurrent packet processing

2. **Lock annotations**:
   - Document lock ordering requirements
   - Add debug assertions for lock state
   - Consider lock-free alternatives where appropriate

3. **Code review checklist**:
   - All shared state accesses under lock?
   - No TOCTOU patterns (check-then-act)?
   - Atomic operations use correct memory ordering?
   - Callback reentrancy considered?

---

## Next Steps

**Round 5**: Security vulnerabilities and attack surfaces
- Input validation gaps
- Resource exhaustion vectors
- Cryptographic validation bypasses
- Integer overflows in security-critical code
- Injection attacks and side-channels

---

**Round 4 Completion**: 2026-04-02
**Next Round**: Round 5 - Security and attack surface analysis
