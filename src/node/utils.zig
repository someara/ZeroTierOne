/// Miscellaneous utility functions used throughout the ZeroTier core.
///
/// Converted from `node/Utils.hpp` and `node/Utils.cpp`. Many C++ utilities
/// have direct Zig standard library equivalents and are noted here so callers
/// know which stdlib function to use instead.
///
/// Stdlib equivalents (do NOT re-wrap these):
///   - `Utils::copy`          -> `@memcpy` / `std.mem.copyForwards`
///   - `Utils::zero`          -> `@memset(ptr, 0)`
///   - `Utils::burn`          -> `std.crypto.secureZero`
///   - `Utils::hton/ntoh`     -> `std.mem.nativeTo(.big)` / `std.mem.bigToNative`
///   - `Utils::loadBigEndian`  -> `std.mem.readInt(T, buf, .big)`
///   - `Utils::storeBigEndian` -> `std.mem.writeInt(T, buf, val, .big)`
///   - `Utils::loadLittleEndian`  -> `std.mem.readInt(T, buf, .little)`
///   - `Utils::storeLittleEndian` -> `std.mem.writeInt(T, buf, val, .little)`
///   - `Utils::swapBytes`     -> `@byteSwap`
///   - `Utils::countBits`     -> `@popCount`
///   - `Utils::getSecureRandom` -> `std.crypto.random.bytes`
///   - `Utils::strToUInt` etc -> `std.fmt.parseInt`
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// ── Constants ──────────────────────────────────────────────────────

/// 256 bits of zero, usable as a constant reference.
pub const ZERO256 = [4]u64{ 0, 0, 0, 0 };

/// Hexadecimal character lookup table (lowercase).
pub const HEXCHARS = "0123456789abcdef";

// ── Integer log2 ───────────────────────────────────────────────────

/// Compute the position of the most significant bit set in a 32-bit integer.
///
/// Returns 0 if `v` is 0. This matches the C++ Utils::log2 behavior.
pub fn log2(v: u32) u5 {
    if (v == 0) return 0;
    const leading_zeros: u6 = @clz(v);
    return @intCast(31 - @as(u6, leading_zeros));
}

// ── Constant-time comparison ───────────────────────────────────────

/// Perform a time-invariant binary comparison of two byte slices.
///
/// Both slices must be the same length. Returns true if all bytes are equal.
/// Timing does not depend on the position of the first difference.
pub fn secureEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        diff |= byte_a ^ byte_b;
    }
    return diff == 0;
}

// ── Check if memory is all-zero ────────────────────────────────────

/// Check if a memory region is entirely zero.
pub fn isZero(buf: []const u8) bool {
    for (buf) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

// ── Decimal formatting ─────────────────────────────────────────────

/// Convert an unsigned long to a decimal string in a caller-provided buffer.
///
/// Returns a slice into `buf` containing the decimal representation.
/// Buffer must be at least 24 bytes.
pub fn decimal(n: u64, buf: *[24]u8) []const u8 {
    if (n == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var val = n;
    var pos: usize = 24;
    while (val > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(val % 10));
        val /= 10;
    }
    return buf[pos..24];
}

// ── Hex encoding ───────────────────────────────────────────────────

/// Encode a u64 as a 16-character lowercase hex string.
pub fn hex64(val: u64, buf: *[16]u8) *const [16]u8 {
    inline for (0..16) |i| {
        buf[i] = HEXCHARS[@as(u4, @truncate(val >> @intCast(60 - i * 4)))];
    }
    return buf;
}

/// Encode a u64 as a 10-character lowercase hex string (lower 40 bits).
/// Used for ZeroTier address formatting.
pub fn hex10(val: u64, buf: *[10]u8) *const [10]u8 {
    inline for (0..10) |i| {
        buf[i] = HEXCHARS[@as(u4, @truncate(val >> @intCast(36 - i * 4)))];
    }
    return buf;
}

/// Encode a u32 as an 8-character lowercase hex string.
pub fn hex32(val: u32, buf: *[8]u8) *const [8]u8 {
    inline for (0..8) |i| {
        buf[i] = HEXCHARS[@as(u4, @truncate(val >> @intCast(28 - i * 4)))];
    }
    return buf;
}

/// Encode a u16 as a 4-character lowercase hex string.
pub fn hex16(val: u16, buf: *[4]u8) *const [4]u8 {
    inline for (0..4) |i| {
        buf[i] = HEXCHARS[@as(u4, @truncate(val >> @intCast(12 - i * 4)))];
    }
    return buf;
}

/// Encode a u8 as a 2-character lowercase hex string.
pub fn hex8(val: u8, buf: *[2]u8) *const [2]u8 {
    buf[0] = HEXCHARS[@as(u4, @truncate(val >> 4))];
    buf[1] = HEXCHARS[@as(u4, @truncate(val))];
    return buf;
}

/// Encode an arbitrary byte slice as a hex string into a caller-provided buffer.
///
/// `out` must be at least `src.len * 2` bytes. Returns the written portion.
pub fn hexSlice(src: []const u8, out: []u8) []const u8 {
    const needed = src.len * 2;
    std.debug.assert(out.len >= needed);
    for (src, 0..) |byte, i| {
        out[i * 2] = HEXCHARS[@as(u4, @truncate(byte >> 4))];
        out[i * 2 + 1] = HEXCHARS[@as(u4, @truncate(byte))];
    }
    return out[0..needed];
}

// ── Hex decoding ───────────────────────────────────────────────────

/// Decode a single hex character to its 4-bit value, or null if invalid.
fn hexCharVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

/// Decode a hex string into bytes.
///
/// Reads pairs of hex characters from `hex_str` and writes decoded bytes
/// into `out`. Stops at the end of `hex_str`, when `out` is full, or
/// when a non-hex character is encountered. Returns the number of bytes
/// written to `out`.
pub fn unhex(hex_str: []const u8, out: []u8) usize {
    var written: usize = 0;
    var i: usize = 0;
    while (written < out.len and i + 1 < hex_str.len) {
        const high = hexCharVal(hex_str[i]) orelse break;
        const low = hexCharVal(hex_str[i + 1]) orelse break;
        out[written] = (@as(u8, high) << 4) | @as(u8, low);
        written += 1;
        i += 2;
    }
    return written;
}

/// Decode a null-terminated hex C string into bytes.
///
/// Reads pairs of hex characters and writes decoded bytes into `out`.
/// Stops at the null terminator, when `out` is full, or when a non-hex
/// character is encountered. Returns the number of bytes written.
pub fn unhexZ(hex_str: [*:0]const u8, out: []u8) usize {
    var written: usize = 0;
    var i: usize = 0;
    while (written < out.len) {
        const c1 = hex_str[i];
        if (c1 == 0) break;
        const c2 = hex_str[i + 1];
        if (c2 == 0) break;

        const high = hexCharVal(c1) orelse break;
        const low = hexCharVal(c2) orelse break;
        out[written] = (@as(u8, high) << 4) | @as(u8, low);
        written += 1;
        i += 2;
    }
    return written;
}

// ── Float normalization ────────────────────────────────────────────

/// Normalize a value from one range to another.
///
/// Maps `value` from [big_min, big_max] to [target_min, target_max].
pub fn normalize(
    value: f32,
    big_min: f32,
    big_max: f32,
    target_min: f32,
    target_max: f32,
) f32 {
    const big_span = big_max - big_min;
    const small_span = target_max - target_min;
    const value_scaled = (value - big_min) / big_span;
    return target_min + value_scaled * small_span;
}

// ── Safe string copy ───────────────────────────────────────────────

/// Perform a safe C string copy, ALWAYS null-terminating the result.
///
/// Returns true on success, false on overflow (buffer will still be
/// null-terminated). If `src` is null (empty), `dest` receives a
/// zero-length string and true is returned.
pub fn scopy(dest: []u8, src: ?[*:0]const u8) bool {
    if (dest.len == 0) return false;
    const s = src orelse {
        dest[0] = 0;
        return true;
    };
    var i: usize = 0;
    while (i < dest.len - 1) {
        dest[i] = s[i];
        if (s[i] == 0) return true;
        i += 1;
    }
    dest[i] = 0;
    return false; // truncated
}

// ── MAC address cleaning ───────────────────────────────────────────

/// Remove '-' and ':' separators from a MAC address string in-place.
///
/// Returns the new length of the cleaned string.
pub fn cleanMac(mac: []u8) usize {
    var write_pos: usize = 0;
    for (mac) |c| {
        if (c != '-' and c != ':') {
            mac[write_pos] = c;
            write_pos += 1;
        }
    }
    return write_pos;
}

// ── Tests ──────────────────────────────────────────────────────────

test "ZERO256 is all zeros" {
    for (ZERO256) |val| {
        try testing.expectEqual(@as(u64, 0), val);
    }
}

test "log2 matches C++ Utils::log2" {
    try testing.expectEqual(@as(u5, 0), log2(0));
    try testing.expectEqual(@as(u5, 0), log2(1));
    try testing.expectEqual(@as(u5, 1), log2(2));
    try testing.expectEqual(@as(u5, 1), log2(3));
    try testing.expectEqual(@as(u5, 7), log2(0xff));
    try testing.expectEqual(@as(u5, 15), log2(0xffff));
    try testing.expectEqual(@as(u5, 31), log2(0xffffffff));
    try testing.expectEqual(@as(u5, 4), log2(16));
    try testing.expectEqual(@as(u5, 4), log2(31));
    try testing.expectEqual(@as(u5, 5), log2(32));
}

test "secureEq" {
    const a = "hello";
    const b = "hello";
    const c = "world";
    const d = "hell";

    try testing.expect(secureEq(a, b));
    try testing.expect(!secureEq(a, c));
    try testing.expect(!secureEq(a, d)); // different lengths
}

test "isZero" {
    const zeros = [_]u8{ 0, 0, 0, 0 };
    const nonzero = [_]u8{ 0, 0, 1, 0 };
    const empty: []const u8 = &[_]u8{};

    try testing.expect(isZero(&zeros));
    try testing.expect(!isZero(&nonzero));
    try testing.expect(isZero(empty));
}

test "decimal formatting" {
    var buf: [24]u8 = undefined;

    try testing.expectEqualSlices(u8, "0", decimal(0, &buf));
    try testing.expectEqualSlices(u8, "1", decimal(1, &buf));
    try testing.expectEqualSlices(u8, "42", decimal(42, &buf));
    try testing.expectEqualSlices(u8, "123456789", decimal(123456789, &buf));
    try testing.expectEqualSlices(u8, "18446744073709551615", decimal(std.math.maxInt(u64), &buf));
}

test "hex encoding" {
    var buf16: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, "0000000000000000", hex64(0, &buf16));
    try testing.expectEqualSlices(u8, "deadbeefcafebabe", hex64(0xdeadbeefcafebabe, &buf16));

    var buf10: [10]u8 = undefined;
    try testing.expectEqualSlices(u8, "0000000000", hex10(0, &buf10));
    try testing.expectEqualSlices(u8, "deadbeefca", hex10(0xdeadbeefca, &buf10));

    var buf8: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, "deadbeef", hex32(0xdeadbeef, &buf8));

    var buf4: [4]u8 = undefined;
    try testing.expectEqualSlices(u8, "1234", hex16(0x1234, &buf4));

    var buf2: [2]u8 = undefined;
    try testing.expectEqualSlices(u8, "ff", hex8(0xff, &buf2));
    try testing.expectEqualSlices(u8, "0a", hex8(0x0a, &buf2));
}

test "hexSlice" {
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var out: [8]u8 = undefined;
    const result = hexSlice(&input, &out);
    try testing.expectEqualSlices(u8, "deadbeef", result);
}

test "unhex basic" {
    var out: [4]u8 = undefined;
    const n = unhex("deadbeef", &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, &out);
}

test "unhex mixed case" {
    var out: [3]u8 = undefined;
    const n = unhex("AbCdEf", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xab, 0xcd, 0xef }, &out);
}

test "unhex truncates to buffer size" {
    var out: [2]u8 = undefined;
    const n = unhex("deadbeef", &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad }, &out);
}

test "unhex stops on invalid chars" {
    var out: [4]u8 = undefined;
    const n = unhex("abXXef", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u8, 0xab), out[0]);
}

test "unhexZ" {
    var out: [4]u8 = undefined;
    const n = unhexZ("DEADBEEF", &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, &out);
}

test "normalize" {
    // Map 50 from [0,100] to [0,1]
    try testing.expectApproxEqAbs(@as(f32, 0.5), normalize(50, 0, 100, 0, 1), 0.001);

    // Map 0 from [0,100] to [0,1]
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalize(0, 0, 100, 0, 1), 0.001);

    // Map 100 from [0,100] to [10,20]
    try testing.expectApproxEqAbs(@as(f32, 20.0), normalize(100, 0, 100, 10, 20), 0.001);
}

test "scopy" {
    var buf: [8]u8 = undefined;

    // Normal copy
    try testing.expect(scopy(&buf, "hello"));
    try testing.expectEqualSlices(u8, "hello", buf[0..5]);
    try testing.expectEqual(@as(u8, 0), buf[5]);

    // Null source
    try testing.expect(scopy(&buf, null));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    // Truncation
    try testing.expect(!scopy(&buf, "this is too long for buffer"));
    try testing.expectEqual(@as(u8, 0), buf[7]); // still null-terminated
}

test "cleanMac" {
    var mac = "AA:BB:CC:DD:EE:FF".*;
    const new_len = cleanMac(&mac);
    try testing.expectEqual(@as(usize, 12), new_len);
    try testing.expectEqualSlices(u8, "AABBCCDDEEFF", mac[0..12]);

    var mac2 = "AA-BB-CC-DD-EE-FF".*;
    const new_len2 = cleanMac(&mac2);
    try testing.expectEqual(@as(usize, 12), new_len2);
    try testing.expectEqualSlices(u8, "AABBCCDDEEFF", mac2[0..12]);
}

test "hex/unhex round-trip" {
    const original = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    var hex_buf: [16]u8 = undefined;
    _ = hexSlice(&original, &hex_buf);

    var decoded: [8]u8 = undefined;
    const n = unhex(&hex_buf, &decoded);
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqualSlices(u8, &original, &decoded);
}
