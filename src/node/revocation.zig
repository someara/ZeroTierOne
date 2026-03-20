/// A revocation certificate to instantaneously revoke a COM, capability, or tag.
///
/// Converted from `node/Revocation.hpp` and `node/Revocation.cpp`. Revocations
/// are signed by the network controller and can be propagated via a rumor mill
/// algorithm when the fast-propagation flag is set.
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

// ── Constants ──────────────────────────────────────────────────────

/// Maximum serialized size of a Revocation (generous upper bound).
pub const max_serialized_size: u32 = 384;

/// Sentinel value used as a delimiter for the signing payload.
const for_sign_sentinel: u64 = 0x7f7f7f7f7f7f7f7f;

/// Flag: fast propagation via rumor mill algorithm.
pub const flag_fast_propagate: u64 = 0x1;

// ── Revocation ─────────────────────────────────────────────────────

pub const Revocation = struct {
    _id: u32,
    _credential_id: u32,
    _network_id: u64,
    _threshold: i64,
    _flags: u64,
    _target: Address,
    _signed_by: Address,
    _type: Credential.Type,
    _signature: ecc.Signature,

    /// Credential type identifier for wire protocol.
    pub const credential_type = Credential.Type.revocation;

    // ── Constructors ──────────────────────────────────────

    /// Create an empty revocation.
    pub fn init() Revocation {
        return .{
            ._id = 0,
            ._credential_id = 0,
            ._network_id = 0,
            ._threshold = 0,
            ._flags = 0,
            ._target = Address.zero(),
            ._signed_by = Address.zero(),
            ._type = Credential.Type.null,
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    /// Create a revocation with the given fields.
    pub fn create(
        revocation_id: u32,
        nwid: u64,
        cred_id: u32,
        thr: i64,
        flags: u64,
        tgt: Address,
        cred_type: Credential.Type,
    ) Revocation {
        return .{
            ._id = revocation_id,
            ._credential_id = cred_id,
            ._network_id = nwid,
            ._threshold = thr,
            ._flags = flags,
            ._target = tgt,
            ._signed_by = Address.zero(),
            ._type = cred_type,
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    // ── Accessors ─────────────────────────────────────────

    pub fn id(self: *const Revocation) u32 {
        return self._id;
    }

    pub fn credentialId(self: *const Revocation) u32 {
        return self._credential_id;
    }

    pub fn networkId(self: *const Revocation) u64 {
        return self._network_id;
    }

    pub fn threshold(self: *const Revocation) i64 {
        return self._threshold;
    }

    pub fn target(self: *const Revocation) Address {
        return self._target;
    }

    pub fn signer(self: *const Revocation) Address {
        return self._signed_by;
    }

    pub fn credentialType(self: *const Revocation) Credential.Type {
        return self._type;
    }

    pub fn fastPropagate(self: *const Revocation) bool {
        return (self._flags & flag_fast_propagate) != 0;
    }

    // ── Signing ───────────────────────────────────────────

    /// Sign this revocation with the given identity.
    ///
    /// Returns false if the identity has no private key.
    pub fn sign(self: *Revocation, signer_identity: *const Identity) bool {
        if (!signer_identity.hasPrivate()) return false;

        self._signed_by = signer_identity.address();

        var tmp: Buffer(max_serialized_size) = .{};
        self.serializeForSign(&tmp) catch return false;

        const sig = signer_identity.sign(tmp.data()) orelse return false;
        self._signature = sig;
        return true;
    }

    /// Verify this revocation's signature against a known identity.
    ///
    /// NOTE: Full verification requires RuntimeEnvironment/Topology
    /// (Phase 4-6 dependencies). The caller must validate that
    /// `_signed_by` is the correct network controller and look up
    /// the identity.
    pub fn verifySignature(self: *const Revocation, signer_identity: *const Identity) bool {
        var tmp: Buffer(max_serialized_size) = .{};
        self.serializeForSign(&tmp) catch return false;
        return signer_identity.verify(tmp.data(), &self._signature);
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize for signing (with sentinel delimiters, no signature).
    fn serializeForSign(self: *const Revocation, buf: *Buffer(max_serialized_size)) !void {
        try buf.appendInt(u64, for_sign_sentinel);
        try self.serializeInner(buf);
        try buf.appendInt(u16, 0); // additional fields length
        try buf.appendInt(u64, for_sign_sentinel);
    }

    /// Serialize the core fields (shared between wire and signing).
    fn serializeInner(self: *const Revocation, buf: anytype) !void {
        try buf.appendInt(u32, 0); // 4 unused bytes
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u32, 0); // 4 unused bytes
        try buf.appendInt(u32, self._credential_id);
        try buf.appendInt(u64, @bitCast(self._threshold));
        try buf.appendInt(u64, self._flags);
        try self._target.appendTo(max_serialized_size, buf);
        try self._signed_by.appendTo(max_serialized_size, buf);
        try buf.appendByte(self._type.toInt(), 1);
    }

    /// Serialize to wire format.
    ///
    /// Wire format:
    ///   unused(4) + id(4) + networkId(8) + unused(4) + credentialId(4) +
    ///   threshold(8) + flags(8) + target(5) + signedBy(5) + type(1) +
    ///   sigType(1) + sigLen(2) + signature(96) + additionalFieldsLen(2)
    pub fn serialize(self: *const Revocation, comptime C: u32, buf: *Buffer(C)) !void {
        try buf.appendInt(u32, 0); // 4 unused bytes
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u32, 0); // 4 unused bytes
        try buf.appendInt(u32, self._credential_id);
        try buf.appendInt(u64, @bitCast(self._threshold));
        try buf.appendInt(u64, self._flags);
        try self._target.appendTo(C, buf);
        try self._signed_by.appendTo(C, buf);
        try buf.appendByte(self._type.toInt(), 1);
        try buf.appendByte(1, 1); // 1 == Ed25519
        try buf.appendInt(u16, ecc.signature_len);
        try buf.appendBytes(&self._signature);
        try buf.appendInt(u16, 0); // additional fields length
    }

    /// Deserialize from wire format.
    ///
    /// Returns the revocation and the number of bytes consumed.
    pub fn deserialize(comptime C: u32, buf: *const Buffer(C), start: u32) !DeserializeResult {
        var self = Revocation.init();
        var p = start;

        p += 4; // skip 4 unused bytes
        self._id = try buf.at(u32, p);
        p += 4;
        self._network_id = try buf.at(u64, p);
        p += 8;
        p += 4; // skip 4 unused bytes
        self._credential_id = try buf.at(u32, p);
        p += 4;
        self._threshold = @bitCast(try buf.at(u64, p));
        p += 8;
        self._flags = try buf.at(u64, p);
        p += 8;

        const target_bytes = try buf.field(p, 5);
        self._target = Address.fromSlice(target_bytes);
        p += 5;
        const signed_by_bytes = try buf.field(p, 5);
        self._signed_by = Address.fromSlice(signed_by_bytes);
        p += 5;

        const type_byte = try buf.getByte(p);
        p += 1;
        self._type = Credential.Type.fromInt(type_byte) orelse Credential.Type.null;

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
            // Unknown signature type — skip
            const skip_len = try buf.at(u16, p);
            p += 2 + skip_len;
        }

        // Skip additional fields
        const additional_len = try buf.at(u16, p);
        p += 2 + additional_len;

        if (p > buf._l) {
            return error.OutOfBounds;
        }

        return .{ .revocation = self, .bytes_read = p - start };
    }
};

/// Result of deserializing a Revocation.
pub const DeserializeResult = struct {
    revocation: Revocation,
    bytes_read: u32,
};

// ── Tests ──────────────────────────────────────────────────────────

test "Revocation: init produces zero revocation" {
    const r = Revocation.init();
    try testing.expectEqual(@as(u32, 0), r.id());
    try testing.expectEqual(@as(u32, 0), r.credentialId());
    try testing.expectEqual(@as(u64, 0), r.networkId());
    try testing.expectEqual(@as(i64, 0), r.threshold());
    try testing.expect(!r.target().isSet());
    try testing.expect(!r.signer().isSet());
    try testing.expectEqual(Credential.Type.null, r.credentialType());
    try testing.expect(!r.fastPropagate());
}

test "Revocation: create with fields" {
    const tgt = Address.init(0x1234567890);
    const r = Revocation.create(42, 0xdeadbeef00000000, 7, -1000, flag_fast_propagate, tgt, Credential.Type.tag);

    try testing.expectEqual(@as(u32, 42), r.id());
    try testing.expectEqual(@as(u32, 7), r.credentialId());
    try testing.expectEqual(@as(u64, 0xdeadbeef00000000), r.networkId());
    try testing.expectEqual(@as(i64, -1000), r.threshold());
    try testing.expect(r.target().eql(tgt));
    try testing.expect(!r.signer().isSet());
    try testing.expectEqual(Credential.Type.tag, r.credentialType());
    try testing.expect(r.fastPropagate());
}

test "Revocation: serialize and deserialize round-trip" {
    const tgt = Address.init(0xaabbccddee);
    const r = Revocation.create(99, 0x1122334455667788, 3, 5000, 0, tgt, Credential.Type.com);

    var buf: Buffer(512) = .{};
    try r.serialize(512, &buf);
    try testing.expect(buf._l > 0);

    const result = try Revocation.deserialize(512, &buf, 0);
    try testing.expectEqual(@as(u32, 99), result.revocation.id());
    try testing.expectEqual(@as(u32, 3), result.revocation.credentialId());
    try testing.expectEqual(@as(u64, 0x1122334455667788), result.revocation.networkId());
    try testing.expectEqual(@as(i64, 5000), result.revocation.threshold());
    try testing.expect(result.revocation.target().eql(tgt));
    try testing.expectEqual(Credential.Type.com, result.revocation.credentialType());
    try testing.expectEqual(buf._l, result.bytes_read);
}

test "Revocation: sign and verify" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const tgt = Address.init(0x1111111111);

    var r = Revocation.create(1, 0x2000000000000000, 0, 100, 0, tgt, Credential.Type.capability);
    try testing.expect(r.sign(&id1));
    try testing.expect(r.signer().eql(id1.address()));
    try testing.expect(r.verifySignature(&id1));

    // Tamper with threshold — should fail verification
    var r2 = r;
    r2._threshold = 999;
    try testing.expect(!r2.verifySignature(&id1));
}

test "Revocation: fast propagate flag" {
    const tgt = Address.init(1);
    const r1 = Revocation.create(1, 0, 0, 0, flag_fast_propagate, tgt, Credential.Type.null);
    try testing.expect(r1.fastPropagate());

    const r2 = Revocation.create(1, 0, 0, 0, 0, tgt, Credential.Type.null);
    try testing.expect(!r2.fastPropagate());

    const r3 = Revocation.create(1, 0, 0, 0, 0xff, tgt, Credential.Type.null);
    try testing.expect(r3.fastPropagate());
}
