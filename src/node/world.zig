/// A world definition (planet or moon) — root topology for a ZeroTier network.
///
/// Converted from `node/World.hpp`. A World is a signed collection of root
/// servers and their stable endpoints. Updates are authenticated by verifying
/// the Ed25519 signature against the current `updatesMustBeSignedBy` public
/// key.
///
/// Think of a World as a single data center. ZeroTier operates one planet
/// (Earth) with ID 149604618 and users can create moons (user-defined root
/// sets).
///
/// No heap allocation. This is a value type with fixed-capacity arrays.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Buffer = @import("buffer.zig").Buffer;
const ecc = @import("ecc.zig");
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;

// ── Constants ──────────────────────────────────────────────────────

/// Maximum number of roots (sanity limit).
pub const max_roots: u32 = 4;

/// Maximum number of stable endpoints per root (sanity limit).
pub const max_stable_endpoints_per_root: u32 = 32;

/// The (more than) maximum length of a serialized World.
pub const max_serialized_length: u32 =
    ((1024 + (32 * max_stable_endpoints_per_root)) * max_roots) +
    ecc.public_key_set_len + ecc.signature_len + 128;

/// World ID for Earth — ZeroTier's planet (~149.6M km from the sun).
pub const id_earth: u64 = 149604618;

/// World ID for Mars — reserved for future use.
pub const id_mars: u64 = 227883110;

/// ForSign start sentinel.
const for_sign_start_sentinel: u64 = 0x7f7f7f7f7f7f7f7f;

/// ForSign end sentinel — NOTE: different from credential sentinels.
const for_sign_end_sentinel: u64 = 0xf7f7f7f7f7f7f7f7;

// ── World Type ─────────────────────────────────────────────────────

/// World type identifiers (do not change IDs).
pub const Type = enum(u8) {
    null = 0,
    planet = 1,
    moon = 127,
};

// ── Root ───────────────────────────────────────────────────────────

/// Upstream server definition in a world/moon.
pub const Root = struct {
    identity: Identity,
    stable_endpoints: [max_stable_endpoints_per_root]InetAddress,
    endpoint_count: u32,

    /// Create a zero/empty root.
    pub fn init() Root {
        return .{
            .identity = Identity.init(),
            .stable_endpoints = [_]InetAddress{InetAddress.zero()} ** max_stable_endpoints_per_root,
            .endpoint_count = 0,
        };
    }

    /// Check equality with another root.
    pub fn eql(self: *const Root, other: *const Root) bool {
        if (!self.identity.eql(&other.identity)) return false;
        if (self.endpoint_count != other.endpoint_count) return false;
        for (0..self.endpoint_count) |i| {
            if (!self.stable_endpoints[i].eql(&other.stable_endpoints[i])) return false;
        }
        return true;
    }

    /// Compare for sorting by identity.
    pub fn lessThan(_: void, a: Root, b: Root) bool {
        return a.identity.order(&b.identity) == .lt;
    }
};

// ── World ──────────────────────────────────────────────────────────

pub const World = struct {
    _id: u64,
    _ts: u64,
    _type: Type,
    _updates_must_be_signed_by: ecc.Public,
    _signature: ecc.Signature,
    _roots: [max_roots]Root,
    _root_count: u32,

    // ── Constructors ──────────────────────────────────────

    /// Create an empty/null World.
    pub fn init() World {
        return .{
            ._id = 0,
            ._ts = 0,
            ._type = .null,
            ._updates_must_be_signed_by = [_]u8{0} ** ecc.public_key_set_len,
            ._signature = [_]u8{0} ** ecc.signature_len,
            ._roots = [_]Root{Root.init()} ** max_roots,
            ._root_count = 0,
        };
    }

    // ── Accessors ─────────────────────────────────────────

    /// Root servers for this world and their stable endpoints.
    pub fn roots(self: *const World) []const Root {
        return self._roots[0..self._root_count];
    }

    /// World type: planet, moon, or null.
    pub fn worldType(self: *const World) Type {
        return self._type;
    }

    /// World unique identifier.
    pub fn id(self: *const World) u64 {
        return self._id;
    }

    /// World definition timestamp.
    pub fn timestamp(self: *const World) u64 {
        return self._ts;
    }

    /// Ed25519 signature of this world definition.
    pub fn signature(self: *const World) *const ecc.Signature {
        return &self._signature;
    }

    /// Public key that must sign the next update.
    pub fn updatesMustBeSignedBy(self: *const World) *const ecc.Public {
        return &self._updates_must_be_signed_by;
    }

    /// True if this World is non-null (has a type and ID).
    pub fn isSet(self: *const World) bool {
        return self._type != .null;
    }

    // ── Update logic ──────────────────────────────────────

    /// Check whether a world update should replace this one.
    ///
    /// Returns true if:
    ///   - This world is null/empty, OR
    ///   - The update has the same ID and type, a newer timestamp,
    ///     and a valid signature from our current signing key.
    pub fn shouldBeReplacedBy(self: *const World, update: *const World) bool {
        if (self._id == 0 or self._type == .null) {
            return true;
        }
        if (self._id == update._id and
            self._ts < update._ts and
            @intFromEnum(self._type) == @intFromEnum(update._type))
        {
            var tmp = Buffer(max_serialized_length){};
            update.serialize(max_serialized_length, &tmp, true) catch return false;
            return ecc.verify(
                &self._updates_must_be_signed_by,
                tmp.data(),
                &update._signature,
            );
        }
        return false;
    }

    // ── Equality ──────────────────────────────────────────

    /// Check equality with another World.
    pub fn eql(self: *const World, other: *const World) bool {
        if (self._id != other._id) return false;
        if (self._ts != other._ts) return false;
        if (!mem.eql(u8, &self._updates_must_be_signed_by, &other._updates_must_be_signed_by)) return false;
        if (!mem.eql(u8, &self._signature, &other._signature)) return false;
        if (self._type != other._type) return false;
        if (self._root_count != other._root_count) return false;
        for (0..self._root_count) |i| {
            if (!self._roots[i].eql(&other._roots[i])) return false;
        }
        return true;
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize this World to a buffer.
    ///
    /// If `for_sign` is true, wraps the content in start/end sentinels
    /// and omits the signature (for signature verification).
    pub fn serialize(self: *const World, comptime C: u32, buf: *Buffer(C), for_sign: bool) Buffer(C).Error!void {
        if (for_sign) {
            try buf.appendInt(u64, for_sign_start_sentinel);
        }

        try buf.appendInt(u8, @intFromEnum(self._type));
        try buf.appendInt(u64, self._id);
        try buf.appendInt(u64, self._ts);
        try buf.appendBytes(&self._updates_must_be_signed_by);
        if (!for_sign) {
            try buf.appendBytes(&self._signature);
        }

        try buf.appendInt(u8, @intCast(self._root_count));
        for (0..self._root_count) |i| {
            try self._roots[i].identity.serialize(C, buf, false);
            try buf.appendInt(u8, @intCast(self._roots[i].endpoint_count));
            for (0..self._roots[i].endpoint_count) |j| {
                try self._roots[i].stable_endpoints[j].serialize(C, buf);
            }
        }

        if (self._type == .moon) {
            try buf.appendInt(u16, 0); // no attached dictionary (for future use)
        }

        if (for_sign) {
            try buf.appendInt(u64, for_sign_end_sentinel);
        }
    }

    /// Deserialize a World from a buffer starting at `start_at`.
    ///
    /// Returns the number of bytes consumed.
    pub fn deserialize(self: *World, comptime C: u32, buf: *const Buffer(C), start_at: u32) Buffer(C).Error!u32 {
        var p = start_at;

        self._roots = [_]Root{Root.init()} ** max_roots;
        self._root_count = 0;

        const type_byte = try buf.getByte(p);
        p += 1;

        self._type = switch (type_byte) {
            0 => .null,
            1 => .planet,
            127 => .moon,
            else => return error.OutOfBounds, // invalid type
        };

        self._id = try buf.at(u64, p);
        p += 8;
        self._ts = try buf.at(u64, p);
        p += 8;

        const pub_bytes = try buf.field(p, ecc.public_key_set_len);
        @memcpy(&self._updates_must_be_signed_by, pub_bytes);
        p += ecc.public_key_set_len;

        const sig_bytes = try buf.field(p, ecc.signature_len);
        @memcpy(&self._signature, sig_bytes);
        p += ecc.signature_len;

        const num_roots = try buf.getByte(p);
        p += 1;
        if (num_roots > max_roots) return error.OutOfBounds;

        for (0..num_roots) |k| {
            var root = Root.init();
            const id_result = Identity.deserialize(C, buf, p) orelse return error.OutOfBounds;
            root.identity = id_result.identity;
            p += id_result.bytes_read;

            const num_eps = try buf.getByte(p);
            p += 1;
            if (num_eps > max_stable_endpoints_per_root) return error.OutOfBounds;

            for (0..num_eps) |j| {
                const ep_consumed = try root.stable_endpoints[j].deserialize(C, buf, p);
                p += ep_consumed;
            }
            root.endpoint_count = num_eps;
            self._roots[k] = root;
        }
        self._root_count = num_roots;

        if (self._type == .moon) {
            const dict_len = try buf.at(u16, p);
            p += @as(u32, dict_len) + 2;
        }

        return p - start_at;
    }

    // ── Factory ───────────────────────────────────────────

    /// Create a signed World object.
    ///
    /// `sk` is the public key that must sign the next future update.
    /// `sign_with` is the key pair used to sign this World.
    pub fn make(
        world_type: Type,
        world_id: u64,
        ts: u64,
        sk: *const ecc.Public,
        world_roots: []const Root,
        sign_with: *const ecc.KeyPair,
    ) World {
        var w = World.init();
        w._id = world_id;
        w._ts = ts;
        w._type = world_type;
        w._updates_must_be_signed_by = sk.*;

        const count = @min(@as(u32, @intCast(world_roots.len)), max_roots);
        for (0..count) |i| {
            w._roots[i] = world_roots[i];
        }
        w._root_count = count;

        var tmp = Buffer(max_serialized_length){};
        w.serialize(max_serialized_length, &tmp, true) catch return w;
        w._signature = ecc.sign(&sign_with.private_key, &sign_with.public_key, tmp.data()) catch return w;
        return w;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "World: init creates null world" {
    const w = World.init();
    try testing.expect(!w.isSet());
    try testing.expectEqual(Type.null, w.worldType());
    try testing.expectEqual(@as(u64, 0), w.id());
    try testing.expectEqual(@as(u64, 0), w.timestamp());
    try testing.expectEqual(@as(usize, 0), w.roots().len);
}

test "World: Root init creates empty root" {
    const r = Root.init();
    try testing.expectEqual(@as(u32, 0), r.endpoint_count);
    try testing.expect(!r.identity.isSet());
}

test "World: Root equality" {
    const r1 = Root.init();
    const r2 = Root.init();
    try testing.expect(r1.eql(&r2));
}

test "World: serialize/deserialize round-trip null world" {
    const w = World.init();
    var buf = Buffer(max_serialized_length){};
    try w.serialize(max_serialized_length, &buf, false);

    var w2 = World.init();
    _ = try w2.deserialize(max_serialized_length, &buf, 0);

    try testing.expect(w.eql(&w2));
}

test "World: serialize/deserialize round-trip planet" {
    // Create a planet world with a root server
    var w = World.init();
    w._type = .planet;
    w._id = id_earth;
    w._ts = 1234567890;

    // Fill in some dummy key bytes for the signing key
    for (&w._updates_must_be_signed_by, 0..) |*b, i| {
        b.* = @intCast(i & 0xff);
    }

    // Fill signature with pattern
    for (&w._signature, 0..) |*b, i| {
        b.* = @intCast((i + 17) & 0xff);
    }

    // Serialize
    var buf = Buffer(max_serialized_length){};
    try w.serialize(max_serialized_length, &buf, false);

    // Deserialize
    var w2 = World.init();
    const consumed = try w2.deserialize(max_serialized_length, &buf, 0);

    try testing.expect(consumed > 0);
    try testing.expect(w.eql(&w2));
    try testing.expectEqual(Type.planet, w2.worldType());
    try testing.expectEqual(id_earth, w2.id());
    try testing.expectEqual(@as(u64, 1234567890), w2.timestamp());
    try testing.expect(w2.isSet());
}

test "World: serialize/deserialize round-trip moon with dict" {
    var w = World.init();
    w._type = .moon;
    w._id = 42;
    w._ts = 100;

    var buf = Buffer(max_serialized_length){};
    try w.serialize(max_serialized_length, &buf, false);

    var w2 = World.init();
    _ = try w2.deserialize(max_serialized_length, &buf, 0);

    try testing.expectEqual(Type.moon, w2.worldType());
    try testing.expectEqual(@as(u64, 42), w2.id());
}

test "World: forSign serialization includes sentinels" {
    var w = World.init();
    w._type = .planet;
    w._id = 1;
    w._ts = 2;

    // forSign = true
    var buf_sign = Buffer(max_serialized_length){};
    try w.serialize(max_serialized_length, &buf_sign, true);

    // forSign = false
    var buf_normal = Buffer(max_serialized_length){};
    try w.serialize(max_serialized_length, &buf_normal, false);

    // forSign version should have 8 bytes start sentinel + 8 bytes end sentinel
    // but no signature (96 bytes less), so the difference is:
    // +16 (sentinels) - 96 (no signature) = -80
    const sign_size = buf_sign.size();
    const normal_size = buf_normal.size();
    try testing.expect(sign_size + 80 == normal_size);

    // Check start sentinel
    const start_val = try buf_sign.at(u64, 0);
    try testing.expectEqual(for_sign_start_sentinel, start_val);

    // Check end sentinel is the last 8 bytes
    const end_val = try buf_sign.at(u64, sign_size - 8);
    try testing.expectEqual(for_sign_end_sentinel, end_val);
}

test "World: make creates signed world" {
    const kp = ecc.generate() catch return;
    var sk: ecc.Public = undefined;
    sk = kp.public_key;

    var root = Root.init();
    // Use the same identity for simplicity in test
    root.identity = Identity.init();
    root.stable_endpoints[0] = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    root.endpoint_count = 1;

    const world_roots = [_]Root{root};
    const w = World.make(.planet, id_earth, 1000, &sk, &world_roots, &kp);

    try testing.expect(w.isSet());
    try testing.expectEqual(Type.planet, w.worldType());
    try testing.expectEqual(id_earth, w.id());
    try testing.expectEqual(@as(u64, 1000), w.timestamp());
    try testing.expectEqual(@as(usize, 1), w.roots().len);

    // Signature should be non-zero
    var all_zero = true;
    for (w._signature) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "World: shouldBeReplacedBy — null world accepts any update" {
    const w = World.init();
    var update = World.init();
    update._type = .planet;
    update._id = 1;
    try testing.expect(w.shouldBeReplacedBy(&update));
}

test "World: shouldBeReplacedBy — different ID rejected" {
    var w = World.init();
    w._type = .planet;
    w._id = 1;
    w._ts = 100;

    var update = World.init();
    update._type = .planet;
    update._id = 2; // different ID
    update._ts = 200;

    try testing.expect(!w.shouldBeReplacedBy(&update));
}

test "World: shouldBeReplacedBy — older timestamp rejected" {
    var w = World.init();
    w._type = .planet;
    w._id = 1;
    w._ts = 200;

    var update = World.init();
    update._type = .planet;
    update._id = 1;
    update._ts = 100; // older

    try testing.expect(!w.shouldBeReplacedBy(&update));
}

test "World: shouldBeReplacedBy — properly signed update accepted" {
    const kp = ecc.generate() catch return;

    var root = Root.init();
    root.stable_endpoints[0] = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    root.endpoint_count = 1;

    const world_roots = [_]Root{root};

    // Create original world
    const w1 = World.make(.planet, id_earth, 1000, &kp.public_key, &world_roots, &kp);

    // Create updated world (same signing key, newer timestamp)
    const w2 = World.make(.planet, id_earth, 2000, &kp.public_key, &world_roots, &kp);

    try testing.expect(w1.shouldBeReplacedBy(&w2));
}

test "World: equality" {
    var w1 = World.init();
    w1._type = .planet;
    w1._id = id_earth;
    w1._ts = 100;

    var w2 = World.init();
    w2._type = .planet;
    w2._id = id_earth;
    w2._ts = 100;

    try testing.expect(w1.eql(&w2));

    w2._ts = 200;
    try testing.expect(!w1.eql(&w2));
}

test "World: constants match C++ defines" {
    try testing.expectEqual(@as(u32, 4), max_roots);
    try testing.expectEqual(@as(u32, 32), max_stable_endpoints_per_root);
    try testing.expectEqual(@as(u64, 149604618), id_earth);
    try testing.expectEqual(@as(u64, 227883110), id_mars);
}
