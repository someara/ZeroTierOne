/// Certificate indicating ownership of network identifiers (IPs and MACs).
///
/// Converted from `node/CertificateOfOwnership.hpp` and
/// `node/CertificateOfOwnership.cpp`. A COO certifies that a network
/// member owns specific IP addresses or MAC addresses, as assigned by
/// the network controller.
///
/// No heap allocation. This is a value type.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const Credential = @import("credential.zig");
const ecc = @import("ecc.zig");
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;

// ── Platform types ─────────────────────────────────────────────────

const AF = std.c.AF;

// ── Constants ──────────────────────────────────────────────────────

/// Maximum number of things (IPs/MACs) per certificate.
pub const max_things: u32 = 16;

/// Maximum size of a thing's value field in bytes.
pub const max_thing_value_size: u32 = 16;

/// Maximum serialized size (generous upper bound).
pub const max_serialized_size: u32 = 768;

/// Sentinel value used as a delimiter for the signing payload.
const for_sign_sentinel: u64 = 0x7f7f7f7f7f7f7f7f;

/// Thing type identifiers.
pub const Thing = enum(u8) {
    null = 0,
    mac_address = 1,
    ipv4_address = 2,
    ipv6_address = 3,
};

// ── CertificateOfOwnership ────────────────────────────────────────

pub const CertificateOfOwnership = struct {
    _network_id: u64,
    _ts: i64,
    _flags: u64,
    _id: u32,
    _thing_count: u16,
    _thing_types: [max_things]u8,
    _thing_values: [max_things][max_thing_value_size]u8,
    _issued_to: Address,
    _signed_by: Address,
    _signature: ecc.Signature,

    /// Credential type identifier for wire protocol.
    pub const credential_type = Credential.Type.coo;

    // ── Constructors ──────────────────────────────────────

    /// Create a zero/empty COO.
    pub fn init() CertificateOfOwnership {
        return .{
            ._network_id = 0,
            ._ts = 0,
            ._flags = 0,
            ._id = 0,
            ._thing_count = 0,
            ._thing_types = [_]u8{0} ** max_things,
            ._thing_values = [_][max_thing_value_size]u8{[_]u8{0} ** max_thing_value_size} ** max_things,
            ._issued_to = Address.zero(),
            ._signed_by = Address.zero(),
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    /// Create a COO with the given fields.
    pub fn create(nwid: u64, ts: i64, issued_to: Address, coo_id: u32) CertificateOfOwnership {
        var self = CertificateOfOwnership.init();
        self._network_id = nwid;
        self._ts = ts;
        self._id = coo_id;
        self._issued_to = issued_to;
        return self;
    }

    // ── Accessors ─────────────────────────────────────────

    pub fn networkId(self: *const CertificateOfOwnership) u64 {
        return self._network_id;
    }

    pub fn timestamp(self: *const CertificateOfOwnership) i64 {
        return self._ts;
    }

    pub fn id(self: *const CertificateOfOwnership) u32 {
        return self._id;
    }

    pub fn thingCount(self: *const CertificateOfOwnership) u16 {
        return self._thing_count;
    }

    pub fn thingType(self: *const CertificateOfOwnership, i: u32) Thing {
        return std.meta.intToEnum(Thing, self._thing_types[i]) catch .null;
    }

    pub fn thingValue(self: *const CertificateOfOwnership, i: u32) *const [max_thing_value_size]u8 {
        return &self._thing_values[i];
    }

    pub fn issuedTo(self: *const CertificateOfOwnership) Address {
        return self._issued_to;
    }

    // ── Ownership checks ──────────────────────────────────

    /// Check if this COO certifies ownership of the given IP address.
    pub fn ownsIp(self: *const CertificateOfOwnership, ip: *const InetAddress) bool {
        const raw = ip.rawIpData() orelse return false;
        if (ip.isV4()) {
            return self.ownsRaw(.ipv4_address, raw);
        } else if (ip.isV6()) {
            return self.ownsRaw(.ipv6_address, raw);
        }
        return false;
    }

    /// Check if this COO certifies ownership of the given MAC address.
    pub fn ownsMac(self: *const CertificateOfOwnership, mac_val: MAC) bool {
        var tmp: [6]u8 = undefined;
        mac_val.copyTo(&tmp);
        return self.ownsRaw(.mac_address, &tmp);
    }

    /// Add an IP address to this COO's owned things.
    pub fn addIp(self: *CertificateOfOwnership, ip: *const InetAddress) void {
        if (self._thing_count >= max_things) return;

        const idx: usize = self._thing_count;
        if (ip.isV4()) {
            const raw = ip.rawIpData() orelse return;
            self._thing_types[idx] = @intFromEnum(Thing.ipv4_address);
            @memcpy(self._thing_values[idx][0..raw.len], raw);
            self._thing_count += 1;
        } else if (ip.isV6()) {
            const raw = ip.rawIpData() orelse return;
            self._thing_types[idx] = @intFromEnum(Thing.ipv6_address);
            @memcpy(self._thing_values[idx][0..raw.len], raw);
            self._thing_count += 1;
        }
    }

    /// Add a MAC address to this COO's owned things.
    pub fn addMac(self: *CertificateOfOwnership, mac_val: MAC) void {
        if (self._thing_count >= max_things) return;

        const idx: usize = self._thing_count;
        self._thing_types[idx] = @intFromEnum(Thing.mac_address);
        var tmp: [6]u8 = undefined;
        mac_val.copyTo(&tmp);
        @memcpy(self._thing_values[idx][0..6], &tmp);
        self._thing_count += 1;
    }

    // ── Signing ───────────────────────────────────────────

    /// Sign this COO with the given identity.
    ///
    /// Returns false if the identity has no private key.
    pub fn signCoo(self: *CertificateOfOwnership, signer_identity: *const Identity) bool {
        if (!signer_identity.hasPrivate()) return false;

        self._signed_by = signer_identity.address();

        var tmp: Buffer(max_serialized_size) = .{};
        self.serializeForSign(&tmp) catch return false;

        const sig = signer_identity.sign(tmp.data()) orelse return false;
        self._signature = sig;
        return true;
    }

    /// Verify this COO's signature against a known identity.
    ///
    /// NOTE: Full verification requires RuntimeEnvironment/Topology.
    /// The caller must validate that `_signed_by` matches the network
    /// controller and look up the signer identity.
    pub fn verifySignature(
        self: *const CertificateOfOwnership,
        signer_identity: *const Identity,
    ) bool {
        var tmp: Buffer(max_serialized_size) = .{};
        self.serializeForSign(&tmp) catch return false;
        return signer_identity.verify(tmp.data(), &self._signature);
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize for signing (with sentinel delimiters, no signature).
    fn serializeForSign(self: *const CertificateOfOwnership, buf: *Buffer(max_serialized_size)) !void {
        try buf.appendInt(u64, for_sign_sentinel);
        try self.serializeCore(max_serialized_size, buf);
        try buf.appendInt(u16, 0); // additional fields length
        try buf.appendInt(u64, for_sign_sentinel);
    }

    /// Serialize the core fields (shared between wire and signing).
    fn serializeCore(
        self: *const CertificateOfOwnership,
        comptime C: u32,
        buf: *Buffer(C),
    ) !void {
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u64, @bitCast(self._ts));
        try buf.appendInt(u64, self._flags);
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u16, self._thing_count);

        var i: u32 = 0;
        while (i < self._thing_count) : (i += 1) {
            try buf.appendByte(self._thing_types[i], 1);
            try buf.appendBytes(&self._thing_values[i]);
        }

        try self._issued_to.appendTo(C, buf);
        try self._signed_by.appendTo(C, buf);
    }

    /// Serialize to wire format.
    ///
    /// Wire format:
    ///   networkId(8) + ts(8) + flags(8) + id(4) + thingCount(2) +
    ///   [thingType(1) + thingValue(16)] × N +
    ///   issuedTo(5) + signedBy(5) +
    ///   sigType(1) + sigLen(2) + signature(96) +
    ///   additionalFieldsLen(2)
    pub fn serialize(self: *const CertificateOfOwnership, comptime C: u32, buf: *Buffer(C)) !void {
        try self.serializeCore(C, buf);
        try buf.appendByte(1, 1); // 1 == Ed25519
        try buf.appendInt(u16, ecc.signature_len);
        try buf.appendBytes(&self._signature);
        try buf.appendInt(u16, 0); // additional fields length
    }

    /// Deserialize from wire format.
    ///
    /// Returns the COO and the number of bytes consumed.
    pub fn deserialize(comptime C: u32, buf: *const Buffer(C), start: u32) !DeserializeResult {
        var self = CertificateOfOwnership.init();
        var p = start;

        self._network_id = try buf.at(u64, p);
        p += 8;
        self._ts = @bitCast(try buf.at(u64, p));
        p += 8;
        self._flags = try buf.at(u64, p);
        p += 8;
        self._id = try buf.at(u32, p);
        p += 4;
        self._thing_count = try buf.at(u16, p);
        p += 2;

        var i: u32 = 0;
        while (i < self._thing_count) : (i += 1) {
            if (i < max_things) {
                self._thing_types[i] = try buf.getByte(p);
                p += 1;
                const val_bytes = try buf.field(p, max_thing_value_size);
                @memcpy(&self._thing_values[i], val_bytes);
                p += max_thing_value_size;
            }
        }

        const issued_to_bytes = try buf.field(p, 5);
        self._issued_to = Address.fromSlice(issued_to_bytes);
        p += 5;
        const signed_by_bytes = try buf.field(p, 5);
        self._signed_by = Address.fromSlice(signed_by_bytes);
        p += 5;

        const sig_type = try buf.getByte(p);
        p += 1;
        if (sig_type == 1) {
            const sig_len = try buf.at(u16, p);
            if (sig_len != ecc.signature_len) {
                return error.OutOfBounds;
            }
            p += 2;
            const sig_bytes = try buf.field(p, ecc.signature_len);
            @memcpy(&self._signature, sig_bytes);
            p += ecc.signature_len;
        } else {
            const skip_len = try buf.at(u16, p);
            p += 2 + skip_len;
        }

        // Skip additional fields
        const additional_len = try buf.at(u16, p);
        p += 2 + additional_len;

        if (p > buf._l) {
            return error.OutOfBounds;
        }

        return .{ .coo = self, .bytes_read = p - start };
    }

    // ── Comparison ────────────────────────────────────────

    /// Natural sort order by ID.
    pub fn lessThan(_: void, a: CertificateOfOwnership, b: CertificateOfOwnership) bool {
        return a._id < b._id;
    }

    pub fn eql(self: *const CertificateOfOwnership, other: *const CertificateOfOwnership) bool {
        return self._network_id == other._network_id and
            self._ts == other._ts and
            self._flags == other._flags and
            self._id == other._id and
            self._thing_count == other._thing_count and
            mem.eql(u8, &self._thing_types, &other._thing_types) and
            blk: {
                for (0..max_things) |i| {
                    if (!mem.eql(u8, &self._thing_values[i], &other._thing_values[i])) break :blk false;
                }
                break :blk true;
            } and
            self._issued_to.eql(other._issued_to) and
            self._signed_by.eql(other._signed_by) and
            mem.eql(u8, &self._signature, &other._signature);
    }

    // ── Private helpers ───────────────────────────────────

    fn ownsRaw(self: *const CertificateOfOwnership, thing_type: Thing, val: []const u8) bool {
        const type_byte = @intFromEnum(thing_type);
        var i: u32 = 0;
        while (i < self._thing_count) : (i += 1) {
            if (self._thing_types[i] == type_byte) {
                if (val.len <= max_thing_value_size and
                    mem.eql(u8, self._thing_values[i][0..val.len], val))
                {
                    return true;
                }
            }
        }
        return false;
    }
};

/// Result of deserializing a CertificateOfOwnership.
pub const DeserializeResult = struct {
    coo: CertificateOfOwnership,
    bytes_read: u32,
};

// ── Tests ──────────────────────────────────────────────────────────

test "COO: init produces empty COO" {
    const c = CertificateOfOwnership.init();
    try testing.expectEqual(@as(u64, 0), c.networkId());
    try testing.expectEqual(@as(i64, 0), c.timestamp());
    try testing.expectEqual(@as(u32, 0), c.id());
    try testing.expectEqual(@as(u16, 0), c.thingCount());
    try testing.expect(!c.issuedTo().isSet());
}

test "COO: create with fields" {
    const addr = Address.init(0x1234567890);
    const c = CertificateOfOwnership.create(0xdeadbeef00000000, 1000, addr, 42);
    try testing.expectEqual(@as(u64, 0xdeadbeef00000000), c.networkId());
    try testing.expectEqual(@as(i64, 1000), c.timestamp());
    try testing.expectEqual(@as(u32, 42), c.id());
    try testing.expect(c.issuedTo().eql(addr));
}

test "COO: addIp and ownsIp for IPv4" {
    const addr = Address.init(1);
    var c = CertificateOfOwnership.create(0, 0, addr, 0);

    const ip = InetAddress.initV4(.{ 192, 168, 1, 100 }, 0);
    c.addIp(&ip);
    try testing.expectEqual(@as(u16, 1), c.thingCount());
    try testing.expect(c.ownsIp(&ip));

    // Different IP should not be owned
    const ip2 = InetAddress.initV4(.{ 10, 0, 0, 1 }, 0);
    try testing.expect(!c.ownsIp(&ip2));
}

test "COO: addIp and ownsIp for IPv6" {
    const addr = Address.init(1);
    var c = CertificateOfOwnership.create(0, 0, addr, 0);

    const ip = InetAddress.initV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
    c.addIp(&ip);
    try testing.expectEqual(@as(u16, 1), c.thingCount());
    try testing.expect(c.ownsIp(&ip));
}

test "COO: addMac and ownsMac" {
    const addr = Address.init(1);
    var c = CertificateOfOwnership.create(0, 0, addr, 0);

    const mac_val = MAC.fromOctets(0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff);
    c.addMac(mac_val);
    try testing.expectEqual(@as(u16, 1), c.thingCount());
    try testing.expect(c.ownsMac(mac_val));

    const mac2 = MAC.fromOctets(0x11, 0x22, 0x33, 0x44, 0x55, 0x66);
    try testing.expect(!c.ownsMac(mac2));
}

test "COO: max things limit" {
    const addr = Address.init(1);
    var c = CertificateOfOwnership.create(0, 0, addr, 0);

    // Add max_things MACs
    var i: u32 = 0;
    while (i < max_things) : (i += 1) {
        const mac_val = MAC.fromOctets(@truncate(i), 0, 0, 0, 0, 0);
        c.addMac(mac_val);
    }
    try testing.expectEqual(@as(u16, max_things), c.thingCount());

    // Adding one more should be silently ignored
    const extra = MAC.fromOctets(0xff, 0xff, 0xff, 0xff, 0xff, 0xff);
    c.addMac(extra);
    try testing.expectEqual(@as(u16, max_things), c.thingCount());
}

test "COO: serialize and deserialize round-trip" {
    const addr = Address.init(0xaabbccddee);
    var c = CertificateOfOwnership.create(0x1122334455667788, -500, addr, 7);

    const ip = InetAddress.initV4(.{ 10, 0, 0, 1 }, 0);
    c.addIp(&ip);
    const mac_val = MAC.fromOctets(0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff);
    c.addMac(mac_val);

    var buf: Buffer(1024) = .{};
    try c.serialize(1024, &buf);
    try testing.expect(buf._l > 0);

    const result = try CertificateOfOwnership.deserialize(1024, &buf, 0);
    try testing.expectEqual(@as(u64, 0x1122334455667788), result.coo.networkId());
    try testing.expectEqual(@as(i64, -500), result.coo.timestamp());
    try testing.expectEqual(@as(u32, 7), result.coo.id());
    try testing.expectEqual(@as(u16, 2), result.coo.thingCount());
    try testing.expect(result.coo.ownsIp(&ip));
    try testing.expect(result.coo.ownsMac(mac_val));
    try testing.expectEqual(buf._l, result.bytes_read);
}

test "COO: sign and verify" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const addr = id1.address();

    var c = CertificateOfOwnership.create(0x1000000000000000, 12345, addr, 1);
    const ip = InetAddress.initV4(.{ 192, 168, 1, 1 }, 0);
    c.addIp(&ip);

    try testing.expect(c.signCoo(&id1));
    try testing.expect(c.verifySignature(&id1));

    // Tamper — should fail
    var c2 = c;
    c2._id = 999;
    try testing.expect(!c2.verifySignature(&id1));
}

test "COO: equality" {
    const addr = Address.init(0xaabbccddee);
    var c1 = CertificateOfOwnership.create(0x1000, 100, addr, 5);
    var c2 = CertificateOfOwnership.create(0x1000, 100, addr, 5);

    const ip = InetAddress.initV4(.{ 10, 0, 0, 1 }, 0);
    c1.addIp(&ip);
    c2.addIp(&ip);

    try testing.expect(c1.eql(&c2));

    var c3 = CertificateOfOwnership.create(0x1000, 100, addr, 6);
    c3.addIp(&ip);
    try testing.expect(!c1.eql(&c3));
}

test "COO: lessThan ordering" {
    const addr = Address.init(1);
    const c1 = CertificateOfOwnership.create(0, 0, addr, 10);
    const c2 = CertificateOfOwnership.create(0, 0, addr, 20);
    const c3 = CertificateOfOwnership.create(0, 0, addr, 5);

    try testing.expect(CertificateOfOwnership.lessThan({}, c1, c2));
    try testing.expect(!CertificateOfOwnership.lessThan({}, c2, c1));
    try testing.expect(CertificateOfOwnership.lessThan({}, c3, c1));
}
