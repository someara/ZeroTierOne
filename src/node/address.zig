/// A ZeroTier network address — a 40-bit (5-byte) unique node identifier.
///
/// Converted from `node/Address.hpp`. Addresses are stored internally as
/// the lower 40 bits of a `u64`. The all-zero address and any address
/// with a first byte of 0xff are reserved.
///
/// No heap allocation is performed. This is a value type.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const constants = @import("constants.zig");
const Buffer = @import("buffer.zig").Buffer;
const utils = @import("utils.zig");

// ── Constants ──────────────────────────────────────────────────────

/// Length of an address in bytes (5).
pub const ADDRESS_LENGTH: u32 = 5;

/// Length of an address as a hex string (10 characters).
pub const ADDRESS_LENGTH_HEX: u32 = 10;

/// Reserved prefix byte — addresses starting with 0xff are reserved.
pub const RESERVED_PREFIX: u8 = 0xff;

/// Bit mask for the 40-bit address space.
const MASK_40: u64 = 0xff_ffff_ffff;

// ── Address ────────────────────────────────────────────────────────

pub const Address = struct {
    _a: u64,

    /// Create an address from a raw `u64`. Only the lower 40 bits are used.
    pub fn init(a: u64) Address {
        return .{ ._a = a & MASK_40 };
    }

    /// Zero (null) address.
    pub fn zero() Address {
        return .{ ._a = 0 };
    }

    /// Parse an address from a 5-byte big-endian buffer.
    pub fn fromBytes(bytes: *const [ADDRESS_LENGTH]u8) Address {
        var a: u64 = 0;
        a |= @as(u64, bytes[0]) << 32;
        a |= @as(u64, bytes[1]) << 24;
        a |= @as(u64, bytes[2]) << 16;
        a |= @as(u64, bytes[3]) << 8;
        a |= @as(u64, bytes[4]);
        return .{ ._a = a };
    }

    /// Parse an address from an arbitrary-length slice.
    /// Returns a zero address if `bytes.len < ADDRESS_LENGTH`.
    pub fn fromSlice(bytes: []const u8) Address {
        if (bytes.len < ADDRESS_LENGTH) return Address.zero();
        return fromBytes(bytes[0..ADDRESS_LENGTH]);
    }

    /// Serialize address to a 5-byte big-endian buffer.
    pub fn toBytes(self: Address, out: *[ADDRESS_LENGTH]u8) void {
        out[0] = @truncate(self._a >> 32);
        out[1] = @truncate(self._a >> 24);
        out[2] = @truncate(self._a >> 16);
        out[3] = @truncate(self._a >> 8);
        out[4] = @truncate(self._a);
    }

    /// Append address in big-endian byte order to a Buffer.
    pub fn appendTo(self: Address, comptime C: u32, buf: *Buffer(C)) Buffer(C).Error!void {
        const p = try buf.appendField(ADDRESS_LENGTH);
        p[0] = @truncate(self._a >> 32);
        p[1] = @truncate(self._a >> 24);
        p[2] = @truncate(self._a >> 16);
        p[3] = @truncate(self._a >> 8);
        p[4] = @truncate(self._a);
    }

    /// Return the address as a `u64` (lower 40 bits only).
    pub fn toInt(self: Address) u64 {
        return self._a;
    }

    /// Return a 10-character lowercase hex string representation.
    pub fn toString(self: Address, buf: *[10]u8) *const [10]u8 {
        return utils.hex10(self._a, buf);
    }

    /// Return true if this address is non-zero.
    pub fn isSet(self: Address) bool {
        return self._a != 0;
    }

    /// Check if this address is reserved.
    ///
    /// The all-zero null address and any address beginning with 0xff are
    /// reserved. (0xff is reserved for future use to designate possibly
    /// longer addresses, addresses based on IPv6 innards, etc.)
    pub fn isReserved(self: Address) bool {
        return self._a == 0 or @as(u8, @truncate(self._a >> 32)) == RESERVED_PREFIX;
    }

    /// Return a single byte at position `i` (0..4), interpreting the
    /// address in big-endian byte order.
    pub fn getByte(self: Address, i: u3) u8 {
        return @truncate(self._a >> (32 - @as(u6, i) * 8));
    }

    /// Hash code for use with Hashtable.
    pub fn hashCode(self: Address) u64 {
        return self._a;
    }

    /// Extract the network controller address from a 64-bit network ID.
    ///
    /// The controller address is the upper 40 bits of the network ID
    /// (i.e., `nwid >> 24`).
    pub fn controllerFor(nwid: u64) Address {
        return Address.init(nwid >> 24);
    }

    // ── Comparison / ordering ──────────────────────────────────────

    pub fn eql(self: Address, other: Address) bool {
        return self._a == other._a;
    }

    pub fn eqlInt(self: Address, a: u64) bool {
        return self._a == (a & MASK_40);
    }

    pub fn order(self: Address, other: Address) std.math.Order {
        return std.math.order(self._a, other._a);
    }

    pub fn lessThan(_: void, a: Address, b: Address) bool {
        return a._a < b._a;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "Address: zero and init" {
    const z = Address.zero();
    try testing.expect(!z.isSet());
    try testing.expect(z.isReserved());
    try testing.expectEqual(@as(u64, 0), z.toInt());

    const a = Address.init(0x1234567890);
    try testing.expectEqual(@as(u64, 0x1234567890), a.toInt());
    try testing.expect(a.isSet());
    try testing.expect(!a.isReserved());
}

test "Address: 40-bit masking" {
    // Upper bits beyond 40 should be masked off.
    const a = Address.init(0xABCD_1234567890);
    try testing.expectEqual(@as(u64, 0x1234567890), a.toInt());
}

test "Address: bytes round-trip" {
    const original = Address.init(0xABCDEF0123);
    var buf: [5]u8 = undefined;
    original.toBytes(&buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD, 0xEF, 0x01, 0x23 }, &buf);

    const restored = Address.fromBytes(&buf);
    try testing.expect(original.eql(restored));
}

test "Address: fromSlice short" {
    const short = Address.fromSlice(&[_]u8{ 0x01, 0x02 });
    try testing.expect(!short.isSet());
}

test "Address: appendTo buffer" {
    const a = Address.init(0xABCDEF0123);
    var buf = Buffer(128){};
    try a.appendTo(128, &buf);
    try testing.expectEqual(@as(u32, 5), buf.size());
    const data = (try buf.field(0, 5));
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xCD, 0xEF, 0x01, 0x23 }, data);
}

test "Address: toString" {
    const a = Address.init(0x0102030405);
    var buf: [10]u8 = undefined;
    const s = a.toString(&buf);
    try testing.expectEqualStrings("0102030405", s);
}

test "Address: isReserved" {
    // Zero is reserved
    try testing.expect(Address.zero().isReserved());

    // Address starting with 0xff is reserved
    try testing.expect(Address.init(0xFF00000001).isReserved());

    // Normal address is not reserved
    try testing.expect(!Address.init(0x0102030405).isReserved());
}

test "Address: getByte" {
    const a = Address.init(0xABCDEF0123);
    try testing.expectEqual(@as(u8, 0xAB), a.getByte(0));
    try testing.expectEqual(@as(u8, 0xCD), a.getByte(1));
    try testing.expectEqual(@as(u8, 0xEF), a.getByte(2));
    try testing.expectEqual(@as(u8, 0x01), a.getByte(3));
    try testing.expectEqual(@as(u8, 0x23), a.getByte(4));
}

test "Address: comparison" {
    const a = Address.init(0x0000000001);
    const b = Address.init(0x0000000002);
    const c = Address.init(0x0000000001);

    try testing.expect(a.eql(c));
    try testing.expect(!a.eql(b));
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
    try testing.expectEqual(std.math.Order.eq, a.order(c));
}

test "Address: eqlInt masks upper bits" {
    const a = Address.init(0x1234567890);
    try testing.expect(a.eqlInt(0xFFFF_1234567890));
    try testing.expect(!a.eqlInt(0x1234567891));
}

test "Address: controllerFor" {
    // Network ID 0x0102030405_060708 -> controller is upper 40 bits = nwid >> 24
    const nwid: u64 = 0x0102030405_060708;
    const controller = Address.controllerFor(nwid);
    try testing.expectEqual(@as(u64, nwid >> 24), controller.toInt());

    // For typical ZT network IDs the controller address is the first 10 hex chars
    const nwid2: u64 = 0x8056c2e21c_000001;
    const ctrl2 = Address.controllerFor(nwid2);
    try testing.expectEqual(@as(u64, 0x8056c2e21c), ctrl2.toInt());
}
