/// Certificate of network membership (COM).
///
/// Converted from `node/CertificateOfMembership.hpp` and
/// `node/CertificateOfMembership.cpp`. A COM contains a sorted set of
/// qualifier tuples {id, value, maxDelta} that define membership criteria.
///
/// Two COMs "agree" if every qualifier in one exists in the other and
/// the absolute difference between values is within maxDelta. The
/// timestamp qualifier provides the fundamental freshness criterion.
///
/// The signing format differs from other credentials: qualifiers are
/// packed as big-endian u64 triples into a raw buffer (NOT using the
/// standard serialize(forSign) pattern with sentinel delimiters).
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
const sha = @import("sha512.zig");

// ── Constants ──────────────────────────────────────────────────────

/// Maximum number of qualifiers in a COM.
pub const max_qualifiers: u32 = 8;

/// Maximum serialized size (generous upper bound).
pub const max_serialized_size: u32 = 512;

/// Reserved qualifier IDs (values below 1024 are reserved).
pub const ReservedId = struct {
    /// Timestamp of certificate.
    pub const timestamp: u64 = 0;
    /// Network ID for which certificate was issued.
    pub const network_id: u64 = 1;
    /// ZeroTier address to whom certificate was issued.
    pub const issued_to: u64 = 2;
    // IDs 3-6 reserved for full hash of identity to which this COM was issued.
};

// ── Qualifier ──────────────────────────────────────────────────────

pub const Qualifier = struct {
    qualifier_id: u64,
    value: u64,
    max_delta: u64,

    pub fn init() Qualifier {
        return .{ .qualifier_id = 0, .value = 0, .max_delta = 0 };
    }
};

// ── CertificateOfMembership ───────────────────────────────────────

pub const CertificateOfMembership = struct {
    _qualifiers: [max_qualifiers]Qualifier,
    _qualifier_count: u32,
    _signed_by: Address,
    _signature: ecc.Signature,

    /// Credential type identifier for wire protocol.
    pub const credential_type = Credential.Type.com;

    // ── Constructors ──────────────────────────────────────

    /// Create an empty (unsigned) COM.
    pub fn init() CertificateOfMembership {
        var qualifiers: [max_qualifiers]Qualifier = undefined;
        for (&qualifiers) |*q| {
            q.* = Qualifier.init();
        }
        return .{
            ._qualifiers = qualifiers,
            ._qualifier_count = 0,
            ._signed_by = Address.zero(),
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    /// Create from required fields common to all networks.
    ///
    /// Sets 7 qualifiers: timestamp(0), network_id(1), issued_to(2),
    /// and identity hash (3-6) from the issued-to identity's public key.
    pub fn create(
        ts: u64,
        ts_max_delta: u64,
        nwid: u64,
        issued_to: *const Identity,
    ) CertificateOfMembership {
        var self = CertificateOfMembership.init();

        self._qualifiers[0] = .{
            .qualifier_id = ReservedId.timestamp,
            .value = ts,
            .max_delta = ts_max_delta,
        };
        self._qualifiers[1] = .{
            .qualifier_id = ReservedId.network_id,
            .value = nwid,
            .max_delta = 0,
        };
        self._qualifiers[2] = .{
            .qualifier_id = ReservedId.issued_to,
            .value = issued_to.address().toInt(),
            .max_delta = 0xffffffffffffffff,
        };

        // Include hash of full identity public key for hardening.
        // Pack 4 x u64 from SHA-384(address || public_key) using
        // big-to-native conversion (matching C++ Utils::ntoh).
        var id_hash: [sha.sha384_digest_len]u8 = undefined;
        issued_to.publicKeyHash(&id_hash);

        for (0..4) |i| {
            const offset = i * 8;
            const hash_val = mem.readInt(u64, id_hash[offset..][0..8], .big);
            self._qualifiers[i + 3] = .{
                .qualifier_id = @as(u64, i + 3),
                .value = hash_val,
                .max_delta = 0xffffffffffffffff,
            };
        }

        self._qualifier_count = 7;
        return self;
    }

    // ── Accessors ─────────────────────────────────────────

    /// Return true if this COM has any qualifiers.
    pub fn isSet(self: *const CertificateOfMembership) bool {
        return self._qualifier_count != 0;
    }

    /// Credential ID is always 0 for COMs.
    pub fn id(_: *const CertificateOfMembership) u32 {
        return 0;
    }

    /// Return the timestamp value, or 0 if not present.
    pub fn timestamp(self: *const CertificateOfMembership) i64 {
        for (self._qualifiers[0..self._qualifier_count]) |q| {
            if (q.qualifier_id == ReservedId.timestamp) {
                return @bitCast(q.value);
            }
        }
        return 0;
    }

    /// Return the address to which this COM was issued, or zero.
    pub fn issuedTo(self: *const CertificateOfMembership) Address {
        for (self._qualifiers[0..self._qualifier_count]) |q| {
            if (q.qualifier_id == ReservedId.issued_to) {
                return Address.init(q.value);
            }
        }
        return Address.zero();
    }

    /// Return the network ID, or 0 if not present.
    pub fn networkId(self: *const CertificateOfMembership) u64 {
        for (self._qualifiers[0..self._qualifier_count]) |q| {
            if (q.qualifier_id == ReservedId.network_id) {
                return q.value;
            }
        }
        return 0;
    }

    /// Return true if signed.
    pub fn isSigned(self: *const CertificateOfMembership) bool {
        return self._signed_by.isSet();
    }

    /// Return the address that signed this COM, or zero.
    pub fn signedByAddr(self: *const CertificateOfMembership) Address {
        return self._signed_by;
    }

    pub fn qualifierCount(self: *const CertificateOfMembership) u32 {
        return self._qualifier_count;
    }

    // ── Agreement ─────────────────────────────────────────

    /// Check if this COM agrees with another.
    ///
    /// Returns true if all qualifiers in `self` are present in `other`
    /// and their value differences are within this COM's maxDelta
    /// tolerances. Also verifies identity hash fields (3-6) if present.
    pub fn agreesWith(
        self: *const CertificateOfMembership,
        other: *const CertificateOfMembership,
        other_identity: *const Identity,
    ) bool {
        if (self._qualifier_count == 0 or other._qualifier_count == 0) {
            return false;
        }

        var full_identity_verification = false;

        for (self._qualifiers[0..self._qualifier_count]) |q| {
            const qid = q.qualifier_id;
            if (qid >= 3 and qid <= 6) {
                full_identity_verification = true;
            }

            // Find this qualifier in the other COM
            const other_val = findQualifier(other, qid) orelse return false;

            const a = q.value;
            const b = other_val;
            const diff = if (a >= b) a - b else b - a;
            if (diff > q.max_delta) {
                return false;
            }
        }

        // If this COM has identity hash fields, verify the other identity
        if (full_identity_verification) {
            var id_hash: [sha.sha384_digest_len]u8 = undefined;
            other_identity.publicKeyHash(&id_hash);

            for (0..4) |i| {
                const other_val = findQualifier(other, @as(u64, i + 3)) orelse return false;
                const offset = i * 8;
                const expected = mem.readInt(u64, id_hash[offset..][0..8], .big);
                if (other_val != expected) {
                    return false;
                }
            }
        }

        return true;
    }

    // ── Signing ───────────────────────────────────────────

    /// Sign this COM.
    ///
    /// The signing format packs qualifiers as big-endian u64 triples
    /// into a raw buffer (NOT using sentinel-delimited serialization).
    /// Returns false if the identity has no private key.
    pub fn signCom(self: *CertificateOfMembership, signer_identity: *const Identity) bool {
        if (!signer_identity.hasPrivate()) return false;

        var buf: [max_qualifiers * 3 * 8]u8 = undefined;
        const data_len = self.packQualifiersForSigning(&buf);

        const sig = signer_identity.sign(buf[0..data_len]) orelse return false;
        self._signature = sig;
        self._signed_by = signer_identity.address();
        return true;
    }

    /// Verify this COM's signature against a known identity.
    ///
    /// NOTE: Full verification requires RuntimeEnvironment/Topology.
    /// The caller must validate that `_signed_by` matches the network
    /// controller and look up the signer identity.
    pub fn verifySignature(
        self: *const CertificateOfMembership,
        signer_identity: *const Identity,
    ) bool {
        var buf: [max_qualifiers * 3 * 8]u8 = undefined;
        const data_len = self.packQualifiersForSigning(&buf);
        return signer_identity.verify(buf[0..data_len], &self._signature);
    }

    /// Pack qualifiers as big-endian u64 triples for signing/verification.
    fn packQualifiersForSigning(self: *const CertificateOfMembership, buf: *[max_qualifiers * 3 * 8]u8) usize {
        var offset: usize = 0;
        for (self._qualifiers[0..self._qualifier_count]) |q| {
            mem.writeInt(u64, buf[offset..][0..8], q.qualifier_id, .big);
            offset += 8;
            mem.writeInt(u64, buf[offset..][0..8], q.value, .big);
            offset += 8;
            mem.writeInt(u64, buf[offset..][0..8], q.max_delta, .big);
            offset += 8;
        }
        return offset;
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize to wire format.
    ///
    /// Wire format:
    ///   version(1) + qualifierCount(2) +
    ///   [id(8) + value(8) + maxDelta(8)] × N +
    ///   signedBy(5) + [signature(96) if signed]
    pub fn serialize(self: *const CertificateOfMembership, comptime C: u32, buf: *Buffer(C)) !void {
        try buf.appendByte(1, 1); // version byte
        try buf.appendInt(u16, @intCast(self._qualifier_count));

        for (self._qualifiers[0..self._qualifier_count]) |q| {
            try buf.appendInt(u64, q.qualifier_id);
            try buf.appendInt(u64, q.value);
            try buf.appendInt(u64, q.max_delta);
        }

        try self._signed_by.appendTo(C, buf);
        if (self._signed_by.isSet()) {
            try buf.appendBytes(&self._signature);
        }
    }

    /// Deserialize from wire format.
    ///
    /// Returns the COM and the number of bytes consumed.
    pub fn deserialize(comptime C: u32, buf: *const Buffer(C), start: u32) !DeserializeResult {
        var self = CertificateOfMembership.init();
        var p = start;

        const version = try buf.getByte(p);
        p += 1;
        if (version != 1) {
            return error.OutOfBounds;
        }

        const numq = try buf.at(u16, p);
        p += 2;

        var last_id: u64 = 0;
        var i: u32 = 0;
        while (i < numq) : (i += 1) {
            const qid = try buf.at(u64, p);
            if (qid < last_id) {
                return error.OutOfBounds; // qualifiers must be sorted
            }
            last_id = qid;

            if (self._qualifier_count >= max_qualifiers) {
                return error.OutOfBounds;
            }

            self._qualifiers[self._qualifier_count] = .{
                .qualifier_id = qid,
                .value = try buf.at(u64, p + 8),
                .max_delta = try buf.at(u64, p + 16),
            };
            p += 24;
            self._qualifier_count += 1;
        }

        const signed_by_bytes = try buf.field(p, 5);
        self._signed_by = Address.fromSlice(signed_by_bytes);
        p += 5;

        if (self._signed_by.isSet()) {
            const sig_bytes = try buf.field(p, ecc.signature_len);
            @memcpy(&self._signature, sig_bytes);
            p += ecc.signature_len;
        }

        return .{ .com = self, .bytes_read = p - start };
    }

    // ── Comparison ────────────────────────────────────────

    pub fn eql(self: *const CertificateOfMembership, other: *const CertificateOfMembership) bool {
        if (!self._signed_by.eql(other._signed_by)) return false;
        if (self._qualifier_count != other._qualifier_count) return false;

        for (0..self._qualifier_count) |i| {
            const a = self._qualifiers[i];
            const b = other._qualifiers[i];
            if (a.qualifier_id != b.qualifier_id or a.value != b.value or a.max_delta != b.max_delta) {
                return false;
            }
        }

        return mem.eql(u8, &self._signature, &other._signature);
    }

    // ── Private helpers ───────────────────────────────────

    fn findQualifier(com: *const CertificateOfMembership, qid: u64) ?u64 {
        for (com._qualifiers[0..com._qualifier_count]) |q| {
            if (q.qualifier_id == qid) return q.value;
        }
        return null;
    }
};

/// Result of deserializing a CertificateOfMembership.
pub const DeserializeResult = struct {
    com: CertificateOfMembership,
    bytes_read: u32,
};

// ── Tests ──────────────────────────────────────────────────────────

test "COM: init produces empty COM" {
    const c = CertificateOfMembership.init();
    try testing.expect(!c.isSet());
    try testing.expectEqual(@as(u32, 0), c.id());
    try testing.expectEqual(@as(i64, 0), c.timestamp());
    try testing.expect(!c.issuedTo().isSet());
    try testing.expectEqual(@as(u64, 0), c.networkId());
    try testing.expect(!c.isSigned());
}

test "COM: create sets 7 qualifiers" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    const com = CertificateOfMembership.create(1000, 100, 0xdeadbeef00000000, &id1);
    try testing.expect(com.isSet());
    try testing.expectEqual(@as(u32, 7), com.qualifierCount());
    try testing.expectEqual(@as(i64, 1000), com.timestamp());
    try testing.expectEqual(@as(u64, 0xdeadbeef00000000), com.networkId());
    try testing.expect(com.issuedTo().eql(id1.address()));
}

test "COM: serialize and deserialize round-trip" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    var com = CertificateOfMembership.create(5000, 200, 0x1122334455667788, &id1);
    // Sign it so signedBy is set and signature is included in serialization
    try testing.expect(com.signCom(&id1));

    var buf: Buffer(1024) = .{};
    try com.serialize(1024, &buf);
    try testing.expect(buf._l > 0);

    const result = try CertificateOfMembership.deserialize(1024, &buf, 0);
    try testing.expect(result.com.isSet());
    try testing.expectEqual(@as(u32, 7), result.com.qualifierCount());
    try testing.expectEqual(@as(i64, 5000), result.com.timestamp());
    try testing.expectEqual(@as(u64, 0x1122334455667788), result.com.networkId());
    try testing.expect(result.com.issuedTo().eql(id1.address()));
    try testing.expect(result.com.isSigned());
    try testing.expectEqual(buf._l, result.bytes_read);
}

test "COM: sign and verify" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    var com = CertificateOfMembership.create(1000, 100, 0xdeadbeef00000000, &id1);
    try testing.expect(com.signCom(&id1));
    try testing.expect(com.isSigned());
    try testing.expect(com.signedByAddr().eql(id1.address()));
    try testing.expect(com.verifySignature(&id1));

    // Tamper with qualifier value — should fail
    var com2 = com;
    com2._qualifiers[0].value = 9999;
    try testing.expect(!com2.verifySignature(&id1));
}

test "COM: agreesWith basic" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const id2 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    const nwid: u64 = 0x1234567800000000;
    const com1 = CertificateOfMembership.create(1000, 100, nwid, &id1);
    const com2 = CertificateOfMembership.create(1050, 100, nwid, &id2);

    // com1 agrees with com2 (timestamp diff 50 <= maxDelta 100)
    try testing.expect(com1.agreesWith(&com2, &id2));

    // com with very different timestamp should fail
    const com3 = CertificateOfMembership.create(2000, 100, nwid, &id2);
    try testing.expect(!com1.agreesWith(&com3, &id2));
}

test "COM: agreesWith empty COMs returns false" {
    const empty1 = CertificateOfMembership.init();
    const empty2 = CertificateOfMembership.init();
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try testing.expect(!empty1.agreesWith(&empty2, &id1));
}

test "COM: equality" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    const com1 = CertificateOfMembership.create(1000, 100, 0xdeadbeef00000000, &id1);
    const com2 = CertificateOfMembership.create(1000, 100, 0xdeadbeef00000000, &id1);
    try testing.expect(com1.eql(&com2));

    const com3 = CertificateOfMembership.create(2000, 100, 0xdeadbeef00000000, &id1);
    try testing.expect(!com1.eql(&com3));
}

test "COM: deserialize rejects bad version" {
    var buf: Buffer(64) = .{};
    try buf.appendByte(2, 1); // version 2 — unsupported
    try buf.appendInt(u16, 0);
    try buf.appendByte(0, 5); // signedBy

    const result = CertificateOfMembership.deserialize(64, &buf, 0);
    try testing.expectError(error.OutOfBounds, result);
}
