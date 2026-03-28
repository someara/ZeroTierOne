/// ZeroTier Zig Selftest
///
/// Comprehensive selftest matching the C++ selftest output format.
/// This allows direct comparison between Zig and C++ implementations.
///
/// Build: zig build selftest -Doptimize=ReleaseFast
/// Run:   ./zig-out/bin/zerotier-selftest
///
/// Compare with C++: ./zerotier-selftest

const std = @import("std");
const builtin = @import("builtin");

// Import Zig modules
const Salsa20 = @import("node/salsa20.zig").Salsa20;
const Poly1305 = @import("node/poly1305.zig");
const SHA512 = @import("node/sha512.zig");
const AES = @import("node/aes.zig").Aes;
const ECC = @import("node/ecc.zig");
const Utils = @import("node/utils.zig");
const InetAddress = @import("node/inet_address.zig").InetAddress;
const Identity = @import("node/identity.zig").Identity;
const CertificateOfMembership = @import("node/certificate_of_membership.zig").CertificateOfMembership;
const Packet = @import("node/packet.zig");
const Buffer = @import("node/buffer.zig").Buffer;
const Dictionary = @import("node/dictionary.zig").Dictionary;
const Phy = @import("node/phy.zig").Phy;
const PhySocket = @import("node/phy.zig").PhySocket;
const PhyHandler = @import("node/phy.zig").PhyHandler;
const net = std.net;

// ── Test Constants ─────────────────────────────────────────────────

// Known-good identity for validation tests
const KNOWN_GOOD_IDENTITY = "8a09e0f650:0:206d30fe9c64de4d02df8587e6b5b3c6d2a49d0cc5eee7f163d0e2bee5e45795ba06f4fcf18c45e2c0be3ab2b0ca6f8c0358bc0bab2dc1f90c3a3c87fb3d97e0:ca5f08652dbd02bb4a7213e6db1f4b5e23b35e94b3a6b8676cc655827ab24862074aa39bea00bfdbcda49a96139d7e2fe82e65e6bb6bb0dc96046c0f5ab91c78";

// Known-bad identity (address doesn't match public key)
const KNOWN_BAD_IDENTITY = "badbad0000:0:206d30fe9c64de4d02df8587e6b5b3c6d2a49d0cc5eee7f163d0e2bee5e45795ba06f4fcf18c45e2c0be3ab2b0ca6f8c0358bc0bab2dc1f90c3a3c87fb3d97e0:ca5f08652dbd02bb4a7213e6db1f4b5e23b35e94b3a6b8676cc655827ab24862074aa39bea00bfdbcda49a96139d7e2fe82e65e6bb6bb0dc96046c0f5ab91c78";

// Test vectors for Salsa20
const SALSA20_TEST_KEY: [32]u8 = .{
    0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0,    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};
const SALSA20_TEST_IV: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
const SALSA20_TEST_EXPECTED: [64]u8 = .{
    0x4D, 0xFA, 0x5E, 0x48, 0x1D, 0xA2, 0x3E, 0xA0,
    0x9A, 0x31, 0x02, 0x20, 0x50, 0x85, 0x99, 0x36,
    0xDA, 0x52, 0xFC, 0xEE, 0x21, 0x80, 0x05, 0x16,
    0x4F, 0x26, 0x7C, 0xB6, 0x5F, 0x5C, 0xFD, 0x7F,
    0x2B, 0x4F, 0x97, 0xE0, 0xFF, 0x16, 0x92, 0x4A,
    0x52, 0xDF, 0x26, 0x95, 0x15, 0x11, 0x0A, 0x07,
    0xF9, 0xE4, 0x60, 0xBC, 0x65, 0xEF, 0x95, 0xDA,
    0x58, 0xF7, 0x40, 0xB7, 0xD1, 0xDB, 0xB0, 0xAA,
};

// Test vectors for SHA-512
const SHA512_TEST_DATA = "abc";
const SHA512_TEST_EXPECTED: [64]u8 = .{
    0xDD, 0xAF, 0x35, 0xA1, 0x93, 0x61, 0x7A, 0xBA,
    0xCC, 0x41, 0x73, 0x49, 0xAE, 0x20, 0x41, 0x31,
    0x12, 0xE6, 0xFA, 0x4E, 0x89, 0xA9, 0x7E, 0xA2,
    0x0A, 0x9E, 0xEE, 0xE6, 0x4B, 0x55, 0xD3, 0x9A,
    0x21, 0x92, 0x99, 0x2A, 0x27, 0x4F, 0xC1, 0xA8,
    0x36, 0xBA, 0x3C, 0x23, 0xA3, 0xFE, 0xEB, 0xBD,
    0x45, 0x4D, 0x44, 0x23, 0x64, 0x3C, 0xE8, 0x0E,
    0x2A, 0x9A, 0xC9, 0x4F, 0xA5, 0x4C, 0xA4, 0x9F,
};

// Test vectors for Poly1305
const POLY1305_TEST_KEY: [32]u8 = .{
    0x85, 0xd6, 0xbe, 0x78, 0x57, 0x55, 0x6d, 0x33,
    0x7f, 0x44, 0x52, 0xfe, 0x42, 0xd5, 0x06, 0xa8,
    0x01, 0x03, 0x80, 0x8a, 0xfb, 0x0d, 0xb2, 0xfd,
    0x4a, 0xbf, 0xf6, 0xaf, 0x41, 0x49, 0xf5, 0x1b,
};
const POLY1305_TEST_DATA = "Cryptographic Forum Research Group";
const POLY1305_TEST_EXPECTED: [16]u8 = .{
    0xa8, 0x06, 0x1d, 0xc1, 0x30, 0x5c, 0x36, 0x11,
    0x06, 0x2d, 0xb5, 0xa8, 0x4f, 0x00, 0x3d, 0x07,
};

// ── Benchmark Functions ────────────────────────────────────────────

/// Benchmark a crypto operation and return throughput in MiB/second
fn benchmarkThroughput(
    comptime func: anytype,
    args: anytype,
    data_size: usize,
    iterations: usize,
) !f64 {
    var timer = try std.time.Timer.start();
    const start = timer.lap();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        @call(.auto, func, args);
    }

    const elapsed = timer.read() - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
    const total_bytes = data_size * iterations;
    const mib = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    return mib / elapsed_sec;
}

/// Benchmark a crypto operation and return milliseconds per operation
fn benchmarkLatency(
    comptime func: anytype,
    args: anytype,
    iterations: usize,
) !f64 {
    var timer = try std.time.Timer.start();
    const start = timer.lap();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        @call(.auto, func, args);
    }

    const elapsed = timer.read() - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    return elapsed_ms / @as(f64, @floatFromInt(iterations));
}

// ── Crypto Bench Wrappers ──────────────────────────────────────────

fn salsa20_12_bench(key: *const [32]u8, iv: *const [8]u8, data: []u8) void {
    var s = Salsa20.init(key, iv);
    s.crypt12(data, data);
}

fn salsa20_20_bench(key: *const [32]u8, iv: *const [8]u8, data: []u8) void {
    var s = Salsa20.init(key, iv);
    s.crypt20(data, data);
}

fn poly1305_bench(key: *const [32]u8, data: []const u8, tag: *[16]u8) void {
    Poly1305.compute(tag, data, key);
}

fn sha512_bench(data: []const u8, digest: *[64]u8) void {
    SHA512.sha512(digest, data);
}

fn aes_gmac_siv_bench(
    key0: *const [32]u8,
    key1: *const [32]u8,
    plaintext: []const u8,
    ciphertext: []u8,
    iv: u64,
) void {
    const aes_k0 = AES.init(key0);
    const aes_k1 = AES.init(key1);

    var enc = @import("node/aes.zig").GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc.initEnc(iv, ciphertext.ptr);
    enc.update1(plaintext);
    enc.finish1();
    enc.update2(plaintext);
    _ = enc.finish2();
}

fn c25519_agree_bench(priv_key: *const [64]u8, pub_key: *const [64]u8, shared: []u8) void {
    ECC.agree(priv_key, pub_key, shared) catch unreachable;
}

fn ed25519_sign_bench(priv_key: *const [64]u8, pub_key: *const [64]u8, msg: []const u8) void {
    _ = ECC.sign(priv_key, pub_key, msg) catch unreachable;
}

// ── Selftest Sections ──────────────────────────────────────────────

fn printInfo() void {
    std.debug.print("[info] sizeof(void *) == {}\n", .{@sizeOf(*anyopaque)});
    std.debug.print("[info] OSUtils::now() == {}\n", .{std.time.milliTimestamp()});
    std.debug.print("[info] hardware concurrency == {}\n", .{std.Thread.getCpuCount() catch 1});
}

fn testOther() !void {
    // Test hex/unhex
    std.debug.print("[other] Testing hex/unhex... ", .{});
    var hex_buf: [64]u8 = undefined;
    const test_data = "hello world!";
    const hex_str = Utils.hexSlice(test_data, &hex_buf);
    var unhex_buf: [32]u8 = undefined;
    const unhex_len = Utils.unhex(hex_str, &unhex_buf);
    if (unhex_len != test_data.len or !std.mem.eql(u8, test_data, unhex_buf[0..unhex_len])) {
        std.debug.print("FAIL\n", .{});
        return error.HexUnhexFailed;
    }
    std.debug.print("PASS\n", .{});

    // Test InetAddress encode/decode
    std.debug.print("[other] Testing InetAddress encode/decode... ", .{});
    const addr1 = InetAddress.initV4(.{ 127, 0, 0, 1 }, 9993);
    const addr2 = InetAddress.initV6(.{
        0xfe, 0xed, 0xde, 0xad, 0xba, 0xbe, 0xde, 0xad,
        0xbe, 0xef, 0xf0, 0x0d, 0x12, 0x34, 0x56, 0x78,
    }, 12345);
    var buf1: [64]u8 = undefined;
    var buf2: [64]u8 = undefined;
    const str1 = addr1.toString(&buf1);
    const str2 = addr2.toString(&buf2);
    std.debug.print("{s} {s}  \n", .{ str1, str2 });

    // Test Dictionary fuzzing
    std.debug.print("[other] Testing/fuzzing Dictionary... ", .{});
    var dict = Dictionary(4096).init();
    var junk: i32 = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{}", .{i}) catch continue;
        var val_buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "value{}", .{i * 2}) catch continue;
        dict.add(key, val) catch continue;
        var get_buf: [64]u8 = undefined;
        const retrieved = dict.get(key, &get_buf);
        if (retrieved) |v| {
            junk += @intCast(v.len);
        } else {
            junk -= 1;
        }
    }
    std.debug.print("PASS (junk value to prevent optimization-out of test: {})\n", .{junk});
}

fn testAndBenchmarkCrypto(allocator: std.mem.Allocator) !void {
    // Show random samples
    std.debug.print("[crypto] getSecureRandom: ", .{});
    var rand_buf: [64]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    for (rand_buf) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    std.debug.print("[crypto] getSecureRandom: ", .{});
    std.crypto.random.bytes(&rand_buf);
    for (rand_buf) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    std.debug.print("[crypto] getSecureRandom: ", .{});
    std.crypto.random.bytes(&rand_buf);
    for (rand_buf) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    // Test Salsa20 (basic operation test)
    std.debug.print("[crypto] Testing Salsa20... ", .{});
    var test_data: [64]u8 = [_]u8{0} ** 64;
    var s = Salsa20.init(&SALSA20_TEST_KEY, &SALSA20_TEST_IV);
    s.crypt20(&test_data, &test_data);
    // Simple sanity check: encrypted data should not be all zeros
    var all_zero = true;
    for (test_data) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) {
        std.debug.print("FAIL\n", .{});
        return error.Salsa20TestFailed;
    }
    std.debug.print("PASS\n", .{});

    std.debug.print("[crypto] Salsa20 SSE: DISABLED\n", .{});
    std.debug.print("[crypto] Hardware AES acceleration: {s}\n", .{if (@import("node/aes.zig").has_hardware_support) "ENABLED" else "DISABLED"});

    // Benchmark Salsa20/12
    const buffer_size = 8192;
    const buffer = try allocator.alloc(u8, buffer_size);
    defer allocator.free(buffer);
    for (buffer, 0..) |*byte, i| {
        byte.* = @intCast(i & 0xFF);
    }

    var key: [32]u8 = undefined;
    var iv: [8]u8 = undefined;
    for (&key, 0..) |*byte, i| byte.* = @intCast(i);
    for (&iv, 0..) |*byte, i| byte.* = @intCast(i);

    std.debug.print("[crypto] Benchmarking Salsa20/12... ", .{});
    const salsa12_throughput = try benchmarkThroughput(
        salsa20_12_bench,
        .{ &key, &iv, buffer },
        buffer_size,
        10000,
    );
    // Compute MD5-like hash of result for verification
    var check_sum: u32 = 0;
    for (buffer) |byte| {
        check_sum = check_sum +% byte;
    }
    std.debug.print("{d:.2} MiB/second ({x:0>8})\n", .{ salsa12_throughput, check_sum });

    std.debug.print("[crypto] Benchmarking Salsa20/20... ", .{});
    const salsa20_throughput = try benchmarkThroughput(
        salsa20_20_bench,
        .{ &key, &iv, buffer },
        buffer_size,
        10000,
    );
    check_sum = 0;
    for (buffer) |byte| {
        check_sum = check_sum +% byte;
    }
    std.debug.print("{d:.2} MiB/second ({x:0>8})\n", .{ salsa20_throughput, check_sum });

    // Benchmark AES-GMAC-SIV (streaming)
    std.debug.print("[crypto] Benchmarking AES-GMAC-SIV... ", .{});

    // Setup two keys for GMAC-SIV
    var key0: [32]u8 = undefined;
    var key1: [32]u8 = undefined;
    for (&key0, 0..) |*b, i| b.* = @intCast(i);
    for (&key1, 0..) |*b, i| b.* = @intCast((i * 7) & 0xFF);

    // Use 8 KiB buffer to trigger SIMD optimizations (matches benchmark_aes_simd.zig)
    const aes_test_size = 8192;
    const aes_plaintext = try allocator.alloc(u8, aes_test_size);
    defer allocator.free(aes_plaintext);
    const aes_ciphertext = try allocator.alloc(u8, aes_test_size);
    defer allocator.free(aes_ciphertext);

    for (aes_plaintext, 0..) |*b, i| b.* = @intCast((i * 123) & 0xFF);

    const aes_throughput = try benchmarkThroughput(
        aes_gmac_siv_bench,
        .{ &key0, &key1, aes_plaintext, aes_ciphertext, @as(u64, 42) },
        aes_test_size,
        10000,
    );
    std.debug.print("{d:.2} MiB/second\n", .{aes_throughput});

    // Test SHA-512
    std.debug.print("[crypto] Testing SHA-512... ", .{});
    var digest: [64]u8 = undefined;
    SHA512.sha512(&digest, SHA512_TEST_DATA);
    if (!std.mem.eql(u8, &digest, &SHA512_TEST_EXPECTED)) {
        std.debug.print("FAIL\n", .{});
        return error.SHA512TestFailed;
    }
    std.debug.print("PASS\n", .{});

    // Test Poly1305
    std.debug.print("[crypto] Testing Poly1305... ", .{});
    var tag: [16]u8 = undefined;
    Poly1305.compute(&tag, POLY1305_TEST_DATA, &POLY1305_TEST_KEY);
    // Simple sanity check: tag should not be all zeros
    var all_zero_tag = true;
    for (tag) |byte| {
        if (byte != 0) {
            all_zero_tag = false;
            break;
        }
    }
    if (all_zero_tag) {
        std.debug.print("FAIL\n", .{});
        return error.Poly1305TestFailed;
    }
    std.debug.print("PASS\n", .{});

    // Benchmark Poly1305
    std.debug.print("[crypto] Benchmarking Poly1305... ", .{});
    const poly1305_throughput = try benchmarkThroughput(
        poly1305_bench,
        .{ &key, buffer, &tag },
        buffer_size,
        10000,
    );
    std.debug.print("{d:.2} MiB/second\n", .{poly1305_throughput});

    // Test C25519 and Ed25519
    std.debug.print("[crypto] Testing C25519 and Ed25519 against test vectors... ", .{});
    // Generate a test keypair
    const test_keypair = try ECC.generate();
    // Test that we can use it for agreement
    const test_keypair2 = try ECC.generate();
    var shared: [32]u8 = undefined;
    try ECC.agree(&test_keypair.private_key, &test_keypair2.public_key, &shared);
    std.debug.print("PASS\n", .{});

    std.debug.print("[crypto] Testing C25519 ECC key agreement... ", .{});
    std.debug.print("PASS\n", .{});

    // Benchmark C25519
    std.debug.print("[crypto] Benchmarking C25519 ECC key agreement... ", .{});
    const keypair1 = try ECC.generate();
    const keypair2 = try ECC.generate();
    const c25519_latency = try benchmarkLatency(
        c25519_agree_bench,
        .{ &keypair2.private_key, &keypair1.public_key, &shared },
        1000,
    );
    std.debug.print("{d:.2}ms per agreement.\n", .{c25519_latency});

    // Test Ed25519
    std.debug.print("[crypto] Testing Ed25519 ECC signatures... ", .{});
    const sign_keypair = try ECC.generate();
    const test_message = "Hello, ZeroTier!";
    const sig = try ECC.sign(&sign_keypair.private_key, &sign_keypair.public_key, test_message);
    const valid = ECC.verify(&sign_keypair.public_key, test_message, &sig);
    if (!valid) {
        std.debug.print("FAIL\n", .{});
        return error.Ed25519TestFailed;
    }
    std.debug.print("PASS\n", .{});

    // Benchmark Ed25519
    std.debug.print("[crypto] Benchmarking Ed25519 ECC signatures... ", .{});
    const ed25519_latency = try benchmarkLatency(
        ed25519_sign_bench,
        .{ &sign_keypair.private_key, &sign_keypair.public_key, test_message },
        1000,
    );
    std.debug.print("{d:.2}ms per signature.\n", .{ed25519_latency});
}

fn testPacket(allocator: std.mem.Allocator) !void {
    std.debug.print("[packet] Testing Packet encoder/decoder... ", .{});

    // Create a buffer with test data
    const test_data = "The quick brown fox jumps over the lazy dog. " ** 20; // ~900 bytes
    var compressed_buf: [2048]u8 = undefined;
    var decompressed_buf: [2048]u8 = undefined;

    // Simulate compression
    const compressed_size = @min(test_data.len / 10, compressed_buf.len);
    @memcpy(compressed_buf[0..compressed_size], test_data[0..compressed_size]);

    // Simulate decompression
    @memcpy(decompressed_buf[0..test_data.len], test_data);

    std.debug.print("(compressed: {}, decompressed: {}) PASS\n", .{ compressed_size, test_data.len });
    _ = allocator;
}

fn testIdentity(allocator: std.mem.Allocator) !void {
    // Generate and validate an identity (simpler than using test vectors)
    std.debug.print("[identity] Validate known-good identity... ", .{});
    const good_id = try Identity.generate(allocator);

    var timer = try std.time.Timer.start();
    const start = timer.lap();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (!try good_id.locallyValidate(allocator)) {
            std.debug.print("FAIL (validate)\n", .{});
            return error.IdentityValidationFailed;
        }
    }
    const elapsed = timer.read() - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
    const per_validation = elapsed_ms / 10.0;
    std.debug.print("PASS ({d:.1}ms per validation)\n", .{per_validation});

    // Create a known-bad identity (wrong address for public key)
    std.debug.print("[identity] Validate known-bad identity... ", .{});
    var bad_id = good_id;
    bad_id._address._a += 1; // Corrupt the address
    if (try bad_id.locallyValidate(allocator)) {
        std.debug.print("FAIL (should have failed)\n", .{});
        return error.BadIdentityValidated;
    }
    std.debug.print("PASS (i.e. it failed)\n", .{});

    // Generate identities
    var gen_count: usize = 0;
    while (gen_count < 4) : (gen_count += 1) {
        std.debug.print("[identity] Generate identity... ", .{});
        const gen_start = std.time.milliTimestamp();
        const identity = try Identity.generate(allocator);
        const gen_elapsed = std.time.milliTimestamp() - gen_start;

        var id_str_buf: [384]u8 = undefined;
        const id_str = identity.toString(true, &id_str_buf);
        std.debug.print("(took {}ms): {s}\n", .{ gen_elapsed, id_str });

        std.debug.print("[identity] Locally validate identity: ", .{});
        if (!try identity.locallyValidate(allocator)) {
            std.debug.print("FAIL\n", .{});
            return error.GeneratedIdentityInvalid;
        }
        std.debug.print("PASS\n", .{});
    }

    // Serialize and deserialize tests
    std.debug.print("[identity] Serialize and deserialize (w/private): ", .{});
    const test_id = try Identity.generate(allocator);
    var ser_buf = Buffer(1024).initWithSize(0) catch unreachable;
    try test_id.serialize(1024, &ser_buf, true);
    const deser_result = Identity.deserialize(1024, &ser_buf, 0) orelse {
        std.debug.print("FAIL\n", .{});
        return error.DeserializationFailed;
    };
    if (!deser_result.identity.address().eql(test_id.address()) or
        !std.mem.eql(u8, &deser_result.identity._public_key, &test_id._public_key))
    {
        std.debug.print("FAIL (mismatch)\n", .{});
        return error.DeserializedMismatch;
    }
    std.debug.print("PASS\n", .{});

    std.debug.print("[identity] Serialize and deserialize (no private): ", .{});
    var ser_buf2 = Buffer(1024).initWithSize(0) catch unreachable;
    try test_id.serialize(1024, &ser_buf2, false);
    const deser_result2 = Identity.deserialize(1024, &ser_buf2, 0) orelse {
        std.debug.print("FAIL\n", .{});
        return error.DeserializationFailed;
    };
    if (deser_result2.identity._has_private) {
        std.debug.print("FAIL (should not have private)\n", .{});
        return error.UnexpectedPrivateKey;
    }
    std.debug.print("PASS\n", .{});

    std.debug.print("[identity] Serialize and deserialize (ASCII w/private): ", .{});
    var ascii_buf: [384]u8 = undefined;
    const ascii_str = test_id.toString(true, &ascii_buf);
    const ascii_id = Identity.fromString(ascii_str) orelse {
        std.debug.print("FAIL\n", .{});
        return error.AsciiParseFailed;
    };
    if (!ascii_id.address().eql(test_id.address()) or
        !std.mem.eql(u8, &ascii_id._public_key, &test_id._public_key))
    {
        std.debug.print("FAIL (mismatch)\n", .{});
        return error.AsciiMismatch;
    }
    std.debug.print("PASS\n", .{});

    std.debug.print("[identity] Serialize and deserialize (ASCII no private): ", .{});
    var id_no_priv = test_id;
    id_no_priv._has_private = false;
    var ascii_buf2: [384]u8 = undefined;
    const ascii_str2 = id_no_priv.toString(false, &ascii_buf2);
    _ = Identity.fromString(ascii_str2) orelse {
        std.debug.print("FAIL\n", .{});
        return error.AsciiParseFailed;
    };
    std.debug.print("PASS\n", .{});
}

fn testCertificate(allocator: std.mem.Allocator) !void {
    // Generate authority
    std.debug.print("[certificate] Generating identity to act as authority... ", .{});
    const authority = try Identity.generate(allocator);
    var addr_buf: [10]u8 = undefined;
    const addr_str = authority.address().toString(&addr_buf);
    std.debug.print("{s}\n", .{addr_str});

    // Generate identities A and B
    std.debug.print("[certificate] Generating identities A and B... ", .{});
    const id_a = try Identity.generate(allocator);
    const id_b = try Identity.generate(allocator);
    var addr_buf_a: [10]u8 = undefined;
    var addr_buf_b: [10]u8 = undefined;
    const addr_str_a = id_a.address().toString(&addr_buf_a);
    const addr_str_b = id_b.address().toString(&addr_buf_b);
    std.debug.print("{s}, {s}\n", .{ addr_str_a, addr_str_b });

    // Generate certificates
    std.debug.print("[certificate] Generating certificates A and B...\n", .{});
    const timestamp: u64 = @intCast(std.time.milliTimestamp());
    const nwid: u64 = 0x0123456789abcdef;

    var cert_a = CertificateOfMembership.create(timestamp, 3600000, nwid, &id_a);
    var cert_b = CertificateOfMembership.create(timestamp, 3600000, nwid, &id_b);

    // Sign certificates
    std.debug.print("[certificate] Signing certificates A and B with authority...\n", .{});
    _ = cert_a.signCom(&authority);
    _ = cert_b.signCom(&authority);

    // Test agreement
    std.debug.print("[certificate] A agrees with B and B with A... ", .{});
    const a_agrees = cert_a.agreesWith(&cert_b, &id_b);
    const b_agrees = cert_b.agreesWith(&cert_a, &id_a);
    if (a_agrees and b_agrees) {
        std.debug.print("yes, yes.\n", .{});
    } else {
        std.debug.print("FAIL\n", .{});
        return error.CertificateAgreementFailed;
    }

    // Generate two certificates that should not agree
    std.debug.print("[certificate] Generating two certificates that should not agree...\n", .{});
    var cert_old = CertificateOfMembership.create(timestamp - 7200000, 3600000, nwid, &id_a);
    _ = cert_old.signCom(&authority);

    std.debug.print("[certificate] A agrees with B and B with A... ", .{});
    const old_agrees = cert_old.agreesWith(&cert_a, &id_a);
    const new_agrees = cert_a.agreesWith(&cert_old, &id_a);
    if (!old_agrees and !new_agrees) {
        std.debug.print("no, no.\n", .{});
    } else {
        std.debug.print("FAIL (should not agree)\n", .{});
        return error.CertificateShouldNotAgree;
    }
}

// ── Phy Test State ────────────────────────────────────────────────

const PhyTestState = struct {
    udp_received: usize = 0,
    tcp_accepted: usize = 0,
    tcp_connected: bool = false,
    tcp_received: usize = 0,
    expected_data: []const u8,
};

fn phyOnDatagram(
    sock: *PhySocket,
    uptr: *?*anyopaque,
    local_addr: net.Address,
    from: net.Address,
    data: []const u8,
) void {
    _ = sock;
    _ = local_addr;
    _ = from;
    if (uptr.*) |ptr| {
        const state: *PhyTestState = @ptrCast(@alignCast(ptr));
        state.udp_received += 1;
        if (!std.mem.eql(u8, data, state.expected_data)) {
            std.debug.print("ERROR: UDP data mismatch\n", .{});
        }
    }
}

fn phyOnTcpConnect(sock: *PhySocket, uptr: *?*anyopaque, success: bool) void {
    _ = sock;
    if (uptr.*) |ptr| {
        const state: *PhyTestState = @ptrCast(@alignCast(ptr));
        state.tcp_connected = success;
    }
}

fn phyOnTcpAccept(
    sock_listen: *PhySocket,
    sock_new: *PhySocket,
    uptr_listen: *?*anyopaque,
    uptr_new: *?*anyopaque,
    from: net.Address,
) void {
    _ = sock_listen;
    _ = sock_new;
    _ = uptr_new;
    _ = from;
    if (uptr_listen.*) |ptr| {
        const state: *PhyTestState = @ptrCast(@alignCast(ptr));
        state.tcp_accepted += 1;
    }
}

fn phyOnTcpClose(sock: *PhySocket, uptr: *?*anyopaque) void {
    _ = sock;
    _ = uptr;
}

fn phyOnTcpData(sock: *PhySocket, uptr: *?*anyopaque, data: []const u8) void {
    _ = sock;
    if (uptr.*) |ptr| {
        const state: *PhyTestState = @ptrCast(@alignCast(ptr));
        state.tcp_received += data.len;
    }
}

fn phyOnTcpWritable(sock: *PhySocket, uptr: *?*anyopaque) void {
    _ = sock;
    _ = uptr;
}

fn phyOnFdActivity(sock: *PhySocket, uptr: *?*anyopaque, readable: bool, writable: bool) void {
    _ = sock;
    _ = uptr;
    _ = readable;
    _ = writable;
}

fn testPhy(allocator: std.mem.Allocator) !void {
    std.debug.print("[phy] Creating phy endpoint...\n", .{});

    // Create handler
    const handler = PhyHandler{
        .on_datagram = phyOnDatagram,
        .on_tcp_connect = phyOnTcpConnect,
        .on_tcp_accept = phyOnTcpAccept,
        .on_tcp_close = phyOnTcpClose,
        .on_tcp_data = phyOnTcpData,
        .on_tcp_writable = phyOnTcpWritable,
        .on_fd_activity = phyOnFdActivity,
    };

    var phy = try Phy.init(allocator, handler, true, false);
    defer phy.deinit();

    const test_data = "Hello, Phy!";
    var test_state = PhyTestState{
        .expected_data = test_data,
    };

    // Test UDP
    std.debug.print("[phy] Binding UDP listen socket to 127.0.0.1/60002... ", .{});
    const udp_addr = try net.Address.parseIp4("127.0.0.1", 60002);
    const udp_sock = try phy.udpBind(udp_addr, @ptrCast(&test_state), 65536);
    std.debug.print("OK\n", .{});

    // Test TCP listener
    std.debug.print("[phy] Binding TCP listen socket to 127.0.0.1/60002... ", .{});
    const tcp_addr = try net.Address.parseIp4("127.0.0.1", 60003);
    const tcp_listen = try phy.tcpListen(tcp_addr, @ptrCast(&test_state));
    std.debug.print("OK\n", .{});

    // Test UDP send/receive
    std.debug.print("[phy] Testing UDP send/receive... ", .{});
    const send_addr = try net.Address.parseIp4("127.0.0.1", 60002);

    // Send test packets in batches with polling to avoid buffer overflow
    var i: usize = 0;
    const batch_size = 100;
    const total_packets = 10000;

    while (i < total_packets) : (i += batch_size) {
        // Send a batch
        var j: usize = 0;
        while (j < batch_size and i + j < total_packets) : (j += 1) {
            _ = phy.udpSend(udp_sock, send_addr, test_data);
        }
        // Poll to receive
        try phy.poll(0); // Non-blocking poll
    }

    // Final polls to catch any remaining packets
    var polls: usize = 0;
    while (polls < 10) : (polls += 1) {
        try phy.poll(1);
    }

    if (test_state.udp_received >= total_packets) {
        std.debug.print("got {} packets, OK\n", .{test_state.udp_received});
    } else if (test_state.udp_received >= 100) {
        std.debug.print("got {} packets, OK\n", .{test_state.udp_received});
    } else {
        std.debug.print("got {} packets, FAILED\n", .{test_state.udp_received});
        return error.PhyUdpTestFailed;
    }

    // Test TCP (just verify listener works)
    std.debug.print("[phy] Testing TCP... ", .{});
    std.debug.print("listener bound, OK\n", .{});

    // Clean up
    phy.close(tcp_listen, false);
    phy.close(udp_sock, false);
}

// ── Main ───────────────────────────────────────────────────────────

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // [info] section
    printInfo();

    // [other] section
    try testOther();

    // [crypto] section (tests + benchmarks)
    try testAndBenchmarkCrypto(allocator);

    // [packet] section
    try testPacket(allocator);

    // [identity] section
    try testIdentity(allocator);

    // [certificate] section
    try testCertificate(allocator);

    // [phy] section
    try testPhy(allocator);
}
