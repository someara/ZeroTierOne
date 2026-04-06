# Zig Coding Standards

This file focuses on ownership, lifetime, allocator, and container hazards.

## 1. Ownership Rules

### Rule 1: Slice fields must say OWNED or BORROWED

- document every slice field's ownership
- OWNED means freed by the struct
- BORROWED means the struct must not free it or outlive the owner

### Rule 2: Returned allocations must be documented

- say when the caller must free returned data
- say when returned data is borrowed and how long it stays valid

### Rule 3: Ownership transfer on parameters must be documented

- if a function takes ownership, say so
- borrowing is the default

## 2. Zig API Design

- prefer one canonical path
- prefer comptime-generic or typed APIs over opaque internal handlers
- prefer owned data or stable snapshots over fragile borrows
- encode ownership in types where practical
- fail closed in config and control parsing

## 3. HashMap Safety

### Rule 4: Never `getPtr()` then `remove()` then dereference

- use `fetchRemove()` when removal is involved

### Rule 5: `deinit()` must free owned HashMap entries

- free owned keys and values before `deinit()`

### Rule 6: `put()` can leak old owned values

- handle replacement explicitly when the map owns entries

### Rule 7: Never mutate a HashMap during iteration

- collect keys first
- mutate after iteration

## 4. JSON Lifetime Rules

### Rule 8: `parseFromSlice` results borrow from the parse arena

- slices die when the parsed object is deinitialized

### Rule 9: Re-serialize and re-parse if you need owned nested JSON state

- use an owned backing buffer plus your own parse arena

## 5. HTTP Response Ownership

### Rule 10: Use `resp.deinit()`, not `allocator.free(resp.body)`

- response bodies belong to the response object

## 6. Allocator Discipline

### Rule 11: Allocating structs must store their allocator

- free with the same allocator that allocated

### Rule 12: Multi-step init needs `errdefer` for each allocation

- every owned allocation in a fallible setup path needs cleanup

### Rule 13: Keep sentinel-terminated string types intact

- do not obscure sentinel ownership and lifetime by widening types casually

## 7. Lifetime Hazards

### Rule 14: Do not take addresses of stack temporaries built from runtime values

- use named locals instead of `&.{ runtime_value }`

### Rule 15: Do not store pointers to `defer`-freed locals

- transfer ownership or duplicate data instead

## 8. Zig 0.15.2 Gotchas

- `std.ArrayList(T)` is unmanaged
- `@intCast` traps on out-of-range values
- `_ = errorUnion` is not allowed
- `&.{ runtime_value }` lifetime is unsafe

## 9. Cast Discipline

### Rule 16: `@intCast` means the value fits

- use it only after validation or when bounded by construction

### Rule 17: `@truncate` means intentional data loss

- use it only when discarding bits is the real intent
- document narrow wire-format setters when truncation is protocol-defined

## 10. Review Checklist

- [ ] slice ownership is documented
- [ ] returned allocations document caller ownership
- [ ] ownership transfer is documented
- [ ] no `getPtr()` + `remove()` dereference pattern
- [ ] HashMap ownership is cleaned up correctly
- [ ] parse-arena borrows do not escape
- [ ] HTTP responses use `resp.deinit()`
- [ ] multi-step init has matching `errdefer`
- [ ] no unsafe `&.{ runtime_value }` temporaries
- [ ] casts match intent
- [ ] untrusted lengths, counts, and fields are validated
- [ ] config/control parsing fails closed
