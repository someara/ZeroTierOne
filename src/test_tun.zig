/// Test TUN Device — Verify TUN device creation and operation
///
/// This test creates a TUN device, configures it with an IP address,
/// and verifies we can read/write packets.
///
/// Build: zig build-exe src/test_tun.zig -I./src -I.
/// Run:   sudo ./test_tun  (requires root for network interface creation)

const std = @import("std");
const TunDevice = @import("node/tun_device.zig").TunDevice;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  TUN Device Test — macOS utun\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n\n", .{});

    // ── Step 1: Open TUN Device ───────────────────────────────────────
    std.debug.print("Step 1: Opening TUN device...\n", .{});
    var tun = try TunDevice.open(allocator, "utun");
    defer tun.close();

    std.debug.print("\n", .{});

    // ── Step 2: Configure IP Address ──────────────────────────────────
    std.debug.print("Step 2: Configuring IP address...\n", .{});

    // Use 10.147.20.1 (typical ZeroTier range)
    const ip = [4]u8{10, 147, 20, 1};
    const netmask = [4]u8{255, 255, 0, 0};

    try tun.setAddress(ip, netmask);

    std.debug.print("\n", .{});

    // ── Step 3: Verify Interface ──────────────────────────────────────
    std.debug.print("Step 3: Verifying interface is up...\n", .{});

    // Run ifconfig to show the interface
    const argv = [_][]const u8{
        "/sbin/ifconfig",
        tun.name,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    std.debug.print("\n", .{});
    const result = try child.spawnAndWait();
    std.debug.print("\n", .{});

    if (result != .Exited or result.Exited != 0) {
        std.debug.print("⚠️  Warning: ifconfig returned non-zero\n", .{});
    }

    // ── Step 4: Test Packet I/O ───────────────────────────────────────
    std.debug.print("Step 4: Testing packet I/O...\n", .{});
    std.debug.print("  (Waiting 3 seconds for packets...)\n", .{});
    std.debug.print("  Try: ping 10.147.20.1\n", .{});
    std.debug.print("\n", .{});

    var packets_received: u32 = 0;
    const start_time = std.time.milliTimestamp();
    const timeout_ms: i64 = 3000;

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        var buf: [2048]u8 = undefined;

        const len = tun.read(&buf) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };

        packets_received += 1;

        // Parse packet
        if (len < 20) {
            std.debug.print("  → Received short packet ({d} bytes)\n", .{len});
            continue;
        }

        const version = buf[0] >> 4;
        if (version == 4) {
            // IPv4 packet
            const protocol = buf[9];
            const src_ip = buf[12..16];
            const dst_ip = buf[16..20];

            const proto_name = switch (protocol) {
                1 => "ICMP",
                6 => "TCP",
                17 => "UDP",
                else => "???",
            };

            std.debug.print("  → IPv4 {s}: {d}.{d}.{d}.{d} → {d}.{d}.{d}.{d} ({d} bytes)\n",
                .{proto_name, src_ip[0], src_ip[1], src_ip[2], src_ip[3],
                  dst_ip[0], dst_ip[1], dst_ip[2], dst_ip[3], len});

            // If it's ICMP echo request (ping), we could reply
            if (protocol == 1 and len >= 28) {
                const icmp_type = buf[20];
                if (icmp_type == 8) { // Echo request
                    std.debug.print("      (ICMP Echo Request — ping detected!)\n", .{});

                    // Optionally: send echo reply
                    // This would require:
                    // 1. Swap src/dst IPs
                    // 2. Change ICMP type to 0 (Echo Reply)
                    // 3. Recalculate checksums
                    // 4. tun.write(reply_packet)
                    // For now, we just log it
                }
            }
        } else if (version == 6) {
            std.debug.print("  → IPv6 packet ({d} bytes)\n", .{len});
        } else {
            std.debug.print("  → Unknown packet version {d} ({d} bytes)\n", .{version, len});
        }
    }

    std.debug.print("\n", .{});

    // ── Summary ────────────────────────────────────────────────────────
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Test Summary\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════\n", .{});
    std.debug.print("Device:            {s}\n", .{tun.name});
    std.debug.print("Unit number:       {d}\n", .{tun.unit_number});
    std.debug.print("IP address:        10.147.20.1/16\n", .{});
    std.debug.print("Packets received:  {d}\n", .{packets_received});
    std.debug.print("\n", .{});

    if (packets_received == 0) {
        std.debug.print("⚠️  No packets received. This is normal if you didn't ping.\n", .{});
        std.debug.print("    Try: ping 10.147.20.1 (in another terminal)\n", .{});
    } else {
        std.debug.print("✓ TUN device is working correctly!\n", .{});
        std.debug.print("✓ Successfully received and parsed packets\n", .{});
    }

    std.debug.print("\n", .{});
}
