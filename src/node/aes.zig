/// AES-256 and associated constructions for ZeroTier.
///
/// Converted from `node/AES.hpp`, `node/AES.cpp`, `node/AES_aesni.cpp`,
/// and `node/AES_armcrypto.cpp` (~2,382 lines of C/C++).
///
/// Provides:
///   - AES-256 single-block ECB encrypt/decrypt
///   - Streaming GMAC (GHASH + AES)
///   - Streaming AES-CTR (32-bit big-endian counter)
///   - AES-GMAC-SIV authenticated encryption/decryption
///
/// Hardware acceleration (AES-NI on x86-64, ARM Crypto Extensions on
/// aarch64) is provided automatically by the Zig standard library at
/// compile time — no runtime detection is needed.
const std = @import("std");

const Aes256 = std.crypto.core.aes.Aes256;
const Aes256EncryptCtx = std.crypto.core.aes.AesEncryptCtx(Aes256);
const Aes256DecryptCtx = std.crypto.core.aes.AesDecryptCtx(Aes256);
const Ghash = std.crypto.onetimeauth.Ghash;
const modes = std.crypto.core.modes;

// ── Public constants ───────────────────────────────────────────────

/// True if this platform has hardware AES acceleration.
pub const has_hardware_support: bool = std.crypto.core.aes.has_hardware_support;

/// AES block size in bytes.
pub const block_len: comptime_int = 16;

// ── Aes (top-level cipher) ────────────────────────────────────────

/// AES-256 block cipher.
///
/// Wraps Zig stdlib `Aes256` with an API matching the C++ `AES` class.
/// Key material is securely zeroed on `deinit`.
pub const Aes = struct {
    enc_ctx: Aes256EncryptCtx,
    dec_ctx: Aes256DecryptCtx,

    /// Initialize with a 256-bit (32-byte) key.
    pub fn init(key: *const [32]u8) Aes {
        const enc = Aes256.initEnc(key.*);
        return .{
            .enc_ctx = enc,
            .dec_ctx = Aes256DecryptCtx.initFromEnc(enc),
        };
    }

    /// Encrypt a single 16-byte block (ECB mode).
    pub fn encrypt(self: *const Aes, in_block: *const [16]u8) [16]u8 {
        var out: [16]u8 = undefined;
        self.enc_ctx.encrypt(&out, in_block);
        return out;
    }

    /// Decrypt a single 16-byte block (ECB mode).
    pub fn decrypt(self: *const Aes, in_block: *const [16]u8) [16]u8 {
        var out: [16]u8 = undefined;
        self.dec_ctx.decrypt(&out, in_block);
        return out;
    }

    /// Encrypt a block in-place.
    pub fn encryptInPlace(self: *const Aes, block: *[16]u8) void {
        var out: [16]u8 = undefined;
        self.enc_ctx.encrypt(&out, block);
        block.* = out;
    }

    /// Decrypt a block in-place.
    pub fn decryptInPlace(self: *const Aes, block: *[16]u8) void {
        var out: [16]u8 = undefined;
        self.dec_ctx.decrypt(&out, block);
        block.* = out;
    }

    /// Securely zero key material.
    pub fn deinit(self: *Aes) void {
        const enc_bytes: *[@sizeOf(Aes256EncryptCtx)]u8 = @ptrCast(
            &self.enc_ctx,
        );
        std.crypto.secureZero(u8, enc_bytes);
        const dec_bytes: *[@sizeOf(Aes256DecryptCtx)]u8 = @ptrCast(
            &self.dec_ctx,
        );
        std.crypto.secureZero(u8, dec_bytes);
    }
};

// ── GMAC ──────────────────────────────────────────────────────────

/// Streaming GMAC calculator (GHASH + AES-encrypted counter).
///
/// Matches the C++ `AES::GMAC` class. Uses Zig stdlib `GHash` for
/// the polynomial hashing which automatically uses PCLMUL or PMULL
/// when available.
///
/// Protocol:
///   1. Call `initGmac()` with a 96-bit IV.
///   2. Call `update()` one or more times with data.
///   3. Call `finish()` to produce the 128-bit tag.
pub const Gmac = struct {
    /// BORROWED: reference to the keyed AES instance for IV encryption.
    aes: *const Aes,
    ghash: Ghash,
    iv: [16]u8,
    remainder: [16]u8,
    remainder_len: u4,
    total_len: u64,

    /// Create an uninitialized GMAC bound to a keyed AES instance.
    pub fn initCtx(aes: *const Aes) Gmac {
        return .{
            .aes = aes,
            .ghash = undefined,
            .iv = undefined,
            .remainder = undefined,
            .remainder_len = 0,
            .total_len = 0,
        };
    }

    /// Reset and initialize for a new GMAC calculation.
    ///
    /// The IV is 96 bits (12 bytes). The remaining 32 bits are set to
    /// the big-endian value 1 (the fixed counter for GMAC, matching
    /// the GCM J0 derivation for 96-bit nonces).
    pub fn initGmac(self: *Gmac, iv: *const [12]u8) void {
        // Derive GHASH key H = AES_K(0^128).
        const zero_block = [_]u8{0} ** 16;
        const h = self.aes.encrypt(&zero_block);
        self.ghash = Ghash.init(&h);

        // Set IV: 96-bit nonce || big-endian counter = 1.
        @memcpy(self.iv[0..12], iv);
        self.iv[12] = 0;
        self.iv[13] = 0;
        self.iv[14] = 0;
        self.iv[15] = 1;

        self.remainder_len = 0;
        self.total_len = 0;
    }

    /// Process data through GMAC (streaming).
    pub fn update(self: *Gmac, data: []const u8) void {
        self.total_len += data.len;

        var remaining = data;

        // If we have buffered partial-block data, fill it first.
        if (self.remainder_len > 0) {
            const need: usize = 16 - @as(usize, self.remainder_len);
            if (remaining.len < need) {
                // Still not enough for a full block.
                @memcpy(
                    self.remainder[self.remainder_len..][0..remaining.len],
                    remaining,
                );
                self.remainder_len += @intCast(remaining.len);
                return;
            }
            @memcpy(self.remainder[self.remainder_len..16], remaining[0..need]);
            self.ghash.update(&self.remainder);
            remaining = remaining[need..];
            self.remainder_len = 0;
        }

        // Process full 16-byte blocks.
        const full_blocks = remaining.len / 16 * 16;
        if (full_blocks > 0) {
            self.ghash.update(remaining[0..full_blocks]);
            remaining = remaining[full_blocks..];
        }

        // Buffer any leftover bytes.
        if (remaining.len > 0) {
            @memcpy(self.remainder[0..remaining.len], remaining);
            self.remainder_len = @intCast(remaining.len);
        }
    }

    /// Finalize and produce the 128-bit GMAC tag.
    ///
    /// After calling this, the instance must be re-initialized before
    /// further use.
    pub fn finish(self: *Gmac) [16]u8 {
        // Pad any remaining partial block with zeros.
        if (self.remainder_len > 0) {
            @memset(self.remainder[self.remainder_len..16], 0);
            self.ghash.update(&self.remainder);
        }

        // GCM length block: 0 bits of AAD (for standalone GMAC, data
        // IS the AAD) || len(data) in bits.
        //
        // Wait — in ZeroTier's usage, GMAC is used as a pure MAC where
        // all input is AAD (there's no ciphertext in the GCM sense).
        // The length encoding matches standard GHASH finalization:
        // hash in a 128-bit block of (0 || len_bits) in big-endian.
        var len_block: [16]u8 = [_]u8{0} ** 16;
        const len_bits: u64 = self.total_len << 3;
        std.mem.writeInt(u64, len_block[0..8], 0, .big); // AAD length = 0
        // Actually in ZeroTier's GMAC the data IS the authenticated data,
        // and the length is encoded in the first 8 bytes.
        // Looking at the C++ code: y0 ^= hton((uint64_t)_len << 3);
        // That XORs into y0 which is the FIRST half — so it's:
        //   data_len_bits (8 bytes, BE) || 0 (8 bytes)
        // This is non-standard! Standard GHASH finalization is:
        //   aad_len_bits (8 BE) || ct_len_bits (8 BE)
        // But ZeroTier only XORs the data length into y0 (first 8 bytes)
        // and leaves y1 untouched.
        //
        // We must replicate this exactly. The stdlib Ghash finalization
        // does NOT match this, so we need to manually finalize.

        // Manual GHASH finalization: XOR in the length block and multiply.
        std.mem.writeInt(u64, len_block[0..8], len_bits, .big);
        // len_block[8..16] remains zero — matching the C++ behavior.
        self.ghash.update(&len_block);

        // Get the GHASH result.
        var ghash_tag: [16]u8 = undefined;
        self.ghash.final(&ghash_tag);

        // XOR with AES_K(IV || counter=1) to produce the final tag.
        const encrypted_iv = self.aes.encrypt(&self.iv);
        for (&ghash_tag, encrypted_iv) |*g, e| {
            g.* ^= e;
        }

        return ghash_tag;
    }
};

// ── CTR ───────────────────────────────────────────────────────────

/// Streaming AES-CTR encryption/decryption.
///
/// Matches the C++ `AES::CTR` class. Only the least significant 32
/// bits of the counter are incremented (big-endian). This limits
/// input to 2^36 bytes (64 GiB) per IV which is sufficient for
/// ZeroTier's packet-level usage.
///
/// The streaming interface accumulates input and writes XOR'd output
/// to a pre-allocated buffer. Partial blocks at the end are handled
/// by `finish()`.
pub const Ctr = struct {
    /// BORROWED: reference to the keyed AES instance.
    aes: *const Aes,
    ctr_block: [16]u8,
    /// BORROWED: pre-allocated output buffer pointer.
    output: [*]u8,
    total_len: u32,

    /// Create a CTR instance bound to a keyed AES instance.
    pub fn initCtx(aes: *const Aes) Ctr {
        return .{
            .aes = aes,
            .ctr_block = undefined,
            .output = undefined,
            .total_len = 0,
        };
    }

    /// Initialize with a full 128-bit IV (including counter portion).
    pub fn initWithIv(self: *Ctr, iv: *const [16]u8, output: [*]u8) void {
        self.ctr_block = iv.*;
        self.output = output;
        self.total_len = 0;
    }

    /// Initialize with a 96-bit IV and 32-bit initial counter (big-endian).
    pub fn initWithIvAndCounter(
        self: *Ctr,
        iv: *const [12]u8,
        initial_counter: u32,
        output: [*]u8,
    ) void {
        @memcpy(self.ctr_block[0..12], iv);
        std.mem.writeInt(u32, self.ctr_block[12..16], initial_counter, .big);
        self.output = output;
        self.total_len = 0;
    }

    /// Encrypt/decrypt data (XOR with AES-CTR keystream).
    ///
    /// Output is written to the buffer provided at init time, starting
    /// at offset `total_len`. Multiple calls accumulate.
    pub fn crypt(self: *Ctr, input: []const u8) void {
        var remaining = input;
        var out = self.output + self.total_len;

        // Handle partial block from previous call.
        const partial = self.total_len & 0xf;
        if (partial != 0) {
            // First, copy raw input bytes into the output at the current
            // position (matching C++ behavior where partial bytes are
            // stored un-XOR'd, then completed when the block fills).
            while (remaining.len > 0) {
                out[0] = remaining[0];
                out += 1;
                remaining = remaining[1..];
                self.total_len += 1;

                if ((self.total_len & 0xf) == 0) {
                    // Block is now complete — encrypt counter and XOR.
                    const keystream = self.aes.encrypt(&self.ctr_block);
                    self.incrementCounter();
                    const block_start = self.output + (self.total_len - 16);
                    for (0..16) |i| {
                        block_start[i] ^= keystream[i];
                    }
                    break;
                }
            }
            out = self.output + self.total_len;
        }

        // Process full 16-byte blocks.
        while (remaining.len >= 16) {
            const keystream = self.aes.encrypt(&self.ctr_block);
            self.incrementCounter();
            for (0..16) |i| {
                out[i] = remaining[i] ^ keystream[i];
            }
            out += 16;
            remaining = remaining[16..];
            self.total_len += 16;
        }

        // Store any leftover bytes (un-XOR'd until finish() or next crypt()).
        for (remaining) |byte| {
            out[0] = byte;
            out += 1;
        }
        self.total_len += @intCast(remaining.len);
    }

    /// Process any remaining partial block.
    ///
    /// Must be called once after the last `crypt()` call if the total
    /// length is not a multiple of 16.
    pub fn finish(self: *Ctr) void {
        const rem = self.total_len & 0xf;
        if (rem != 0) {
            const keystream = self.aes.encrypt(&self.ctr_block);
            const block_start = self.output + (self.total_len - rem);
            for (0..rem) |i| {
                block_start[i] ^= keystream[i];
            }
        }
    }

    /// Increment the 32-bit big-endian counter in bytes [12..16].
    fn incrementCounter(self: *Ctr) void {
        const val = std.mem.readInt(u32, self.ctr_block[12..16], .big);
        std.mem.writeInt(u32, self.ctr_block[12..16], val +% 1, .big);
    }
};

// ── GMACSIVEncryptor ──────────────────────────────────────────────

/// Two-pass GMAC-SIV authenticated encryption.
///
/// Matches the C++ `AES::GMACSIVEncryptor`. Uses two AES keys:
///   - K0: for GMAC (authentication)
///   - K1: for AES-CTR (encryption) and tag encryption
///
/// Protocol:
///   1. `initEnc()` — set 64-bit IV and output buffer
///   2. `aad()` — optional additional authenticated data
///   3. `update1()` — first pass: feed plaintext into GMAC
///   4. `finish1()` — compute MAC, derive CTR nonce
///   5. `update2()` — second pass: CTR-encrypt plaintext
///   6. `finish2()` — finalize, returns 128-bit tag
pub const GmacSivEncryptor = struct {
    gmac: Gmac,
    ctr: Ctr,
    /// BORROWED: output buffer pointer.
    output_ptr: ?[*]u8,
    tag: [16]u8,

    /// Create an encryptor with two AES key instances.
    pub fn init(k0: *const Aes, k1: *const Aes) GmacSivEncryptor {
        return .{
            .gmac = Gmac.initCtx(k0),
            .ctr = Ctr.initCtx(k1),
            .output_ptr = null,
            .tag = undefined,
        };
    }

    /// Initialize for a new message.
    ///
    /// `iv` is a 64-bit value in network byte order (as it appears on
    /// the wire). `output` must be large enough for all plaintext.
    pub fn initEnc(self: *GmacSivEncryptor, iv: u64, output: [*]u8) void {
        self.output_ptr = output;

        // Store IV in tag[0..8], zero tag[8..16].
        std.mem.writeInt(u64, self.tag[0..8], iv, .big);
        @memset(self.tag[8..16], 0);

        // Initialize GMAC with 96-bit IV (64-bit IV + 32 bits of zero).
        // The C++ code does: _tag[0] = iv; _tag[1] = 0;
        //                    _gmac.init(reinterpret_cast<uint8_t*>(_tag));
        // On a little-endian machine, _tag[0] (uint64_t) stored at byte
        // offset 0 has the least-significant byte first. So the 12-byte
        // IV passed to GMAC.init is the LE representation of the u64 iv
        // followed by 4 zero bytes.
        //
        // But wait — the iv parameter is documented as "in network byte
        // order (byte order in which it will appear on the wire)". This
        // means the caller stores it as a u64 in native byte order (the
        // value IS the packet ID), and it's cast to bytes through the
        // pointer. On LE machines (all targets): bytes are LE.
        //
        // For wire compatibility we must replicate the exact byte layout.
        // The C++ stores the u64 iv as a native-endian uint64_t at
        // _tag[0], then passes the byte representation to GMAC.init.
        // On little-endian: _tag bytes are LE(iv) || 0x00000000.
        //
        // We need to write the iv in NATIVE byte order to match C++.
        std.mem.writeInt(u64, self.tag[0..8], iv, .little);
        @memset(self.tag[8..16], 0);

        self.gmac.initGmac(self.tag[0..12]);
    }

    /// Process additional authenticated data (not encrypted).
    ///
    /// Must be called before `update1()`. Pads to 16-byte boundary.
    pub fn aad(self: *GmacSivEncryptor, aad_data: []const u8) void {
        self.gmac.update(aad_data);

        // Pad to 16-byte boundary.
        const pad_len = aad_data.len & 0xf;
        if (pad_len != 0) {
            const zeros = [_]u8{0} ** 16;
            self.gmac.update(zeros[0 .. 16 - pad_len]);
        }
    }

    /// First pass: feed plaintext into GMAC.
    pub fn update1(self: *GmacSivEncryptor, input: []const u8) void {
        self.gmac.update(input);
    }

    /// Complete first pass: compute MAC, derive CTR IV.
    pub fn finish1(self: *GmacSivEncryptor) void {
        // Compute 128-bit GMAC tag.
        const gmac_tag = self.gmac.finish();

        // XOR-fold 128-bit tag to 64-bit: tag[1] = tmp[0] ^ tmp[1].
        // The C++ does: _tag[1] = tmp[0] ^ tmp[1] (as uint64_t).
        const tmp0 = std.mem.readInt(u64, gmac_tag[0..8], .little);
        const tmp1 = std.mem.readInt(u64, gmac_tag[8..16], .little);
        std.mem.writeInt(u64, self.tag[8..16], tmp0 ^ tmp1, .little);

        // Encrypt the tag with K1: _tag = AES_K1(_tag).
        self.ctr.aes.encryptInPlace(&self.tag);

        // Derive CTR nonce: clear MSB of counter portion to allow
        // 2^31 bytes of input. The C++ does:
        //   tmp[1] = _tag[1] & ZT_CONST_TO_BE_UINT64(0xffffffff7fffffff)
        // On little-endian this masks byte 11 (bit 7 of the 4th counter byte).
        var ctr_iv: [16]u8 = self.tag;
        // The mask 0xffffffff7fffffff in big-endian means: in the second
        // u64 (bytes 8-15), clear bit 31 counting from MSB. This is byte
        // offset 12 from the start (3rd byte of second u64 in BE), or
        // in memory terms the mask clears bit 7 of byte[11] on LE.
        //
        // Actually, let me trace through the C++ more carefully:
        //   uint64_t tmp[2]; tmp[0] = _tag[0]; tmp[1] = _tag[1] & MASK;
        //   _ctr.init(reinterpret_cast<uint8_t*>(tmp), _output);
        //
        // ZT_CONST_TO_BE_UINT64(0xffffffff7fffffffULL) on LE becomes
        // the byte-swapped value. Let me compute:
        //   0xffffffff7fffffff in big-endian bytes:
        //     ff ff ff ff 7f ff ff ff
        //   On a LE machine, ZT_CONST_TO_BE_UINT64 byte-swaps it to:
        //     0xffffff7fffffffff (native u64)
        //   So _tag[1] & 0xffffff7fffffffff masks byte[3] of the
        //   second u64 (byte[11] of the 16-byte block), clearing bit 7.
        //
        // Wait — let me be more precise. _tag is uint64_t[2]:
        //   _tag[0] occupies bytes 0..7
        //   _tag[1] occupies bytes 8..15
        // On LE, _tag[1] = X means bytes 8..15 store X in LE.
        //   X & 0xffffff7fffffffff:
        //     bits of X:     byte[8]=b0, byte[9]=b1, ..., byte[15]=b7
        //     mask in LE:    ff ff ff ff ff ff 7f ff
        //     → byte[14] has bit 7 cleared (0x7f).
        //
        // Hmm, let me just work with the actual bytes. The mask
        // ZT_CONST_TO_BE_UINT64(0xffffffff7fffffffULL) on LE:
        //   Original bytes of 0xffffffff7fffffff (8 bytes, big-endian):
        //     [0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff]
        //   This is what gets stored in the u64 on a big-endian machine.
        //   On LE, ZT_CONST_TO_BE_UINT64 converts to big-endian repr,
        //   so the MEMORY layout is:
        //     [0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff]
        //   regardless of machine endianness!
        //
        // So the mask applied to tmp[1] in MEMORY is:
        //   bytes 8-15: AND with [ff, ff, ff, ff, 7f, ff, ff, ff]
        // That clears bit 7 of byte[12] (offset 4 within second u64).
        // Since CTR.init interprets this as a 128-bit IV with the counter
        // in the last 4 bytes (bytes 12-15), byte[12] is the MSB of the
        // 32-bit counter.
        ctr_iv[12] &= 0x7f;

        self.ctr.initWithIv(&ctr_iv, self.output_ptr.?);
    }

    /// Second pass: CTR-encrypt plaintext.
    pub fn update2(self: *GmacSivEncryptor, input: []const u8) void {
        self.ctr.crypt(input);
    }

    /// Finalize encryption. Returns the 128-bit tag (IV+MAC).
    pub fn finish2(self: *GmacSivEncryptor) *const [16]u8 {
        self.ctr.finish();
        return &self.tag;
    }
};

// ── GMACSIVDecryptor ──────────────────────────────────────────────

/// Single-pass GMAC-SIV authenticated decryption.
///
/// Matches the C++ `AES::GMACSIVDecryptor`.
///
/// Protocol:
///   1. `initDec()` — provide received 128-bit tag and output buffer
///   2. `aad()` — optional AAD (same as encryption)
///   3. `update()` — feed ciphertext (decrypted via CTR in one pass)
///   4. `finish()` — verify MAC, return true if authentic
pub const GmacSivDecryptor = struct {
    gmac: Gmac,
    ctr: Ctr,
    iv_mac: [16]u8,
    /// BORROWED: output buffer for decrypted plaintext.
    output_ptr: ?[*]u8,
    decrypted_len: u32,

    /// Create a decryptor with two AES key instances.
    pub fn init(k0: *const Aes, k1: *const Aes) GmacSivDecryptor {
        return .{
            .gmac = Gmac.initCtx(k0),
            .ctr = Ctr.initCtx(k1),
            .iv_mac = undefined,
            .output_ptr = null,
            .decrypted_len = 0,
        };
    }

    /// Initialize for decryption.
    ///
    /// `tag` is the 128-bit combined IV/MAC received from the sender.
    pub fn initDec(
        self: *GmacSivDecryptor,
        tag: *const [16]u8,
        output: [*]u8,
    ) void {
        // Derive CTR nonce from tag (clear MSB of counter).
        var ctr_iv: [16]u8 = tag.*;
        ctr_iv[12] &= 0x7f;
        self.ctr.initWithIv(&ctr_iv, output);

        // Decrypt tag with AES_K1 to recover original [IV, folded_mac].
        self.iv_mac = self.ctr.aes.decrypt(tag);

        // Initialize GMAC with 96-bit IV (first 8 bytes = IV, next 4 = 0).
        // The C++ does: tmp[0] = _ivMac[0]; tmp[1] = 0;
        //               _gmac.init(reinterpret_cast<uint8_t*>(tmp));
        var gmac_iv: [12]u8 = undefined;
        @memcpy(gmac_iv[0..8], self.iv_mac[0..8]);
        @memset(gmac_iv[8..12], 0);
        self.gmac.initGmac(&gmac_iv);

        self.output_ptr = output;
        self.decrypted_len = 0;
    }

    /// Process AAD (same as encryption side).
    pub fn aad(self: *GmacSivDecryptor, aad_data: []const u8) void {
        self.gmac.update(aad_data);
        const pad_len = aad_data.len & 0xf;
        if (pad_len != 0) {
            const zeros = [_]u8{0} ** 16;
            self.gmac.update(zeros[0 .. 16 - pad_len]);
        }
    }

    /// Feed ciphertext for decryption (CTR mode).
    pub fn update(self: *GmacSivDecryptor, input: []const u8) void {
        self.ctr.crypt(input);
        self.decrypted_len += @intCast(input.len);
    }

    /// Finalize decryption and verify MAC.
    ///
    /// Returns true if the MAC is valid (plaintext is authentic).
    pub fn finish(self: *GmacSivDecryptor) bool {
        self.ctr.finish();

        // Feed decrypted plaintext into GMAC.
        const pt_slice = self.output_ptr.?[0..self.decrypted_len];
        self.gmac.update(pt_slice);

        // Finalize GMAC and XOR-fold.
        const gmac_tag = self.gmac.finish();
        const tag0 = std.mem.readInt(u64, gmac_tag[0..8], .little);
        const tag1 = std.mem.readInt(u64, gmac_tag[8..16], .little);
        const folded = tag0 ^ tag1;

        // Compare with stored folded MAC.
        const expected = std.mem.readInt(u64, self.iv_mac[8..16], .little);
        return folded == expected;
    }
};

// ── Tests ──────────────────────────────────────────────────────────
//
// Tests are organized as:
//   1. NIST / public test vectors (AES-256 ECB)
//   2. C++ cross-validation vectors (GMAC, CTR, GMAC-SIV)
//   3. Structural / roundtrip / rejection tests
//
// Cross-validation vectors were generated by `tmp/gen_aes_vectors.cpp`
// which uses the C++ `AES` class directly.

const testing = std.testing;

/// Parse a comptime hex string into a byte array.
fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var result: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch unreachable;
    return result;
}

// ── 1. NIST / Public Test Vectors ─────────────────────────────────

test "AES-256 ECB NIST test vector" {
    // NIST FIPS 197 AES-256 test vector.
    const key = hexToBytes("000102030405060708090a0b0c0d0e0f" ++
        "101112131415161718191a1b1c1d1e1f");
    const plaintext = hexToBytes("00112233445566778899aabbccddeeff");
    const expected = hexToBytes("8ea2b7ca516745bfeafc49904b496089");

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    const ciphertext = aes_ctx.encrypt(&plaintext);
    try testing.expectEqualSlices(u8, &expected, &ciphertext);

    const decrypted = aes_ctx.decrypt(&ciphertext);
    try testing.expectEqualSlices(u8, &plaintext, &decrypted);
}

// ── 2. C++ Cross-Validation Vectors ───────────────────────────────

test "GMAC: 48-byte data cross-validation" {
    // C++: GMAC(key=0x42*32, iv=0x01*12, data=0x00..0x2f)
    //      tag = d8daa0127e451de1c3aef9183e8829ee
    const key = [_]u8{0x42} ** 32;
    const iv = [_]u8{0x01} ** 12;
    var data: [48]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);

    const expected_tag = hexToBytes("d8daa0127e451de1c3aef9183e8829ee");

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();
    var gmac = Gmac.initCtx(&aes_ctx);
    gmac.initGmac(&iv);
    gmac.update(&data);
    const tag = gmac.finish();
    try testing.expectEqualSlices(u8, &expected_tag, &tag);
}

test "GMAC: empty data cross-validation" {
    // C++: GMAC(key=0xaa*32, iv=0xbb*12, empty)
    //      tag = b8158b02f1a3faa3eb59e1b01dfec355
    const key = [_]u8{0xaa} ** 32;
    const iv = [_]u8{0xbb} ** 12;
    const expected_tag = hexToBytes("b8158b02f1a3faa3eb59e1b01dfec355");

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();
    var gmac = Gmac.initCtx(&aes_ctx);
    gmac.initGmac(&iv);
    const tag = gmac.finish();
    try testing.expectEqualSlices(u8, &expected_tag, &tag);
}

test "GMAC: 7-byte partial block cross-validation" {
    // C++: GMAC(key=0x55*32, iv=0x77*12, data=deadbeefcafe42)
    //      tag = a26b4aa20405aa1065b71241450bd442
    const key = [_]u8{0x55} ** 32;
    const iv = [_]u8{0x77} ** 12;
    const data = hexToBytes("deadbeefcafe42");
    const expected_tag = hexToBytes("a26b4aa20405aa1065b71241450bd442");

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();
    var gmac = Gmac.initCtx(&aes_ctx);
    gmac.initGmac(&iv);
    gmac.update(&data);
    const tag = gmac.finish();
    try testing.expectEqualSlices(u8, &expected_tag, &tag);
}

test "GMAC: chunked matches single-shot cross-validation" {
    // Same input as the 48-byte GMAC test, but fed in chunks.
    // C++ result: d8daa0127e451de1c3aef9183e8829ee
    const key = [_]u8{0x42} ** 32;
    const iv = [_]u8{0x01} ** 12;
    var data: [48]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);

    const expected_tag = hexToBytes("d8daa0127e451de1c3aef9183e8829ee");

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();
    var gmac = Gmac.initCtx(&aes_ctx);
    gmac.initGmac(&iv);

    // Feed in varied chunk sizes: 5, 11, 16, 3, 13.
    gmac.update(data[0..5]);
    gmac.update(data[5..16]);
    gmac.update(data[16..32]);
    gmac.update(data[32..35]);
    gmac.update(data[35..48]);

    const tag = gmac.finish();
    try testing.expectEqualSlices(u8, &expected_tag, &tag);
}

test "AES-CTR: cross-validation with C++ output" {
    // C++: AES-CTR(key=0x55*32, iv=0x01*12, ctr=0,
    //      pt="Hello, ZeroTier AES-CTR streaming test! This is longer than 16 bytes.")
    //      ct=fdf54bcbc5d0d571...a69e7885c
    const key = [_]u8{0x55} ** 32;
    const iv = [_]u8{0x01} ** 12;
    const plaintext = "Hello, ZeroTier AES-CTR streaming test! " ++
        "This is longer than 16 bytes.";
    const expected_ct = hexToBytes(
        "fdf54bcbc5d0d57141556c17e1f2661b" ++
            "0f7a6b2d2f23db1ccffea516cba37dbb" ++
            "8b555e6a19dbcfcd08c82151ec049721" ++
            "d5b66816ad058f1eb50e118e605f6329" ++
            "ba69e7885c",
    );

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    var ciphertext: [plaintext.len]u8 = undefined;
    var ctr_ctx = Ctr.initCtx(&aes_ctx);
    ctr_ctx.initWithIvAndCounter(&iv, 0, &ciphertext);
    ctr_ctx.crypt(plaintext);
    ctr_ctx.finish();

    try testing.expectEqualSlices(u8, &expected_ct, &ciphertext);
}

test "GMAC-SIV: cross-validation with C++ output" {
    // C++: key0[i]=i*3, key1[i]=i*7+1, iv=0x123456789abcdef0
    //      pt = "Hello, ZeroTier GMAC-SIV test!"
    //      ct = 54c6e7452c38758909df116349992ada5fd5601a639d4fb871d1c5ab388b
    //      tag = 41604e2df8f9e6472cadf02ff9dcf574
    var key0: [32]u8 = undefined;
    for (&key0, 0..) |*b, i| b.* = @intCast((i *% 3) & 0xff);
    var key1: [32]u8 = undefined;
    for (&key1, 0..) |*b, i| b.* = @intCast((i *% 7 +% 1) & 0xff);

    const iv: u64 = 0x123456789abcdef0;
    const plaintext = "Hello, ZeroTier GMAC-SIV test!";
    const expected_ct = hexToBytes(
        "54c6e7452c38758909df116349992ada" ++
            "5fd5601a639d4fb871d1c5ab388b",
    );
    const expected_tag = hexToBytes("41604e2df8f9e6472cadf02ff9dcf574");

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    // Encrypt.
    var ciphertext: [plaintext.len]u8 = undefined;
    var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, &ciphertext);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    const tag = enc.finish2().*;

    try testing.expectEqualSlices(u8, &expected_ct, &ciphertext);
    try testing.expectEqualSlices(u8, &expected_tag, &tag);

    // Decrypt and verify.
    var decrypted: [plaintext.len]u8 = undefined;
    var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
    dec.initDec(&tag, &decrypted);
    dec.update(&ciphertext);
    try testing.expect(dec.finish());
    try testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "GMAC-SIV with AAD: cross-validation with C++ output" {
    // C++: key0[i]=0xaa^i, key1[i]=0xbb^i, iv=42
    //      aad = "additional authenticated data"
    //      pt  = "payload with AAD"
    //      ct  = 6341b06de00ae30ee64c8d54127311b2
    //      tag = dc215e0b2d938596733e3b2027b77d1d
    var key0: [32]u8 = undefined;
    for (&key0, 0..) |*b, i| b.* = @intCast(0xaa ^ (i & 0xff));
    var key1: [32]u8 = undefined;
    for (&key1, 0..) |*b, i| b.* = @intCast(0xbb ^ (i & 0xff));

    const iv: u64 = 42;
    const plaintext = "payload with AAD";
    const aad_data = "additional authenticated data";
    const expected_ct = hexToBytes("6341b06de00ae30ee64c8d54127311b2");
    const expected_tag = hexToBytes("dc215e0b2d938596733e3b2027b77d1d");

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    // Encrypt.
    var ciphertext: [plaintext.len]u8 = undefined;
    var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, &ciphertext);
    enc.aad(aad_data);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    const tag = enc.finish2().*;

    try testing.expectEqualSlices(u8, &expected_ct, &ciphertext);
    try testing.expectEqualSlices(u8, &expected_tag, &tag);

    // Decrypt and verify.
    var decrypted: [plaintext.len]u8 = undefined;
    var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
    dec.initDec(&tag, &decrypted);
    dec.aad(aad_data);
    dec.update(&ciphertext);
    try testing.expect(dec.finish());
    try testing.expectEqualSlices(u8, plaintext, &decrypted);
}

test "GMAC-SIV various lengths: cross-validation with C++ tags" {
    // C++: key0=0x56*32, key1=0x78*32, iv=len, data=0x00..len-1
    const key0 = [_]u8{0x56} ** 32;
    const key1 = [_]u8{0x78} ** 32;

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    const TestCase = struct { len: usize, expected_tag: [16]u8 };
    const cases = [_]TestCase{
        .{ .len = 0, .expected_tag = hexToBytes("34c1e3b7249eee264da409f7bfe8a028") },
        .{ .len = 1, .expected_tag = hexToBytes("a11a6373143c1401369d2264168b0682") },
        .{ .len = 15, .expected_tag = hexToBytes("afb2f22dc6adc54a02f2404648140055") },
        .{ .len = 16, .expected_tag = hexToBytes("23ac8c3a5e7d78b72d8a056f18bc21b2") },
        .{ .len = 17, .expected_tag = hexToBytes("22d0705042d493ad753b2b5351cc5432") },
        .{ .len = 31, .expected_tag = hexToBytes("4935be49411a762d0da5984b8f87bcd3") },
        .{ .len = 32, .expected_tag = hexToBytes("da7f9afee895b4085d5a0b85840fcfb7") },
        .{ .len = 100, .expected_tag = hexToBytes("b716ae66815627cfad4632d69c8e6f6a") },
    };

    var plaintext_buf: [100]u8 = undefined;
    for (&plaintext_buf, 0..) |*b, i| b.* = @intCast(i & 0xff);

    for (cases) |tc| {
        const pt = plaintext_buf[0..tc.len];
        var ct_buf: [100]u8 = undefined;
        const ct = ct_buf[0..tc.len];

        var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
        enc.initEnc(@intCast(tc.len), ct.ptr);
        enc.update1(pt);
        enc.finish1();
        enc.update2(pt);
        const tag: [16]u8 = enc.finish2().*;

        try testing.expectEqualSlices(u8, &tc.expected_tag, &tag);

        // Also verify roundtrip decryption.
        var dec_buf: [100]u8 = undefined;
        const dec_out = dec_buf[0..tc.len];
        var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
        dec.initDec(&tag, dec_out.ptr);
        dec.update(ct);
        try testing.expect(dec.finish());
        try testing.expectEqualSlices(u8, pt, dec_out);
    }
}

// ── 3. Structural / Roundtrip / Rejection Tests ───────────────────

test "AES-256 ECB encrypt-decrypt roundtrip" {
    const key = [_]u8{0xab} ** 32;
    const plaintext = [_]u8{
        0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    };

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    const ct = aes_ctx.encrypt(&plaintext);
    const pt = aes_ctx.decrypt(&ct);
    try testing.expectEqualSlices(u8, &plaintext, &pt);
    try testing.expect(!std.mem.eql(u8, &plaintext, &ct));
}

test "AES-256 in-place encrypt/decrypt" {
    const key = [_]u8{0x42} ** 32;
    const original = [_]u8{
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
        0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0, 0x00,
    };

    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    var block = original;
    aes_ctx.encryptInPlace(&block);
    try testing.expect(!std.mem.eql(u8, &original, &block));

    aes_ctx.decryptInPlace(&block);
    try testing.expectEqualSlices(u8, &original, &block);
}

test "CTR mode: chunked streaming matches single-shot" {
    const key = [_]u8{0x99} ** 32;
    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    const iv = [_]u8{0xaa} ** 12;
    const plaintext = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" ++
        "abcdefghijklmnopqrstuvwxyz!@";

    // Single-shot.
    var ct_single: [plaintext.len]u8 = undefined;
    var ctr1 = Ctr.initCtx(&aes_ctx);
    ctr1.initWithIvAndCounter(&iv, 1, &ct_single);
    ctr1.crypt(plaintext);
    ctr1.finish();

    // Chunked (various sizes).
    var ct_chunked: [plaintext.len]u8 = undefined;
    var ctr2 = Ctr.initCtx(&aes_ctx);
    ctr2.initWithIvAndCounter(&iv, 1, &ct_chunked);

    var offset: usize = 0;
    const chunk_sizes = [_]usize{ 5, 11, 16, 3, 17, 1, plaintext.len - 53 };
    for (chunk_sizes) |size| {
        ctr2.crypt(plaintext[offset .. offset + size]);
        offset += size;
    }
    ctr2.finish();

    try testing.expectEqualSlices(u8, &ct_single, &ct_chunked);
}

test "CTR mode: empty input" {
    const key = [_]u8{0x77} ** 32;
    var aes_ctx = Aes.init(&key);
    defer aes_ctx.deinit();

    var output: [0]u8 = .{};
    var ctr_ctx = Ctr.initCtx(&aes_ctx);
    ctr_ctx.initWithIvAndCounter(&([_]u8{0} ** 12), 0, &output);
    ctr_ctx.crypt(&.{});
    ctr_ctx.finish();
}

test "GMAC-SIV: rejects wrong AAD" {
    const key0 = [_]u8{0xcc} ** 32;
    const key1 = [_]u8{0xdd} ** 32;

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    const plaintext = "secret message";
    const aad_data = "correct AAD";
    const iv: u64 = 99;

    var ciphertext: [plaintext.len]u8 = undefined;
    var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, &ciphertext);
    enc.aad(aad_data);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    const saved_tag: [16]u8 = enc.finish2().*;

    var decrypted: [plaintext.len]u8 = undefined;
    var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
    dec.initDec(&saved_tag, &decrypted);
    dec.aad("wrong AAD");
    dec.update(&ciphertext);
    try testing.expect(!dec.finish());
}

test "GMAC-SIV: rejects tampered ciphertext" {
    const key0 = [_]u8{0xee} ** 32;
    const key1 = [_]u8{0xff} ** 32;

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    const plaintext = "tamper test message";
    const iv: u64 = 0xdeadbeef;

    var ciphertext: [plaintext.len]u8 = undefined;
    var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, &ciphertext);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    const saved_tag: [16]u8 = enc.finish2().*;

    ciphertext[0] ^= 0x01;

    var decrypted: [plaintext.len]u8 = undefined;
    var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
    dec.initDec(&saved_tag, &decrypted);
    dec.update(&ciphertext);
    try testing.expect(!dec.finish());
}

test "GMAC-SIV: rejects tampered tag" {
    const key0 = [_]u8{0x12} ** 32;
    const key1 = [_]u8{0x34} ** 32;

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    const plaintext = "tag tamper test";
    const iv: u64 = 0xcafe;

    var ciphertext: [plaintext.len]u8 = undefined;
    var enc = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, &ciphertext);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    var saved_tag: [16]u8 = enc.finish2().*;

    saved_tag[8] ^= 0x01;

    var decrypted: [plaintext.len]u8 = undefined;
    var dec = GmacSivDecryptor.init(&aes_k0, &aes_k1);
    dec.initDec(&saved_tag, &decrypted);
    dec.update(&ciphertext);
    try testing.expect(!dec.finish());
}

test "GMAC-SIV: different IVs produce different ciphertexts" {
    const key0 = [_]u8{0x9a} ** 32;
    const key1 = [_]u8{0xbc} ** 32;

    var aes_k0 = Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = Aes.init(&key1);
    defer aes_k1.deinit();

    const plaintext = "same plaintext, different IVs";

    var ct1: [plaintext.len]u8 = undefined;
    var enc1 = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc1.initEnc(1, &ct1);
    enc1.update1(plaintext);
    enc1.finish1();
    enc1.update2(plaintext);
    _ = enc1.finish2();

    var ct2: [plaintext.len]u8 = undefined;
    var enc2 = GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc2.initEnc(2, &ct2);
    enc2.update1(plaintext);
    enc2.finish1();
    enc2.update2(plaintext);
    _ = enc2.finish2();

    try testing.expect(!std.mem.eql(u8, &ct1, &ct2));
}

test "hardware support flag is compile-time constant" {
    const hw: bool = has_hardware_support;
    _ = hw;
}

test "constants match C++ defines" {
    try testing.expectEqual(16, block_len);
}
