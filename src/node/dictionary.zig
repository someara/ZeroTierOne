/// A small packed key=value store with escape encoding.
///
/// Converted from `node/Dictionary.hpp`. Stores data as a compact blob
/// that is always a valid null-terminated C string. Binary values are
/// escaped so they can be embedded safely. Format: key=value pairs
/// separated by newlines (LF), with special characters escaped as
/// `\0`, `\r`, `\n`, `\e` (for `=`), and `\\`.
///
/// Keys are restricted: no binary data, no CR/LF, and no `=`. This is
/// not checked — callers must ensure key validity. Lookup is linear
/// search, intended for small key sets.
///
/// Used for network configurations and on-disk persistence in ZeroTier
/// One service code.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const utils = @import("utils.zig");
const Address = @import("address.zig").Address;

// ── Error type ────────────────────────────────────────────────────

pub const Error = error{
    /// The dictionary buffer is full; the entry was not added.
    Overflow,
};

// ── Dictionary ────────────────────────────────────────────────────

/// A comptime-sized packed key=value store.
///
/// `C` is the total buffer capacity in bytes (including the
/// null terminator). The buffer is always null-terminated.
pub fn Dictionary(comptime C: u32) type {
    if (C < 2) @compileError("Dictionary capacity must be >= 2");

    return struct {
        const Self = @This();

        /// OWNED — internal storage, always null-terminated.
        _d: [C]u8,

        // ── Constructors ──────────────────────────────────────

        /// Create an empty dictionary (zero-filled).
        pub fn init() Self {
            return .{ ._d = [_]u8{0} ** C };
        }

        /// Create a dictionary from a string slice.
        ///
        /// If `src` is longer than capacity, it is truncated and the
        /// last byte is forced to null. Returns the dictionary.
        pub fn fromSlice(src: []const u8) Self {
            var d = Self.init();
            const copy_len = @min(src.len, C - 1);
            @memcpy(d._d[0..copy_len], src[0..copy_len]);
            d._d[copy_len] = 0;
            // Ensure absolute null-termination at end
            d._d[C - 1] = 0;
            return d;
        }

        /// Create a dictionary from a null-terminated C string.
        pub fn fromCstr(s: [*:0]const u8) Self {
            var d = Self.init();
            var i: u32 = 0;
            while (i < C - 1) : (i += 1) {
                if (s[i] == 0) break;
                d._d[i] = s[i];
            }
            // Everything from i onward is already 0 from init()
            return d;
        }

        // ── Query ─────────────────────────────────────────────

        /// Return true if the dictionary is non-empty.
        pub fn isSet(self: *const Self) bool {
            return self._d[0] != 0;
        }

        /// Size of dictionary content in bytes (not including the
        /// terminating null).
        pub fn sizeBytes(self: *const Self) u32 {
            for (self._d, 0..) |byte, i| {
                if (byte == 0) return @intCast(i);
            }
            return C - 1;
        }

        /// Return a pointer to the raw internal buffer (null-terminated).
        pub fn data(self: *const Self) [*:0]const u8 {
            // Safety: _d[C-1] is always 0 by construction; find
            // the actual sentinel position for the pointer cast.
            return @ptrCast(&self._d);
        }

        /// Return the raw buffer as a slice (up to the first null).
        pub fn slice(self: *const Self) []const u8 {
            const len = self.sizeBytes();
            return self._d[0..len];
        }

        /// Return the full buffer capacity.
        pub fn capacity() u32 {
            return C;
        }

        /// Check if a key is present.
        pub fn contains(self: *const Self, key: []const u8) bool {
            var dest_buf: [2]u8 = undefined;
            return self.getRaw(key, &dest_buf) != null;
        }

        /// Delete all entries.
        pub fn clear(self: *Self) void {
            @memset(&self._d, 0);
        }

        // ── Get operations ────────────────────────────────────

        /// Look up a key and decode its value into `dest`.
        ///
        /// Returns a slice of `dest` containing the decoded value,
        /// or `null` if the key was not found.
        ///
        /// The returned slice is BORROWED from `dest`. The byte
        /// following the returned content in `dest` is set to 0
        /// (null-terminated), matching C++ behavior.
        pub fn getRaw(
            self: *const Self,
            key: []const u8,
            dest: []u8,
        ) ?[]const u8 {
            if (dest.len == 0) return null;

            const buf = &self._d;
            var pos: u32 = 0;

            while (pos < C and buf[pos] != 0) {
                // Try to match the key at current position
                const match = self.matchKey(key, pos);
                if (match) |value_start| {
                    // Decode the value with escape processing
                    return self.decodeValue(value_start, dest);
                }

                // Key didn't match — skip to next line
                pos = self.skipToNextLine(pos);
            }

            dest[0] = 0;
            return null;
        }

        /// Get a string value for the given key.
        ///
        /// Returns a slice of `dest` containing the decoded value,
        /// or `null` if not found.
        pub fn get(self: *const Self, key: []const u8, dest: []u8) ?[]const u8 {
            return self.getRaw(key, dest);
        }

        /// Get a boolean value.
        ///
        /// Returns `true` if the value starts with '1', 't', or 'T'.
        /// Returns `dfl` if the key is not found.
        pub fn getBool(self: *const Self, key: []const u8, dfl: bool) bool {
            var tmp: [4]u8 = undefined;
            const val = self.getRaw(key, &tmp) orelse return dfl;
            if (val.len == 0) return dfl;
            return val[0] == '1' or val[0] == 't' or val[0] == 'T';
        }

        /// Get an unsigned 64-bit integer stored as hex.
        ///
        /// Returns `dfl` if the key is not found or the value is empty.
        pub fn getUI(self: *const Self, key: []const u8, dfl: u64) u64 {
            var tmp: [128]u8 = undefined;
            const val = self.getRaw(key, &tmp) orelse return dfl;
            if (val.len == 0) return dfl;
            return hexStrToU64(val);
        }

        /// Get a signed 64-bit integer stored as hex (with optional
        /// leading '-').
        ///
        /// Returns `dfl` if the key is not found or the value is empty.
        pub fn getI(self: *const Self, key: []const u8, dfl: i64) i64 {
            var tmp: [128]u8 = undefined;
            const val = self.getRaw(key, &tmp) orelse return dfl;
            if (val.len == 0) return dfl;
            return hexStrTo64(val);
        }

        // ── Add operations ────────────────────────────────────

        /// Add a key=value pair with binary-safe escape encoding.
        ///
        /// If the key already exists, another entry is appended
        /// (the first will still be returned by `get`). Returns
        /// `error.Overflow` if there is not enough room.
        pub fn add(self: *Self, key: []const u8, value: []const u8) Error!void {
            const start = self.sizeBytes();
            var j: u32 = start;

            // Newline separator if this isn't the first entry
            if (j > 0) {
                if (j >= C - 1) return error.Overflow;
                self._d[j] = '\n';
                j += 1;
            }

            // Write key
            for (key) |c| {
                if (j >= C - 1) {
                    self.rollback(start);
                    return error.Overflow;
                }
                self._d[j] = c;
                j += 1;
            }

            // Write '='
            if (j >= C - 1) {
                self.rollback(start);
                return error.Overflow;
            }
            self._d[j] = '=';
            j += 1;

            // Write escaped value
            for (value) |c| {
                switch (c) {
                    0 => {
                        if (j + 1 >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = '\\';
                        self._d[j + 1] = '0';
                        j += 2;
                    },
                    '\r' => {
                        if (j + 1 >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = '\\';
                        self._d[j + 1] = 'r';
                        j += 2;
                    },
                    '\n' => {
                        if (j + 1 >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = '\\';
                        self._d[j + 1] = 'n';
                        j += 2;
                    },
                    '\\' => {
                        if (j + 1 >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = '\\';
                        self._d[j + 1] = '\\';
                        j += 2;
                    },
                    '=' => {
                        if (j + 1 >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = '\\';
                        self._d[j + 1] = 'e';
                        j += 2;
                    },
                    else => {
                        if (j >= C - 1) {
                            self.rollback(start);
                            return error.Overflow;
                        }
                        self._d[j] = c;
                        j += 1;
                    },
                }
            }

            self._d[j] = 0;
        }

        /// Add a string value (convenience wrapper).
        pub fn addStr(self: *Self, key: []const u8, value: []const u8) Error!void {
            return self.add(key, value);
        }

        /// Add a boolean value as "1" or "0".
        pub fn addBool(self: *Self, key: []const u8, value: bool) Error!void {
            const s: []const u8 = if (value) "1" else "0";
            return self.add(key, s);
        }

        /// Add an unsigned 64-bit integer as a hex string.
        pub fn addU64(self: *Self, key: []const u8, value: u64) Error!void {
            var hex_buf: [16]u8 = undefined;
            const hex_str = utils.hex64(value, &hex_buf);
            return self.add(key, hex_str);
        }

        /// Add a signed 64-bit integer as a hex string (with leading '-'
        /// for negative values).
        pub fn addI64(self: *Self, key: []const u8, value: i64) Error!void {
            if (value >= 0) {
                return self.addU64(key, @intCast(value));
            }
            // Negative: prepend '-' then hex of absolute value
            var hex_buf: [17]u8 = undefined;
            hex_buf[0] = '-';
            const abs_val: u64 = @intCast(-value);
            _ = utils.hex64(abs_val, hex_buf[1..17]);
            return self.add(key, hex_buf[0..17]);
        }

        /// Add an Address as a hex string (16-char padded hex of the
        /// 40-bit address value).
        pub fn addAddress(self: *Self, key: []const u8, addr: Address) Error!void {
            return self.addU64(key, addr.toInt());
        }

        // ── Private helpers ───────────────────────────────────

        /// Try to match `key` at position `pos` in the buffer.
        ///
        /// Returns the buffer position immediately after the '=' if
        /// the key matches, or `null` if it doesn't.
        fn matchKey(self: *const Self, key: []const u8, start: u32) ?u32 {
            const buf = &self._d;
            var pos = start;
            var ki: usize = 0;

            // Match each character of the key
            while (ki < key.len) {
                if (pos >= C or buf[pos] == 0) return null;
                if (buf[pos] != key[ki]) return null;
                pos += 1;
                ki += 1;
            }

            // After key, must find '='
            if (pos >= C or buf[pos] != '=') return null;
            return pos + 1;
        }

        /// Decode an escaped value starting at `start` into `dest`.
        ///
        /// Returns a slice of `dest` with the decoded content, or
        /// `null` if the buffer is corrupt (hit EOF unexpectedly).
        /// The byte after the returned content is set to 0.
        fn decodeValue(self: *const Self, start: u32, dest: []u8) ?[]const u8 {
            const buf = &self._d;
            var pos = start;
            var j: usize = 0;
            var esc = false;

            while (pos < C and buf[pos] != 0 and buf[pos] != '\r' and buf[pos] != '\n') {
                if (esc) {
                    esc = false;
                    const decoded: u8 = switch (buf[pos]) {
                        'r' => '\r',
                        'n' => '\n',
                        '0' => 0,
                        'e' => '=',
                        else => buf[pos],
                    };
                    if (j >= dest.len) {
                        // Dest full — null-terminate at last position
                        dest[dest.len - 1] = 0;
                        return dest[0 .. dest.len - 1];
                    }
                    dest[j] = decoded;
                    j += 1;
                } else if (buf[pos] == '\\') {
                    esc = true;
                } else {
                    if (j >= dest.len) {
                        dest[dest.len - 1] = 0;
                        return dest[0 .. dest.len - 1];
                    }
                    dest[j] = buf[pos];
                    j += 1;
                }
                pos += 1;
            }

            // Null-terminate the output
            if (j < dest.len) {
                dest[j] = 0;
            }
            return dest[0..j];
        }

        /// Skip from the current position to the start of the next line.
        ///
        /// Returns the position of the first character of the next line,
        /// or a position where `buf[pos] == 0` (end of content).
        fn skipToNextLine(self: *const Self, start: u32) u32 {
            const buf = &self._d;
            var pos = start;

            // Skip to end of current line
            while (pos < C and buf[pos] != 0 and buf[pos] != '\r' and buf[pos] != '\n') {
                pos += 1;
            }

            // Skip the line terminator
            if (pos < C and (buf[pos] == '\r' or buf[pos] == '\n')) {
                pos += 1;
            }

            return pos;
        }

        /// Roll back a failed add by null-terminating at the original
        /// content end position.
        fn rollback(self: *Self, original_end: u32) void {
            self._d[original_end] = 0;
        }
    };
}

// ── Hex parsing helpers (package-level) ───────────────────────────

/// Parse a hex string (slice) to u64, matching C++ `strtoull(s, NULL, 16)`.
///
/// Skips leading whitespace, handles optional "0x"/"0X" prefix, stops
/// at first non-hex character. Returns 0 for empty/invalid input.
fn hexStrToU64(s: []const u8) u64 {
    var i: usize = 0;

    // Skip leading whitespace
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    if (i >= s.len) return 0;

    // Optional 0x prefix
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        i += 2;
    }

    var result: u64 = 0;
    while (i < s.len) : (i += 1) {
        const nybble = hexCharVal(s[i]) orelse break;
        result = (result << 4) | @as(u64, nybble);
    }
    return result;
}

/// Parse a hex string (slice) to i64, matching C++ `strtoll(s, NULL, 16)`.
///
/// Handles optional leading '-' sign. Returns 0 for empty/invalid input.
fn hexStrTo64(s: []const u8) i64 {
    var i: usize = 0;

    // Skip leading whitespace
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    if (i >= s.len) return 0;

    var negative = false;
    if (s[i] == '-') {
        negative = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }

    const unsigned_val = hexStrToU64(s[i..]);
    if (negative) {
        // Use wrapping negate to handle edge cases like i64 min
        return -%@as(i64, @bitCast(unsigned_val));
    }
    return @bitCast(unsigned_val);
}

/// Decode a single hex character to its 4-bit value, or null if invalid.
fn hexCharVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────

test "Dictionary: init creates empty dictionary" {
    const Dict = Dictionary(256);
    const d = Dict.init();
    try testing.expect(!d.isSet());
    try testing.expectEqual(@as(u32, 0), d.sizeBytes());
    try testing.expectEqual(@as(u32, 256), Dict.capacity());
}

test "Dictionary: add and get simple string" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("hello", "world");
    try testing.expect(d.isSet());

    var buf: [64]u8 = undefined;
    const val = d.get("hello", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("world", val.?);
}

test "Dictionary: multiple entries" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("key1", "value1");
    try d.add("key2", "value2");
    try d.add("key3", "value3");

    var buf: [64]u8 = undefined;

    const v1 = d.get("key1", &buf);
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?);

    const v2 = d.get("key2", &buf);
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?);

    const v3 = d.get("key3", &buf);
    try testing.expect(v3 != null);
    try testing.expectEqualStrings("value3", v3.?);
}

test "Dictionary: missing key returns null" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("exists", "yes");

    var buf: [64]u8 = undefined;
    const val = d.get("missing", &buf);
    try testing.expect(val == null);
}

test "Dictionary: escape encoding round-trip" {
    const Dict = Dictionary(512);
    var d = Dict.init();

    // Value containing all special characters: NUL, CR, LF, =, backslash
    const special = [_]u8{ 'a', 0, '\r', '\n', '=', '\\', 'z' };
    try d.add("special", &special);

    var buf: [64]u8 = undefined;
    const val = d.get("special", &buf);
    try testing.expect(val != null);
    try testing.expectEqual(@as(usize, 7), val.?.len);
    try testing.expectEqual(@as(u8, 'a'), val.?[0]);
    try testing.expectEqual(@as(u8, 0), val.?[1]);
    try testing.expectEqual(@as(u8, '\r'), val.?[2]);
    try testing.expectEqual(@as(u8, '\n'), val.?[3]);
    try testing.expectEqual(@as(u8, '='), val.?[4]);
    try testing.expectEqual(@as(u8, '\\'), val.?[5]);
    try testing.expectEqual(@as(u8, 'z'), val.?[6]);
}

test "Dictionary: bool values" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.addBool("flag_true", true);
    try d.addBool("flag_false", false);

    try testing.expect(d.getBool("flag_true", false));
    try testing.expect(!d.getBool("flag_false", true));
    try testing.expect(d.getBool("missing", true)); // default
    try testing.expect(!d.getBool("missing", false)); // default
}

test "Dictionary: u64 hex values" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.addU64("num", 0xdeadbeef);

    const val = d.getUI("num", 0);
    try testing.expectEqual(@as(u64, 0xdeadbeef), val);

    // Default when missing
    try testing.expectEqual(@as(u64, 42), d.getUI("missing", 42));
}

test "Dictionary: i64 hex values" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.addI64("positive", 12345);
    try d.addI64("negative", -12345);

    try testing.expectEqual(@as(i64, 12345), d.getI("positive", 0));
    try testing.expectEqual(@as(i64, -12345), d.getI("negative", 0));
    try testing.expectEqual(@as(i64, 99), d.getI("missing", 99));
}

test "Dictionary: address values" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    const addr = Address.init(0x1234567890);
    try d.addAddress("addr", addr);

    const val = d.getUI("addr", 0);
    try testing.expectEqual(@as(u64, 0x1234567890), val);
}

test "Dictionary: contains" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("present", "value");

    try testing.expect(d.contains("present"));
    try testing.expect(!d.contains("absent"));
}

test "Dictionary: clear" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("key", "value");
    try testing.expect(d.isSet());

    d.clear();
    try testing.expect(!d.isSet());
    try testing.expectEqual(@as(u32, 0), d.sizeBytes());
}

test "Dictionary: fromSlice" {
    const Dict = Dictionary(256);
    const raw = "key1=value1\nkey2=value2";
    const d = Dict.fromSlice(raw);

    var buf: [64]u8 = undefined;
    const v1 = d.get("key1", &buf);
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?);

    const v2 = d.get("key2", &buf);
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?);
}

test "Dictionary: fromCstr" {
    const Dict = Dictionary(256);
    const d = Dict.fromCstr("hello=world");

    var buf: [64]u8 = undefined;
    const val = d.get("hello", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("world", val.?);
}

test "Dictionary: overflow returns error" {
    // Very small dictionary — 16 bytes total
    const Dict = Dictionary(16);
    var d = Dict.init();

    // First short entry should fit
    try d.add("k", "v");

    // A long value that exceeds capacity should fail
    const result = d.add("big", "this_is_way_too_long_for_the_buffer");
    try testing.expectError(error.Overflow, result);

    // Original entry should still be intact after rollback
    var buf: [64]u8 = undefined;
    const val = d.get("k", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("v", val.?);
}

test "Dictionary: data returns null-terminated pointer" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("key", "val");

    const ptr = d.data();
    // Should be null-terminated C string
    const len = mem.len(ptr);
    try testing.expect(len > 0);
    try testing.expect(len < 256);
}

test "Dictionary: slice returns content" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("a", "b");

    const s = d.slice();
    try testing.expectEqualStrings("a=b", s);
}

test "Dictionary: empty value" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("empty", "");

    var buf: [64]u8 = undefined;
    const val = d.get("empty", &buf);
    try testing.expect(val != null);
    try testing.expectEqual(@as(usize, 0), val.?.len);
}

test "Dictionary: key prefix doesn't false-match" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("abc", "correct");
    try d.add("ab", "wrong");

    var buf: [64]u8 = undefined;
    const val = d.get("abc", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("correct", val.?);

    const val2 = d.get("ab", &buf);
    try testing.expect(val2 != null);
    try testing.expectEqualStrings("wrong", val2.?);
}

test "Dictionary: duplicate keys return first" {
    const Dict = Dictionary(256);
    var d = Dict.init();
    try d.add("dup", "first");
    try d.add("dup", "second");

    var buf: [64]u8 = undefined;
    const val = d.get("dup", &buf);
    try testing.expect(val != null);
    try testing.expectEqualStrings("first", val.?);
}

test "hexStrToU64 basic" {
    try testing.expectEqual(@as(u64, 0xdeadbeef), hexStrToU64("deadbeef"));
    try testing.expectEqual(@as(u64, 0xDEADBEEF), hexStrToU64("DEADBEEF"));
    try testing.expectEqual(@as(u64, 0), hexStrToU64(""));
    try testing.expectEqual(@as(u64, 0xff), hexStrToU64("ff"));
    try testing.expectEqual(@as(u64, 0xff), hexStrToU64("0xff"));
    try testing.expectEqual(@as(u64, 0xff), hexStrToU64("0XFF"));
}

test "hexStrTo64 basic" {
    try testing.expectEqual(@as(i64, 0xff), hexStrTo64("ff"));
    try testing.expectEqual(@as(i64, -0xff), hexStrTo64("-ff"));
    try testing.expectEqual(@as(i64, 0), hexStrTo64(""));
}

test "hexStrToU64 with leading zeros" {
    // C++ Utils::hex(uint64_t) produces 16-char padded hex
    try testing.expectEqual(@as(u64, 0x00000000deadbeef), hexStrToU64("00000000deadbeef"));
    try testing.expectEqual(@as(u64, 0x0000001234567890), hexStrToU64("0000001234567890"));
}
