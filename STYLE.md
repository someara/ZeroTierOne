# Coding Standards

Inspired by OpenBSD Kernel Normal Form (`style(9)`) and the defensive
programming tradition of the BSD operating systems. Adapted for Zig and
the specific requirements of a FreeBSD Kubernetes node agent.

> "Code is read far more often than it is written. Optimize for the
> auditor, not the author."

---

## 1. Philosophy

- **Correctness over cleverness.** If a reader needs to think twice about
  what a line does, rewrite it.
- **Every error path is a first-class citizen.** Error handling is not
  an afterthought — it is half the program.
- **Fail closed.** When state is ambiguous, stop the container rather
  than leave it running unsupervised. When data is suspect, reject it
  rather than guess.
- **Small, auditable functions.** A function should do one thing. If you
  cannot describe it in one sentence, it is too large.
- **Explicit over implicit.** No magic. No hidden control flow. No
  silent data loss.

---

## 2. Error Handling

### 2.1 No silent swallowing

Every `catch` must be intentional. Prefer exhaustive `switch` over
catch-all patterns:

```zig
// GOOD — exhaustive, auditable
foo() catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
    error.InvalidInput => {
        log.warn("bad input, skipping", .{});
        return null;
    },
};

// BAD — erases information
foo() catch |_| return null;

// BAD — hides OOM
foo() catch return error.GenericFailure;
```

### 2.2 OutOfMemory must propagate

Never erase `OutOfMemory` into a domain-specific error. OOM indicates
system-wide memory pressure and must be visible to callers so they can
shed load or abort gracefully.

```zig
// GOOD
const name = allocator.dupe(u8, input) catch |err| switch (err) {
    error.OutOfMemory => return error.OutOfMemory,
};

// BAD — OOM becomes "not found"
const name = allocator.dupe(u8, input) catch return null;
```

When a function's return type cannot express `OutOfMemory` (e.g., it
returns `void` or `?T`), this must be documented as a known limitation
with a comment explaining the consequence.

### 2.3 C interop error checking

All C library functions that return `-1` on error set `errno` in
thread-local storage. Never interpret the return code as a negated
errno — read the real value:

```zig
// GOOD
const rc = c.some_function(args);
if (rc == -1) {
    const e = std.c._errno().*;
    log.err("some_function failed: errno={d}", .{e});
    return error.SyscallFailed;
}

// BAD — interprets -1 as errno 1 (EPERM)
const rc = c.some_function(args);
switch (std.posix.errno(rc)) { ... }
```

### 2.4 No `catch unreachable` for heap allocation

`catch unreachable` asserts that an error cannot occur. Heap allocation
can always fail. Use `try`, `catch`, or an explicit OOM path.

```zig
// GOOD
const buf = try allocator.alloc(u8, n);

// ACCEPTABLE — when the consequence is documented
const buf = allocator.alloc(u8, n) catch {
    log.warn("OOM building status, field omitted", .{});
    break :blk null;
};

// BAD — panics on OOM in production
const buf = allocator.alloc(u8, n) catch unreachable;
```

---

## 3. Resource Safety

### 3.1 Immediate `defer` / `errdefer`

Every resource acquisition must have its release on the immediately
following line (or same line). This makes leak-freedom locally
verifiable.

```zig
const fd = try std.posix.open(path, .{});
defer std.posix.close(fd);

const buf = try allocator.alloc(u8, n);
errdefer allocator.free(buf);
// ... use buf, then return it to caller (transfer ownership)
```

### 3.2 File descriptors

- Every `open` / `socket` / `accept` has a `defer close` or
  `errdefer close`.
- Use `CLOEXEC` flags on all new descriptors to prevent leaking
  into child processes.

### 3.3 Jail and network resources

- Jail creation → `errdefer jail.destroy()`
- epair creation → `errdefer epair.destroy()`
- IP allocation → `errdefer ipam.release(ip)`
- ZFS clone → `errdefer zfs.destroy(dataset)`

The pattern: if any step in a multi-resource provisioning sequence
fails, all previously acquired resources must be released via
`errdefer`, not by manual cleanup at the error site.

---

## 4. Input Validation

### 4.1 Trust boundaries

All data crossing a trust boundary must be validated before use.
Trust boundaries in this project:

1. **Kubernetes API** — Pod specs, container names, UIDs, image refs
2. **OCI registries** — Manifests, blob digests, tar contents
3. **C API returns** — errno values, jail IDs, file descriptors
4. **Network data** — HTTP headers, response bodies, watch events
5. **Wire protocols** — DNS packets, binary file formats, serialized
   data from disk or network. Every field must be validated; reserved
   values must be rejected, not ignored.

### 4.2 Names and identifiers

Kubernetes names used in filesystem paths, ZFS datasets, or jail names
must be validated against RFC 1123 DNS label rules (`isValidK8sName`)
or UUID format (`isValidUid`) before use.

### 4.3 No silent truncation

If data does not fit in a buffer, return an error. Never silently
clip, wrap, or discard:

```zig
// GOOD
const n = std.math.cast(u32, value) orelse return error.Overflow;

// BAD — silent wrap on 32-bit overflow
const n: u32 = @intCast(value);
```

### 4.4 Path traversal defense

Any path component derived from external input must be checked for
traversal sequences (`..`, absolute paths, null bytes). Symlink
targets in tar archives must be validated (`isSafeTarPath`,
`isSafeSymlinkTarget`).

### 4.5 Binary protocol parsing

When parsing untrusted binary data (network packets, file formats):

- **Reject unknown field types.** If a field has reserved or undefined
  values, return an error — do not silently skip or treat as a default.
  Accepting unknown values today creates silent data corruption when
  those values gain meaning tomorrow.
- **Validate pointer/offset targets.** Any pointer or offset embedded in
  the data must be bounds-checked against both the data length and a
  minimum valid offset (e.g., past fixed headers). Forward pointers
  and self-referencing pointers must be rejected.
- **Cap recursion/indirection depth.** Compression pointers, nested
  structures, and recursive references need a hard depth limit to
  prevent stack overflow or infinite loops from crafted input.
- **Treat every byte as adversarial.** Do not assume fields contain
  valid values just because earlier fields were valid. Validate each
  field independently.

### 4.6 Struct invariants

When a struct's methods depend on internal data being well-formed
(e.g., a buffer always containing valid wire-format data), document
the invariant in a doc comment on the struct. This tells readers
which guarantee makes the code safe, and which constructors/mutators
are responsible for maintaining it.

If the struct's fields are public, the invariant comment must note
that direct field mutation can break it.

---

## 5. Structural Rules

### 5.1 Function length

- **Target: ≤120 lines** (fits on ~2 screens).
- **Hard limit: 150 lines.** Functions exceeding this must be
  decomposed unless there is a documented reason (e.g., a single
  state machine that is clearer as one block).
- Extract helper functions with descriptive names. A 300-line function
  with 5 clear phases should become 5 functions called in sequence.

### 5.2 File length

- **Target: ≤1500 lines** (excluding tests).
- **Review trigger: 2000 lines.** Files exceeding this should be
  evaluated for decomposition.
- Tests may live at the bottom of the file they test, or in a
  separate `foo_test.zig` alongside `foo.zig`.

### 5.3 One struct, one responsibility

Each major struct should own a single concern. If a struct has methods
spanning multiple unrelated responsibilities (e.g., networking AND
status building AND probe execution), factor the responsibilities
into separate modules that operate on the struct.

### 5.4 Module organization

A source file should have this order:

1. File-level doc comment (what this module does)
2. Imports: `std` first, then project modules, then C imports
3. Public type definitions
4. Private type definitions
5. Public functions
6. Private functions
7. Tests (at bottom)

### 5.5 Bitwise expression readability

Always parenthesize bitwise operators (`&`, `|`, `^`) when combined
with comparison operators (`==`, `!=`, `<`, `>`), even though Zig's
precedence makes it unnecessary. Readers from C/C++ backgrounds will
misread the precedence:

```zig
// GOOD
if ((flags & 0x80) != 0) ...
if ((label_type & 0xc0) == 0xc0) ...

// BAD — correct in Zig, misread by humans
if (flags & 0x80 != 0) ...
```

### 5.6 Doc comment accuracy

A doc comment is a contract. If a function's documented behavior
differs from its actual behavior, that is a bug — fix the code or
fix the comment, but never leave them divergent. When behavior has
caveats or limitations, state them in the doc comment rather than
leaving the caller to discover them by reading the implementation.

### 5.7 Dead code

Remove unused constants, functions, and imports immediately. Dead code
misleads readers into thinking it is load-bearing. If code is
intentionally kept for future use, it must have a comment explaining
what will use it and when — otherwise delete it.

---

## 6. Naming Conventions

Follow Zig's standard conventions:

| Kind | Style | Example |
|------|-------|---------|
| Functions, methods | `camelCase` | `buildStatus`, `resolveEnvValue` |
| Types, structs, enums | `PascalCase` | `PodWorker`, `ProbeOutcome` |
| Constants | `snake_case` or `SCREAMING_SNAKE` | `max_retry_count`, `STDERR_FILENO` |
| Local variables | `snake_case` | `container_name`, `exit_code` |
| Error values | `PascalCase` after `error.` | `error.OutOfMemory`, `error.InvalidPodName` |

### 6.1 Import aliases

Use the natural module name, not abbreviations:

```zig
// GOOD
const jail = @import("../runtime/jail.zig");
const api_types = @import("../k8s/api_types.zig");

// BAD
const j = @import("../runtime/jail.zig");
const at = @import("../k8s/api_types.zig");
```

---

## 7. C Interop Safety

### 7.1 Sentinel-terminated strings

All strings passed to C functions must be null-terminated. Use
`allocPrintZ` / `allocSentinel` / `toPosixPath` — never manually
append `\0`:

```zig
// GOOD
const path = try std.fmt.allocPrintZ(allocator, "/jails/{s}", .{name});
defer allocator.free(path);

// BAD — manual null termination is error-prone
var buf: [256]u8 = undefined;
const n = std.fmt.bufPrint(&buf, "/jails/{s}", .{name});
buf[n] = 0;
```

### 7.2 Integer conversions at C boundaries

Use `std.math.cast` for runtime integer conversions that may fail.
Use `@intCast` only when the value has already been range-checked or
is compile-time known:

```zig
// GOOD — guarded cast
const fd: std.posix.fd_t = std.math.cast(std.posix.fd_t, raw_fd) orelse return error.InvalidFd;

// GOOD — value is known safe (loop counter bounded by small array)
const idx: u8 = @intCast(i); // i < containers.len, which was validated ≤ 255

// BAD — unguarded, panics on overflow
const n: u32 = @intCast(some_usize);
```

### 7.3 Null bytes and control characters

Any string that will cross a C API boundary (jail names, ZFS dataset
names, file paths) must be pre-scanned for null bytes (`\x00`) and
control characters. C APIs treat `\x00` as a string terminator,
enabling truncation attacks.

---

## 8. Concurrency

### 8.1 Single-threaded state mutation

The main event loop (kqueue) is the sole mutator of pod state. The
watch thread only enqueues events; the kubelet HTTP server only reads
state under a mutex. This design eliminates most data races by
construction.

### 8.2 Lock discipline

- Document lock ordering when multiple mutexes exist.
- Minimize work done under a lock — no allocation, no I/O, no
  blocking calls while holding a mutex if avoidable.
- Use UID-based lookups after releasing a lock, never raw pointers
  (pointers may be invalidated by HashMap mutations).

### 8.3 Shared state access

```zig
// GOOD — lookup by UID after lock release
const uid = event.uid;
self.pods_mutex.lock();
const worker = self.pods.get(uid);
self.pods_mutex.unlock();
if (worker) |w| { ... }

// BAD — pointer obtained under lock, used after release
self.pods_mutex.lock();
const ptr = &self.pods.get(uid).?;
self.pods_mutex.unlock();
ptr.*.doSomething(); // ptr may be dangling
```

---

## 9. Workflow

### 9.1 Bug-fix loop

When hunting bugs:
1. Find at most **3 issues**.
2. Fix them.
3. Run `zig build test`.
4. Commit.
5. Repeat.

Do not batch-discover dozens of issues before fixing any. Small
iterations catch regressions early and keep commits reviewable.

When adding a new rule to these standards, sweep the existing codebase
for violations before considering the rule adopted. A rule that only
applies to future code creates an inconsistent codebase where the
same pattern is correct in old files and incorrect in new ones.

### 9.2 Severity classification

| Level | Definition | Example |
|-------|-----------|---------|
| **CRITICAL** | Data corruption, security bypass, use-after-free | Heap buffer overflow in tar extraction |
| **HIGH** | Resource leak, crash in production path, privilege escalation vector | Jail fd leak, path traversal via unsanitized name |
| **MEDIUM** | Error erasure, incorrect status reporting, degraded behavior | OOM mapped to generic error, silent field truncation |
| **LOW** | Cosmetic, minor inefficiency, edge case in non-critical path | Redundant allocation, off-by-one in log message |

### 9.3 Commit discipline

- Every commit must pass `zig build test` on the host.
- Code changes that affect native FreeBSD behavior must also pass
  `zig build` on the VM before or immediately after commit.
- Commit messages state *what changed and why*, not just *what files
  were touched*.

### 9.4 VM testing

Before declaring a feature complete:
- Build natively on the FreeBSD VM.
- Deploy the agent against a real K8s API server.
- Exercise the feature end-to-end (create pod, observe logs, verify
  cleanup).

### 9.5 Test expectations for new code

Every new public function must have at least:
- One test for the happy path.
- One test for each documented error return.
- One test for boundary conditions (empty input, maximum size, zero).

For parsers, also add:
- One test for malformed/adversarial input per field.
- One round-trip test (parse → serialize → compare) when a writer
  exists.

---

## References

- OpenBSD `style(9)` — Kernel Normal Form
- Zig Language Reference — https://ziglang.org/documentation/master/
- FreeBSD `jail(2)`, `capsicum(4)` — Sandboxing primitives
- Kubernetes API Conventions — https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md
