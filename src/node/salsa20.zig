/// Salsa20 stream cipher — stateful wrapper.
///
/// Converted from `node/Salsa20.hpp` and `node/Salsa20.cpp`. Provides
/// a stateful encryption context matching the C++ API pattern:
/// `init(key, iv)` then repeated `crypt12()`/`crypt20()` calls with
/// automatic block counter advancement.
///
/// The underlying implementation uses Zig's standard library
/// `std.crypto.stream.salsa.Salsa(rounds)` which produces identical
/// output to the C++ DJB reference implementation.
///
/// On ARM64, we use a hand-optimized NEON implementation for Salsa20/12
/// which provides ~30-50% speedup over the stdlib version.
///
/// Also provides `memxor()` for fast XOR of byte slices, used by
/// Packet.cpp independently of Salsa20 encryption.
const std = @import("std");
const builtin = @import("builtin");
const crypto = std.crypto;

// Platform-specific SIMD module for Salsa20/12 and Salsa20/20
const simd_arm = if (builtin.cpu.arch == .aarch64)
    @import("salsa20_simd_arm.zig")
else
    struct {
        pub fn salsa20_12_xor_neon(_: []u8, _: []const u8, _: u64, _: [32]u8, _: [8]u8) void {
            @panic("ARM NEON Salsa20/12 not available on this platform");
        }
        pub fn salsa20_20_xor_neon(_: []u8, _: []const u8, _: u64, _: [32]u8, _: [8]u8) void {
            @panic("ARM NEON Salsa20/20 not available on this platform");
        }
    };

// ── Public constants ───────────────────────────────────────────────

pub const key_length: comptime_int = 32;
pub const nonce_length: comptime_int = 8;
pub const block_length: comptime_int = 64;

// ── Stdlib Salsa types ─────────────────────────────────────────────

const Salsa12 = crypto.stream.salsa.Salsa(12);
const Salsa20Cipher = crypto.stream.salsa.Salsa(20);

// ── Stateful Salsa20 context ───────────────────────────────────────

/// Stateful Salsa20 stream cipher context.
///
/// Stores key, nonce, and block counter. Provides `crypt12()` and
/// `crypt20()` methods that automatically advance the block counter
/// across multiple calls, matching the C++ `Salsa20` class behavior.
///
/// The block counter advances by `ceil(len / 64)` per call. A
/// partial block (< 64 bytes) still consumes one full block of
/// keystream, exactly as in the C++ implementation.
pub const Salsa20 = struct {
    /// 256-bit key — OWNED: copied at init, securely zeroed on deinit.
    key_data: [key_length]u8,
    /// 64-bit nonce — OWNED: copied at init, securely zeroed on deinit.
    nonce_data: [nonce_length]u8,
    /// 64-bit block counter, advances by 1 per 64-byte block processed.
    block_counter: u64,

    /// Initialize a Salsa20 context with the given key and nonce.
    /// Block counter starts at 0.
    pub fn init(key: *const [key_length]u8, nonce: *const [nonce_length]u8) Salsa20 {
        return .{
            .key_data = key.*,
            .nonce_data = nonce.*,
            .block_counter = 0,
        };
    }

    /// Re-initialize with a new key and nonce. Resets block counter to 0.
    /// Previous key/nonce are overwritten (not securely zeroed first —
    /// call `deinit()` before `reinit()` if the old key is sensitive
    /// and you want it wiped).
    pub fn reinit(self: *Salsa20, key: *const [key_length]u8, nonce: *const [nonce_length]u8) void {
        // Securely zero old key material before overwriting
        crypto.secureZero(u8, &self.key_data);
        crypto.secureZero(u8, &self.nonce_data);
        self.key_data = key.*;
        self.nonce_data = nonce.*;
        self.block_counter = 0;
    }

    /// Encrypt/decrypt using Salsa20/12 (12 rounds).
    ///
    /// XORs `in_buf` with the Salsa20/12 keystream and writes the
    /// result to `out_buf`. Advances the block counter by
    /// `ceil(len / 64)`. Supports in-place operation (out == in).
    ///
    /// On ARM64, uses NEON-optimized implementation for better performance.
    ///
    /// Panics if `in_buf.len != out_buf.len`.
    pub fn crypt12(self: *Salsa20, out_buf: []u8, in_buf: []const u8) void {
        std.debug.assert(in_buf.len == out_buf.len);
        if (in_buf.len == 0) return;

        // Use SIMD on ARM64 for better performance
        if (builtin.cpu.arch == .aarch64) {
            simd_arm.salsa20_12_xor_neon(out_buf, in_buf, self.block_counter, self.key_data, self.nonce_data);
        } else {
            Salsa12.xor(out_buf, in_buf, self.block_counter, self.key_data, self.nonce_data);
        }
        self.block_counter += blocksConsumed(in_buf.len);
    }

    /// Encrypt/decrypt using Salsa20/20 (20 rounds).
    ///
    /// XORs `in_buf` with the Salsa20/20 keystream and writes the
    /// result to `out_buf`. Advances the block counter by
    /// `ceil(len / 64)`. Supports in-place operation (out == in).
    ///
    /// On ARM64, uses NEON-optimized implementation for better performance.
    ///
    /// Panics if `in_buf.len != out_buf.len`.
    pub fn crypt20(self: *Salsa20, out_buf: []u8, in_buf: []const u8) void {
        std.debug.assert(in_buf.len == out_buf.len);
        if (in_buf.len == 0) return;

        // Use SIMD on ARM64 for better performance
        if (builtin.cpu.arch == .aarch64) {
            simd_arm.salsa20_20_xor_neon(out_buf, in_buf, self.block_counter, self.key_data, self.nonce_data);
        } else {
            Salsa20Cipher.xor(out_buf, in_buf, self.block_counter, self.key_data, self.nonce_data);
        }
        self.block_counter += blocksConsumed(in_buf.len);
    }

    /// Securely zero all key material.
    pub fn deinit(self: *Salsa20) void {
        crypto.secureZero(u8, &self.key_data);
        crypto.secureZero(u8, &self.nonce_data);
        self.block_counter = 0;
    }
};

// ── memxor ─────────────────────────────────────────────────────────

/// XOR `src` into `dst` byte-by-byte: `dst[i] ^= src[i]`.
///
/// Both slices must have the same length. This is used by Packet.cpp
/// for XOR operations independent of Salsa20 encryption (e.g.,
/// combining keystream fragments with packet headers).
///
/// Panics if `dst.len != src.len`.
pub fn memxor(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |*d, s| {
        d.* ^= s;
    }
}

// ── Private helpers ────────────────────────────────────────────────

/// Compute the number of 64-byte blocks consumed by `byte_len` bytes.
/// A partial block (1..63 bytes) still consumes 1 block of keystream.
fn blocksConsumed(byte_len: usize) u64 {
    if (byte_len == 0) return 0;
    return @as(u64, (byte_len + block_length - 1) / block_length);
}

// ── Tests ──────────────────────────────────────────────────────────

test "selftest vector: Salsa20/20 keystream" {
    // From selftest.cpp: s20TV0Key, s20TV0Iv, s20TV0Ks
    // Encrypts 64 zero bytes with Salsa20/20 and checks the keystream.
    const key = [32]u8{
        0x0f, 0x62, 0xb5, 0x08, 0x5b, 0xae, 0x01, 0x54,
        0xa7, 0xfa, 0x4d, 0xa0, 0xf3, 0x46, 0x99, 0xec,
        0x3f, 0x92, 0xe5, 0x38, 0x8b, 0xde, 0x31, 0x84,
        0xd7, 0x2a, 0x7d, 0xd0, 0x23, 0x76, 0xc9, 0x1c,
    };
    const iv = [8]u8{ 0x28, 0x8f, 0xf6, 0x5d, 0xc4, 0x2b, 0x92, 0xf9 };
    const expected = [64]u8{
        0x5e, 0x5e, 0x71, 0xf9, 0x01, 0x99, 0x34, 0x03,
        0x04, 0xab, 0xb2, 0x2a, 0x37, 0xb6, 0x62, 0x5b,
        0xf8, 0x83, 0xfb, 0x89, 0xce, 0x3b, 0x21, 0xf5,
        0x4a, 0x10, 0xb8, 0x10, 0x66, 0xef, 0x87, 0xda,
        0x30, 0xb7, 0x76, 0x99, 0xaa, 0x73, 0x79, 0xda,
        0x59, 0x5c, 0x77, 0xdd, 0x59, 0x54, 0x2d, 0xa2,
        0x08, 0xe5, 0x95, 0x4f, 0x89, 0xe4, 0x0e, 0xb7,
        0xaa, 0x80, 0xa8, 0x4a, 0x61, 0x76, 0x66, 0x3f,
    };

    const zeros = [_]u8{0} ** 64;
    var out: [64]u8 = undefined;
    var ctx = Salsa20.init(&key, &iv);
    defer ctx.deinit();
    ctx.crypt20(&out, &zeros);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "selftest vector: Salsa20/12 keystream" {
    // From selftest.cpp: s2012TV0Key, s2012TV0Iv, s2012TV0Ks
    // Same key/iv as Salsa20/20 test but with 12 rounds.
    const key = [32]u8{
        0x0f, 0x62, 0xb5, 0x08, 0x5b, 0xae, 0x01, 0x54,
        0xa7, 0xfa, 0x4d, 0xa0, 0xf3, 0x46, 0x99, 0xec,
        0x3f, 0x92, 0xe5, 0x38, 0x8b, 0xde, 0x31, 0x84,
        0xd7, 0x2a, 0x7d, 0xd0, 0x23, 0x76, 0xc9, 0x1c,
    };
    const iv = [8]u8{ 0x28, 0x8f, 0xf6, 0x5d, 0xc4, 0x2b, 0x92, 0xf9 };
    const expected = [64]u8{
        0x99, 0xDB, 0x33, 0xAD, 0x11, 0xCE, 0x0C, 0xCB,
        0x3B, 0xFD, 0xBF, 0x8D, 0x0C, 0x18, 0x16, 0x04,
        0x52, 0xD0, 0x14, 0xCD, 0xE9, 0x89, 0xB4, 0xC4,
        0x11, 0xA5, 0x59, 0xFF, 0x7C, 0x20, 0xA1, 0x69,
        0xE6, 0xDC, 0x99, 0x09, 0xD8, 0x16, 0xBE, 0xCE,
        0xDC, 0x40, 0x63, 0xCE, 0x07, 0xCE, 0xA8, 0x28,
        0xF4, 0x4B, 0xF9, 0xB6, 0xC9, 0xA0, 0xA0, 0xB2,
        0x00, 0xE1, 0xB5, 0x2A, 0xF4, 0x18, 0x59, 0xC5,
    };

    const zeros = [_]u8{0} ** 64;
    var out: [64]u8 = undefined;
    var ctx = Salsa20.init(&key, &iv);
    defer ctx.deinit();
    ctx.crypt12(&out, &zeros);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "encrypt then decrypt round-trip (Salsa20/20)" {
    // Matches selftest.cpp pattern: encrypt with crypt20, then
    // re-init and decrypt with crypt20 — result matches original.
    const key = "12345678123456781234567812345678";
    const iv = "12345678";

    var plaintext: [256]u8 = undefined;
    for (&plaintext, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var ciphertext: [256]u8 = undefined;
    var recovered: [256]u8 = undefined;

    var ctx = Salsa20.init(key, iv);
    ctx.crypt20(&ciphertext, &plaintext);

    // Re-init resets counter to 0
    ctx.reinit(key, iv);
    ctx.crypt20(&recovered, &ciphertext);

    try std.testing.expectEqualSlices(u8, &plaintext, &recovered);
}

test "encrypt then decrypt round-trip (Salsa20/12)" {
    const key = "abcdefghijklmnopqrstuvwxyz012345";
    const iv = "nonce123";

    var plaintext: [200]u8 = undefined;
    for (&plaintext, 0..) |*b, i| {
        b.* = @truncate(i *% 7 +% 13);
    }

    var ciphertext: [200]u8 = undefined;
    var recovered: [200]u8 = undefined;

    var ctx = Salsa20.init(key, iv);
    ctx.crypt12(&ciphertext, &plaintext);

    ctx.reinit(key, iv);
    ctx.crypt12(&recovered, &ciphertext);

    try std.testing.expectEqualSlices(u8, &plaintext, &recovered);
}

test "in-place encryption (out == in)" {
    const key = [_]u8{0x42} ** 32;
    const iv = [_]u8{0x99} ** 8;

    var buf: [128]u8 = undefined;
    for (&buf, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    const original = buf;

    // Encrypt in-place
    var ctx = Salsa20.init(&key, &iv);
    ctx.crypt20(&buf, &buf);

    // Should have changed
    try std.testing.expect(!std.mem.eql(u8, &original, &buf));

    // Decrypt in-place
    ctx.reinit(&key, &iv);
    ctx.crypt20(&buf, &buf);

    // Should match original
    try std.testing.expectEqualSlices(u8, &original, &buf);
}

test "multi-block counter advancement" {
    // Verify that calling crypt12 twice with partial data produces
    // the same result as one call with all data combined. This tests
    // that the block counter advances correctly.
    const key = [_]u8{0xAB} ** 32;
    const iv = [_]u8{0xCD} ** 8;

    // One-shot: 128 bytes in one call
    const zeros = [_]u8{0} ** 128;
    var oneshot: [128]u8 = undefined;
    var ctx1 = Salsa20.init(&key, &iv);
    ctx1.crypt12(&oneshot, &zeros);

    // Two-call: 64 bytes + 64 bytes
    var twocall: [128]u8 = undefined;
    var ctx2 = Salsa20.init(&key, &iv);
    ctx2.crypt12(twocall[0..64], zeros[0..64]);
    ctx2.crypt12(twocall[64..128], zeros[64..128]);

    try std.testing.expectEqualSlices(u8, &oneshot, &twocall);
}

test "partial block counter advancement" {
    // Verify that a partial block (< 64 bytes) consumes 1 full block
    // of keystream, matching C++ behavior.
    const key = [_]u8{0x11} ** 32;
    const iv = [_]u8{0x22} ** 8;

    // Call 1: 32 bytes (half a block) — should consume block 0
    // Call 2: 64 bytes — should use block 1 (NOT block 0 remainder)
    var ctx = Salsa20.init(&key, &iv);
    var out1: [32]u8 = undefined;
    ctx.crypt12(&out1, &([_]u8{0} ** 32));
    try std.testing.expectEqual(@as(u64, 1), ctx.block_counter);

    var out2: [64]u8 = undefined;
    ctx.crypt12(&out2, &([_]u8{0} ** 64));
    try std.testing.expectEqual(@as(u64, 2), ctx.block_counter);
}

test "Packet.cpp MAC key derivation pattern" {
    // The most common Salsa20 usage in ZeroTier: Packet.cpp generates
    // a 32-byte MAC key from the first half of block 0, then encrypts
    // the payload starting at block 1.
    //
    // This test verifies the pattern works with our stateful wrapper.
    const key = [_]u8{0xDE} ** 32;
    const iv = [_]u8{0xAD} ** 8;

    // Step 1: generate 32-byte MAC key from zero bytes
    var mac_key: [32]u8 = undefined;
    var ctx = Salsa20.init(&key, &iv);
    ctx.crypt12(&mac_key, &([_]u8{0} ** 32));

    // Counter should be at 1 (consumed one block)
    try std.testing.expectEqual(@as(u64, 1), ctx.block_counter);

    // Step 2: encrypt a 100-byte payload starting at block 1
    var payload: [100]u8 = undefined;
    for (&payload, 0..) |*b, i| {
        b.* = @truncate(i);
    }
    const original_payload = payload;
    ctx.crypt12(&payload, &payload);

    // Counter should be at 3 (100 bytes = 2 blocks)
    try std.testing.expectEqual(@as(u64, 3), ctx.block_counter);

    // Decrypt: re-init, skip MAC key block, then decrypt payload
    ctx.reinit(&key, &iv);
    var mac_key2: [32]u8 = undefined;
    ctx.crypt12(&mac_key2, &([_]u8{0} ** 32));
    ctx.crypt12(&payload, &payload);

    // MAC keys should match
    try std.testing.expectEqualSlices(u8, &mac_key, &mac_key2);
    // Payload should be recovered
    try std.testing.expectEqualSlices(u8, &original_payload, &payload);
}

test "empty input is a no-op" {
    const key = [_]u8{0} ** 32;
    const iv = [_]u8{0} ** 8;

    var ctx = Salsa20.init(&key, &iv);
    var empty: [0]u8 = .{};
    ctx.crypt12(&empty, &empty);
    ctx.crypt20(&empty, &empty);

    // Counter should not advance
    try std.testing.expectEqual(@as(u64, 0), ctx.block_counter);
}

test "deinit zeros key material" {
    const key = [_]u8{0xFF} ** 32;
    const iv = [_]u8{0xEE} ** 8;

    var ctx = Salsa20.init(&key, &iv);
    ctx.deinit();

    // Key and nonce should be zeroed
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &ctx.key_data);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), &ctx.nonce_data);
    try std.testing.expectEqual(@as(u64, 0), ctx.block_counter);
}

test "memxor basic" {
    var dst = [_]u8{ 0xFF, 0x00, 0xAA, 0x55 };
    const src = [_]u8{ 0x0F, 0xF0, 0x55, 0xAA };
    memxor(&dst, &src);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xF0, 0xF0, 0xFF, 0xFF }, &dst);
}

test "memxor with zeros is identity" {
    var dst = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const original = dst;
    const zeros = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    memxor(&dst, &zeros);
    try std.testing.expectEqualSlices(u8, &original, &dst);
}

test "memxor self-XOR produces zeros" {
    var dst = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const src = dst;
    memxor(&dst, &src);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 4), &dst);
}

test "memxor large buffer" {
    var dst: [256]u8 = undefined;
    var src: [256]u8 = undefined;
    for (&dst, &src, 0..) |*d, *s, i| {
        d.* = @truncate(i);
        s.* = @truncate(i ^ 0xFF);
    }
    memxor(&dst, &src);
    for (dst, 0..) |d, i| {
        const byte_i: u8 = @truncate(i);
        const expected: u8 = byte_i ^ (byte_i ^ 0xFF);
        try std.testing.expectEqual(expected, d);
    }
}

test "memxor empty slices" {
    var empty: [0]u8 = .{};
    memxor(&empty, &empty);
    // Should not crash
}

test "blocksConsumed" {
    try std.testing.expectEqual(@as(u64, 0), blocksConsumed(0));
    try std.testing.expectEqual(@as(u64, 1), blocksConsumed(1));
    try std.testing.expectEqual(@as(u64, 1), blocksConsumed(32));
    try std.testing.expectEqual(@as(u64, 1), blocksConsumed(63));
    try std.testing.expectEqual(@as(u64, 1), blocksConsumed(64));
    try std.testing.expectEqual(@as(u64, 2), blocksConsumed(65));
    try std.testing.expectEqual(@as(u64, 2), blocksConsumed(128));
    try std.testing.expectEqual(@as(u64, 3), blocksConsumed(129));
}

test "constants match C++ values" {
    try std.testing.expectEqual(32, key_length);
    try std.testing.expectEqual(8, nonce_length);
    try std.testing.expectEqual(64, block_length);
    try std.testing.expectEqual(key_length, Salsa12.key_length);
    try std.testing.expectEqual(nonce_length, Salsa12.nonce_length);
    try std.testing.expectEqual(key_length, Salsa20Cipher.key_length);
    try std.testing.expectEqual(nonce_length, Salsa20Cipher.nonce_length);
}
