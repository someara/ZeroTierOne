/// Benchmark packet processing pipeline performance
///
/// Measures throughput and latency of key packet operations:
/// - Packet encryption (armor)
/// - Packet decryption (dearmor)
/// - Compression/decompression
/// - Full round-trip
///
/// Run with: zig build bench-packets
const std = @import("std");
const testing = std.testing;

const Identity = @import("node/identity.zig").Identity;
const Packet = @import("node/packet.zig").Packet;
const Verb = @import("node/packet.zig").Verb;

const ITERATIONS = 10_000;
const PAYLOAD_SIZE = 1400; // Typical MTU

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== ZeroTier Packet Processing Benchmark ===\n\n", .{});

    // Setup: Generate identities and shared key
    var id_a = try Identity.generate(allocator);
    var id_b = try Identity.generate(allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    var shared_key: [32]u8 = undefined;
    _ = id_a.agree(&id_b, &shared_key);

    // Benchmark 1: Packet armor (encrypt)
    {
        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            var pkt = Packet{ .buf = .{} };
            pkt.reset(id_b.address(), id_a.address(), .echo);

            var payload: [PAYLOAD_SIZE]u8 = undefined;
            @memset(&payload, @intCast(i & 0xFF));
            try pkt.buf.appendBytes(&payload);

            pkt.armor(&shared_key, true, false, null, null);
        }

        const elapsed = timer.read();
        const ns_per_packet = elapsed / ITERATIONS;
        const packets_per_sec = (ITERATIONS * std.time.ns_per_s) / elapsed;

        std.debug.print("[armor] {d} packets encrypted\n", .{ITERATIONS});
        std.debug.print("  {d} ns/packet ({d:.2} us/packet)\n", .{ns_per_packet, @as(f64, @floatFromInt(ns_per_packet)) / 1000.0});
        std.debug.print("  {d} packets/second\n", .{packets_per_sec});
        std.debug.print("  {d:.2} MiB/s\n\n", .{@as(f64, @floatFromInt(packets_per_sec * PAYLOAD_SIZE)) / (1024.0 * 1024.0)});
    }

    // Benchmark 2: Packet dearmor (decrypt)
    {
        // Pre-encrypt a packet
        var template_pkt = Packet{ .buf = .{} };
        template_pkt.reset(id_b.address(), id_a.address(), .echo);
        var payload: [PAYLOAD_SIZE]u8 = undefined;
        @memset(&payload, 0x42);
        try template_pkt.buf.appendBytes(&payload);
        template_pkt.armor(&shared_key, true, false, null, null);

        var encrypted_data: [4096]u8 = undefined;
        const encrypted_len = template_pkt.buf.size();
        @memcpy(encrypted_data[0..encrypted_len], template_pkt.buf.data());

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            var pkt = Packet{ .buf = .{} };
            pkt.buf.setSize(encrypted_len) catch unreachable;
            @memcpy(pkt.buf.dataMut()[0..encrypted_len], encrypted_data[0..encrypted_len]);

            _ = pkt.dearmor(&shared_key, null, null);
        }

        const elapsed = timer.read();
        const ns_per_packet = elapsed / ITERATIONS;
        const packets_per_sec = (ITERATIONS * std.time.ns_per_s) / elapsed;

        std.debug.print("[dearmor] {d} packets decrypted\n", .{ITERATIONS});
        std.debug.print("  {d} ns/packet ({d:.2} us/packet)\n", .{ns_per_packet, @as(f64, @floatFromInt(ns_per_packet)) / 1000.0});
        std.debug.print("  {d} packets/second\n", .{packets_per_sec});
        std.debug.print("  {d:.2} MiB/s\n\n", .{@as(f64, @floatFromInt(packets_per_sec * PAYLOAD_SIZE)) / (1024.0 * 1024.0)});
    }

    // Benchmark 3: Full round-trip (armor + dearmor)
    {
        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            // Encrypt
            var pkt_out = Packet{ .buf = .{} };
            pkt_out.reset(id_b.address(), id_a.address(), .echo);
            var payload: [PAYLOAD_SIZE]u8 = undefined;
            @memset(&payload, @intCast(i & 0xFF));
            try pkt_out.buf.appendBytes(&payload);
            pkt_out.armor(&shared_key, true, false, null, null);

            // Copy encrypted data
            var encrypted_data: [4096]u8 = undefined;
            const encrypted_len = pkt_out.buf.size();
            @memcpy(encrypted_data[0..encrypted_len], pkt_out.buf.data());

            // Decrypt
            var pkt_in = Packet{ .buf = .{} };
            pkt_in.buf.setSize(encrypted_len) catch unreachable;
            @memcpy(pkt_in.buf.dataMut()[0..encrypted_len], encrypted_data[0..encrypted_len]);
            _ = pkt_in.dearmor(&shared_key, null, null);
        }

        const elapsed = timer.read();
        const ns_per_roundtrip = elapsed / ITERATIONS;
        const roundtrips_per_sec = (ITERATIONS * std.time.ns_per_s) / elapsed;

        std.debug.print("[round-trip] {d} packets encrypted + decrypted\n", .{ITERATIONS});
        std.debug.print("  {d} ns/round-trip ({d:.2} us/round-trip)\n", .{ns_per_roundtrip, @as(f64, @floatFromInt(ns_per_roundtrip)) / 1000.0});
        std.debug.print("  {d} round-trips/second\n", .{roundtrips_per_sec});
        std.debug.print("  {d:.2} MiB/s (bidirectional)\n\n", .{@as(f64, @floatFromInt(roundtrips_per_sec * PAYLOAD_SIZE * 2)) / (1024.0 * 1024.0)});
    }

    std.debug.print("Benchmark complete.\n", .{});
}
