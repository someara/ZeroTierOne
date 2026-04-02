/// Compile-time utilities for ZeroTier
///
/// Provides comptime parsing functions that convert string literals to
/// binary data at compile time, eliminating runtime parsing overhead.
///
/// Inspired by pdns Phase 4 comptime optimizations (commit 40a3adbcf).
///
/// Benefits:
/// - Zero runtime cost (parsing happens at compile time)
/// - Format errors caught during build
/// - More readable than hand-written structs
/// - Same binary output as hand-written data
const std = @import("std");

/// Parse an IPv4 address string at compile time.
///
/// Example:
///   const localhost = comptime comptimeParseIPv4("127.0.0.1");
///   // Becomes: .{ 127, 0, 0, 1 } in binary
///
/// Compile errors if format is invalid.
pub fn comptimeParseIPv4(comptime ip_str: []const u8) [4]u8 {
    comptime {
        var result: [4]u8 = undefined;
        var octet_idx: usize = 0;
        var start: usize = 0;

        for (ip_str, 0..) |ch, i| {
            if (ch == '.' or i == ip_str.len - 1) {
                const end = if (ch == '.') i else i + 1;
                const octet_str = ip_str[start..end];

                if (octet_idx >= 4) {
                    @compileError("IPv4 address has too many octets: " ++ ip_str);
                }

                const octet = parseU8(octet_str) catch {
                    @compileError("Invalid octet in IPv4 address: " ++ octet_str);
                };

                result[octet_idx] = octet;
                octet_idx += 1;
                start = i + 1;
            }
        }

        if (octet_idx != 4) {
            @compileError("IPv4 address has wrong number of octets: " ++ ip_str);
        }

        return result;
    }
}

/// Parse an IPv6 address string at compile time (simplified - full form only).
///
/// Example:
///   const addr = comptime comptimeParseIPv6("2001:0db8:0000:0000:0000:0000:0000:0001");
///
/// Note: Currently only supports full form (no :: compression).
pub fn comptimeParseIPv6(comptime ip_str: []const u8) [16]u8 {
    comptime {
        var result: [16]u8 = undefined;
        var group_idx: usize = 0;
        var start: usize = 0;

        for (ip_str, 0..) |ch, i| {
            if (ch == ':' or i == ip_str.len - 1) {
                const end = if (ch == ':') i else i + 1;
                const group_str = ip_str[start..end];

                if (group_idx >= 8) {
                    @compileError("IPv6 address has too many groups: " ++ ip_str);
                }

                const group = parseU16Hex(group_str) catch {
                    @compileError("Invalid group in IPv6 address: " ++ group_str);
                };

                // Store as big-endian
                result[group_idx * 2] = @truncate(group >> 8);
                result[group_idx * 2 + 1] = @truncate(group & 0xFF);

                group_idx += 1;
                start = i + 1;
            }
        }

        if (group_idx != 8) {
            @compileError("IPv6 address has wrong number of groups: " ++ ip_str);
        }

        return result;
    }
}

/// Parse a ZeroTier address (10-digit hex) at compile time.
///
/// Example:
///   const addr = comptime comptimeParseZTAddress("8056c2e21c");
///   // Becomes: 0x8056c2e21c in binary
pub fn comptimeParseZTAddress(comptime addr_str: []const u8) u64 {
    comptime {
        if (addr_str.len != 10) {
            @compileError("ZeroTier address must be exactly 10 hex digits: " ++ addr_str);
        }

        return parseU64Hex(addr_str) catch {
            @compileError("Invalid ZeroTier address: " ++ addr_str);
        };
    }
}

/// Parse a MAC address (6 bytes, colon-separated) at compile time.
///
/// Example:
///   const mac = comptime comptimeParse MAC("02:00:00:00:00:00");
///   // Becomes: .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x00 }
pub fn comptimeParseMAC(comptime mac_str: []const u8) [6]u8 {
    comptime {
        var result: [6]u8 = undefined;
        var byte_idx: usize = 0;
        var start: usize = 0;

        for (mac_str, 0..) |ch, i| {
            if (ch == ':' or i == mac_str.len - 1) {
                const end = if (ch == ':') i else i + 1;
                const byte_str = mac_str[start..end];

                if (byte_idx >= 6) {
                    @compileError("MAC address has too many bytes: " ++ mac_str);
                }

                const byte = parseU8Hex(byte_str) catch {
                    @compileError("Invalid byte in MAC address: " ++ byte_str);
                };

                result[byte_idx] = byte;
                byte_idx += 1;
                start = i + 1;
            }
        }

        if (byte_idx != 6) {
            @compileError("MAC address has wrong number of bytes: " ++ mac_str);
        }

        return result;
    }
}

/// Parse a u16 port number at compile time.
///
/// Example:
///   const port = comptime comptimeParsePort("9993");
///   // Becomes: 9993 in binary
pub fn comptimeParsePort(comptime port_str: []const u8) u16 {
    comptime {
        const port = parseU16(port_str) catch {
            @compileError("Invalid port number: " ++ port_str);
        };

        if (port == 0) {
            @compileError("Port number cannot be zero");
        }

        return port;
    }
}

// ── Helper Functions (comptime only) ────────────────────────────────────

fn parseU8(comptime s: []const u8) !u8 {
    comptime {
        var result: u16 = 0;
        for (s) |ch| {
            if (ch < '0' or ch > '9') {
                return error.InvalidDigit;
            }
            result = result * 10 + (ch - '0');
            if (result > 255) {
                return error.Overflow;
            }
        }
        return @intCast(result);
    }
}

fn parseU16(comptime s: []const u8) !u16 {
    comptime {
        var result: u32 = 0;
        for (s) |ch| {
            if (ch < '0' or ch > '9') {
                return error.InvalidDigit;
            }
            result = result * 10 + (ch - '0');
            if (result > 65535) {
                return error.Overflow;
            }
        }
        return @intCast(result);
    }
}

fn parseU8Hex(comptime s: []const u8) !u8 {
    comptime {
        var result: u8 = 0;
        for (s) |ch| {
            const digit = if (ch >= '0' and ch <= '9')
                ch - '0'
            else if (ch >= 'a' and ch <= 'f')
                ch - 'a' + 10
            else if (ch >= 'A' and ch <= 'F')
                ch - 'A' + 10
            else
                return error.InvalidHexDigit;

            result = result * 16 + digit;
        }
        return result;
    }
}

fn parseU16Hex(comptime s: []const u8) !u16 {
    comptime {
        var result: u16 = 0;
        for (s) |ch| {
            const digit = if (ch >= '0' and ch <= '9')
                ch - '0'
            else if (ch >= 'a' and ch <= 'f')
                ch - 'a' + 10
            else if (ch >= 'A' and ch <= 'F')
                ch - 'A' + 10
            else
                return error.InvalidHexDigit;

            result = result * 16 + digit;
        }
        return result;
    }
}

fn parseU64Hex(comptime s: []const u8) !u64 {
    comptime {
        var result: u64 = 0;
        for (s) |ch| {
            const digit: u64 = if (ch >= '0' and ch <= '9')
                ch - '0'
            else if (ch >= 'a' and ch <= 'f')
                ch - 'a' + 10
            else if (ch >= 'A' and ch <= 'F')
                ch - 'A' + 10
            else
                return error.InvalidHexDigit;

            result = result * 16 + digit;
        }
        return result;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "comptimeParseIPv4" {
    const localhost = comptime comptimeParseIPv4("127.0.0.1");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 0, 0, 1 }, &localhost);

    const google_dns = comptime comptimeParseIPv4("8.8.8.8");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 8, 8, 8 }, &google_dns);

    const zero = comptime comptimeParseIPv4("0.0.0.0");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &zero);
}

test "comptimeParseIPv6" {
    const addr = comptime comptimeParseIPv6("2001:0db8:0000:0000:0000:0000:0000:0001");
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    }, &addr);
}

test "comptimeParseZTAddress" {
    const earth = comptime comptimeParseZTAddress("8056c2e21c");
    try std.testing.expectEqual(@as(u64, 0x8056c2e21c), earth);

    const addr = comptime comptimeParseZTAddress("deadbeef00");
    try std.testing.expectEqual(@as(u64, 0xdeadbeef00), addr);
}

test "comptimeParseMAC" {
    const mac = comptime comptimeParseMAC("02:00:00:00:00:01");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 }, &mac);

    const broadcast = comptime comptimeParseMAC("ff:ff:ff:ff:ff:ff");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, &broadcast);
}

test "comptimeParsePort" {
    const zt_port = comptime comptimeParsePort("9993");
    try std.testing.expectEqual(@as(u16, 9993), zt_port);

    const http = comptime comptimeParsePort("80");
    try std.testing.expectEqual(@as(u16, 80), http);
}
