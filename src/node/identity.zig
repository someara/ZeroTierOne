/// A ZeroTier identity — public key, 40-bit address, and optional private key.
///
/// Converted from `node/Identity.hpp` and `node/Identity.cpp`. An identity
/// consists of a C25519/Ed25519 public key pair, a 40-bit ZeroTier address
/// derived from the public key using a memory-hard hashcash algorithm, and
/// an optional private key for signing and key agreement.
///
/// The address derivation makes it computationally expensive to find a
/// different public key that produces the same address.
///
/// No heap allocation — the private key is stored inline (with a flag).
const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const crypto = std.crypto;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const constants = @import("constants.zig");
const ecc = @import("ecc.zig");
const sha = @import("sha512.zig");
const salsa20_mod = @import("salsa20.zig");
const utils = @import("utils.zig");

// ── Constants ──────────────────────────────────────────────────────

/// Maximum size of an ASCII identity string (address:type:pubkey:privkey).
pub const string_buffer_length: u32 = 384;

/// Hashcash threshold: first byte of memory-hard digest must be < 17.
const gen_hashcash_first_byte_less_than: u8 = 17;

/// Memory used by the memory-hard hash function (2 MiB).
const gen_memory: usize = 2097152;

// ── Identity ──────────────────────────────────────────────────────

pub const Identity = struct {
    _address: Address,
    _public_key: ecc.Public,
    _private_key: ecc.Private,
    _has_private: bool,

    // ── Constructors ──────────────────────────────────────

    /// Create an empty (unset) identity.
    pub fn init() Identity {
        return .{
            ._address = Address.zero(),
            ._public_key = [_]u8{0} ** 64,
            ._private_key = [_]u8{0} ** 64,
            ._has_private = false,
        };
    }

    /// Parse an identity from an ASCII string.
    ///
    /// Returns `null` if the string is malformed. Note: this validates
    /// format only. Call `locallyValidate()` to verify the address/key
    /// correspondence.
    pub fn fromString(str: []const u8) ?Identity {
        var self = Identity.init();

        // Tokenize by ':'
        var field_no: u32 = 0;
        var start: usize = 0;
        var pos: usize = 0;

        while (pos <= str.len) {
            const at_end = pos == str.len;
            const at_sep = !at_end and str[pos] == ':';

            if (at_end or at_sep) {
                const field = str[start..pos];
                switch (field_no) {
                    0 => {
                        // Address field — hex string
                        const addr_val = parseHexU64(field) orelse return null;
                        self._address = Address.init(addr_val);
                        if (self._address.isReserved()) {
                            return null;
                        }
                    },
                    1 => {
                        // Type field — must be "0"
                        if (field.len != 1 or field[0] != '0') {
                            return null;
                        }
                    },
                    2 => {
                        // Public key — hex (128 chars = 64 bytes)
                        if (utils.unhex(field, &self._public_key) != ecc.public_key_set_len) {
                            self._address = Address.zero();
                            return null;
                        }
                    },
                    3 => {
                        // Private key (optional) — hex (128 chars = 64 bytes)
                        if (utils.unhex(field, &self._private_key) != ecc.private_key_set_len) {
                            self._address = Address.zero();
                            return null;
                        }
                        self._has_private = true;
                    },
                    else => {
                        self._address = Address.zero();
                        return null;
                    },
                }
                field_no += 1;
                start = pos + 1;
            }
            pos += 1;
        }

        if (field_no < 3) {
            self._address = Address.zero();
            return null;
        }

        return self;
    }

    /// Deserialize a binary identity from a Buffer at the given offset.
    ///
    /// Returns the identity and the number of bytes consumed, or `null`
    /// if the data is invalid.
    pub fn deserialize(comptime C: u32, buf: *const Buffer(C), start_at: u32) ?struct { identity: Identity, bytes_read: u32 } {
        var self = Identity.init();
        var p = start_at;

        // Read 5-byte address
        const addr_bytes = buf.field(p, constants.address_length) catch return null;
        self._address = Address.fromBytes(addr_bytes[0..constants.address_length]);
        p += constants.address_length;

        // Read type byte (must be 0)
        const type_byte = buf.at(u8, p) catch return null;
        if (type_byte != 0) return null;
        p += 1;

        // Read public key (64 bytes)
        const pub_bytes = buf.field(p, ecc.public_key_set_len) catch return null;
        @memcpy(&self._public_key, pub_bytes[0..ecc.public_key_set_len]);
        p += ecc.public_key_set_len;

        // Read private key length
        const priv_len_byte = buf.at(u8, p) catch return null;
        p += 1;

        if (priv_len_byte > 0) {
            if (priv_len_byte != ecc.private_key_set_len) return null;
            const priv_bytes = buf.field(p, ecc.private_key_set_len) catch return null;
            @memcpy(&self._private_key, priv_bytes[0..ecc.private_key_set_len]);
            self._has_private = true;
            p += ecc.private_key_set_len;
        }

        return .{ .identity = self, .bytes_read = p - start_at };
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize this identity in binary form, appending to a Buffer.
    ///
    /// If `include_private` is true and a private key is present,
    /// the private key is included.
    pub fn serialize(
        self: *const Identity,
        comptime C: u32,
        buf: *Buffer(C),
        include_private: bool,
    ) Buffer(C).Error!void {
        try self._address.appendTo(C, buf);
        try buf.appendByte(0, 1); // identity type 0 (C25519/Ed25519)
        try buf.appendBytes(&self._public_key);
        if (self._has_private and include_private) {
            try buf.appendByte(@as(u8, ecc.private_key_set_len), 1);
            try buf.appendBytes(&self._private_key);
        } else {
            try buf.appendByte(0, 1);
        }
    }

    /// Serialize to an ASCII string.
    ///
    /// Format: `<address>:0:<pubkey_hex>[:<privkey_hex>]`
    /// Returns a slice of `buf` containing the string.
    pub fn toString(
        self: *const Identity,
        include_private: bool,
        buf: *[string_buffer_length]u8,
    ) []const u8 {
        var pos: usize = 0;

        // Address (10 hex chars)
        const addr_hex = utils.hex10(self._address.toInt(), buf[pos..][0..10]);
        _ = addr_hex;
        pos += 10;

        // ":0:"
        buf[pos] = ':';
        buf[pos + 1] = '0';
        buf[pos + 2] = ':';
        pos += 3;

        // Public key (128 hex chars)
        _ = utils.hexSlice(&self._public_key, buf[pos .. pos + 128]);
        pos += 128;

        // Optional private key
        if (self._has_private and include_private) {
            buf[pos] = ':';
            pos += 1;
            _ = utils.hexSlice(&self._private_key, buf[pos .. pos + 128]);
            pos += 128;
        }

        return buf[0..pos];
    }

    // ── Generation and validation ─────────────────────────

    /// Generate a new identity (address + key pair).
    ///
    /// This is computationally expensive due to the memory-hard
    /// hashcash proof-of-work. Allocates 2 MiB of scratch memory.
    pub fn generate(allocator: std.mem.Allocator) !Identity {
        const genmem = try allocator.alloc(u8, gen_memory);
        defer allocator.free(genmem);

        var digest: [64]u8 = undefined;
        var self = Identity.init();

        while (true) {
            const kp = try ecc.generateSatisfyingWithContext(
                GenContext{ .digest = &digest, .genmem = genmem },
                genCondition,
            );

            const addr = Address.fromBytes(digest[59..64]);
            if (!addr.isReserved()) {
                self._address = addr;
                self._public_key = kp.public_key;
                self._private_key = kp.private_key;
                self._has_private = true;
                return self;
            }
        }
    }

    /// Validate that this identity's address was correctly derived from
    /// its public key using the memory-hard hashcash algorithm.
    ///
    /// Allocates 2 MiB of scratch memory.
    pub fn locallyValidate(self: *const Identity, allocator: std.mem.Allocator) !bool {
        if (self._address.isReserved()) return false;

        const genmem = try allocator.alloc(u8, gen_memory);
        defer allocator.free(genmem);

        var digest: [64]u8 = undefined;
        computeMemoryHardHash(&self._public_key, &digest, genmem);

        // Check hashcash condition
        if (digest[0] >= gen_hashcash_first_byte_less_than) return false;

        // Check that last 5 bytes of digest match the address
        var addr_bytes: [5]u8 = undefined;
        self._address.toBytes(&addr_bytes);

        return mem.eql(u8, digest[59..64], &addr_bytes);
    }

    // ── Cryptographic operations ──────────────────────────

    /// Return true if this identity has a private key.
    pub fn hasPrivate(self: *const Identity) bool {
        return self._has_private;
    }

    /// Compute SHA-384 hash of address + public key.
    pub fn publicKeyHash(self: *const Identity, hash_out: *[sha.sha384_digest_len]u8) void {
        var addr_bytes: [constants.address_length]u8 = undefined;
        self._address.toBytes(&addr_bytes);
        sha.sha384TwoPart(hash_out, &addr_bytes, &self._public_key);
    }

    /// Compute SHA-512 of the private key, if present.
    ///
    /// Returns `null` if no private key exists.
    pub fn sha512PrivateKey(self: *const Identity, hash_out: *[sha.sha512_digest_len]u8) ?*[sha.sha512_digest_len]u8 {
        if (!self._has_private) return null;
        sha.sha512(hash_out, &self._private_key);
        return hash_out;
    }

    /// Sign a message using Ed25519 (private key required).
    ///
    /// Returns the 96-byte ZeroTier signature, or `null` if no
    /// private key is present.
    pub fn sign(self: *const Identity, data: []const u8) ?ecc.Signature {
        if (!self._has_private) return null;
        return ecc.sign(&self._private_key, &self._public_key, data) catch return null;
    }

    /// Verify a signature against this identity's public key.
    pub fn verify(self: *const Identity, data: []const u8, signature: []const u8) bool {
        if (signature.len != ecc.signature_len) return false;
        return ecc.verify(&self._public_key, data, signature[0..ecc.signature_len]);
    }

    /// Perform ECDH key agreement with another identity.
    ///
    /// Returns false if this identity has no private key.
    /// Fixed BUG #30: Validate key_out buffer size (must be at least 32 bytes for typical usage)
    pub fn agree(self: *const Identity, other: *const Identity, key_out: []u8) bool {
        if (!self._has_private) return false;
        if (key_out.len < 32) return false; // Prevent buffer overflow
        ecc.agree(&self._private_key, &other._public_key, key_out) catch return false;
        return true;
    }

    // ── Accessors ─────────────────────────────────────────

    /// Return the address.
    pub fn address(self: *const Identity) Address {
        return self._address;
    }

    /// Return the public key.
    pub fn publicKey(self: *const Identity) *const ecc.Public {
        return &self._public_key;
    }

    /// Return true if this identity is non-empty (address is set).
    pub fn isSet(self: *const Identity) bool {
        return self._address.isSet();
    }

    // ── Comparison / equality ─────────────────────────────

    /// Two identities are equal if they have the same address AND
    /// the same public key.
    pub fn eql(self: *const Identity, other: *const Identity) bool {
        return self._address.eql(other._address) and
            mem.eql(u8, &self._public_key, &other._public_key);
    }

    pub fn order(self: *const Identity, other: *const Identity) std.math.Order {
        const addr_ord = self._address.order(other._address);
        if (addr_ord != .eq) return addr_ord;
        return mem.order(u8, &self._public_key, &other._public_key);
    }

    // ── Secure cleanup ────────────────────────────────────

    /// Securely zero private key material.
    pub fn deinit(self: *Identity) void {
        crypto.secureZero(u8, &self._private_key);
        self._has_private = false;
    }
};

// ── Memory-hard hash ──────────────────────────────────────────────

/// The generation condition context passed to `generateSatisfyingWithContext`.
const GenContext = struct {
    digest: *[64]u8,
    /// BORROWED — caller-owned 2 MiB scratch buffer.
    genmem: []u8,
};

/// Hashcash condition: compute memory-hard hash of public key and check
/// that first byte is below threshold.
fn genCondition(ctx: GenContext, kp: *const ecc.KeyPair) bool {
    computeMemoryHardHash(&kp.public_key, ctx.digest, ctx.genmem);
    return ctx.digest[0] < gen_hashcash_first_byte_less_than;
}

/// Memory-hard composition of SHA-512 and Salsa20 for hashcash.
///
/// `genmem` must be at least `gen_memory` (2 MiB) bytes. This function
/// matches the C++ `_computeMemoryHardHash` exactly.
pub fn computeMemoryHardHash(
    public_key: *const [ecc.public_key_set_len]u8,
    digest: *[64]u8,
    genmem: []u8,
) void {
    std.debug.assert(genmem.len >= gen_memory);

    // Step 1: SHA-512 the public key to get initial digest
    sha.sha512(digest, public_key);

    // Step 2: Initialize genmem using Salsa20/20 in CBC-like mode
    @memset(genmem[0..gen_memory], 0);
    var s20 = salsa20_mod.Salsa20.init(
        digest[0..32],
        digest[32..40],
    );
    s20.crypt20(genmem[0..64], genmem[0..64]);

    var i: usize = 64;
    while (i < gen_memory) : (i += 64) {
        const k = i - 64;
        // Copy previous block (CBC-like chaining)
        @memcpy(genmem[i .. i + 64], genmem[k .. k + 64]);
        // Encrypt in-place
        s20.crypt20(genmem[i .. i + 64], genmem[i .. i + 64]);
    }

    // Step 3: Render final digest using genmem as a lookup table
    const genmem_u64: [*]align(1) u64 = @ptrCast(genmem.ptr);
    const digest_u64: *align(1) [8]u64 = @ptrCast(digest);

    i = 0;
    const num_u64 = gen_memory / @sizeOf(u64);
    while (i < num_u64) {
        const raw1 = mem.bigToNative(u64, genmem_u64[i]);
        i += 1;
        const raw2 = mem.bigToNative(u64, genmem_u64[i]);
        i += 1;

        const idx1 = raw1 % (64 / @sizeOf(u64)); // mod 8
        const idx2 = raw2 % num_u64;

        // Swap digest[idx1] with genmem[idx2]
        const tmp = genmem_u64[idx2];
        genmem_u64[idx2] = digest_u64[idx1];
        digest_u64[idx1] = tmp;

        // Re-encrypt digest
        s20.crypt20(digest, digest);
    }
}

// ── Hex parsing helper ────────────────────────────────────────────

/// Parse a hex string into a u64. Returns null on invalid/empty input.
fn parseHexU64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var result: u64 = 0;
    for (s) |c| {
        const nybble: u64 = if (c >= '0' and c <= '9')
            c - '0'
        else if (c >= 'a' and c <= 'f')
            c - 'a' + 10
        else if (c >= 'A' and c <= 'F')
            c - 'A' + 10
        else
            return null;
        result = (result << 4) | nybble;
    }
    return result;
}

// ── Tests ─────────────────────────────────────────────────────────

// Known-good identity from selftest.cpp
const known_good_identity =
    "8e4df28b72:0:" ++
    "ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843" ++
    "fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7:" ++
    "bd8dd6e4ce7022d2f812797a80c6ee8ad180dc4ebf301dec8b06d1be08832bdd" ++
    "d63a2f1cfa7b2c504474c75bdc8898ba476ef92e8e2d0509f8441985171ff16e";

// Known-bad identity (first address byte changed: 8 -> 9)
const known_bad_identity =
    "9e4df28b72:0:" ++
    "ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843" ++
    "fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7:" ++
    "bd8dd6e4ce7022d2f812797a80c6ee8ad180dc4ebf301dec8b06d1be08832bdd" ++
    "d63a2f1cfa7b2c504474c75bdc8898ba476ef92e8e2d0509f8441985171ff16e";

test "Identity: init creates empty identity" {
    const id = Identity.init();
    try testing.expect(!id.isSet());
    try testing.expect(!id.hasPrivate());
}

test "Identity: fromString known-good identity" {
    const id = Identity.fromString(known_good_identity);
    try testing.expect(id != null);
    const identity = id.?;
    try testing.expect(identity.isSet());
    try testing.expect(identity.hasPrivate());
    try testing.expectEqual(@as(u64, 0x8e4df28b72), identity.address().toInt());
}

test "Identity: fromString without private key" {
    // Take the known good identity, strip the private key part
    const pub_only =
        "8e4df28b72:0:" ++
        "ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843" ++
        "fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7";
    const id = Identity.fromString(pub_only);
    try testing.expect(id != null);
    const identity = id.?;
    try testing.expect(identity.isSet());
    try testing.expect(!identity.hasPrivate());
}

test "Identity: fromString rejects invalid type" {
    const bad_type = "8e4df28b72:1:ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7";
    const id = Identity.fromString(bad_type);
    try testing.expect(id == null);
}

test "Identity: fromString rejects too few fields" {
    const too_few = "8e4df28b72:0";
    const id = Identity.fromString(too_few);
    try testing.expect(id == null);
}

test "Identity: fromString rejects reserved address" {
    // Address ff00000000 (starts with 0xff)
    const reserved = "ff00000000:0:ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7";
    const id = Identity.fromString(reserved);
    try testing.expect(id == null);
}

test "Identity: toString round-trip with private key" {
    const id = Identity.fromString(known_good_identity).?;
    var buf: [string_buffer_length]u8 = undefined;
    const str = id.toString(true, &buf);

    const id2 = Identity.fromString(str);
    try testing.expect(id2 != null);
    try testing.expect(id.eql(&id2.?));
    try testing.expect(id2.?.hasPrivate());
}

test "Identity: toString round-trip without private key" {
    const id = Identity.fromString(known_good_identity).?;
    var buf: [string_buffer_length]u8 = undefined;
    const str = id.toString(false, &buf);

    const id2 = Identity.fromString(str);
    try testing.expect(id2 != null);
    try testing.expect(id.eql(&id2.?));
    try testing.expect(!id2.?.hasPrivate());
}

test "Identity: locallyValidate known-good" {
    const id = Identity.fromString(known_good_identity).?;
    const valid = try id.locallyValidate(testing.allocator);
    try testing.expect(valid);
}

test "Identity: locallyValidate known-bad" {
    const id = Identity.fromString(known_bad_identity).?;
    const valid = try id.locallyValidate(testing.allocator);
    try testing.expect(!valid);
}

test "Identity: serialize and deserialize with private key" {
    const id = Identity.fromString(known_good_identity).?;
    var buf = Buffer(512){};
    try id.serialize(512, &buf, true);

    const result = Identity.deserialize(512, &buf, 0);
    try testing.expect(result != null);
    const id2 = result.?.identity;
    try testing.expect(id.eql(&id2));
    try testing.expect(id2.hasPrivate());
}

test "Identity: serialize and deserialize without private key" {
    const id = Identity.fromString(known_good_identity).?;
    var buf = Buffer(512){};
    try id.serialize(512, &buf, false);

    const result = Identity.deserialize(512, &buf, 0);
    try testing.expect(result != null);
    const id2 = result.?.identity;
    try testing.expect(id.eql(&id2));
    try testing.expect(!id2.hasPrivate());
}

test "Identity: sign and verify" {
    const id = Identity.fromString(known_good_identity).?;
    const message = "Hello, ZeroTier!";

    const sig = id.sign(message);
    try testing.expect(sig != null);

    // Verify against same identity's public key
    try testing.expect(id.verify(message, &sig.?));

    // Verify fails with wrong message
    try testing.expect(!id.verify("Wrong message", &sig.?));
}

test "Identity: agree produces shared secret" {
    const id1 = Identity.fromString(known_good_identity).?;

    // Create a second identity from just the public key portion
    // (we need id1 to have a private key for agreement)
    const id2_str =
        "8e4df28b72:0:" ++
        "ac3d46abe0c21f3cfe7a6c8d6a85cfcffcb82fbd55af6a4d6350657c68200843" ++
        "fa2e16f9418bbd9702cae365f2af5fb4c420908b803a681d4daef6114d78a2d7";
    const id2 = Identity.fromString(id2_str).?;

    var key: [constants.symmetric_key_size]u8 = undefined;
    try testing.expect(id1.agree(&id2, &key));

    // Key should not be all zeros
    try testing.expect(!utils.isZero(&key));
}

test "Identity: publicKeyHash produces consistent output" {
    const id = Identity.fromString(known_good_identity).?;
    var hash1: [sha.sha384_digest_len]u8 = undefined;
    var hash2: [sha.sha384_digest_len]u8 = undefined;
    id.publicKeyHash(&hash1);
    id.publicKeyHash(&hash2);
    try testing.expectEqualSlices(u8, &hash1, &hash2);
    try testing.expect(!utils.isZero(&hash1));
}

test "Identity: equality and ordering" {
    const id1 = Identity.fromString(known_good_identity).?;
    const id2 = Identity.fromString(known_good_identity).?;
    const id3 = Identity.fromString(known_bad_identity).?;

    try testing.expect(id1.eql(&id2));
    try testing.expect(!id1.eql(&id3));

    // id1 address 0x8e... < id3 address 0x9e..., so id1 < id3
    try testing.expectEqual(std.math.Order.lt, id1.order(&id3));
}

test "Identity: generate and validate" {
    const id = try Identity.generate(testing.allocator);
    try testing.expect(id.isSet());
    try testing.expect(id.hasPrivate());
    try testing.expect(!id.address().isReserved());

    const valid = try id.locallyValidate(testing.allocator);
    try testing.expect(valid);

    // toString round-trip
    var buf: [string_buffer_length]u8 = undefined;
    const str = id.toString(true, &buf);
    const id2 = Identity.fromString(str);
    try testing.expect(id2 != null);
    try testing.expect(id.eql(&id2.?));
}

test "Identity: deinit zeroes private key" {
    var id = Identity.fromString(known_good_identity).?;
    try testing.expect(id.hasPrivate());
    id.deinit();
    try testing.expect(!id.hasPrivate());
    try testing.expect(utils.isZero(&id._private_key));
}

test "parseHexU64" {
    try testing.expectEqual(@as(u64, 0x8e4df28b72), parseHexU64("8e4df28b72").?);
    try testing.expectEqual(@as(u64, 0), parseHexU64("0").?);
    try testing.expectEqual(@as(u64, 0xff), parseHexU64("ff").?);
    try testing.expect(parseHexU64("") == null);
    try testing.expect(parseHexU64("xyz") == null);
}
