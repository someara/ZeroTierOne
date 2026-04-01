# Coding Standards

## Why This Document Exists

Zig has no borrow checker, no ownership system, and no lifetime tracking. Unlike
Rust, which rejects use-after-free at compile time, Zig only detects it at
runtime in debug builds (by filling freed memory with `0xaa`). In release builds,
UAF is silent corruption.

Every UAF bug we've fixed in this project — HashMap slot invalidation, JSON arena
slices stored past their lifetime, stack-scoped temporaries captured by pointer,
HTTP response bodies freed with the wrong allocator — would have been a compile
error in Rust. We don't have that safety net, so we need conventions.

This document codifies the patterns that prevent these classes of bugs.

---

## 1. Ownership Rules

### Rule 1: Annotate every slice field as OWNED or BORROWED

Every `[]const u8`, `[]u8`, `?[]const u8`, or `?[:0]const u8` field on a struct
MUST have a doc comment stating its ownership:

```zig
/// K8s pod name — OWNED: heap-duped by initFromPod()
name: []const u8,

/// Pod spec — BORROWED: points into _parsed_pod's arena,
/// valid as long as _parsed_pod is alive.
pod_spec: ?k8s_types.PodSpec = null,
```

"OWNED" means the struct is responsible for freeing it in `deinit()`.
"BORROWED" means someone else owns it; the struct must not free it, and must not
outlive the owner.

### Rule 2: Functions returning allocated memory MUST document it

If a function returns a slice that the caller must free, say so explicitly:

```zig
/// Build a container name string for the given pod.
/// Returns a heap-allocated sentinel-terminated string.
/// Caller must free with `allocator`.
fn buildContainerName(allocator: Allocator, ns: []const u8, name: []const u8) ![:0]const u8 {
```

If a function returns a borrowed slice (e.g. pointing into a buffer or parsed
data), document the lifetime constraint:

```zig
/// Returns the token for this registry/repo, or null.
/// Returned slice is borrowed from the token cache — valid until
/// the RegistryClient is deinitialized or the token is replaced.
fn getToken(self: *RegistryClient, registry: []const u8, repo: []const u8) ?[]const u8 {
```

### Rule 3: Document ownership transfer on function parameters

When a function takes ownership of a parameter (will free it or store it), the
doc comment MUST say so:

```zig
/// Handle a pod watch event.
/// Takes ownership of `parsed_event` and calls `.deinit()` when done.
pub fn handleWatchEvent(self: *NodeAgent, parsed_event: *std.json.Parsed(...)) !void {
    defer parsed_event.deinit();
```

When a function borrows a parameter (caller retains ownership), no annotation is
needed — borrowing is the default assumption.

---

## 2. HashMap Safety

### Rule 4: NEVER `getPtr()` then `remove()` then dereference

`getPtr()` returns a pointer into the HashMap's internal storage. After
`remove()`, that slot is invalidated (filled with `0xaa` in debug). Dereferencing
the pointer — including calling `.deinit()` on it — is use-after-free.

```zig
// BAD — use-after-free
if (self.pods.getPtr(uid)) |worker| {
    worker.stop(self);
    _ = self.pods.remove(uid);  // invalidates `worker`
    worker.deinit();            // UAF!
}

// GOOD — fetchRemove returns a copy of the KV pair
if (self.pods.getPtr(uid)) |worker| {
    worker.stop(self);
    var kv = self.pods.fetchRemove(uid).?;  // copy, slot invalidated
    kv.value.deinit();                       // safe — operating on copy
}
```

`getPtr()` is fine for in-place mutation without removal:
```zig
// OK — no removal, pointer stays valid
if (self.pods.getPtr(uid)) |worker| {
    worker.setResourceVersion(new_rv);
    worker.start(self) catch {};
}
```

### Rule 5: HashMap `deinit()` MUST free all owned entries

If a HashMap's keys or values contain allocated memory, the struct's `deinit()`
must iterate and free them all:

```zig
pub fn deinit(self: *RegistryClient) void {
    var it = self.tokens.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.tokens.deinit();
}
```

### Rule 6: `put()` silently leaks if the key already exists

`HashMap.put()` overwrites the old value without freeing it. If the HashMap owns
its values, you must handle the old entry:

```zig
// BAD — leaks old value if key exists
self.tokens.put(key, new_value) catch return error.OutOfMemory;

// GOOD — free old entry first
const gop = self.tokens.getOrPut(key) catch return error.OutOfMemory;
if (gop.found_existing) {
    self.allocator.free(gop.value_ptr.*);
    self.allocator.free(gop.key_ptr.*);
}
gop.key_ptr.* = new_key;
gop.value_ptr.* = new_value;

// ALSO OK — if you can guarantee the key never exists yet
// (e.g. checked with getToken() before calling ensureAuth())
// Document the invariant with a comment.
```

### Rule 7: Never modify a HashMap during iteration

Collect keys/values to modify into a separate list, then apply changes after
iteration completes:

```zig
// Collect stale UIDs first — can't modify HashMap during iteration
var stale_uids = std.ArrayListUnmanaged([]const u8){};
defer stale_uids.deinit(self.allocator);

var it = self.pods.iterator();
while (it.next()) |entry| {
    if (shouldRemove(entry)) {
        stale_uids.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*)) catch continue;
    }
}

for (stale_uids.items) |uid| {
    if (self.pods.getPtr(uid)) |worker| {
        worker.stop(self);
        var kv = self.pods.fetchRemove(uid).?;
        kv.value.deinit();
    }
    self.allocator.free(uid);
}
```

---

## 3. JSON Parse Lifetimes

### Rule 8: Slices from `parseFromSlice` are BORROWED from the parse arena

`std.json.parseFromSlice` returns a `Parsed(T)` whose `.value` contains string
slices pointing into the parsed arena. These slices are invalidated when
`.deinit()` is called.

```zig
// BAD — stored_name dangles after parsed.deinit()
var parsed = try std.json.parseFromSlice(Pod, allocator, json, .{});
const stored_name = parsed.value.metadata.?.name.?;  // borrows from arena
parsed.deinit();  // arena freed
use(stored_name);  // UAF!

// GOOD — dupe before deinit
var parsed = try std.json.parseFromSlice(Pod, allocator, json, .{});
defer parsed.deinit();
const owned_name = try allocator.dupe(u8, parsed.value.metadata.?.name.?);
```

### Rule 9: For complex nested data, re-serialize and re-parse with an owned arena

When you need to store deeply nested parsed data (like a full PodSpec with
containers, env vars, volume mounts), duping individual strings is impractical.
Instead, serialize to JSON and re-parse with a per-object allocator:

```zig
// Serialize the pod to JSON bytes we own
var json_buf = std.ArrayListUnmanaged(u8){};
std.json.stringify(pod, .{}, json_buf.writer(allocator)) catch return error.OutOfMemory;
const pod_json = try json_buf.toOwnedSlice(allocator);
errdefer allocator.free(pod_json);

// Re-parse with our own allocator — now the arena is ours
var parsed_pod = try std.json.parseFromSlice(Pod, allocator, pod_json, .{
    .ignore_unknown_fields = true,
});
// Store both _pod_json (backing bytes) and _parsed_pod (arena owner)
// pod_spec points into _parsed_pod's arena — valid as long as both are alive
```

---

## 4. HTTP Response Ownership

### Rule 10: Use `resp.deinit()`, never `allocator.free(resp.body)`

The HTTP client allocates response bodies with its own internal allocator. The
caller's allocator is a different allocator. Freeing with the wrong allocator is
undefined behavior (typically a size mismatch panic in debug GPA).

```zig
// BAD
const resp = try client.getConfigMap(namespace, name);
defer allocator.free(resp.body);  // wrong allocator!

// GOOD
var resp = try client.getConfigMap(namespace, name);
defer resp.deinit();  // frees body with the correct allocator
```

Note: `resp` must be `var` (not `const`) because `deinit()` takes `*Self`.

---

## 5. Allocator Discipline

### Rule 11: Every struct that allocates MUST store its allocator

The allocator used for allocation must be the same one used for freeing. Store it
as a field named `allocator`:

```zig
pub const PodWorker = struct {
    allocator: std.mem.Allocator,
    name: []const u8,  // allocated with self.allocator

    pub fn deinit(self: *PodWorker) void {
        self.allocator.free(self.name);  // same allocator
    }
};
```

### Rule 12: `errdefer` every allocation in multi-step initialization

When a function makes multiple allocations, each one needs an `errdefer` to
handle cleanup if a later allocation fails:

```zig
const owned_name = try allocator.dupe(u8, name);
errdefer allocator.free(owned_name);

const owned_ns = try allocator.dupe(u8, ns);
errdefer allocator.free(owned_ns);

const owned_uid = try allocator.dupe(u8, uid);
errdefer allocator.free(owned_uid);

// If we get here, all allocations succeeded — return the struct.
// errdefers are cancelled on successful return.
return .{ .name = owned_name, .namespace = owned_ns, .uid = owned_uid, ... };
```

Missing an `errdefer` means that allocation leaks if a later step fails. The
compiler will not warn you.

### Rule 13: Match allocation and free types for sentinel-terminated strings

`allocPrintSentinel(..., 0)` returns `[:0]const u8`. Freeing it requires passing
the sentinel-terminated slice, not a plain `[]const u8`:

```zig
const name: [:0]const u8 = try std.fmt.allocPrintSentinel(allocator, "...", .{}, 0);
// Store as [:0]const u8, free as [:0]const u8
allocator.free(name);  // OK — Zig's free accepts both [:0] and []
```

If you store a `[:0]const u8` in a `?[:0]const u8` optional field, the types
align. Don't accidentally widen to `[]const u8` — while `free` handles it, the
type mismatch obscures the sentinel and can cause confusion.

---

## 6. Stack and Temporary Lifetime Hazards

### Rule 14: Never take the address of a stack-scoped array literal with runtime values

`&.{ runtime_val }` creates a stack-allocated anonymous array. The pointer
dangles as soon as the enclosing scope exits:

```zig
// BAD — dangling pointer after scope exit
const iovecs = &.{
    .{ .name = "name", .value = runtime_name },
};
// iovecs points to stack memory that may be overwritten

// GOOD — use a named local variable
var iovecs = [_]Iovec{
    .{ .name = "name", .value = runtime_name },
};
// iovecs lives on the stack for the duration of this function
```

The key distinction: `&.{...}` creates a temporary that the compiler may place
anywhere. A named `var` array has a well-defined lifetime tied to its scope.

### Rule 15: Don't store pointers to `defer`-freed locals

If a local variable is freed by `defer`, don't store a pointer to it in a struct
that outlives the function:

```zig
// BAD
const name_z = try allocPrintSentinel(allocator, "{s}", .{name}, 0);
defer allocator.free(name_z);
self.jail.name = name_z;  // dangles after function returns!

// GOOD — transfer ownership to the struct
const name_z = try allocPrintSentinel(allocator, "{s}", .{name}, 0);
// No defer — struct takes ownership
self.container_name = name_z;
// Free in self.deinit() or self.stop()
```

---

## 7. Zig 0.15.2 Gotchas

Known pitfalls specific to Zig 0.15.2 (the version used in this project).

### API Changes from Earlier Versions

| Old API | 0.15.2 API | Notes |
|---------|-----------|-------|
| `std.fmt.allocPrintZ` | `std.fmt.allocPrintSentinel` | Takes sentinel value as last arg |
| `std.time.sleep` | `std.Thread.sleep` | Moved to Thread namespace |
| `std.ArrayList(T)` managed | `std.ArrayList(T)` unmanaged | All methods require allocator parameter |
| `file.writer()` no args | `file.writer(&buf)` | Requires buffer argument (vtable dispatch) |

### `std.http.Client` PUT Bug

`responseHasBody()` returns `false` for PUT requests. The workaround is to call
the body reader directly:

```zig
// BAD — response.reader() returns null for PUT
const reader = resp.reader() orelse return error.NoBody;

// GOOD — access the reader directly
const reader = response.request.reader.bodyReader();
```

### `@intCast` Panics on Out-of-Range

`@intCast` is a safety-checked cast — it panics (even in release builds) if the
value doesn't fit. For narrowing casts where truncation is acceptable, use
`@truncate` with `@bitCast`:

```zig
// BAD — panics if ev.data is negative
const status: u32 = @intCast(ev.data);  // ev.data is i64

// GOOD — safe truncation to lower 32 bits
const status: u32 = @truncate(@as(u64, @bitCast(ev.data)));
```

### `_ = errorUnion` is Forbidden

Zig 0.15.2 does not allow discarding error unions with `_`. Use `catch {}`:

```zig
// BAD — compile error
_ = mayFail();

// GOOD
mayFail() catch {};
```

### Stack Array Literals with Runtime Values Dangle

As covered in Rule 14 — `&.{ runtime_value }` creates a temporary with an
unpredictable lifetime. Use named variables.

### Package Name in `build.zig.zon`

Must be a bare identifier, not a string with special characters:

```zig
// BAD
.name = .@"fbsd-k8s",

// GOOD
.name = .fbsd_k8s,
```

### `HashMap.fetchRemove()` Returns a Copy

`fetchRemove()` returns `?KV` — a **copy** of the key-value pair. The HashMap
slot is invalidated after the call, but the returned copy is safe to use. This is
the correct way to remove and then operate on the removed value.

`getPtr()` returns a **pointer into internal storage**. It is invalidated by any
mutating operation on the HashMap (`remove`, `put`, `resize`, etc.).

## 7.5. Cast and Truncation Discipline

### Rule 16: `@truncate` vs `@intCast` — choose by intent

- **`@intCast`**: Use when the value is guaranteed to fit (already
  range-checked or bounded by construction). This documents "I have
  verified this fits."
- **`@truncate`**: Use only when you intentionally discard high bits
  (e.g., extracting the low 32 bits of a 64-bit counter). This
  documents "I know I'm losing information."

If a value has been masked (`& 0x0f`) or bounded, it fits — use
`@intCast`, not `@truncate`:

```zig
// GOOD — masked to 4 bits, guaranteed to fit in u4
const rcode: u4 = @intCast(byte & 0x0f);

// BAD — implies intentional data loss, but none occurs
const rcode: u4 = @truncate(byte & 0x0f);
```

### Rule 17: Document intentional bit-width truncation

When a wire format or protocol mandates a field width narrower than
the Zig type (e.g., DNS header RCODE is 4 bits but RCode is u8),
the setter must document this constraint. Silent masking without
documentation violates "no silent truncation":

```zig
/// Set the 4-bit RCODE in the header. Only the low 4 bits are
/// stored; extended RCodes (>15) require the EDNS0 OPT record.
pub fn setRcode(self: *Header, rc: RCode) void {
    self.bytes[3] = (self.bytes[3] & 0xf0) | (@intFromEnum(rc) & 0x0f);
}
```

---

## 8. FreeBSD API Patterns

### `std.posix.errno()` with `use_libc`

When the target uses libc (true for all FreeBSD targets), `std.posix.errno(rc)`
correctly:
1. Checks if `rc == -1`
2. Reads the thread-local `errno` value
3. Returns the errno as a Zig error enum

This means calling `errno()` on C library return values (e.g., `jail_set`,
`jail_remove`) is correct. The audit finding that this was wrong was a false
positive.

### jail(2) Parameter Formatting

- `vfs_flagopt()` checks name presence only — value is ignored. Used for
  `persist`, `allow.*` flags.
- `jail_set` return value is always the JID; descriptor fd is written back
  through the `"desc"` iovec parameter.
- `JAIL_CREATE` without `JAIL_ATTACH` requires `persist` — otherwise EINVAL.
- `allow.mount.zfs` negation is `allow.mount.nozfs` (not `allow.nomount.zfs`).

### Input Validation for pf Rules

Any string that flows into a pf rule file must be validated. Pod IPs come from
the K8s API as raw `[]const u8` — a crafted value with embedded newlines could
inject arbitrary pf rules:

```zig
// Always validate before using in pf rules
if (!isValidIpAddress(pod_ip)) return error.InvalidIpAddress;
```

Protocol strings are safe when they come from `normalizeProtocol()` which returns
comptime string literals.

---

## Checklist for Code Review

When reviewing a change, check for:

- [ ] Every new `[]const u8` field has an OWNED/BORROWED annotation
- [ ] Every function returning allocated memory documents "caller must free"
- [ ] No `getPtr()` + `remove()` + dereference pattern (use `fetchRemove()`)
- [ ] `parseFromSlice` results don't escape their `Parsed(T)` lifetime
- [ ] HTTP response bodies freed with `resp.deinit()`, not `allocator.free()`
- [ ] Every allocation in multi-step init has a matching `errdefer`
- [ ] HashMap `put()` doesn't silently leak existing entries
- [ ] No `&.{runtime_value}` patterns (use named variables)
- [ ] `@intCast` only used where the value is guaranteed to fit
- [ ] `@truncate` only used for intentional data loss, not masked values
- [ ] Wire-format setters with narrower bit widths document the constraint
- [ ] Strings from external input (K8s API, user config) validated before use
- [ ] Length-prefixed records verify exact byte count consumed after parsing
- [ ] Allocation sizes derived from untrusted data are capped against actual data size
