/// A 48-bit IEEE 802 Ethernet MAC address.
///
/// Converted from `node/MAC.hpp`. MAC addresses are stored internally as
/// the lower 48 bits of a `u64`. Provides methods for ZeroTier-specific
/// MAC derivation from network IDs and ZeroTier addresses.
///
/// No heap allocation is performed. This is a value type.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const utils = @import("utils.zig");

// ── Constants ──────────────────────────────────────────────────────

/// Bit mask for the 48-bit MAC address space.
const MASK_48: u64 = 0xffff_ffffffff;

/// Number of bytes in a MAC address.
pub const MAC_LENGTH: u32 = 6;

// ── MAC ────────────────────────────────────────────────────────────

pub const MAC = struct {
    _m: u64,

    /// Create a MAC from a raw `u64`. Only the lower 48 bits are used.
    pub fn init(m: u64) MAC {
        return .{ ._m = m & MASK_48 };
    }

    /// Zero (null) MAC.
    pub fn zero() MAC {
        return .{ ._m = 0 };
    }

    /// Construct a MAC from six individual octets.
    pub fn fromOctets(a: u8, b: u8, c: u8, d: u8, e: u8, f: u8) MAC {
        return .{
            ._m = (@as(u64, a) << 40) |
                (@as(u64, b) << 32) |
                (@as(u64, c) << 24) |
                (@as(u64, d) << 16) |
                (@as(u64, e) << 8) |
                @as(u64, f),
        };
    }

    /// Parse a MAC from a 6-byte big-endian buffer.
    pub fn fromBytes(bytes: *const [MAC_LENGTH]u8) MAC {
        var m: u64 = 0;
        m |= @as(u64, bytes[0]) << 40;
        m |= @as(u64, bytes[1]) << 32;
        m |= @as(u64, bytes[2]) << 24;
        m |= @as(u64, bytes[3]) << 16;
        m |= @as(u64, bytes[4]) << 8;
        m |= @as(u64, bytes[5]);
        return .{ ._m = m };
    }

    /// Parse a MAC from an arbitrary-length slice.
    /// Returns a zero MAC if `bytes.len < 6`.
    pub fn fromSlice(bytes: []const u8) MAC {
        if (bytes.len < MAC_LENGTH) return MAC.zero();
        return fromBytes(bytes[0..MAC_LENGTH]);
    }

    /// Serialize MAC to a 6-byte big-endian buffer.
    pub fn copyTo(self: MAC, out: *[MAC_LENGTH]u8) void {
        out[0] = @truncate(self._m >> 40);
        out[1] = @truncate(self._m >> 32);
        out[2] = @truncate(self._m >> 24);
        out[3] = @truncate(self._m >> 16);
        out[4] = @truncate(self._m >> 8);
        out[5] = @truncate(self._m);
    }

    /// Append MAC in big-endian byte order to a Buffer.
    pub fn appendTo(self: MAC, comptime C: u32, buf: *Buffer(C)) Buffer(C).Error!void {
        const p = try buf.appendField(MAC_LENGTH);
        p[0] = @truncate(self._m >> 40);
        p[1] = @truncate(self._m >> 32);
        p[2] = @truncate(self._m >> 24);
        p[3] = @truncate(self._m >> 16);
        p[4] = @truncate(self._m >> 8);
        p[5] = @truncate(self._m);
    }

    /// Return the MAC as a `u64` (lower 48 bits only).
    pub fn toInt(self: MAC) u64 {
        return self._m;
    }

    /// Return true if this MAC is non-zero.
    pub fn isSet(self: MAC) bool {
        return self._m != 0;
    }

    /// Return true if this is the broadcast MAC (ff:ff:ff:ff:ff:ff).
    pub fn isBroadcast(self: MAC) bool {
        return self._m == 0xffffffffffff;
    }

    /// Return true if this is a multicast MAC (bit 0 of first octet set).
    pub fn isMulticast(self: MAC) bool {
        return (self._m & 0x010000000000) != 0;
    }

    /// Return true if this is a locally-administered MAC (bit 1 of first octet set).
    pub fn isLocallyAdministered(self: MAC) bool {
        return (self._m & 0x020000000000) != 0;
    }

    /// Derive a MAC from a ZeroTier address and network ID.
    ///
    /// The first octet is derived from the network ID (locally administered,
    /// not multicast). The remaining 5 bytes are the ZT address XORed with
    /// bytes 1-5 of the network ID.
    pub fn fromAddress(ztaddr: Address, nwid: u64) MAC {
        var m: u64 = @as(u64, firstOctetForNetwork(nwid)) << 40;
        m |= ztaddr.toInt(); // 40 bits
        m ^= ((nwid >> 8) & 0xff) << 32;
        m ^= ((nwid >> 16) & 0xff) << 24;
        m ^= ((nwid >> 24) & 0xff) << 16;
        m ^= ((nwid >> 32) & 0xff) << 8;
        m ^= (nwid >> 40) & 0xff;
        return .{ ._m = m };
    }

    /// Recover the ZeroTier address from this MAC and a network ID.
    ///
    /// This reverses `fromAddress` by XORing the network ID bytes back out.
    /// Only valid for unicast MACs derived from ZeroTier addresses.
    pub fn toAddress(self: MAC, nwid: u64) Address {
        var a: u64 = self._m & 0xffffffffff; // least significant 40 bits
        a ^= ((nwid >> 8) & 0xff) << 32;
        a ^= ((nwid >> 16) & 0xff) << 24;
        a ^= ((nwid >> 24) & 0xff) << 16;
        a ^= ((nwid >> 32) & 0xff) << 8;
        a ^= (nwid >> 40) & 0xff;
        return Address.init(a);
    }

    /// Compute the first octet of a ZeroTier-derived MAC for a given network ID.
    ///
    /// The result is locally administered (bit 1 set), not multicast (bit 0 clear),
    /// derived from the LSB of the network ID. The value 0x52 is blacklisted
    /// because it is used by KVM/libvirt.
    pub fn firstOctetForNetwork(nwid: u64) u8 {
        const a: u8 = (@as(u8, @truncate(nwid)) & 0xfe) | 0x02;
        return if (a == 0x52) 0x32 else a;
    }

    /// Return a single byte at position `i` (0..5), interpreting the
    /// MAC in big-endian byte order.
    pub fn getByte(self: MAC, i: u3) u8 {
        std.debug.assert(i <= 5);
        return @truncate(self._m >> (40 - @as(u6, i) * 8));
    }

    /// Hash code for use with Hashtable.
    pub fn hashCode(self: MAC) u64 {
        return self._m;
    }

    /// Format as a colon-separated hex string: "aa:bb:cc:dd:ee:ff".
    pub fn toString(self: MAC, buf: *[18]u8) *const [17]u8 {
        const H = utils.HEXCHARS;
        buf[0] = H[@as(u4, @truncate(self._m >> 44))];
        buf[1] = H[@as(u4, @truncate(self._m >> 40))];
        buf[2] = ':';
        buf[3] = H[@as(u4, @truncate(self._m >> 36))];
        buf[4] = H[@as(u4, @truncate(self._m >> 32))];
        buf[5] = ':';
        buf[6] = H[@as(u4, @truncate(self._m >> 28))];
        buf[7] = H[@as(u4, @truncate(self._m >> 24))];
        buf[8] = ':';
        buf[9] = H[@as(u4, @truncate(self._m >> 20))];
        buf[10] = H[@as(u4, @truncate(self._m >> 16))];
        buf[11] = ':';
        buf[12] = H[@as(u4, @truncate(self._m >> 12))];
        buf[13] = H[@as(u4, @truncate(self._m >> 8))];
        buf[14] = ':';
        buf[15] = H[@as(u4, @truncate(self._m >> 4))];
        buf[16] = H[@as(u4, @truncate(self._m))];
        buf[17] = 0;
        return buf[0..17];
    }

    // ── Comparison / ordering ──────────────────────────────────────

    pub fn eql(self: MAC, other: MAC) bool {
        return self._m == other._m;
    }

    pub fn order(self: MAC, other: MAC) std.math.Order {
        return std.math.order(self._m, other._m);
    }

    pub fn lessThan(_: void, a: MAC, b: MAC) bool {
        return a._m < b._m;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "MAC: zero and init" {
    const z = MAC.zero();
    try testing.expect(!z.isSet());
    try testing.expectEqual(@as(u64, 0), z.toInt());

    const m = MAC.init(0xAABBCCDDEEFF);
    try testing.expectEqual(@as(u64, 0xAABBCCDDEEFF), m.toInt());
    try testing.expect(m.isSet());
}

test "MAC: 48-bit masking" {
    const m = MAC.init(0xFFFF_AABBCCDDEEFF);
    try testing.expectEqual(@as(u64, 0xAABBCCDDEEFF), m.toInt());
}

test "MAC: fromOctets" {
    const m = MAC.fromOctets(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF);
    try testing.expectEqual(@as(u64, 0xAABBCCDDEEFF), m.toInt());
}

test "MAC: bytes round-trip" {
    const original = MAC.init(0x112233445566);
    var buf: [6]u8 = undefined;
    original.copyTo(&buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 }, &buf);

    const restored = MAC.fromBytes(&buf);
    try testing.expect(original.eql(restored));
}

test "MAC: fromSlice short" {
    const short = MAC.fromSlice(&[_]u8{ 0x01, 0x02 });
    try testing.expect(!short.isSet());
}

test "MAC: appendTo buffer" {
    const m = MAC.init(0xAABBCCDDEEFF);
    var buf = Buffer(128){};
    try m.appendTo(128, &buf);
    try testing.expectEqual(@as(u32, 6), buf.size());
    const data = try buf.field(0, 6);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF }, data);
}

test "MAC: broadcast and multicast detection" {
    const bcast = MAC.init(0xffffffffffff);
    try testing.expect(bcast.isBroadcast());
    try testing.expect(bcast.isMulticast());

    const mcast = MAC.fromOctets(0x01, 0x00, 0x5e, 0x00, 0x00, 0x01);
    try testing.expect(!mcast.isBroadcast());
    try testing.expect(mcast.isMulticast());

    const ucast = MAC.fromOctets(0x00, 0x11, 0x22, 0x33, 0x44, 0x55);
    try testing.expect(!ucast.isBroadcast());
    try testing.expect(!ucast.isMulticast());
}

test "MAC: locally administered" {
    // Bit 1 of first octet = locally administered
    const la = MAC.fromOctets(0x02, 0x00, 0x00, 0x00, 0x00, 0x01);
    try testing.expect(la.isLocallyAdministered());

    const global = MAC.fromOctets(0x00, 0x11, 0x22, 0x33, 0x44, 0x55);
    try testing.expect(!global.isLocallyAdministered());
}

test "MAC: firstOctetForNetwork" {
    // Basic: LSB of nwid, set bit 1 (locally admin), clear bit 0 (unicast)
    try testing.expectEqual(@as(u8, 0x02), MAC.firstOctetForNetwork(0x00));
    try testing.expectEqual(@as(u8, 0x06), MAC.firstOctetForNetwork(0x04));

    // 0x52 is blacklisted -> replaced with 0x32
    // nwid & 0xfe | 0x02 = 0x52 when nwid & 0xff == 0x50 or 0x52
    try testing.expectEqual(@as(u8, 0x32), MAC.firstOctetForNetwork(0x52));
    try testing.expectEqual(@as(u8, 0x32), MAC.firstOctetForNetwork(0x50));
}

test "MAC: fromAddress / toAddress round-trip" {
    const ztaddr = Address.init(0x1234567890);
    const nwid: u64 = 0xABCDEF0123456789;

    const m = MAC.fromAddress(ztaddr, nwid);
    try testing.expect(m.isSet());
    try testing.expect(m.isLocallyAdministered());
    try testing.expect(!m.isMulticast());

    const recovered = m.toAddress(nwid);
    try testing.expect(ztaddr.eql(recovered));
}

test "MAC: toString" {
    const m = MAC.fromOctets(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF);
    var buf: [18]u8 = undefined;
    const s = m.toString(&buf);
    try testing.expectEqualStrings("aa:bb:cc:dd:ee:ff", s);
}

test "MAC: getByte" {
    const m = MAC.init(0xA1B2C3D4E5F6);
    try testing.expectEqual(@as(u8, 0xA1), m.getByte(0));
    try testing.expectEqual(@as(u8, 0xB2), m.getByte(1));
    try testing.expectEqual(@as(u8, 0xC3), m.getByte(2));
    try testing.expectEqual(@as(u8, 0xD4), m.getByte(3));
    try testing.expectEqual(@as(u8, 0xE5), m.getByte(4));
    try testing.expectEqual(@as(u8, 0xF6), m.getByte(5));
}

test "MAC: comparison" {
    const a = MAC.init(0x000000000001);
    const b = MAC.init(0x000000000002);
    const c = MAC.init(0x000000000001);

    try testing.expect(a.eql(c));
    try testing.expect(!a.eql(b));
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.gt, b.order(a));
    try testing.expectEqual(std.math.Order.eq, a.order(c));
}
