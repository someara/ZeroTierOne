/// A multicast group composed of a multicast MAC and a 32-bit ADI field.
///
/// Converted from `node/MulticastGroup.hpp`. ADI stands for Additional
/// Distinguishing Information. It is primarily used to add selectivity to
/// broadcast (ff:ff:ff:ff:ff:ff) memberships — for example, IPv4 ARP
/// uses the target IPv4 address as the ADI so that ARP becomes a selective
/// multicast query rather than a true broadcast.
///
/// MulticastGroup is an immutable value type. No heap allocation.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const MAC = @import("mac.zig").MAC;
const InetAddress = @import("inet_address.zig").InetAddress;

// ── MulticastGroup ─────────────────────────────────────────────────

pub const MulticastGroup = struct {
    _mac: MAC,
    _adi: u32,

    /// Create a multicast group from a MAC and an ADI.
    pub fn init(mac_val: MAC, adi_val: u32) MulticastGroup {
        return .{ ._mac = mac_val, ._adi = adi_val };
    }

    /// Create a zero/null multicast group.
    pub fn zero() MulticastGroup {
        return .{ ._mac = MAC.zero(), ._adi = 0 };
    }

    /// Derive the multicast group used for address resolution (ARP/NDP).
    ///
    /// For IPv4: broadcast MAC with the IPv4 address as ADI (makes ARP
    /// selective).
    /// For IPv6: solicited-node multicast MAC from the last 3 bytes of
    /// the IPv6 address, with ADI = 0 (gives 24 bits of uniqueness).
    /// Returns a zero group for other address families.
    pub fn deriveMulticastGroupForAddressResolution(ip: *const InetAddress) MulticastGroup {
        if (ip.isV4()) {
            const raw = ip.rawIpData() orelse return MulticastGroup.zero();
            // ADI = big-endian IPv4 address interpreted as host u32
            const adi_val = mem.readInt(u32, raw[0..4], .big);
            return MulticastGroup.init(MAC.init(0xffffffffffff), adi_val);
        } else if (ip.isV6()) {
            const raw = ip.rawIpData() orelse return MulticastGroup.zero();
            // IPv6 solicited-node multicast: 33:33:ff:XX:YY:ZZ
            return MulticastGroup.init(
                MAC.fromOctets(0x33, 0x33, 0xff, raw[13], raw[14], raw[15]),
                0,
            );
        }
        return MulticastGroup.zero();
    }

    /// Return the multicast MAC address.
    pub fn mac(self: *const MulticastGroup) MAC {
        return self._mac;
    }

    /// Return the additional distinguishing information.
    pub fn adi(self: *const MulticastGroup) u32 {
        return self._adi;
    }

    /// Compute a hash code for use in hash tables.
    pub fn hashCode(self: *const MulticastGroup) u64 {
        return self._mac.hashCode() ^ @as(u64, self._adi);
    }

    /// Equality comparison.
    pub fn eql(self: *const MulticastGroup, other: *const MulticastGroup) bool {
        return self._mac.eql(other._mac) and self._adi == other._adi;
    }

    /// Less-than comparison for ordering.
    pub fn lessThan(self: *const MulticastGroup, other: *const MulticastGroup) bool {
        const mac_ord = self._mac.order(other._mac);
        if (mac_ord == .lt) return true;
        if (mac_ord == .eq) return self._adi < other._adi;
        return false;
    }

    /// Three-way ordering.
    pub fn order(self: *const MulticastGroup, other: *const MulticastGroup) std.math.Order {
        if (self.eql(other)) return .eq;
        if (self.lessThan(other)) return .lt;
        return .gt;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "MulticastGroup: zero" {
    const g = MulticastGroup.zero();
    try testing.expectEqual(@as(u32, 0), g.adi());
    try testing.expect(!g.mac().isSet());
}

test "MulticastGroup: init" {
    const mac = MAC.fromOctets(0x33, 0x33, 0x00, 0x00, 0x00, 0x01);
    const g = MulticastGroup.init(mac, 42);
    try testing.expect(g.mac().eql(mac));
    try testing.expectEqual(@as(u32, 42), g.adi());
}

test "MulticastGroup: deriveMulticastGroupForAddressResolution IPv4" {
    // ARP for 192.168.1.100 => broadcast MAC, ADI = 0xC0A80164
    const addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 0);
    const g = MulticastGroup.deriveMulticastGroupForAddressResolution(&addr);
    try testing.expect(g.mac().eql(MAC.init(0xffffffffffff)));
    try testing.expectEqual(@as(u32, 0xC0A80164), g.adi());
}

test "MulticastGroup: deriveMulticastGroupForAddressResolution IPv6" {
    // NDP for 2001:db8::1 => 33:33:ff:00:00:01, ADI = 0
    const addr = InetAddress.initV6(
        .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        0,
    );
    const g = MulticastGroup.deriveMulticastGroupForAddressResolution(&addr);
    try testing.expect(g.mac().eql(MAC.fromOctets(0x33, 0x33, 0xff, 0x00, 0x00, 0x01)));
    try testing.expectEqual(@as(u32, 0), g.adi());
}

test "MulticastGroup: deriveMulticastGroupForAddressResolution zero" {
    // Zero address => zero group
    const addr = InetAddress.zero();
    const g = MulticastGroup.deriveMulticastGroupForAddressResolution(&addr);
    try testing.expect(g.eql(&MulticastGroup.zero()));
}

test "MulticastGroup: equality" {
    const a = MulticastGroup.init(MAC.init(0xffffffffffff), 100);
    const b = MulticastGroup.init(MAC.init(0xffffffffffff), 100);
    const c = MulticastGroup.init(MAC.init(0xffffffffffff), 200);
    try testing.expect(a.eql(&b));
    try testing.expect(!a.eql(&c));
}

test "MulticastGroup: ordering" {
    const a = MulticastGroup.init(MAC.init(0x010000000000), 0);
    const b = MulticastGroup.init(MAC.init(0x020000000000), 0);
    const c = MulticastGroup.init(MAC.init(0x010000000000), 1);
    // a < b (different MAC)
    try testing.expect(a.lessThan(&b));
    try testing.expect(!b.lessThan(&a));
    // a < c (same MAC, different ADI)
    try testing.expect(a.lessThan(&c));
    try testing.expect(!c.lessThan(&a));
}

test "MulticastGroup: hashCode" {
    const a = MulticastGroup.init(MAC.init(0xffffffffffff), 42);
    const b = MulticastGroup.init(MAC.init(0xffffffffffff), 42);
    try testing.expectEqual(a.hashCode(), b.hashCode());
    // Different ADI should (usually) produce different hash
    const c = MulticastGroup.init(MAC.init(0xffffffffffff), 43);
    try testing.expect(a.hashCode() != c.hashCode());
}
