/// Tray App Logic — Pure Zig, no GUI dependencies
///
/// All business logic for the tray app: JSON parsing, formatting, state.
/// Fully unit-testable without macOS or ObjC.

const std = @import("std");

pub const MAX_NETWORKS = 16;

pub const NetworkInfo = struct {
    id: [16]u8 = undefined,
    id_len: u8 = 0,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    status: [32]u8 = undefined,
    status_len: u8 = 0,
    ip: [64]u8 = undefined,
    ip_len: u8 = 0,

    pub fn getId(self: *const NetworkInfo) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn getName(self: *const NetworkInfo) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getStatus(self: *const NetworkInfo) []const u8 {
        return self.status[0..self.status_len];
    }

    pub fn getIp(self: *const NetworkInfo) []const u8 {
        return self.ip[0..self.ip_len];
    }
};

pub const ServiceStatus = struct {
    online: bool = false,
    address: [16]u8 = undefined,
    address_len: u8 = 0,
    version: [32]u8 = undefined,
    version_len: u8 = 0,

    pub fn getAddress(self: *const ServiceStatus) []const u8 {
        return self.address[0..self.address_len];
    }

    pub fn getVersion(self: *const ServiceStatus) []const u8 {
        return self.version[0..self.version_len];
    }
};

/// Parse /network JSON response into NetworkInfo array.
/// Returns the number of networks parsed (up to out.len).
pub fn parseNetworks(allocator: std.mem.Allocator, json_response: []const u8, out: []NetworkInfo) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidFormat;
    const items = parsed.value.array.items;

    var count: usize = 0;
    for (items) |item| {
        if (count >= out.len) break;
        if (item != .object) continue;
        const obj = item.object;

        var info = NetworkInfo{};

        if (getStr(obj, "id")) |s| {
            const len: u8 = @intCast(@min(s.len, 16));
            @memcpy(info.id[0..len], s[0..len]);
            info.id_len = len;
        }

        if (getStr(obj, "name")) |s| {
            const len: u8 = @intCast(@min(s.len, 64));
            @memcpy(info.name[0..len], s[0..len]);
            info.name_len = len;
        }

        if (getStr(obj, "status")) |s| {
            const len: u8 = @intCast(@min(s.len, 32));
            @memcpy(info.status[0..len], s[0..len]);
            info.status_len = len;
        }

        // First assigned address
        if (obj.get("assignedAddresses")) |addrs| {
            if (addrs == .array and addrs.array.items.len > 0) {
                if (addrs.array.items[0] == .string) {
                    const s = addrs.array.items[0].string;
                    const len: u8 = @intCast(@min(s.len, 64));
                    @memcpy(info.ip[0..len], s[0..len]);
                    info.ip_len = len;
                }
            }
        }

        out[count] = info;
        count += 1;
    }

    return count;
}

/// Parse /status JSON response.
pub fn parseStatus(allocator: std.mem.Allocator, json_response: []const u8) !ServiceStatus {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidFormat;
    const obj = parsed.value.object;

    var status = ServiceStatus{};

    if (obj.get("online")) |v| {
        if (v == .bool) status.online = v.bool;
    }

    if (getStr(obj, "address")) |s| {
        const len: u8 = @intCast(@min(s.len, 16));
        @memcpy(status.address[0..len], s[0..len]);
        status.address_len = len;
    }

    if (getStr(obj, "version")) |s| {
        const len: u8 = @intCast(@min(s.len, 32));
        @memcpy(status.version[0..len], s[0..len]);
        status.version_len = len;
    }

    return status;
}

/// Format network title: "name (id)" or just "id"
pub fn formatNetworkTitle(info: *const NetworkInfo, buf: []u8) []const u8 {
    const id = info.getId();
    const name = info.getName();

    if (name.len > 0) {
        return std.fmt.bufPrint(buf, "{s} ({s})", .{ name, id }) catch id;
    }
    return std.fmt.bufPrint(buf, "{s}", .{id}) catch "???";
}

/// Format network detail line: "  STATUS - ip"
pub fn formatNetworkDetail(info: *const NetworkInfo, buf: []u8) []const u8 {
    const status_str = if (info.status_len > 0) info.getStatus() else "UNKNOWN";
    const ip_str = if (info.ip_len > 0) info.getIp() else "no address";
    return std.fmt.bufPrint(buf, "  {s} - {s}", .{ status_str, ip_str }) catch "  ...";
}

/// Format API path: "/network/<id>"
pub fn formatNetworkPath(network_id: []const u8, buf: []u8) ?[]const u8 {
    if (network_id.len == 0 or network_id.len > 16) return null;
    return std.fmt.bufPrint(buf, "/network/{s}", .{network_id}) catch null;
}

/// Menu bar title based on online status
pub fn menuBarTitle(online: bool) []const u8 {
    return if (online) "ZT" else "ZT!";
}

/// Menu header text
pub fn menuHeaderText(online: bool) []const u8 {
    return if (online) "ZeroTier - Online" else "ZeroTier - Offline";
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}
