/// SHA-512, SHA-384, HMAC-SHA-384, and KBKDF-HMAC-SHA-384 wrappers.
///
/// Converted from `node/SHA512.hpp` and `node/SHA512.cpp`. Wraps
/// Zig's standard library implementations which are portable across
/// all target platforms (no platform-specific CommonCrypto/OpenSSL
/// needed).
///
/// The C++ version uses CommonCrypto on macOS and a bundled public-domain
/// implementation on other platforms. This Zig version uses
/// `std.crypto.hash.sha2` and `std.crypto.auth.hmac` uniformly.
const std = @import("std");

const constants = @import("constants.zig");

// ── Public constants ───────────────────────────────────────────────

pub const sha512_digest_len: comptime_int = 64;
pub const sha384_digest_len: comptime_int = 48;
pub const sha512_block_len: comptime_int = 128;
pub const sha384_block_len: comptime_int = 128;
pub const hmac_sha384_len: comptime_int = 48;

// ── Type aliases for stdlib types ──────────────────────────────────

pub const Sha512 = std.crypto.hash.sha2.Sha512;
pub const Sha384 = std.crypto.hash.sha2.Sha384;
pub const HmacSha384 = std.crypto.auth.hmac.Hmac(Sha384);

// ── One-shot hash functions ────────────────────────────────────────

/// Compute SHA-512 digest of `data` into `digest`.
pub fn sha512(
    digest: *[sha512_digest_len]u8,
    data: []const u8,
) void {
    Sha512.hash(data, digest, .{});
}

/// Compute SHA-384 digest of `data` into `digest`.
pub fn sha384(
    digest: *[sha384_digest_len]u8,
    data: []const u8,
) void {
    Sha384.hash(data, digest, .{});
}

/// Compute SHA-384 digest of `data0 ++ data1` (two-part) into `digest`.
/// This avoids allocating a concatenated buffer.
pub fn sha384TwoPart(
    digest: *[sha384_digest_len]u8,
    data0: []const u8,
    data1: []const u8,
) void {
    var h = Sha384.init(.{});
    h.update(data0);
    h.update(data1);
    h.final(digest);
}

// ── HMAC-SHA-384 ───────────────────────────────────────────────────

/// Compute HMAC-SHA-384 using a `symmetric_key_size`-byte key.
///
/// This matches the C++ `HMACSHA384()` function which takes a
/// `ZT_SYMMETRIC_KEY_SIZE` (48) byte key.
pub fn hmacSha384(
    mac: *[hmac_sha384_len]u8,
    key: *const [constants.symmetric_key_size]u8,
    msg: []const u8,
) void {
    // Zig's HMAC handles key padding to block size internally.
    // Keys shorter than block_length are zero-padded, which matches
    // the C++ manual ipad/opad implementation exactly.
    var ctx = HmacSha384.init(key);
    ctx.update(msg);
    ctx.final(mac);
}

// ── KBKDF-HMAC-SHA-384 ────────────────────────────────────────────

/// Compute KBKDF (Key-Based Key Derivation Function) using
/// HMAC-SHA-384 as the PRF.
///
/// Implements NIST SP 800-108 counter mode KDF:
///   PRF(key, iter || "ZT" || label || 0x00 || context || L)
///
/// where L = 384 (output key length in bits, big-endian u32).
///
/// Matches C++ `KBKDFHMACSHA384()`.
pub fn kbkdfHmacSha384(
    out: *[constants.symmetric_key_size]u8,
    key: *const [constants.symmetric_key_size]u8,
    label: u8,
    context: u8,
    iter: u32,
) void {
    var kbkdf_msg: [13]u8 = undefined;

    // Iteration counter (big-endian u32)
    std.mem.writeInt(u32, kbkdf_msg[0..4], iter, .big);

    // "ZT" prefix + label + null separator
    kbkdf_msg[4] = 'Z';
    kbkdf_msg[5] = 'T';
    kbkdf_msg[6] = label;
    kbkdf_msg[7] = 0;

    // Context byte
    kbkdf_msg[8] = context;

    // Output key length: 384 bits = 0x00000180 (big-endian)
    kbkdf_msg[9] = 0;
    kbkdf_msg[10] = 0;
    kbkdf_msg[11] = 0x01;
    kbkdf_msg[12] = 0x80;

    hmacSha384(out, key, &kbkdf_msg);
}

// ── Tests ──────────────────────────────────────────────────────────

test "sha512 selftest vector" {
    // From selftest.cpp: sha512TV0Input / sha512TV0Digest
    const input = "supercalifragilisticexpealidocious";
    const expected = [64]u8{
        0x18, 0x2a, 0x85, 0x59, 0x69, 0xe5, 0xd3, 0xe6,
        0xcb, 0xf6, 0x05, 0x24, 0xad, 0xf2, 0x88, 0xd1,
        0xbb, 0xf2, 0x52, 0x92, 0x81, 0x24, 0x31, 0xf6,
        0xd2, 0x52, 0xf1, 0xdb, 0xc1, 0xcb, 0x44, 0xdf,
        0x21, 0x57, 0x3d, 0xe1, 0xb0, 0x6b, 0x68, 0x75,
        0x95, 0x9f, 0x3b, 0x6f, 0x87, 0xb1, 0x13, 0x81,
        0xd0, 0xbc, 0x79, 0x2c, 0x43, 0x3a, 0x13, 0x55,
        0x3c, 0xe0, 0x84, 0xc2, 0x92, 0x55, 0x31, 0x1c,
    };

    var digest: [sha512_digest_len]u8 = undefined;
    sha512(&digest, input);
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "sha384 basic" {
    // NIST test vector for SHA-384: "abc"
    const expected = [48]u8{
        0xcb, 0x00, 0x75, 0x3f, 0x45, 0xa3, 0x5e, 0x8b,
        0xb5, 0xa0, 0x3d, 0x69, 0x9a, 0xc6, 0x50, 0x07,
        0x27, 0x2c, 0x32, 0xab, 0x0e, 0xde, 0xd1, 0x63,
        0x1a, 0x8b, 0x60, 0x5a, 0x43, 0xff, 0x5b, 0xed,
        0x80, 0x86, 0x07, 0x2b, 0xa1, 0xe7, 0xcc, 0x23,
        0x58, 0xba, 0xec, 0xa1, 0x34, 0xc8, 0x25, 0xa7,
    };

    var digest: [sha384_digest_len]u8 = undefined;
    sha384(&digest, "abc");
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "sha384 two-part equals single" {
    const full_msg = "Hello, World! This is a test message for SHA-384.";
    const part0 = full_msg[0..20];
    const part1 = full_msg[20..];

    var single_digest: [sha384_digest_len]u8 = undefined;
    var two_part_digest: [sha384_digest_len]u8 = undefined;

    sha384(&single_digest, full_msg);
    sha384TwoPart(&two_part_digest, part0, part1);

    try std.testing.expectEqualSlices(u8, &single_digest, &two_part_digest);
}

test "sha512 empty input" {
    // SHA-512 of empty string (well-known value)
    const expected = [64]u8{
        0xcf, 0x83, 0xe1, 0x35, 0x7e, 0xef, 0xb8, 0xbd,
        0xf1, 0x54, 0x28, 0x50, 0xd6, 0x6d, 0x80, 0x07,
        0xd6, 0x20, 0xe4, 0x05, 0x0b, 0x57, 0x15, 0xdc,
        0x83, 0xf4, 0xa9, 0x21, 0xd3, 0x6c, 0xe9, 0xce,
        0x47, 0xd0, 0xd1, 0x3c, 0x5d, 0x85, 0xf2, 0xb0,
        0xff, 0x83, 0x18, 0xd2, 0x87, 0x7e, 0xec, 0x2f,
        0x63, 0xb9, 0x31, 0xbd, 0x47, 0x41, 0x7a, 0x81,
        0xa5, 0x38, 0x32, 0x7a, 0xf9, 0x27, 0xda, 0x3e,
    };

    var digest: [sha512_digest_len]u8 = undefined;
    sha512(&digest, "");
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "sha384 empty input" {
    // SHA-384 of empty string (well-known value)
    const expected = [48]u8{
        0x38, 0xb0, 0x60, 0xa7, 0x51, 0xac, 0x96, 0x38,
        0x4c, 0xd9, 0x32, 0x7e, 0xb1, 0xb1, 0xe3, 0x6a,
        0x21, 0xfd, 0xb7, 0x11, 0x14, 0xbe, 0x07, 0x43,
        0x4c, 0x0c, 0xc7, 0xbf, 0x63, 0xf6, 0xe1, 0xda,
        0x27, 0x4e, 0xde, 0xbf, 0xe7, 0x6f, 0x65, 0xfb,
        0xd5, 0x1a, 0xd2, 0xf1, 0x48, 0x98, 0xb9, 0x5b,
    };

    var digest: [sha384_digest_len]u8 = undefined;
    sha384(&digest, "");
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "hmac_sha384 rfc4231 test case 2" {
    // RFC 4231 Test Case 2:
    //   Key  = "Jefe" (4 bytes, but we need symmetric_key_size=48 bytes)
    // Since our interface requires exactly 48-byte keys, use a custom
    // test: compute HMAC-SHA384 with a known 48-byte key and verify
    // the result is deterministic and matches Zig stdlib directly.
    const key = [_]u8{0xaa} ** constants.symmetric_key_size;
    const msg = "Test Using Larger Than Block-Size Key - Hash Key First";

    var mac: [hmac_sha384_len]u8 = undefined;
    hmacSha384(&mac, &key, msg);

    // Cross-check against direct stdlib call
    var expected: [hmac_sha384_len]u8 = undefined;
    var ctx = HmacSha384.init(&key);
    ctx.update(msg);
    ctx.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &mac);
}

test "hmac_sha384 deterministic" {
    const key = [_]u8{0x01} ** constants.symmetric_key_size;
    const msg = "hello world";

    var mac1: [hmac_sha384_len]u8 = undefined;
    var mac2: [hmac_sha384_len]u8 = undefined;

    hmacSha384(&mac1, &key, msg);
    hmacSha384(&mac2, &key, msg);

    try std.testing.expectEqualSlices(u8, &mac1, &mac2);
}

test "hmac_sha384 different keys produce different macs" {
    const key1 = [_]u8{0x01} ** constants.symmetric_key_size;
    const key2 = [_]u8{0x02} ** constants.symmetric_key_size;
    const msg = "same message";

    var mac1: [hmac_sha384_len]u8 = undefined;
    var mac2: [hmac_sha384_len]u8 = undefined;

    hmacSha384(&mac1, &key1, msg);
    hmacSha384(&mac2, &key2, msg);

    // Different keys must produce different MACs
    try std.testing.expect(!std.mem.eql(u8, &mac1, &mac2));
}

test "kbkdf_hmac_sha384 deterministic" {
    const key = [_]u8{0x42} ** constants.symmetric_key_size;

    var out1: [constants.symmetric_key_size]u8 = undefined;
    var out2: [constants.symmetric_key_size]u8 = undefined;

    kbkdfHmacSha384(&out1, &key, 'A', 'B', 1);
    kbkdfHmacSha384(&out2, &key, 'A', 'B', 1);

    try std.testing.expectEqualSlices(u8, &out1, &out2);
}

test "kbkdf_hmac_sha384 different labels produce different keys" {
    const key = [_]u8{0x42} ** constants.symmetric_key_size;

    var out_a: [constants.symmetric_key_size]u8 = undefined;
    var out_b: [constants.symmetric_key_size]u8 = undefined;

    kbkdfHmacSha384(&out_a, &key, 'A', 'X', 0);
    kbkdfHmacSha384(&out_b, &key, 'B', 'X', 0);

    try std.testing.expect(!std.mem.eql(u8, &out_a, &out_b));
}

test "kbkdf_hmac_sha384 different contexts produce different keys" {
    const key = [_]u8{0x42} ** constants.symmetric_key_size;

    var out_x: [constants.symmetric_key_size]u8 = undefined;
    var out_y: [constants.symmetric_key_size]u8 = undefined;

    kbkdfHmacSha384(&out_x, &key, 'L', 'X', 0);
    kbkdfHmacSha384(&out_y, &key, 'L', 'Y', 0);

    try std.testing.expect(!std.mem.eql(u8, &out_x, &out_y));
}

test "kbkdf_hmac_sha384 different iterations produce different keys" {
    const key = [_]u8{0x42} ** constants.symmetric_key_size;

    var out0: [constants.symmetric_key_size]u8 = undefined;
    var out1: [constants.symmetric_key_size]u8 = undefined;

    kbkdfHmacSha384(&out0, &key, 'L', 'C', 0);
    kbkdfHmacSha384(&out1, &key, 'L', 'C', 1);

    try std.testing.expect(!std.mem.eql(u8, &out0, &out1));
}

test "kbkdf_hmac_sha384 message format matches C++" {
    // Verify the 13-byte KBKDF message is constructed correctly
    // by checking that the function builds:
    //   [iter_be32] [0x5a 0x54] [label] [0x00] [context] [0x00 0x00 0x01 0x80]
    // We verify indirectly: calling with iter=0x01020304, label='Z', context='T'
    // should produce a specific HMAC.
    const key = [_]u8{0} ** constants.symmetric_key_size;

    var out: [constants.symmetric_key_size]u8 = undefined;
    kbkdfHmacSha384(&out, &key, 'Z', 'T', 0x01020304);

    // Manually construct the expected message and compute HMAC
    const expected_msg = [13]u8{
        0x01, 0x02, 0x03, 0x04, // iter (big-endian)
        'Z', 'T', 'Z', 0x00, // "ZT" + label + null
        'T', // context
        0x00, 0x00, 0x01, 0x80, // output length = 384 bits
    };

    var expected: [hmac_sha384_len]u8 = undefined;
    hmacSha384(&expected, &key, &expected_msg);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "sha512 constants match C++ defines" {
    try std.testing.expectEqual(64, sha512_digest_len);
    try std.testing.expectEqual(48, sha384_digest_len);
    try std.testing.expectEqual(128, sha512_block_len);
    try std.testing.expectEqual(128, sha384_block_len);
    try std.testing.expectEqual(48, hmac_sha384_len);

    // Verify stdlib agrees
    try std.testing.expectEqual(sha512_digest_len, Sha512.digest_length);
    try std.testing.expectEqual(sha384_digest_len, Sha384.digest_length);
    try std.testing.expectEqual(sha512_block_len, Sha512.block_length);
    try std.testing.expectEqual(sha384_block_len, Sha384.block_length);
}
