/// Unit tests for tray_logic.zig — pure Zig, no GUI or service needed.
const std = @import("std");
const tray = @import("tray_logic.zig");

// --- parseNetworks ---

test "parseNetworks - empty array" {
    const json = "[]";
    var nets: [16]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "parseNetworks - single network with IP" {
    const json =
        \\[{"id":"8056c2e21c000001","name":"earth","status":"OK","assignedAddresses":["10.147.20.1/24"]}]
    ;
    var nets: [16]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("8056c2e21c000001", nets[0].getId());
    try std.testing.expectEqualStrings("earth", nets[0].getName());
    try std.testing.expectEqualStrings("OK", nets[0].getStatus());
    try std.testing.expectEqualStrings("10.147.20.1/24", nets[0].getIp());
}

test "parseNetworks - network without name" {
    const json =
        \\[{"id":"abcd1234abcd1234","status":"ACCESS_DENIED"}]
    ;
    var nets: [16]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("abcd1234abcd1234", nets[0].getId());
    try std.testing.expectEqual(@as(u8, 0), nets[0].name_len);
    try std.testing.expectEqualStrings("ACCESS_DENIED", nets[0].getStatus());
    try std.testing.expectEqual(@as(u8, 0), nets[0].ip_len);
}

test "parseNetworks - multiple networks" {
    const json =
        \\[{"id":"aaaa000000000001","name":"net1","status":"OK","assignedAddresses":["10.0.0.1/24"]},
        \\ {"id":"bbbb000000000002","name":"net2","status":"OK","assignedAddresses":["10.0.1.1/24"]}]
    ;
    var nets: [16]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("aaaa000000000001", nets[0].getId());
    try std.testing.expectEqualStrings("bbbb000000000002", nets[1].getId());
}

test "parseNetworks - respects output buffer limit" {
    // Build JSON with 3 networks but only provide buffer for 2
    const json =
        \\[{"id":"0000000000000001"},{"id":"0000000000000002"},{"id":"0000000000000003"}]
    ;
    var nets: [2]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "parseNetworks - malformed JSON returns error" {
    var nets: [16]tray.NetworkInfo = undefined;
    const result = tray.parseNetworks(std.testing.allocator, "not json", &nets);
    try std.testing.expectError(error.SyntaxError, result);
}

test "parseNetworks - non-array JSON returns error" {
    var nets: [16]tray.NetworkInfo = undefined;
    const result = tray.parseNetworks(std.testing.allocator, "{}", &nets);
    try std.testing.expectError(error.InvalidFormat, result);
}

test "parseNetworks - network with multiple IPs takes first" {
    const json =
        \\[{"id":"1111111111111111","assignedAddresses":["10.0.0.1/24","fd00::1/128"]}]
    ;
    var nets: [16]tray.NetworkInfo = undefined;
    const count = try tray.parseNetworks(std.testing.allocator, json, &nets);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("10.0.0.1/24", nets[0].getIp());
}

// --- parseStatus ---

test "parseStatus - online" {
    const json =
        \\{"online":true,"address":"abcdef1234","version":"1.12.0"}
    ;
    const status = try tray.parseStatus(std.testing.allocator, json);
    try std.testing.expect(status.online);
    try std.testing.expectEqualStrings("abcdef1234", status.getAddress());
    try std.testing.expectEqualStrings("1.12.0", status.getVersion());
}

test "parseStatus - offline" {
    const json =
        \\{"online":false,"address":"abcdef1234","version":"1.12.0"}
    ;
    const status = try tray.parseStatus(std.testing.allocator, json);
    try std.testing.expect(!status.online);
}

test "parseStatus - missing fields" {
    const json = "{}";
    const status = try tray.parseStatus(std.testing.allocator, json);
    try std.testing.expect(!status.online);
    try std.testing.expectEqual(@as(u8, 0), status.address_len);
    try std.testing.expectEqual(@as(u8, 0), status.version_len);
}

test "parseStatus - malformed JSON returns error" {
    const result = tray.parseStatus(std.testing.allocator, "invalid");
    try std.testing.expectError(error.SyntaxError, result);
}

test "parseStatus - non-object JSON returns error" {
    const result = tray.parseStatus(std.testing.allocator, "[]");
    try std.testing.expectError(error.InvalidFormat, result);
}

// --- formatNetworkTitle ---

test "formatNetworkTitle - with name" {
    var info = tray.NetworkInfo{};
    const name = "earth";
    @memcpy(info.name[0..name.len], name);
    info.name_len = name.len;
    const id = "8056c2e21c000001";
    @memcpy(info.id[0..id.len], id);
    info.id_len = id.len;

    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkTitle(&info, &buf);
    try std.testing.expectEqualStrings("earth (8056c2e21c000001)", result);
}

test "formatNetworkTitle - without name" {
    var info = tray.NetworkInfo{};
    const id = "abcd1234abcd1234";
    @memcpy(info.id[0..id.len], id);
    info.id_len = id.len;

    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkTitle(&info, &buf);
    try std.testing.expectEqualStrings("abcd1234abcd1234", result);
}

// --- formatNetworkDetail ---

test "formatNetworkDetail - with IP" {
    var info = tray.NetworkInfo{};
    const status = "OK";
    @memcpy(info.status[0..status.len], status);
    info.status_len = status.len;
    const ip = "10.147.20.1/24";
    @memcpy(info.ip[0..ip.len], ip);
    info.ip_len = ip.len;

    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkDetail(&info, &buf);
    try std.testing.expectEqualStrings("  OK - 10.147.20.1/24", result);
}

test "formatNetworkDetail - no address" {
    var info = tray.NetworkInfo{};
    const status = "ACCESS_DENIED";
    @memcpy(info.status[0..status.len], status);
    info.status_len = status.len;

    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkDetail(&info, &buf);
    try std.testing.expectEqualStrings("  ACCESS_DENIED - no address", result);
}

test "formatNetworkDetail - no status" {
    var info = tray.NetworkInfo{};
    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkDetail(&info, &buf);
    try std.testing.expectEqualStrings("  UNKNOWN - no address", result);
}

// --- formatNetworkPath ---

test "formatNetworkPath - valid ID" {
    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkPath("8056c2e21c000001", &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/network/8056c2e21c000001", result.?);
}

test "formatNetworkPath - empty ID returns null" {
    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkPath("", &buf);
    try std.testing.expect(result == null);
}

test "formatNetworkPath - too long returns null" {
    var buf: [256]u8 = undefined;
    const result = tray.formatNetworkPath("12345678901234567", &buf);
    try std.testing.expect(result == null);
}

// --- menuBarTitle ---

test "menuBarTitle - online" {
    try std.testing.expectEqualStrings("ZT", tray.menuBarTitle(true));
}

test "menuBarTitle - offline" {
    try std.testing.expectEqualStrings("ZT!", tray.menuBarTitle(false));
}

// --- menuHeaderText ---

test "menuHeaderText - online" {
    try std.testing.expectEqualStrings("ZeroTier - Online", tray.menuHeaderText(true));
}

test "menuHeaderText - offline" {
    try std.testing.expectEqualStrings("ZeroTier - Offline", tray.menuHeaderText(false));
}
