/// A tag that can be associated with network members and matched in rules.
///
/// Converted from `node/Tag.hpp` and `node/Tag.cpp`. Tags associate members
/// with values that can be matched in network flow rules. Unlike capabilities,
/// which group rules, tags group members subject to those rules.
///
/// Tags are signed only by the network controller and are never transferable.
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

/// Maximum serialized size of a Tag (generous upper bound for buffers).
pub const max_serialized_size: u32 = 256;

/// Sentinel value used as a delimiter for the signing payload.
const for_sign_sentinel: u64 = 0x7f7f7f7f7f7f7f7f;

// ── Tag ────────────────────────────────────────────────────────────

pub const Tag = struct {
    _id: u32,
    _value: u32,
    _network_id: u64,
    _ts: i64,
    _issued_to: Address,
    _signed_by: Address,
    _signature: ecc.Signature,

    /// Credential type identifier for wire protocol.
    pub const credential_type = Credential.Type.tag;

    // ── Constructors ──────────────────────────────────────

    /// Create a zero/empty tag.
    pub fn init() Tag {
        return .{
            ._id = 0,
            ._value = 0,
            ._network_id = 0,
            ._ts = 0,
            ._issued_to = Address.zero(),
            ._signed_by = Address.zero(),
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    /// Create a tag with the given fields.
    pub fn create(
        nwid: u64,
        ts: i64,
        issued_to: Address,
        tag_id: u32,
        tag_value: u32,
    ) Tag {
        return .{
            ._id = tag_id,
            ._value = tag_value,
            ._network_id = nwid,
            ._ts = ts,
            ._issued_to = issued_to,
            ._signed_by = Address.zero(),
            ._signature = [_]u8{0} ** ecc.signature_len,
        };
    }

    // ── Accessors ─────────────────────────────────────────

    pub fn id(self: *const Tag) u32 {
        return self._id;
    }

    pub fn value(self: *const Tag) u32 {
        return self._value;
    }

    pub fn networkId(self: *const Tag) u64 {
        return self._network_id;
    }

    pub fn timestamp(self: *const Tag) i64 {
        return self._ts;
    }

    pub fn issuedTo(self: *const Tag) Address {
        return self._issued_to;
    }

    pub fn signedBy(self: *const Tag) Address {
        return self._signed_by;
    }

    // ── Signing ───────────────────────────────────────────

    /// Sign this tag with the given identity.
    ///
    /// Sets `_signed_by` to the signer's address and computes the
    /// Ed25519 signature over the `forSign` serialization.
    /// Returns false if the identity has no private key.
    pub fn sign(self: *Tag, signer: *const Identity) bool {
        if (!signer.hasPrivate()) return false;

        self._signed_by = signer.address();

        var tmp: Buffer(max_serialized_size) = .{};
        // Stack buffer — cannot OOM. Failure means tag exceeds max size.
        self.serializeForSign(&tmp) catch return false;

        const sig = signer.sign(tmp.data()) orelse return false;
        self._signature = sig;
        return true;
    }

    /// Verify this tag's signature.
    ///
    /// NOTE: Full verification requires RuntimeEnvironment/Topology
    /// (Phase 4-6 dependencies). This method performs a local signature
    /// check against the provided signer identity. The caller is
    /// responsible for validating that `_signed_by` is the correct
    /// network controller and looking up the identity.
    ///
    /// Returns true if the signature is valid.
    pub fn verifySignature(self: *const Tag, signer_identity: *const Identity) bool {
        var tmp: Buffer(max_serialized_size) = .{};
        // Stack buffer — cannot OOM. Failure means tag exceeds max size.
        self.serializeForSign(&tmp) catch return false;
        return signer_identity.verify(tmp.data(), &self._signature);
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize for signing (with sentinel delimiters, no signature).
    fn serializeForSign(self: *const Tag, buf: *Buffer(max_serialized_size)) !void {
        try buf.appendInt(u64, for_sign_sentinel);
        try self.serializeInner(buf);
        try buf.appendInt(u16, 0); // additional fields length
        try buf.appendInt(u64, for_sign_sentinel);
    }

    /// Serialize the core fields (shared between wire and signing).
    fn serializeInner(self: *const Tag, buf: anytype) !void {
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u64, @bitCast(self._ts));
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u32, self._value);
        try self._issued_to.appendTo(max_serialized_size, buf);
        try self._signed_by.appendTo(max_serialized_size, buf);
    }

    /// Serialize to wire format.
    ///
    /// Wire format:
    ///   networkId(8) + ts(8) + id(4) + value(4) +
    ///   issuedTo(5) + signedBy(5) +
    ///   sigType(1) + sigLen(2) + signature(96) +
    ///   additionalFieldsLen(2)
    pub fn serialize(self: *const Tag, comptime C: u32, buf: *Buffer(C)) !void {
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u64, @bitCast(self._ts));
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u32, self._value);
        try self._issued_to.appendTo(C, buf);
        try self._signed_by.appendTo(C, buf);
        try buf.appendByte(1, 1); // 1 == Ed25519
        try buf.appendInt(u16, ecc.signature_len);
        try buf.appendBytes(&self._signature);
        try buf.appendInt(u16, 0); // additional fields length
    }

    /// Deserialize from wire format.
    ///
    /// Returns the number of bytes consumed, or error on malformed data.
    pub fn deserialize(comptime C: u32, buf: *const Buffer(C), start: u32) !DeserializeResult {
        var self = Tag.init();
        var p = start;

        self._network_id = try buf.at(u64, p);
        p += 8;
        self._ts = @bitCast(try buf.at(u64, p));
        p += 8;
        self._id = try buf.at(u32, p);
        p += 4;
        self._value = try buf.at(u32, p);
        p += 4;

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
            p += 2;
            if (sig_len != ecc.signature_len) {
                return error.OutOfBounds;
            }
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

        return .{ .tag = self, .bytes_read = p - start };
    }

    // ── Comparison ────────────────────────────────────────

    /// Natural sort order by ID (for sorted arrays).
    pub fn lessThan(_: void, a: Tag, b: Tag) bool {
        return a._id < b._id;
    }

    pub fn order(self: *const Tag, other: *const Tag) std.math.Order {
        return std.math.order(self._id, other._id);
    }

    pub fn eql(self: *const Tag, other: *const Tag) bool {
        return self._id == other._id and
            self._value == other._value and
            self._network_id == other._network_id and
            self._ts == other._ts and
            self._issued_to.eql(other._issued_to) and
            self._signed_by.eql(other._signed_by) and
            mem.eql(u8, &self._signature, &other._signature);
    }
};

/// Result of deserializing a Tag.
pub const DeserializeResult = struct {
    tag: Tag,
    bytes_read: u32,
};

// ── Tests ──────────────────────────────────────────────────────────

test "Tag: init produces zero tag" {
    const t = Tag.init();
    try testing.expectEqual(@as(u32, 0), t.id());
    try testing.expectEqual(@as(u32, 0), t.value());
    try testing.expectEqual(@as(u64, 0), t.networkId());
    try testing.expectEqual(@as(i64, 0), t.timestamp());
    try testing.expect(!t.issuedTo().isSet());
    try testing.expect(!t.signedBy().isSet());
}

test "Tag: create with fields" {
    const addr = Address.init(0x1234567890);
    const t = Tag.create(0xdeadbeefcafe0000, 1000, addr, 42, 99);
    try testing.expectEqual(@as(u32, 42), t.id());
    try testing.expectEqual(@as(u32, 99), t.value());
    try testing.expectEqual(@as(u64, 0xdeadbeefcafe0000), t.networkId());
    try testing.expectEqual(@as(i64, 1000), t.timestamp());
    try testing.expect(t.issuedTo().eql(addr));
    try testing.expect(!t.signedBy().isSet());
}

test "Tag: serialize and deserialize round-trip" {
    const addr = Address.init(0xaabbccddee);
    const t = Tag.create(0x1122334455667788, -500, addr, 7, 12345);

    var buf: Buffer(512) = .{};
    try t.serialize(512, &buf);
    try testing.expect(buf._l > 0);

    const result = try Tag.deserialize(512, &buf, 0);
    try testing.expectEqual(@as(u32, 7), result.tag.id());
    try testing.expectEqual(@as(u32, 12345), result.tag.value());
    try testing.expectEqual(@as(u64, 0x1122334455667788), result.tag.networkId());
    try testing.expectEqual(@as(i64, -500), result.tag.timestamp());
    try testing.expect(result.tag.issuedTo().eql(addr));
    try testing.expectEqual(buf._l, result.bytes_read);
}

test "Tag: sign and verify" {
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const addr = id1.address();

    var t = Tag.create(0x1000000000000000, 12345, addr, 1, 100);
    try testing.expect(t.sign(&id1));
    try testing.expect(t.signedBy().eql(addr));
    try testing.expect(t.verifySignature(&id1));

    // Tamper with value — should fail verification
    var t2 = t;
    t2._value = 999;
    try testing.expect(!t2.verifySignature(&id1));
}

test "Tag: deserialize rejects bad signature length" {
    // Build a buffer with a wrong signature length
    var buf: Buffer(512) = .{};
    try buf.appendInt(u64, 0x1122334455667788); // networkId
    try buf.appendInt(u64, 0); // ts
    try buf.appendInt(u32, 1); // id
    try buf.appendInt(u32, 2); // value
    try buf.appendByte(0, 5); // issuedTo
    try buf.appendByte(0, 5); // signedBy
    try buf.appendByte(1, 1); // sigType = 1 (Ed25519)
    try buf.appendInt(u16, 10); // wrong sig length (not 96)

    const result = Tag.deserialize(512, &buf, 0);
    try testing.expectError(error.OutOfBounds, result);
}

test "Tag: lessThan ordering" {
    const a1 = Address.init(1);
    const t1 = Tag.create(0, 0, a1, 10, 0);
    const t2 = Tag.create(0, 0, a1, 20, 0);
    const t3 = Tag.create(0, 0, a1, 5, 0);

    try testing.expect(Tag.lessThan({}, t1, t2));
    try testing.expect(!Tag.lessThan({}, t2, t1));
    try testing.expect(Tag.lessThan({}, t3, t1));
}

test "Tag: equality" {
    const addr = Address.init(0xaabbccddee);
    const t1 = Tag.create(0x1000, 100, addr, 5, 42);
    const t2 = Tag.create(0x1000, 100, addr, 5, 42);
    const t3 = Tag.create(0x1000, 100, addr, 5, 43);

    try testing.expect(t1.eql(&t2));
    try testing.expect(!t1.eql(&t3));
}
