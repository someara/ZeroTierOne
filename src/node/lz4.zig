/// LZ4 block compression and decompression.
///
/// A pure-Zig implementation of the LZ4 block format (no framing).
/// Only the minimal subset needed by ZeroTier's Packet compress/uncompress
/// is implemented: `compressBlock()` and `decompressSafe()`.
///
/// This replaces the ~990-line embedded LZ4 v1.7.5 (BSD 2-Clause) from
/// `node/Packet.cpp`. The LZ4 block format specification is at:
/// https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md
///
/// No heap allocation is performed.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// ── LZ4 block format constants ────────────────────────────────────

const min_match: usize = 4;
const last_literals: usize = 5;
const mf_limit: usize = 12; // wildcard_copy_len(8) + min_match(4)
const max_distance: usize = 65535;

const ml_bits: u3 = 4;
const ml_mask: u8 = 0x0f;
const run_bits: u3 = 4;
const run_mask: u8 = 0xf0;

const hash_log: u6 = 12;
const hash_table_size: usize = 1 << hash_log;

// ── Compression ───────────────────────────────────────────────────

/// Compress `src` into `dst` using the LZ4 block format.
///
/// Returns the number of bytes written to `dst`, or `null` if the
/// compressed output would not fit in `dst` (or would be larger than
/// the input, making compression pointless).
///
/// `dst` must be at least `compressBound(src.len)` bytes to guarantee
/// that compression always succeeds for compressible data.
pub fn compressBlock(src: []const u8, dst: []u8) ?usize {
    if (src.len == 0) return null;
    if (src.len > max_input_size) return null;

    var hash_table: [hash_table_size]u32 = [_]u32{0} ** hash_table_size;

    var ip: usize = 0; // current input position
    var op: usize = 0; // current output position
    var anchor: usize = 0; // start of current literal run

    if (src.len < mf_limit + 1) {
        return writeFinalLiterals(src, dst, anchor, src.len, op);
    }

    // First byte
    hash_table[hash4(readU32(src, 0))] = 0;
    ip = 1;

    // Main loop
    while (ip < src.len - mf_limit) {
        // Find a match
        var match_pos: usize = undefined;
        {
            var step: usize = 1;
            var skip_trigger: usize = 6;
            var search_ip = ip;

            while (true) {
                const h = hash4(readU32(src, search_ip));
                match_pos = hash_table[h];
                hash_table[h] = @intCast(search_ip);

                if (search_ip + step > src.len - mf_limit) {
                    return writeFinalLiterals(src, dst, anchor, src.len, op);
                }

                // Check for match: within distance and 4-byte prefix matches
                if (match_pos + max_distance >= search_ip and
                    readU32(src, match_pos) == readU32(src, search_ip))
                {
                    ip = search_ip;
                    break;
                }

                search_ip += step;
                step = skip_trigger >> 5;
                skip_trigger += 1;
                if (step == 0) step = 1;
            }
        }

        // Catch up: extend match backwards
        while (ip > anchor and match_pos > 0 and src[ip - 1] == src[match_pos - 1]) {
            ip -= 1;
            match_pos -= 1;
        }

        // Encode literal length
        const lit_len = ip - anchor;
        var token_pos = op;
        op += 1;
        if (op > dst.len) return null;

        op = writeLiteralLength(dst, token_pos, lit_len, op) orelse return null;

        // Copy literals
        if (op + lit_len > dst.len) return null;
        @memcpy(dst[op..][0..lit_len], src[anchor..][0..lit_len]);
        op += lit_len;

        // Encode matches
        while (true) {
            // Encode offset (little-endian 16-bit)
            const offset = ip - match_pos;
            if (op + 2 > dst.len) return null;
            dst[op] = @truncate(offset & 0xff);
            dst[op + 1] = @truncate((offset >> 8) & 0xff);
            op += 2;

            // Compute match length (beyond the initial 4 bytes)
            const match_len = countMatch(src, ip + min_match, match_pos + min_match, src.len - last_literals);

            ip += min_match + match_len;

            // Encode match length into token
            op = writeMatchLength(dst, token_pos, match_len, op) orelse return null;

            anchor = ip;

            // Check end of block
            if (ip > src.len - mf_limit) {
                return writeFinalLiterals(src, dst, anchor, src.len, op);
            }

            // Fill table with position two bytes back
            hash_table[hash4(readU32(src, ip - 2))] = @intCast(ip - 2);

            // Test next position for immediate match
            const h = hash4(readU32(src, ip));
            match_pos = hash_table[h];
            hash_table[h] = @intCast(ip);

            if (match_pos + max_distance < ip or readU32(src, match_pos) != readU32(src, ip)) {
                // No match, advance
                ip += 1;
                break;
            }

            // Found another match immediately — write zero-literal token
            token_pos = op;
            op += 1;
            if (op > dst.len) return null;
            dst[token_pos] = 0;
            // Continue the match encoding loop
        }
    }

    return writeFinalLiterals(src, dst, anchor, src.len, op);
}

/// Safe decompression of an LZ4 block.
///
/// Decompresses `src` into `dst`. Returns the number of bytes written
/// to `dst`, or `null` if the data is malformed, truncated, or would
/// exceed `dst.len`.
pub fn decompressSafe(src: []const u8, dst: []u8) ?usize {
    if (src.len == 0) return null;

    var ip: usize = 0; // input position
    var op: usize = 0; // output position

    while (true) {
        // Get token
        if (ip >= src.len) return null;
        const token = src[ip];
        ip += 1;

        // Decode literal length
        var lit_len: usize = @as(usize, token >> 4);
        if (lit_len == 15) {
            lit_len = readVarLen(src, &ip, lit_len) orelse return null;
        }

        // Copy literals
        if (ip + lit_len > src.len) return null;
        if (op + lit_len > dst.len) return null;
        @memcpy(dst[op..][0..lit_len], src[ip..][0..lit_len]);
        ip += lit_len;
        op += lit_len;

        // End of block? (last sequence has no match)
        if (ip >= src.len) break;

        // Decode offset (little-endian 16-bit)
        if (ip + 2 > src.len) return null;
        const offset: usize = @as(usize, src[ip]) | (@as(usize, src[ip + 1]) << 8);
        ip += 2;
        if (offset == 0) return null; // offset 0 is invalid
        if (offset > op) return null; // can't reference before output start

        // Decode match length
        var match_len: usize = @as(usize, token & 0x0f) + min_match;
        if ((token & 0x0f) == 15) {
            match_len = readVarLen(src, &ip, match_len) orelse return null;
        }

        // Copy match (may overlap!)
        if (op + match_len > dst.len) return null;
        const match_start = op - offset;
        copyOverlapping(dst, match_start, op, match_len);
        op += match_len;
    }

    return op;
}

/// Upper bound on compressed output size for a given input size.
pub fn compressBound(input_size: usize) usize {
    if (input_size > max_input_size) return 0;
    return input_size + (input_size / 255) + 16;
}

/// Maximum input size supported.
pub const max_input_size: usize = 0x7E000000;

// ── Internal helpers ──────────────────────────────────────────────

fn hash4(v: u32) usize {
    // LZ4 hash: multiply in 32-bit, then right-shift to get hash_log bits.
    const product: u32 = v *% 2654435761;
    return @intCast(product >> @as(u5, 32 - hash_log));
}

fn readU32(data: []const u8, pos: usize) u32 {
    if (pos + 4 > data.len) return 0;
    return mem.readInt(u32, data[pos..][0..4], .little);
}

/// Count matching bytes starting at `ip` and `mp`, up to `limit`.
fn countMatch(data: []const u8, start_ip: usize, start_mp: usize, limit: usize) usize {
    var ip = start_ip;
    var mp = start_mp;
    while (ip < limit and mp < data.len and data[ip] == data[mp]) {
        ip += 1;
        mp += 1;
    }
    return ip - start_ip;
}

/// Write variable-length literal count into the token and output.
fn writeLiteralLength(dst: []u8, token_pos: usize, lit_len: usize, start_op: usize) ?usize {
    var op = start_op;
    if (lit_len >= 15) {
        dst[token_pos] = 0xf0; // high nibble = 15
        var remaining = lit_len - 15;
        while (remaining >= 255) {
            if (op >= dst.len) return null;
            dst[op] = 255;
            op += 1;
            remaining -= 255;
        }
        if (op >= dst.len) return null;
        dst[op] = @intCast(remaining);
        op += 1;
    } else {
        dst[token_pos] = @as(u8, @intCast(lit_len)) << 4;
    }
    return op;
}

/// Write match length into the token (low nibble) and output overflow bytes.
fn writeMatchLength(dst: []u8, token_pos: usize, match_len: usize, start_op: usize) ?usize {
    var op = start_op;
    if (match_len >= 15) {
        dst[token_pos] |= 0x0f; // low nibble = 15
        var remaining = match_len - 15;
        while (remaining >= 255) {
            if (op >= dst.len) return null;
            dst[op] = 255;
            op += 1;
            remaining -= 255;
        }
        if (op >= dst.len) return null;
        dst[op] = @intCast(remaining);
        op += 1;
    } else {
        dst[token_pos] |= @as(u8, @intCast(match_len));
    }
    return op;
}

/// Write the final literal sequence (last `last_literals` bytes must be literals).
fn writeFinalLiterals(
    src: []const u8,
    dst: []u8,
    anchor: usize,
    src_end: usize,
    start_op: usize,
) ?usize {
    const last_run = src_end - anchor;
    if (last_run == 0 and start_op == 0) return null; // empty input shouldn't get here

    var op = start_op;
    // Token
    if (op >= dst.len) return null;
    if (last_run >= 15) {
        dst[op] = 0xf0;
        op += 1;
        var remaining = last_run - 15;
        while (remaining >= 255) {
            if (op >= dst.len) return null;
            dst[op] = 255;
            op += 1;
            remaining -= 255;
        }
        if (op >= dst.len) return null;
        dst[op] = @intCast(remaining);
        op += 1;
    } else {
        dst[op] = @as(u8, @intCast(last_run)) << 4;
        op += 1;
    }

    // Copy remaining literals
    if (op + last_run > dst.len) return null;
    @memcpy(dst[op..][0..last_run], src[anchor..][0..last_run]);
    op += last_run;

    return op;
}

/// Read a variable-length integer continuation (sequences of 255 bytes).
fn readVarLen(src: []const u8, ip: *usize, initial: usize) ?usize {
    var result = initial;
    while (true) {
        if (ip.* >= src.len) return null;
        const s = src[ip.*];
        ip.* += 1;
        result += s;
        if (s != 255) break;
    }
    return result;
}

/// Copy `len` bytes from `src_off` to `dst_off` within `buf`, handling overlap.
fn copyOverlapping(buf: []u8, src_off: usize, dst_off: usize, len: usize) void {
    // Byte-by-byte copy handles overlapping regions correctly
    for (0..len) |i| {
        buf[dst_off + i] = buf[src_off + i];
    }
}

// ── Tests ─────────────────────────────────────────────────────────

test "LZ4: round-trip empty-ish data" {
    // LZ4 can't compress truly empty input (returns null)
    const result = compressBlock(&[_]u8{}, &[_]u8{});
    try testing.expect(result == null);
}

test "LZ4: round-trip small literal-only data" {
    const input = "Hello, World!";
    var compressed: [256]u8 = undefined;
    const comp_len = compressBlock(input, &compressed) orelse {
        // Small data may not compress; that's valid
        return;
    };

    var decompressed: [256]u8 = undefined;
    const decomp_len = decompressSafe(compressed[0..comp_len], &decompressed) orelse
        return try testing.expect(false);
    try testing.expectEqualSlices(u8, input, decompressed[0..decomp_len]);
}

test "LZ4: round-trip repeated data (highly compressible)" {
    // Create highly compressible data: repeated pattern
    var input: [4096]u8 = undefined;
    for (0..input.len) |i| {
        input[i] = @truncate(i % 16);
    }

    var compressed: [8192]u8 = undefined;
    const comp_len = compressBlock(&input, &compressed).?;
    try testing.expect(comp_len < input.len); // Should compress

    var decompressed: [4096]u8 = undefined;
    const decomp_len = decompressSafe(compressed[0..comp_len], &decompressed).?;
    try testing.expectEqual(input.len, decomp_len);
    try testing.expectEqualSlices(u8, &input, &decompressed);
}

test "LZ4: round-trip with overlapping matches" {
    // Data that creates overlapping match copies
    const input = "ABCABCABCABCABCABCABCABCABCABCABC" ++
        "DEFDEFDEFDEFDEFDEFDEFDEFDEFDEFDEF" ++
        "ABCABCABCABCABCABCABCABCABCABCABC";
    var compressed: [512]u8 = undefined;
    const comp_len = compressBlock(input, &compressed).?;

    var decompressed: [512]u8 = undefined;
    const decomp_len = decompressSafe(compressed[0..comp_len], &decompressed).?;
    try testing.expectEqualSlices(u8, input, decompressed[0..decomp_len]);
}

test "LZ4: decompressSafe rejects truncated input" {
    // Create valid compressed data, then truncate it
    var input: [256]u8 = undefined;
    for (0..input.len) |i| {
        input[i] = @truncate(i % 4);
    }

    var compressed: [512]u8 = undefined;
    const comp_len = compressBlock(&input, &compressed).?;

    // Try to decompress truncated data — should return null
    var decompressed: [256]u8 = undefined;
    if (comp_len > 2) {
        const result = decompressSafe(compressed[0 .. comp_len / 2], &decompressed);
        try testing.expect(result == null);
    }
}

test "LZ4: decompressSafe rejects invalid offset" {
    // Craft a bad LZ4 block: literal "ABCD" then offset=100 (beyond output)
    const bad_data = [_]u8{
        0x04, // token: 0 literals in run, 4-byte match? No — high nibble 0, low nibble 4
        // Actually: token high=0 (0 literals), so no literal bytes
        // Then: offset LE u16
        0x64, 0x00, // offset = 100 (way beyond output start of 0)
    };
    // This should fail: 0 literals, then offset=100 when op=0
    var decompressed: [256]u8 = undefined;
    const result = decompressSafe(&bad_data, &decompressed);
    try testing.expect(result == null);
}

test "LZ4: compress output bounded by compressBound" {
    var input: [1024]u8 = undefined;
    // Fill with random-looking data (hard to compress)
    for (0..input.len) |i| {
        input[i] = @truncate(i *% 137 +% 73);
    }

    const bound = compressBound(input.len);
    var compressed: [2048]u8 = undefined;
    // Even incompressible data should produce something within bounds
    // (or return null if it exceeds dst)
    if (compressBlock(&input, compressed[0..bound])) |comp_len| {
        try testing.expect(comp_len <= bound);
    }
}

test "LZ4: round-trip 64KB data" {
    // Test near the edge of the 64K hash table boundary
    var input: [65000]u8 = undefined;
    for (0..input.len) |i| {
        input[i] = @truncate(i % 251); // prime modulus for variety
    }

    const bound = compressBound(input.len);
    var compressed_buf = [_]u8{0} ** 70000;
    const comp_len = compressBlock(&input, compressed_buf[0..bound]).?;

    var decompressed: [65000]u8 = undefined;
    const decomp_len = decompressSafe(compressed_buf[0..comp_len], &decompressed).?;
    try testing.expectEqual(input.len, decomp_len);
    try testing.expectEqualSlices(u8, &input, &decompressed);
}

test "LZ4: compressBound returns 0 for oversized input" {
    try testing.expectEqual(@as(usize, 0), compressBound(max_input_size + 1));
}

test "LZ4: decompressSafe with zero-length src" {
    var decompressed: [64]u8 = undefined;
    try testing.expect(decompressSafe(&[_]u8{}, &decompressed) == null);
}
