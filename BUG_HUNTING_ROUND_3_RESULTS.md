# Bug Hunting Round 3: Logic Errors and Edge Cases

**Date**: 2026-04-02
**Branch**: zerotea
**Focus**: Logic errors, edge cases, off-by-one errors, and time-based vulnerabilities

---

## Executive Summary

**Round 3 Status**: ✅ Complete

**Bugs Found**: 2 issues identified
- **BUG #1**: Fragment reassembly retry logic disabled (from Round 2, confirmed)
- **BUG #4**: Timestamp underflow vulnerability in time-based comparisons

**False Alarms**: 2
- Array bounds in fragment handling (correctly implemented)
- Memory leak in tun_device.zig generateZtName (properly freed by caller)

---

## Methodology

Systematic code review focusing on:
1. **Array bounds checking** - Off-by-one errors, buffer overruns
2. **Integer arithmetic** - Overflow, underflow, division by zero
3. **Loop termination** - Infinite loops, missing break conditions
4. **Null pointer handling** - Uninitialized pointers, missing null checks
5. **Time-based logic** - Timestamp comparisons, clock skew handling
6. **Error handling** - Unchecked errors, silent failures

---

## Findings

### BUG #1: Fragment Reassembly Retry Logic Disabled (Confirmed)

**File**: `src/node/switch.zig:606-625`

**Status**: Already documented in Round 2, confirmed still present

**Description**: Fragment reassembly retry code path is disabled due to callback type mismatch

**Code**:
```zig
for (&self.rx_queue) |*rq| {
    rq.lock.lock();
    defer rq.lock.unlock();
    if (rq.timestamp != 0 and rq.complete) {
        // Temporarily disabled due to callback type mismatch
        // if (rq.frag0.tryDecode(callbacks, rq.flow_id) or ...)
    }
}
```

**Impact**: Complete fragmented packets may not be processed until next background task

**Recommendation**: Fix callback type conversion to re-enable retry logic

---

### BUG #4: Timestamp Underflow Vulnerability ⚠️

**Severity**: Medium
**Category**: Time-based logic error

**Description**: Time-based comparisons use `(now - timestamp)` without checking if timestamp is in the future. If `timestamp > now` (due to clock skew, NTP adjustment, or malicious packet), the subtraction produces a negative value or very large unsigned value.

**Affected Locations**:
- `src/node/switch.zig:529` - Fragment timeout check
- `src/node/switch.zig:613` - RX queue timeout
- `src/node/switch.zig:638` - WHOIS retry delay
- `src/node/bond.zig:174` - RTT calculation
- `src/node/bond.zig:293` - Path alive timeout
- `src/node/path.zig:320` - Trust expiration check
- `src/node/path.zig:339,355,375` - Age calculations
- `src/node/network.zig:1157` - Entry expiration
- `src/node/membership.zig:176,204` - Multicast and activity timeouts
- 10+ more locations

**Example Code**:
```zig
// src/node/switch.zig:529
if (rq.frag0.tryDecode(callbacks, rq.flow_id) or
    (now - rq.timestamp) > constants.receive_queue_timeout) {
    rq.timestamp = 0;
}
```

**Problem**: If `rq.timestamp` is in the future:
- `(now - rq.timestamp)` wraps to large positive or negative value
- Timeout check may never trigger
- Stale entries never expire

**Attack Scenario**:
1. Malicious peer sends packet with timestamp far in the future
2. Local system stores this timestamp
3. Timeout comparisons break (`now - future_timestamp` < 0)
4. Entry persists indefinitely, consuming resources

**Recommended Fix**:
```zig
// Option 1: Clamp to zero
const age = if (now > rq.timestamp) now - rq.timestamp else 0;
if (rq.frag0.tryDecode(callbacks, rq.flow_id) or
    age > constants.receive_queue_timeout) {
    rq.timestamp = 0;
}

// Option 2: Reject future timestamps
if (rq.timestamp > now) {
    // Clock skew or malicious timestamp - invalidate entry
    rq.timestamp = 0;
}
```

**Impact**:
- **Memory exhaustion**: Entries that should expire don't, filling tables
- **Denial of service**: Stale paths/peers never time out
- **Incorrect RTT**: Negative RTT values corrupt QoS metrics
- **Security bypass**: Trust expiration checks may fail

**Mitigation Priority**: Medium (requires clock manipulation or malicious peer)

---

## Validated Correct Implementations

### Array Bounds Checking (Fragment Handling)

**File**: `src/node/switch.zig:730-769`

**Analysis**: Correctly implemented
- Array size: `frags: [max_packet_fragments - 1]FragmentData`
- Bounds check: `frag_num >= max_packet_fragments` rejects invalid
- Access: `frags[frag_num - 1]` with `frag_num >= 1` check
- Max valid frag_num: `max_packet_fragments - 1`, accessing index `max_packet_fragments - 2` ✅

**Verdict**: ✅ No bug

---

### Binary Search Division

**File**: `src/node/multicaster.zig:126`

**Code**:
```zig
const mid = lo + (hi - lo) / 2;
```

**Analysis**: Safe
- `hi >= lo` always (loop condition ensures this)
- Division by 2 is safe for all values
- Standard binary search pattern

**Verdict**: ✅ No bug

---

### Infinite Loop Protection

**File**: `src/node/capability.zig:363-379`

**Code**:
```zig
while (true) {
    const to_addr = Address.fromSlice(to_bytes);
    if (!to_addr.isSet()) break;  // Termination condition

    if (chain_idx >= max_custody_chain_length) {
        return error.OutOfBounds;  // Bounds protection
    }
    // ... process entry ...
}
```

**Analysis**: Safe
- Clear break condition at line 368
- Bounds check prevents overflow at line 370
- Standard parsing pattern

**Verdict**: ✅ No bug

---

### Mutex Patterns

**Files**: All modules with locks

**Analysis**: All mutex usage follows correct pattern:
```zig
rq.lock.lock();
defer rq.lock.unlock();
// ... critical section ...
```

**Verified**:
- `src/node/switch.zig:526, 608, 739, 834` - All use defer
- No missing unlock calls found
- No double-lock scenarios

**Verdict**: ✅ No bugs

---

### Error Handling

**Analysis**: Reviewed error handling patterns across modules
- Most `catch {}` blocks are intentional silent failures (non-critical operations)
- Critical paths use `try` or explicit error handling
- Buffer operations safely ignore errors (size validation elsewhere)

**Verdict**: ✅ No critical issues

---

## Summary Statistics

**Files Analyzed**: 15+ core modules
**Code Patterns Checked**: 50+ potential issues
**Bugs Found**: 2 (1 already documented, 1 new)
**False Alarms**: 2 (resolved with deeper analysis)

### Bug Breakdown

| Bug # | Severity | Category | Status | File |
|-------|----------|----------|--------|------|
| #1 | Medium | Logic | Known | switch.zig:606 |
| #4 | Medium | Time-based | **NEW** | Multiple files |

---

## Recommendations

### Immediate Actions

1. **Fix timestamp underflow (BUG #4)**:
   - Add age calculation helper with negative value protection
   - Audit all time-based comparisons (20+ locations)
   - Consider rejecting timestamps more than X seconds in future

2. **Re-enable fragment retry (BUG #1)**:
   - Fix callback type mismatch
   - Re-test fragment reassembly

### Long-term Improvements

1. **Time handling utilities**:
   - Create `safeAge(now, timestamp)` helper function
   - Centralize time comparison logic
   - Add clock skew detection

2. **Testing**:
   - Add unit tests with future timestamps
   - Test clock adjustment scenarios
   - Verify timeout behavior under clock skew

---

## Next Steps

**Round 4**: Race conditions and concurrency issues
- Thread safety analysis
- Lock ordering verification
- Atomic operation correctness
- Callback reentrancy

**Round 5**: Security vulnerabilities and input validation
- Packet injection attacks
- Resource exhaustion vectors
- Cryptographic validation gaps
- DoS attack surfaces

---

**Round 3 Completion**: 2026-04-02
**Next Round**: Round 4 - Race conditions and concurrency
