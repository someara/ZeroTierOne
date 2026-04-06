# Bug Hunt Session 2 - 2026-04-07

## Overview
Second systematic code review, 20 additional rounds of bug hunting.

## Bugs Found and Fixed

### Round 1: Statistical Calculation Error
**Location**: `src/node/ring_buffer.zig:178`

**Issue**: Variance calculation used wrong denominator
- Was dividing by `S - 1` (buffer capacity)
- Should divide by `cnt - 1` (actual sample count)
- Results in incorrect variance/stddev when buffer not full
- Could affect path quality metrics

**Fix**: Changed to use `cnt - 1` for unbiased sample variance

**Impact**: MEDIUM - Incorrect statistical calculations for path quality

---

### Round 2: Release Build Vulnerability
**Location**: `src/node/phy_uring.zig:91`

**Issue**: Buffer pool validation only in debug builds
- Used `std.debug.assert(index < BUFFER_COUNT)`
- Compiled out in release builds (`-O ReleaseFast`)
- Invalid index from corrupted io_uring data could access out of bounds
- Could lead to memory corruption

**Fix**: Changed to runtime check with error logging
```zig
if (index >= BUFFER_COUNT) {
    std.debug.print("phy_uring: ERROR: invalid buffer index\n", .{});
    return;
}
```

**Impact**: CRITICAL - Potential memory corruption in release builds

---

## Search Patterns Used (Session 2)
1. `std.debug.assert` - Debug-only checks
2. `unreachable` in non-test code
3. Modulo operations (division by zero)
4. Atomic value usage
5. Variance/statistical calculations
6. Buffer pool management
7. IO operation error handling
8. Sensitive data handling
9. Timing attack vulnerabilities
10. Switch statement exhaustiveness

## Areas Examined (No Issues Found)
- ✅ Atomic operations (properly used)
- ✅ Modulo by zero (all protected by guards)
- ✅ IO error handling (all wrapped in try/catch)
- ✅ Sensitive data (only test keys found)
- ✅ Timing attacks (using constant-time crypto primitives)
- ✅ NULL pointer dereferences (minimal C interop)
- ✅ Memory equality checks (all safe)
- ✅ Errdefer blocks (all correct)
- ✅ Integer underflow (all bounded)

## Test Results
All 391 tests passing after fixes.

## Summary Statistics

### Session 1 (2026-04-06)
- Bugs: 6 (2 critical, 2 medium, 2 low)
- Rounds: 20

### Session 2 (2026-04-07)
- Bugs: 2 (1 critical, 1 medium)
- Rounds: 20

### Total Across Both Sessions
- **Total Bugs**: 8
- **Critical**: 3 (silent OOM, deadlock, release build corruption)
- **Medium**: 3 (division guard, buffer underflow, variance calc)
- **Low**: 2 (documentation, code clarity)

## Commits
- f9440458: Session 1 - Round 1 (3 bugs)
- f30d2cfb: Session 1 - Round 2 (2 bugs)
- 0f5ded54: Session 1 - Round 3 (1 bug)
- d84ce940: Session 2 - Rounds 1-2 (2 bugs)

## Key Findings

The most significant issue found in Session 2 was the `std.debug.assert` usage in a buffer pool. This is a common pitfall in Zig:

**Problem**: Debug assertions are compiled out in release builds, but buffer bounds checking needs to always be present to prevent memory corruption from untrusted data sources (io_uring completion queue).

**Lesson**: Use runtime checks, not debug asserts, for validating data from:
- Network packets
- IO completion queues
- External APIs
- Untrusted file input

Debug asserts should only be used for:
- Validating internal API contracts
- Catching programmer errors during development
- Checking invariants that cannot be violated in correct code

## Code Quality Assessment

Both sessions confirm the codebase is exceptionally clean:
- Proper error propagation throughout
- Good use of RAII patterns (defer/errdefer)
- Safe collection iteration
- Minimal unsafe operations
- Well-bounded arithmetic

The bugs found are primarily:
- Edge cases (empty buffers, single-element collections)
- Defensive checks (division by zero guards)
- Debug vs release behavior differences
