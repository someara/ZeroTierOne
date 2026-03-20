/// Poly1305 one-time message authentication code.
///
/// Converted from `node/Poly1305.hpp` and `node/Poly1305.cpp`. Wraps
/// Zig's standard library `std.crypto.onetimeauth.Poly1305` which
/// implements the same DJB Poly1305-donna algorithm as the C++ code.
///
/// Poly1305 takes a one-time-use 32-byte key and produces a 16-byte
/// message authentication code. The key MUST NOT be reused for
/// different messages. In ZeroTier's protocol, the first 32 bytes of
/// the Salsa20/12 keystream serve as the one-time key.
const std = @import("std");

// ── Public constants ───────────────────────────────────────────────

pub const key_len: comptime_int = 32;
pub const mac_len: comptime_int = 16;

// ── Type alias for stdlib type ─────────────────────────────────────

pub const Poly1305 = std.crypto.onetimeauth.Poly1305;

// ── One-shot computation ───────────────────────────────────────────

/// Compute a Poly1305 authentication tag.
///
/// `auth` receives the 16-byte MAC.
/// `data` is the message to authenticate.
/// `key` is a 32-byte one-time-use key (must not be reused).
pub fn compute(
    auth: *[mac_len]u8,
    data: []const u8,
    key: *const [key_len]u8,
) void {
    Poly1305.create(auth, data, key);
}

// ── Tests ──────────────────────────────────────────────────────────

test "selftest vector 0: 32 zero bytes" {
    // From selftest.cpp: poly1305TV0Input / poly1305TV0Key / poly1305TV0Tag
    const input = [_]u8{0} ** 32;
    // Key = "this is 32-byte key for Poly1305"
    const key = [32]u8{
        0x74, 0x68, 0x69, 0x73, 0x20, 0x69, 0x73, 0x20,
        0x33, 0x32, 0x2d, 0x62, 0x79, 0x74, 0x65, 0x20,
        0x6b, 0x65, 0x79, 0x20, 0x66, 0x6f, 0x72, 0x20,
        0x50, 0x6f, 0x6c, 0x79, 0x31, 0x33, 0x30, 0x35,
    };
    const expected = [16]u8{
        0x49, 0xec, 0x78, 0x09, 0x0e, 0x48, 0x1e, 0xc6,
        0xc2, 0x6b, 0x33, 0xb9, 0x1c, 0xcc, 0x03, 0x07,
    };

    var mac: [mac_len]u8 = undefined;
    compute(&mac, &input, &key);
    try std.testing.expectEqualSlices(u8, &expected, &mac);
}

test "selftest vector 1: Hello world!" {
    // From selftest.cpp: poly1305TV1Input / poly1305TV1Key / poly1305TV1Tag
    const input = [12]u8{
        0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20,
        0x77, 0x6f, 0x72, 0x6c, 0x64, 0x21,
    };
    // Same key as TV0
    const key = [32]u8{
        0x74, 0x68, 0x69, 0x73, 0x20, 0x69, 0x73, 0x20,
        0x33, 0x32, 0x2d, 0x62, 0x79, 0x74, 0x65, 0x20,
        0x6b, 0x65, 0x79, 0x20, 0x66, 0x6f, 0x72, 0x20,
        0x50, 0x6f, 0x6c, 0x79, 0x31, 0x33, 0x30, 0x35,
    };
    const expected = [16]u8{
        0xa6, 0xf7, 0x45, 0x00, 0x8f, 0x81, 0xc9, 0x16,
        0xa2, 0x0d, 0xcc, 0x74, 0xee, 0xf2, 0xb2, 0xf0,
    };

    var mac: [mac_len]u8 = undefined;
    compute(&mac, &input, &key);
    try std.testing.expectEqualSlices(u8, &expected, &mac);
}

test "empty message" {
    const key = [_]u8{0x42} ** 32;

    var mac: [mac_len]u8 = undefined;
    compute(&mac, &[_]u8{}, &key);

    // Must produce a valid (non-zero for this key) tag
    // Cross-check with stdlib directly
    var expected: [mac_len]u8 = undefined;
    Poly1305.create(&expected, &[_]u8{}, &key);
    try std.testing.expectEqualSlices(u8, &expected, &mac);
}

test "deterministic output" {
    const key = [_]u8{0x01} ** 32;
    const msg = "test message for poly1305";

    var mac1: [mac_len]u8 = undefined;
    var mac2: [mac_len]u8 = undefined;

    compute(&mac1, msg, &key);
    compute(&mac2, msg, &key);

    try std.testing.expectEqualSlices(u8, &mac1, &mac2);
}

test "different keys produce different tags" {
    const key1 = [_]u8{0x01} ** 32;
    const key2 = [_]u8{0x02} ** 32;
    const msg = "same message";

    var mac1: [mac_len]u8 = undefined;
    var mac2: [mac_len]u8 = undefined;

    compute(&mac1, msg, &key1);
    compute(&mac2, msg, &key2);

    try std.testing.expect(!std.mem.eql(u8, &mac1, &mac2));
}

test "different messages produce different tags" {
    const key = [_]u8{0x01} ** 32;

    var mac1: [mac_len]u8 = undefined;
    var mac2: [mac_len]u8 = undefined;

    compute(&mac1, "message one", &key);
    compute(&mac2, "message two", &key);

    try std.testing.expect(!std.mem.eql(u8, &mac1, &mac2));
}

test "constants match C++ defines" {
    try std.testing.expectEqual(32, key_len);
    try std.testing.expectEqual(16, mac_len);
    try std.testing.expectEqual(mac_len, Poly1305.mac_length);
    try std.testing.expectEqual(key_len, Poly1305.key_length);
}

test "streaming API matches one-shot" {
    // Verify that using the streaming interface produces the same
    // result as the one-shot compute(), since Packet.cpp may
    // eventually need streaming.
    const key = [_]u8{0xab} ** 32;
    const msg = "Hello, this is a longer message for streaming test purposes.";

    var oneshot_mac: [mac_len]u8 = undefined;
    compute(&oneshot_mac, msg, &key);

    // Streaming: feed in chunks
    var ctx = Poly1305.init(&key);
    ctx.update(msg[0..20]);
    ctx.update(msg[20..40]);
    ctx.update(msg[40..]);
    var streaming_mac: [mac_len]u8 = undefined;
    ctx.final(&streaming_mac);

    try std.testing.expectEqualSlices(u8, &oneshot_mac, &streaming_mac);
}
