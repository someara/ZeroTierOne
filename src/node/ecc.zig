/// Elliptic curve cryptography for ZeroTier V1 identity and key agreement.
///
/// Converted from `node/ECC.hpp` and `node/ECC.cpp`. Uses Zig standard
/// library implementations of X25519 (Curve25519 ECDH) and Edwards25519
/// (Ed25519 signing) instead of the bundled NaCl/SUPERCOP C implementation.
///
/// ZeroTier uses a dual-key scheme:
///   - Bytes  0..31 of the key pair: C25519 (X25519) ECDH key agreement
///   - Bytes 32..63 of the key pair: Ed25519 signing / verification
///
/// The signing scheme is a modified Ed25519 that signs SHA-512(message)[0..32]
/// instead of the raw message, producing a 96-byte signature:
///   - Bytes  0..31: R (encoded curve point, nonce commitment)
///   - Bytes 32..63: S (scalar, proves knowledge of private key)
///   - Bytes 64..95: SHA-512(message)[0..32] (message integrity hash)
const std = @import("std");

const sha = @import("sha512.zig");
const utils = @import("utils.zig");

const Edwards25519 = std.crypto.ecc.Edwards25519;
const X25519 = std.crypto.dh.X25519;
const scalar = Edwards25519.scalar;

// ── Public types ───────────────────────────────────────────────────

/// Combined C25519 + Ed25519 public key (64 bytes).
///   [0..32]  = X25519 ECDH public key
///   [32..64] = Ed25519 signing public key
pub const Public = [64]u8;

/// Combined C25519 + Ed25519 private key (64 bytes).
///   [0..32]  = X25519 ECDH private key
///   [32..64] = Ed25519 signing private key (seed)
pub const Private = [64]u8;

/// Ed25519 signature with appended message hash (96 bytes).
///   [0..32]  = R (nonce commitment point)
///   [32..64] = S (signature scalar)
///   [64..96] = SHA-512(message)[0..32]
pub const Signature = [96]u8;

/// A key pair containing both public and private keys.
pub const KeyPair = struct {
    public_key: Public,
    private_key: Private,
};

// ── Size constants matching C++ defines ────────────────────────────

pub const public_key_set_len: comptime_int = 64;
pub const private_key_set_len: comptime_int = 64;
pub const signature_len: comptime_int = 96;
pub const ephemeral_public_key_len: comptime_int = 32;

// ── Public functions ───────────────────────────────────────────────

/// Generate a random ECC key pair.
///
/// Fills private key with 64 random bytes, then derives both public
/// key halves (DH and Ed25519).
pub fn generate() !KeyPair {
    var kp: KeyPair = undefined;
    std.crypto.random.bytes(&kp.private_key);

    kp.public_key[0..32].* = try calcPubDH(kp.private_key[0..32]);
    kp.public_key[32..64].* = try calcPubED(kp.private_key[32..64]);

    return kp;
}

/// Generate a key pair satisfying an arbitrary condition on the public key.
///
/// Starts with random bytes, computes the Ed25519 key once (bytes 32-63
/// are fixed), then iteratively modifies the DH private key portion and
/// regenerates the DH public key until `condFn` returns true.
///
/// The iteration modifies bytes 8..15 (increment) and 16..23 (decrement)
/// of the private key as little-endian u64 values, matching C++ behavior.
pub fn generateSatisfying(comptime condFn: fn (*const KeyPair) bool) !KeyPair {
    var kp: KeyPair = undefined;
    std.crypto.random.bytes(&kp.private_key);

    // Ed25519 key is computed once — only the DH portion changes.
    kp.public_key[32..64].* = try calcPubED(kp.private_key[32..64]);

    while (true) {
        // Increment bytes 8..15 as little-endian u64 (wrapping).
        const val1 = std.mem.readInt(u64, kp.private_key[8..16], .little);
        std.mem.writeInt(u64, kp.private_key[8..16], val1 +% 1, .little);

        // Decrement bytes 16..23 as little-endian u64 (wrapping).
        const val2 = std.mem.readInt(u64, kp.private_key[16..24], .little);
        std.mem.writeInt(u64, kp.private_key[16..24], val2 -% 1, .little);

        // Regenerate DH public key; skip degenerate keys.
        kp.public_key[0..32].* = calcPubDH(kp.private_key[0..32]) catch continue;

        if (condFn(&kp)) return kp;
    }
}

/// Same as `generateSatisfying` but passes a runtime context to the
/// condition function, since Zig function pointers cannot capture.
pub fn generateSatisfyingWithContext(
    ctx: anytype,
    comptime condFn: fn (@TypeOf(ctx), *const KeyPair) bool,
) !KeyPair {
    var kp: KeyPair = undefined;
    std.crypto.random.bytes(&kp.private_key);

    kp.public_key[32..64].* = try calcPubED(kp.private_key[32..64]);

    while (true) {
        const val1 = std.mem.readInt(u64, kp.private_key[8..16], .little);
        std.mem.writeInt(u64, kp.private_key[8..16], val1 +% 1, .little);

        const val2 = std.mem.readInt(u64, kp.private_key[16..24], .little);
        std.mem.writeInt(u64, kp.private_key[16..24], val2 -% 1, .little);

        kp.public_key[0..32].* = calcPubDH(kp.private_key[0..32]) catch continue;

        if (condFn(ctx, &kp)) return kp;
    }
}

/// Perform C25519 (X25519) ECDH key agreement.
///
/// Computes X25519(my_priv[0..32], their_pub[0..32]), then derives
/// `keybuf.len` bytes of key material by repeatedly SHA-512 hashing
/// the raw shared secret.
pub fn agree(
    my_priv: *const Private,
    their_pub: *const Public,
    keybuf: []u8,
) !void {
    var rawkey: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &rawkey);

    rawkey = try X25519.scalarmult(my_priv[0..32].*, their_pub[0..32].*);

    var digest: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);

    sha.sha512(&digest, &rawkey);

    var i: usize = 0;
    var k: usize = 0;
    while (i < keybuf.len) {
        if (k == 64) {
            k = 0;
            sha.sha512(&digest, &digest);
        }
        keybuf[i] = digest[k];
        i += 1;
        k += 1;
    }
}

/// Sign a message using the ZeroTier modified Ed25519 scheme.
///
/// Steps:
///   1. digest = SHA-512(msg)
///   2. extsk = SHA-512(priv[32..64]); clamp extsk[0..32]
///   3. nonce = reduce64(SHA-512(extsk[32..64] || digest[0..32]))
///   4. R = nonce * B (base point)
///   5. hram = reduce64(SHA-512(R || pub[32..64] || digest[0..32]))
///   6. S = hram * reduce(extsk[0..32]) + nonce  (mod L)
///   7. signature = R(32) || S(32) || digest[0..32](32)
pub fn sign(
    my_priv: *const Private,
    my_pub: *const Public,
    msg: []const u8,
) !Signature {
    // Hash the message.
    var digest: [64]u8 = undefined;
    sha.sha512(&digest, msg);

    // Compute extended secret key from Ed25519 private seed.
    var extsk: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &extsk);
    sha.sha512(&extsk, my_priv[32..64]);

    // Clamp the scalar portion (standard Ed25519 clamping).
    extsk[0] &= 248;
    extsk[31] &= 127;
    extsk[31] |= 64;

    // Deterministic nonce: SHA-512(extsk[32..64] || digest[0..32]).
    var nonce_input: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &nonce_input);
    @memcpy(nonce_input[0..32], extsk[32..64]);
    @memcpy(nonce_input[32..64], digest[0..32]);

    var hmg: [64]u8 = undefined;
    sha.sha512(&hmg, &nonce_input);
    const nonce = scalar.reduce64(hmg);

    // R = nonce * basepoint.
    const r_point = try Edwards25519.basePoint.mul(nonce);
    const r_bytes = r_point.toBytes();

    // HRAM: SHA-512(R || pub_ed || digest[0..32]).
    var hram_input: [96]u8 = undefined;
    @memcpy(hram_input[0..32], &r_bytes);
    @memcpy(hram_input[32..64], my_pub[32..64]);
    @memcpy(hram_input[64..96], digest[0..32]);

    var hram_hash: [64]u8 = undefined;
    sha.sha512(&hram_hash, &hram_input);
    const hram = scalar.reduce64(hram_hash);

    // Reduce the clamped private key scalar (matches C++ sc25519_from32bytes).
    var sk_padded: [64]u8 = [_]u8{0} ** 64;
    defer std.crypto.secureZero(u8, &sk_padded);
    @memcpy(sk_padded[0..32], extsk[0..32]);
    const sk = scalar.reduce64(sk_padded);

    // S = hram * sk + nonce  (mod L).
    const s_bytes = scalar.mulAdd(hram, sk, nonce);

    // Assemble the 96-byte signature: R || S || digest[0..32].
    var sig: Signature = undefined;
    @memcpy(sig[0..32], &r_bytes);
    @memcpy(sig[32..64], &s_bytes);
    @memcpy(sig[64..96], digest[0..32]);

    return sig;
}

/// Verify a ZeroTier modified Ed25519 signature.
///
/// Returns true if the signature is valid for the given public key and
/// message. Any decoding or arithmetic error results in false (invalid).
pub fn verify(
    their_pub: *const Public,
    msg: []const u8,
    sig: *const Signature,
) bool {
    return verifyInner(their_pub, msg, sig) catch false;
}

// ── Private helpers ────────────────────────────────────────────────

/// Derive the X25519 (ECDH) public key from a 32-byte private key.
fn calcPubDH(priv_dh: *const [32]u8) ![32]u8 {
    return X25519.recoverPublicKey(priv_dh.*);
}

/// Derive the Ed25519 signing public key from a 32-byte private seed.
///
/// Hashes the seed with SHA-512, clamps the first 32 bytes, reduces
/// modulo L, and multiplies by the Ed25519 base point.
fn calcPubED(priv_ed: *const [32]u8) ![32]u8 {
    var extsk: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &extsk);
    sha.sha512(&extsk, priv_ed);

    // Standard Ed25519 clamping.
    extsk[0] &= 248;
    extsk[31] &= 127;
    extsk[31] |= 64;

    // Reduce to scalar modulo L (matches C++ sc25519_from32bytes).
    var padded: [64]u8 = [_]u8{0} ** 64;
    @memcpy(padded[0..32], extsk[0..32]);
    const reduced = scalar.reduce64(padded);

    const point = try Edwards25519.basePoint.mul(reduced);
    return point.toBytes();
}

/// Inner verification logic that propagates errors (caught by `verify`).
fn verifyInner(
    their_pub: *const Public,
    msg: []const u8,
    sig: *const Signature,
) !bool {
    // Hash the message and check against the embedded hash.
    var digest: [64]u8 = undefined;
    sha.sha512(&digest, msg);
    if (!utils.secureEq(sig[64..96], digest[0..32])) {
        return false;
    }

    // Decode the Ed25519 public key and negate for verification.
    const a = try Edwards25519.fromBytes(their_pub[32..64].*);
    const neg_a = a.neg();

    // Reconstruct HRAM: SHA-512(R || pub_ed || digest[0..32]).
    var hram_input: [96]u8 = undefined;
    @memcpy(hram_input[0..32], sig[0..32]);
    @memcpy(hram_input[32..64], their_pub[32..64]);
    @memcpy(hram_input[64..96], sig[64..96]);

    var hram_hash: [64]u8 = undefined;
    sha.sha512(&hram_hash, &hram_input);
    const hram = scalar.reduce64(hram_hash);

    // Reduce S from the signature (matches C++ sc25519_from32bytes).
    var s_padded: [64]u8 = [_]u8{0} ** 64;
    @memcpy(s_padded[0..32], sig[32..64]);
    const s_reduced = scalar.reduce64(s_padded);

    // Verify: (-A)*hram + B*S should equal R.
    // mulDoubleBasePublic computes: self * s1 + p2 * s2
    const expected_r = try neg_a.mulDoubleBasePublic(
        hram,
        Edwards25519.basePoint,
        s_reduced,
    );
    const expected_r_bytes = expected_r.toBytes();

    return utils.secureEq(&expected_r_bytes, sig[0..32]);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// Test vector structure matching C++ C25519TestVector from selftest.cpp.
const TestVector = struct {
    pub1: [64]u8,
    priv1: [64]u8,
    pub2: [64]u8,
    priv2: [64]u8,
    agreement: [64]u8,
    agreement_signed_by_1: [96]u8,
    agreement_signed_by_2: [96]u8,
};

// Selftest vectors 0 and 1 from selftest.cpp lines 106-137.
const test_vectors = [_]TestVector{
    // Vector 0
    .{
        .pub1 = .{
            0xa1, 0xfc, 0x7a, 0xb4, 0x6d, 0xdf, 0x7d, 0xcf, 0xe7, 0xec, 0x75, 0xe5, 0xfa, 0xdd, 0x11, 0xcb,
            0xcc, 0x37, 0xf8, 0x84, 0x5d, 0x1c, 0x92, 0x4e, 0x09, 0x89, 0x65, 0xfc, 0xd8, 0xe9, 0x5a, 0x30,
            0xda, 0xe4, 0x86, 0xa3, 0x35, 0xb4, 0x19, 0x0c, 0xbc, 0x7b, 0xcb, 0x3e, 0xb9, 0x4c, 0xbd, 0x16,
            0xe8, 0x3d, 0x13, 0x2b, 0xc9, 0xc3, 0x39, 0xea, 0xf1, 0x42, 0xe7, 0x6f, 0x69, 0x78, 0x9a, 0xb7,
        },
        .priv1 = .{
            0xe5, 0xf3, 0x7b, 0xd4, 0x0e, 0xc9, 0xdc, 0x77, 0x50, 0x86, 0xdc, 0xf4, 0x2e, 0xbc, 0xdb, 0x27,
            0xf0, 0x73, 0xd4, 0x58, 0x73, 0xc4, 0x4b, 0x71, 0x8b, 0x3c, 0xc5, 0x4f, 0xa8, 0x7c, 0xa4, 0x84,
            0xd9, 0x96, 0x23, 0x73, 0xb4, 0x03, 0x16, 0xbf, 0x1e, 0xa1, 0x2d, 0xd8, 0xc4, 0x8a, 0xe7, 0x82,
            0x10, 0xda, 0xc9, 0xe5, 0x45, 0x9b, 0x01, 0xdc, 0x73, 0xa6, 0xc9, 0x17, 0xa8, 0x15, 0x31, 0x6d,
        },
        .pub2 = .{
            0x3e, 0x49, 0xa4, 0x0e, 0x3a, 0xaf, 0xa3, 0x07, 0x3d, 0xf7, 0x2a, 0xec, 0x43, 0xb1, 0xd4, 0x09,
            0x1a, 0xcb, 0x8e, 0x92, 0xf9, 0x65, 0x95, 0x04, 0x6d, 0x2d, 0x9b, 0x34, 0xa3, 0xbf, 0x51, 0x00,
            0xe2, 0xee, 0x23, 0xf5, 0x28, 0x0a, 0xa9, 0xb1, 0x57, 0x0b, 0x96, 0x56, 0x62, 0xba, 0x12, 0x94,
            0xaf, 0xc6, 0x5f, 0xb5, 0x61, 0x43, 0x0f, 0xde, 0x0b, 0xab, 0xfa, 0x4f, 0xfe, 0xc5, 0xe7, 0x18,
        },
        .priv2 = .{
            0x00, 0x4d, 0x41, 0x8d, 0xe4, 0x69, 0x23, 0xae, 0x98, 0xc4, 0x3e, 0x77, 0x0f, 0x1d, 0x94, 0x5d,
            0x29, 0x3e, 0x94, 0x5a, 0x38, 0x39, 0x20, 0x0f, 0xd3, 0x6f, 0x76, 0xa2, 0x29, 0x02, 0x03, 0xcb,
            0x0b, 0x7f, 0x4f, 0x1a, 0x29, 0x51, 0x13, 0x33, 0x7c, 0x99, 0xb3, 0x81, 0x82, 0x39, 0x44, 0x05,
            0x97, 0xfb, 0x0d, 0xf2, 0x93, 0xa2, 0x40, 0x94, 0xf4, 0xff, 0x5d, 0x09, 0x61, 0xe4, 0x5f, 0x76,
        },
        .agreement = .{
            0xab, 0xce, 0xd2, 0x24, 0xe8, 0x93, 0xb0, 0xe7, 0x72, 0x14, 0xdc, 0xbb, 0x7d, 0x0f, 0xd8, 0x94,
            0x16, 0x9e, 0xb5, 0x7f, 0xd7, 0x19, 0x5f, 0x3e, 0x2d, 0x45, 0xd5, 0xf7, 0x90, 0x0b, 0x3e, 0x05,
            0x18, 0x2e, 0x2b, 0xf4, 0xfa, 0xd4, 0xec, 0x62, 0x4a, 0x4f, 0x48, 0x50, 0xaf, 0x1c, 0xe8, 0x9f,
            0x1a, 0xe1, 0x3d, 0x70, 0x49, 0x00, 0xa7, 0xe3, 0x5b, 0x1e, 0xa1, 0x9b, 0x68, 0x1e, 0xa1, 0x73,
        },
        .agreement_signed_by_1 = .{
            0xed, 0xb6, 0xd0, 0xf0, 0x06, 0x6e, 0x33, 0x9c, 0x86, 0xfb, 0xe8, 0xc3, 0x6c, 0x8d, 0xde, 0xdd,
            0xa6, 0xa0, 0x2d, 0xb9, 0x07, 0x29, 0xa3, 0x13, 0xbb, 0xa4, 0xba, 0xec, 0x48, 0xc8, 0xf4, 0x56,
            0x82, 0x79, 0xe2, 0xb1, 0xd3, 0x3d, 0x83, 0x9f, 0x10, 0xe8, 0x52, 0xe6, 0x8b, 0x1c, 0x33, 0x9e,
            0x2b, 0xd2, 0xdb, 0x62, 0x1c, 0x56, 0xfd, 0x50, 0x40, 0x77, 0x81, 0xab, 0x21, 0x67, 0x3e, 0x09,
            0x4f, 0xf2, 0x51, 0xac, 0x7d, 0xe7, 0xd1, 0x5d, 0x4b, 0xe2, 0x08, 0xc6, 0x3f, 0x6a, 0x4d, 0xc8,
            0x5d, 0x74, 0xf6, 0x3b, 0xec, 0x8e, 0xc6, 0x0c, 0x32, 0x27, 0x2f, 0x9c, 0x09, 0x48, 0x59, 0x10,
        },
        .agreement_signed_by_2 = .{
            0x23, 0x0f, 0xa3, 0xe2, 0x69, 0xce, 0xb9, 0xb9, 0xd1, 0x1c, 0x4e, 0xab, 0x63, 0xc9, 0x2e, 0x1e,
            0x7e, 0xa2, 0xa2, 0xa0, 0x49, 0x2e, 0x78, 0xe4, 0x8a, 0x02, 0x3b, 0xa7, 0xab, 0x1f, 0xd4, 0xce,
            0x05, 0xe2, 0x80, 0x09, 0x09, 0x3c, 0x61, 0xc7, 0x10, 0x3a, 0x9c, 0xf4, 0x95, 0xac, 0x89, 0x6f,
            0x23, 0xb3, 0x09, 0xe2, 0x24, 0x3f, 0xf6, 0x96, 0x02, 0x36, 0x41, 0x16, 0x32, 0xe1, 0x66, 0x05,
            0x4f, 0xf2, 0x51, 0xac, 0x7d, 0xe7, 0xd1, 0x5d, 0x4b, 0xe2, 0x08, 0xc6, 0x3f, 0x6a, 0x4d, 0xc8,
            0x5d, 0x74, 0xf6, 0x3b, 0xec, 0x8e, 0xc6, 0x0c, 0x32, 0x27, 0x2f, 0x9c, 0x09, 0x48, 0x59, 0x10,
        },
    },
    // Vector 1
    .{
        .pub1 = .{
            0xfd, 0x81, 0x14, 0xf1, 0x67, 0x07, 0x44, 0xbb, 0x93, 0x84, 0xa2, 0xdc, 0x36, 0xdc, 0xcc, 0xb3,
            0x9e, 0x82, 0xd4, 0x8b, 0x42, 0x56, 0xfb, 0xf2, 0x6e, 0x83, 0x3b, 0x16, 0x2c, 0x29, 0xfb, 0x39,
            0x29, 0x48, 0x85, 0xe3, 0xe3, 0xf7, 0xe7, 0x80, 0x49, 0xd3, 0x01, 0x30, 0x5a, 0x2c, 0x3f, 0x4c,
            0xea, 0x13, 0xeb, 0xda, 0xf4, 0x56, 0x75, 0x8d, 0x50, 0x1e, 0x19, 0x2d, 0x29, 0x2b, 0xfb, 0xdb,
        },
        .priv1 = .{
            0x85, 0x34, 0x4d, 0xf7, 0x39, 0xbf, 0x98, 0x79, 0x8c, 0x98, 0xeb, 0x8d, 0x61, 0x27, 0xec, 0x87,
            0x56, 0xcd, 0xd0, 0xa6, 0x55, 0x77, 0xee, 0xf0, 0x20, 0xd0, 0x59, 0x39, 0x95, 0xab, 0x29, 0x82,
            0x8e, 0x61, 0xf8, 0xad, 0xed, 0xb6, 0x27, 0xc3, 0xd8, 0x16, 0xce, 0x67, 0x78, 0xe2, 0x04, 0x4b,
            0x0c, 0x2d, 0x2f, 0xc3, 0x24, 0x72, 0xbc, 0x53, 0xbd, 0xfe, 0x39, 0x23, 0xd4, 0xaf, 0x27, 0x84,
        },
        .pub2 = .{
            0x11, 0xbe, 0x5f, 0x5a, 0x73, 0xe7, 0x42, 0xef, 0xff, 0x3c, 0x47, 0x6a, 0x0e, 0x6b, 0x9e, 0x96,
            0x21, 0xa3, 0xdf, 0x49, 0xe9, 0x3f, 0x40, 0xfc, 0xab, 0xb3, 0x66, 0xd3, 0x3d, 0xfa, 0x02, 0x29,
            0xf3, 0x43, 0x45, 0x3c, 0x70, 0xa3, 0x5d, 0x39, 0xf7, 0xc0, 0x6a, 0xcd, 0xfa, 0x1d, 0xbe, 0x3b,
            0x91, 0x41, 0xe4, 0xb0, 0x60, 0xc0, 0x22, 0xf7, 0x2c, 0x11, 0x2b, 0x1c, 0x5f, 0x24, 0xef, 0x53,
        },
        .priv2 = .{
            0xfd, 0x3f, 0x09, 0x06, 0xc9, 0x39, 0x8d, 0x48, 0xfa, 0x6b, 0xc9, 0x80, 0xbf, 0xf6, 0xd6, 0x76,
            0xb3, 0x62, 0x70, 0x88, 0x4f, 0xde, 0xde, 0xb9, 0xb4, 0xf0, 0xce, 0xf3, 0x74, 0x0d, 0xea, 0x00,
            0x9e, 0x9c, 0x29, 0xe1, 0xa2, 0x1b, 0xbd, 0xb5, 0x83, 0xcc, 0x12, 0xd8, 0x48, 0x08, 0x5b, 0xe5,
            0xd6, 0xf9, 0x11, 0x5c, 0xe0, 0xd9, 0xc3, 0x3c, 0x26, 0xbd, 0x69, 0x9f, 0x5c, 0x6f, 0x0c, 0x6f,
        },
        .agreement = .{
            0xca, 0xd4, 0x76, 0x32, 0x8b, 0xbe, 0x0c, 0x65, 0x75, 0x43, 0x73, 0xc2, 0xf2, 0xfd, 0x7f, 0xeb,
            0xe4, 0x62, 0xc5, 0x0d, 0x0f, 0xf9, 0x01, 0xc8, 0xb9, 0xfa, 0xca, 0xb4, 0x12, 0x1c, 0xb4, 0xac,
            0x0e, 0x5f, 0x18, 0xfc, 0x0c, 0x7f, 0x2a, 0x55, 0xc5, 0xfd, 0x4d, 0x83, 0xb2, 0x02, 0x31, 0x6a,
            0x3f, 0x14, 0xee, 0x9d, 0x11, 0xa8, 0x06, 0xad, 0xeb, 0x93, 0x19, 0x79, 0xb1, 0xf2, 0x78, 0x05,
        },
        .agreement_signed_by_1 = .{
            0x85, 0xe6, 0xe2, 0xf2, 0x96, 0xe7, 0xa2, 0x8b, 0x7e, 0x36, 0xbd, 0x7b, 0xf4, 0x28, 0x6a, 0xd7,
            0xbc, 0x2a, 0x6a, 0x59, 0xfd, 0xc0, 0xc8, 0x3d, 0x50, 0x0f, 0x0c, 0x2b, 0x12, 0x3a, 0x75, 0xc7,
            0x56, 0xbb, 0x7f, 0x7d, 0x4e, 0xd4, 0x03, 0xb8, 0x7b, 0xde, 0xde, 0x99, 0x65, 0x9e, 0xc4, 0xa6,
            0x6e, 0xfe, 0x00, 0x88, 0xeb, 0x9d, 0xa4, 0xa9, 0x9d, 0x37, 0xc9, 0x4a, 0xcf, 0x69, 0xc4, 0x01,
            0xba, 0xa8, 0xce, 0xeb, 0x72, 0xcb, 0x64, 0x8b, 0x9f, 0xc1, 0x1f, 0x9a, 0x9e, 0x99, 0xcc, 0x39,
            0xec, 0xd9, 0xbb, 0xd9, 0xce, 0xc2, 0x74, 0x6f, 0xd0, 0x2a, 0xb9, 0xc6, 0xe3, 0xf5, 0xe7, 0xf4,
        },
        .agreement_signed_by_2 = .{
            0xb1, 0x39, 0x50, 0xb1, 0x1a, 0x08, 0x42, 0x2b, 0xdd, 0x6d, 0x20, 0x9f, 0x0f, 0x37, 0xba, 0x69,
            0x97, 0x21, 0x30, 0x7a, 0x71, 0x2f, 0xce, 0x98, 0x09, 0x04, 0xa2, 0x98, 0x6a, 0xed, 0x02, 0x1d,
            0x5d, 0x30, 0x8f, 0x03, 0x47, 0x6b, 0x89, 0xfd, 0xf7, 0x1a, 0xca, 0x46, 0x6f, 0x51, 0x69, 0x9a,
            0x2b, 0x18, 0x77, 0xe4, 0xad, 0x0d, 0x7a, 0x66, 0xd2, 0x2c, 0x28, 0xa0, 0xd3, 0x0a, 0x99, 0x0d,
            0xba, 0xa8, 0xce, 0xeb, 0x72, 0xcb, 0x64, 0x8b, 0x9f, 0xc1, 0x1f, 0x9a, 0x9e, 0x99, 0xcc, 0x39,
            0xec, 0xd9, 0xbb, 0xd9, 0xce, 0xc2, 0x74, 0x6f, 0xd0, 0x2a, 0xb9, 0xc6, 0xe3, 0xf5, 0xe7, 0xf4,
        },
    },
};

test "agree symmetry against test vectors" {
    for (&test_vectors) |*tv| {
        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;

        try agree(&tv.priv1, &tv.pub2, &buf1);
        try agree(&tv.priv2, &tv.pub1, &buf2);

        // agree(p1,p2) must equal agree(p2,p1)
        try testing.expectEqualSlices(u8, &buf1, &buf2);
    }
}

test "agree matches expected test vector values" {
    for (&test_vectors) |*tv| {
        var buf: [64]u8 = undefined;
        try agree(&tv.priv1, &tv.pub2, &buf);

        try testing.expectEqualSlices(u8, &tv.agreement, &buf);
    }
}

test "sign R and S match test vector values" {
    for (&test_vectors) |*tv| {
        // Sign the agreement (the message) with key pair 1.
        const sig1 = try sign(&tv.priv1, &tv.pub1, &tv.agreement);

        // C++ selftest checks first 64 bytes (R || S) only.
        try testing.expectEqualSlices(u8, tv.agreement_signed_by_1[0..64], sig1[0..64]);

        // Sign with key pair 2.
        const sig2 = try sign(&tv.priv2, &tv.pub2, &tv.agreement);
        try testing.expectEqualSlices(u8, tv.agreement_signed_by_2[0..64], sig2[0..64]);
    }
}

test "verify roundtrip with test vectors" {
    for (&test_vectors) |*tv| {
        const sig1 = try sign(&tv.priv1, &tv.pub1, &tv.agreement);
        try testing.expect(verify(&tv.pub1, &tv.agreement, &sig1));

        const sig2 = try sign(&tv.priv2, &tv.pub2, &tv.agreement);
        try testing.expect(verify(&tv.pub2, &tv.agreement, &sig2));
    }
}

test "generate and sign/verify roundtrip" {
    const kp = try generate();
    const msg = "ZeroTier ECC roundtrip test message";
    const sig = try sign(&kp.private_key, &kp.public_key, msg);

    try testing.expect(verify(&kp.public_key, msg, &sig));
}

test "verify rejects modified message" {
    const kp = try generate();
    const msg = "original message content";
    const sig = try sign(&kp.private_key, &kp.public_key, msg);

    // Modify one byte of the message.
    const bad_msg = "Original message content";
    try testing.expect(!verify(&kp.public_key, bad_msg, &sig));
}

test "verify rejects bit-flipped signature" {
    const kp = try generate();
    const msg = "message for bit-flip test";
    const sig = try sign(&kp.private_key, &kp.public_key, msg);

    // Flip a bit in each of the three 32-byte sections.
    const offsets = [_]usize{ 5, 37, 70 };
    for (offsets) |offset| {
        var bad_sig = sig;
        bad_sig[offset] ^= 0x01;
        try testing.expect(!verify(&kp.public_key, msg, &bad_sig));
    }
}

test "verify rejects wrong public key" {
    const kp1 = try generate();
    const kp2 = try generate();
    const msg = "message signed by kp1";
    const sig = try sign(&kp1.private_key, &kp1.public_key, msg);

    // Verifying with kp2's public key must fail.
    try testing.expect(!verify(&kp2.public_key, msg, &sig));
}

test "agree produces different keys for different pairs" {
    const kp1 = try generate();
    const kp2 = try generate();
    const kp3 = try generate();

    var buf12: [64]u8 = undefined;
    var buf13: [64]u8 = undefined;
    try agree(&kp1.private_key, &kp2.public_key, &buf12);
    try agree(&kp1.private_key, &kp3.public_key, &buf13);

    // Different peers must produce different shared secrets.
    try testing.expect(!std.mem.eql(u8, &buf12, &buf13));
}

test "signature digest section matches SHA-512 of message" {
    const kp = try generate();
    const msg = "check digest embedding";
    const sig = try sign(&kp.private_key, &kp.public_key, msg);

    var expected_digest: [64]u8 = undefined;
    sha.sha512(&expected_digest, msg);

    // Bytes 64..96 of signature must be SHA-512(msg)[0..32].
    try testing.expectEqualSlices(u8, expected_digest[0..32], sig[64..96]);
}

test "constants match C++ defines" {
    try testing.expectEqual(64, public_key_set_len);
    try testing.expectEqual(64, private_key_set_len);
    try testing.expectEqual(96, signature_len);
    try testing.expectEqual(32, ephemeral_public_key_len);
    try testing.expectEqual(64, @sizeOf(Public));
    try testing.expectEqual(64, @sizeOf(Private));
    try testing.expectEqual(96, @sizeOf(Signature));
}
