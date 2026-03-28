/// AES-GMAC-SIV SIMD Performance Benchmark
///
/// This benchmark measures the throughput of the AES-GMAC-SIV implementation
/// with SIMD optimizations, matching the C++ benchmark methodology.
///
/// Build: zig build-exe src/benchmark_aes_simd.zig -O ReleaseFast
/// Run:   ./benchmark_aes_simd

const std = @import("std");
const AES = @import("node/aes.zig");

const BENCHMARK_SIZE = 8192; // 8 KiB per iteration
const ITERATIONS = 10000;

pub fn main() !void {
    std.debug.print("=== AES-GMAC-SIV SIMD Performance Benchmark ===\n\n", .{});

    // Show platform info
    std.debug.print("Platform: {s}\n", .{@tagName(@import("builtin").cpu.arch)});
    std.debug.print("Hardware AES: {s}\n", .{if (AES.has_hardware_support) "YES" else "NO"});
    std.debug.print("Benchmark size: {} bytes\n", .{BENCHMARK_SIZE});
    std.debug.print("Iterations: {}\n\n", .{ITERATIONS});

    // Setup keys
    var key0: [32]u8 = undefined;
    var key1: [32]u8 = undefined;
    for (&key0, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    for (&key1, 0..) |*b, i| b.* = @intCast((i * 7) & 0xFF);

    var aes_k0 = AES.Aes.init(&key0);
    defer aes_k0.deinit();
    var aes_k1 = AES.Aes.init(&key1);
    defer aes_k1.deinit();

    // Allocate buffers
    const allocator = std.heap.page_allocator;
    const plaintext = try allocator.alloc(u8, BENCHMARK_SIZE);
    defer allocator.free(plaintext);
    const ciphertext = try allocator.alloc(u8, BENCHMARK_SIZE);
    defer allocator.free(ciphertext);

    // Fill plaintext with test pattern
    for (plaintext, 0..) |*byte, i| {
        byte.* = @intCast((i * 123 + 456) & 0xFF);
    }

    // Benchmark encryption
    std.debug.print("Benchmarking AES-GMAC-SIV encryption...\n", .{});

    var timer = try std.time.Timer.start();
    const start = timer.lap();

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        var enc = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);
        const iv: u64 = @intCast(i);
        enc.initEnc(iv, ciphertext.ptr);

        // First pass: GMAC
        enc.update1(plaintext);
        enc.finish1();

        // Second pass: CTR encryption
        enc.update2(plaintext);
        _ = enc.finish2();
    }

    const elapsed = timer.read() - start;
    const elapsed_sec = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
    const total_bytes = BENCHMARK_SIZE * ITERATIONS;
    const mib = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const throughput = mib / elapsed_sec;

    std.debug.print("Elapsed: {d:.3}s\n", .{elapsed_sec});
    std.debug.print("Total data: {d:.2} MiB\n", .{mib});
    std.debug.print("Throughput: {d:.2} MiB/s\n\n", .{throughput});

    // Benchmark decryption
    std.debug.print("Benchmarking AES-GMAC-SIV decryption...\n", .{});

    // First, create a valid ciphertext with tag
    var enc_final = AES.GmacSivEncryptor.init(&aes_k0, &aes_k1);
    enc_final.initEnc(42, ciphertext.ptr);
    enc_final.update1(plaintext);
    enc_final.finish1();
    enc_final.update2(plaintext);
    const tag = enc_final.finish2().*;

    const decrypted = try allocator.alloc(u8, BENCHMARK_SIZE);
    defer allocator.free(decrypted);

    timer.reset();
    const dec_start = timer.lap();

    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        var dec = AES.GmacSivDecryptor.init(&aes_k0, &aes_k1);
        dec.initDec(&tag, decrypted.ptr);
        dec.update(ciphertext);
        _ = dec.finish();
    }

    const dec_elapsed = timer.read() - dec_start;
    const dec_elapsed_sec = @as(f64, @floatFromInt(dec_elapsed)) / 1_000_000_000.0;
    const dec_throughput = mib / dec_elapsed_sec;

    std.debug.print("Elapsed: {d:.3}s\n", .{dec_elapsed_sec});
    std.debug.print("Throughput: {d:.2} MiB/s\n\n", .{dec_throughput});

    // Benchmark AES-CTR only (for comparison)
    std.debug.print("Benchmarking AES-CTR only (no GMAC)...\n", .{});

    const ctr_output = try allocator.alloc(u8, BENCHMARK_SIZE);
    defer allocator.free(ctr_output);

    timer.reset();
    const ctr_start = timer.lap();

    i = 0;
    while (i < ITERATIONS) : (i += 1) {
        var ctr = AES.Ctr.initCtx(&aes_k1);
        const iv = [_]u8{0x01} ** 12;
        ctr.initWithIvAndCounter(&iv, @intCast(i), ctr_output.ptr);
        ctr.crypt(plaintext);
        ctr.finish();
    }

    const ctr_elapsed = timer.read() - ctr_start;
    const ctr_elapsed_sec = @as(f64, @floatFromInt(ctr_elapsed)) / 1_000_000_000.0;
    const ctr_throughput = mib / ctr_elapsed_sec;

    std.debug.print("Elapsed: {d:.3}s\n", .{ctr_elapsed_sec});
    std.debug.print("Throughput: {d:.2} MiB/s\n\n", .{ctr_throughput});

    // Show results summary
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("AES-GMAC-SIV Encrypt: {d:.2} MiB/s\n", .{throughput});
    std.debug.print("AES-GMAC-SIV Decrypt: {d:.2} MiB/s\n", .{dec_throughput});
    std.debug.print("AES-CTR only:         {d:.2} MiB/s\n", .{ctr_throughput});
}
