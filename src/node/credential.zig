/// Credential type identifiers used in the ZeroTier protocol.
///
/// Converted from `node/Credential.hpp`. These type codes are part of the
/// wire protocol (used in Revocation objects and elsewhere) and MUST NOT
/// be changed.
const std = @import("std");

/// Credential type codes. Values are fixed by the wire protocol.
/// Note: value 5 is intentionally skipped (historical gap).
pub const Type = enum(u8) {
    null = 0,
    /// CertificateOfMembership
    com = 1,
    capability = 2,
    tag = 3,
    /// CertificateOfOwnership
    coo = 4,
    // 5 is intentionally absent (historical gap in the protocol)
    revocation = 6,

    /// Return the raw integer value for wire serialization.
    pub fn toInt(self: Type) u8 {
        return @intFromEnum(self);
    }

    /// Parse from a raw integer, returning null for unknown values.
    pub fn fromInt(v: u8) ?Type {
        return std.meta.intToEnum(Type, v) catch null;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "type code values match C++ originals" {
    try std.testing.expectEqual(@as(u8, 0), Type.null.toInt());
    try std.testing.expectEqual(@as(u8, 1), Type.com.toInt());
    try std.testing.expectEqual(@as(u8, 2), Type.capability.toInt());
    try std.testing.expectEqual(@as(u8, 3), Type.tag.toInt());
    try std.testing.expectEqual(@as(u8, 4), Type.coo.toInt());
    try std.testing.expectEqual(@as(u8, 6), Type.revocation.toInt());
}

test "fromInt round-trips valid values" {
    try std.testing.expectEqual(Type.null, Type.fromInt(0).?);
    try std.testing.expectEqual(Type.com, Type.fromInt(1).?);
    try std.testing.expectEqual(Type.capability, Type.fromInt(2).?);
    try std.testing.expectEqual(Type.tag, Type.fromInt(3).?);
    try std.testing.expectEqual(Type.coo, Type.fromInt(4).?);
    try std.testing.expectEqual(Type.revocation, Type.fromInt(6).?);
}

test "fromInt returns null for unknown values" {
    try std.testing.expect(Type.fromInt(5) == null);
    try std.testing.expect(Type.fromInt(7) == null);
    try std.testing.expect(Type.fromInt(255) == null);
}
