# Bug Hunting Round 1 — 2026-04-01

Following STYLE.md §9.1 workflow: Find up to 3 issues, fix them, test, commit, repeat.

## Issues Found

### Issue 1: Unsafe @enumFromInt on untrusted cipher suite (HIGH severity)

**File**: `src/node/packet.zig` line 504
**Type**: Undefined behavior on untrusted network data
**Severity**: HIGH (violates STYLE.md §4.5)

**Problem**: CipherSuite uses `@enumFromInt` without validating the value.

```zig
pub fn cipher(self: *const Packet) CipherSuite {
    const b = self.buf.getByte(idx_flags) catch return .c25519_poly1305_none;
    const raw: u3 = @intCast((b >> 3) & 0x07);
    return @enumFromInt(raw);  // ← UNSAFE: raw could be 4-7
}
```

**Root Cause**: CipherSuite is exhaustive (no `_` wildcard), defining only values 0-3:
```zig
pub const CipherSuite = enum(u3) {
    c25519_poly1305_none = 0,
    c25519_poly1305_salsa2012 = 1,
    no_crypto_trusted_path = 2,
    aes_gmac_siv = 3,
};
```

A u3 can represent 0-7. Values 4-7 from untrusted network data cause undefined behavior in ReleaseFast builds.

**Impact**: Attacker-controlled cipher field with values 4-7 → undefined behavior, potential crash or security bypass.

**STYLE.md §4.5 violation**: "Reject unknown field types. If a field has reserved or undefined values, return an error — do not silently skip or treat as a default."

**Fix**: Add validation before @enumFromInt:
```zig
pub fn cipher(self: *const Packet) ?CipherSuite {
    const b = self.buf.getByte(idx_flags) catch return null;
    const raw: u3 = @intCast((b >> 3) & 0x07);

    // Validate cipher suite is in valid range
    return switch (raw) {
        0...3 => @enumFromInt(raw),
        else => null, // Invalid cipher suite from network
    };
}
```

Alternatively, make CipherSuite non-exhaustive by adding `_,` but then all switch statements on it must handle unknown values explicitly.

---

### Issue 2: @truncate on masked value (LOW severity)

**File**: `src/node/packet.zig` line 536
**Type**: Incorrect cast for bounded value
**Severity**: LOW (violates CODING_STANDARDS.md Rule 16)

**Problem**: Using `@truncate` on a masked value that is guaranteed to fit.

```zig
pub fn verb(self: *const Packet) Verb {
    const b = self.buf.getByte(idx_verb) catch return .nop;
    return @enumFromInt(@as(u5, @truncate(b & 0x1f)));  // ← WRONG cast
}
```

**Root Cause**: `b & 0x1f` masks to 5 bits (0-31), which is guaranteed to fit in u5. Using `@truncate` implies intentional data loss, but no data is lost here.

**CODING_STANDARDS.md Rule 16 violation**: "If a value has been masked (`& 0x0f`) or bounded, it fits — use `@intCast`, not `@truncate`. This documents 'I have verified this fits.'"

**Impact**: Code intent is misleading. No runtime issue since the value fits, but reduces readability.

**Fix**: Use `@intCast` to document that the value is known to fit:
```zig
pub fn verb(self: *const Packet) Verb {
    const b = self.buf.getByte(idx_verb) catch return .nop;
    return @enumFromInt(@as(u5, @intCast(b & 0x1f)));
}
```

---

### Issue 3: Missing documentation of intentional truncation (LOW severity)

**File**: `src/node/packet.zig` lines 570-571
**Type**: Undocumented bit-width constraint
**Severity**: LOW (violates CODING_STANDARDS.md Rule 17)

**Problem**: Intentional truncation of packet size to 16 bits without documentation.

```zig
// Packet size as little-endian u16.
const sz = self.buf.size();
out[19] = in_key[19] ^ @as(u8, @truncate(sz & 0xff));
out[20] = in_key[20] ^ @as(u8, @truncate((sz >> 8) & 0xff));
```

**Root Cause**: `sz` is u32 (from `buf.size()`) but only the lower 16 bits are encoded. If `sz > 65535`, the high bits are silently discarded without warning.

**CODING_STANDARDS.md Rule 17 violation**: "When a wire format or protocol mandates a field width narrower than the Zig type (e.g., DNS header RCODE is 4 bits but RCode is u8), the setter must document this constraint."

**Impact**: If a packet exceeds 65KB, the encoded size wraps. However, `max_packet_length = 7 * 1432 = 10024` which is under 65KB, so this is currently safe. Still, the constraint should be documented.

**Fix**: Add a doc comment or assertion:
```zig
// Packet size as little-endian u16.
// Note: ZeroTier protocol limits packets to 16-bit size (max 65535 bytes).
// Current max_packet_length (10024) is well under this limit.
const sz = self.buf.size();
std.debug.assert(sz <= 0xFFFF); // Protocol constraint
out[19] = in_key[19] ^ @as(u8, @truncate(sz & 0xff));
out[20] = in_key[20] ^ @as(u8, @truncate((sz >> 8) & 0xff));
```

---

## Summary

**Round 1**: 3 issues found
- **Issue 1 (HIGH)**: Unsafe @enumFromInt on CipherSuite from untrusted data
- **Issue 2 (LOW)**: @truncate should be @intCast for masked Verb value
- **Issue 3 (LOW)**: Missing documentation for packet size truncation

## Next Steps

1. Fix all 3 issues
2. Run `zig build test`
3. Commit
4. Begin Round 2
