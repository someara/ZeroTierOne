/// HTTP API Server for the ZeroTier service
///
/// Provides a minimal HTTP/1.1 server on localhost for the tray app and CLI.
/// Runs on a separate thread, serving requests against Node state.
///
/// Endpoints:
///   GET    /status          — Service status (online, address, version)
///   GET    /network         — List joined networks
///   POST   /network/{id}    — Join a network
///   DELETE /network/{id}    — Leave a network

const std = @import("std");
const mem = std.mem;
const net = std.net;
const Allocator = mem.Allocator;
const Node = @import("node.zig").Node;
const InetAddress = @import("inet_address.zig").InetAddress;
const network_mod = @import("network.zig");
const Network = network_mod.Network;
const NetconfFailure = network_mod.NetconfFailure;

const version_string = "2.0.0-zig";

pub const HttpApi = struct {
    allocator: Allocator,
    server: net.Server,
    thread: ?std.Thread,
    node: *Node,
    auth_token: []const u8,
    running: std.atomic.Value(bool),

    pub fn start(
        allocator: Allocator,
        node: *Node,
        port: u16,
        auth_token: []const u8,
    ) !*HttpApi {
        const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const server = try address.listen(.{
            .reuse_address = true,
        });

        const self = try allocator.create(HttpApi);
        self.* = .{
            .allocator = allocator,
            .server = server,
            .thread = null,
            .node = node,
            .auth_token = auth_token,
            .running = std.atomic.Value(bool).init(true),
        };

        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *HttpApi) void {
        self.running.store(false, .release);
        self.server.deinit();
        if (self.thread) |t| t.join();
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *HttpApi) void {
        while (self.running.load(.acquire)) {
            const conn = self.server.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                std.debug.print("http_api: accept error: {}\n", .{err});
                continue;
            };
            self.handleConnection(conn) catch |err| {
                std.debug.print("http_api: connection error: {}\n", .{err});
            };
            conn.stream.close();
        }
    }

    fn handleConnection(self: *HttpApi, conn: net.Server.Connection) !void {
        var buf: [4096]u8 = undefined;
        const n = try conn.stream.read(&buf);
        if (n == 0) return;

        const request_data = buf[0..n];
        const req = parseRequest(request_data) orelse {
            try sendResponse(conn.stream, 400, "Bad Request", "{\"error\":\"bad request\"}");
            return;
        };

        // Check auth (except for empty token which means no auth configured)
        if (self.auth_token.len > 0 and !self.checkAuth(&req)) {
            try sendResponse(conn.stream, 401, "Unauthorized", "{\"error\":\"unauthorized\"}");
            return;
        }

        self.route(conn.stream, &req) catch |err| {
            std.debug.print("http_api: handler error: {}\n", .{err});
            try sendResponse(conn.stream, 500, "Internal Server Error", "{\"error\":\"internal error\"}");
        };
    }

    fn route(self: *HttpApi, stream: net.Stream, req: *const HttpRequest) !void {
        // GET /status
        if (req.method == .GET and mem.eql(u8, req.path, "/status")) {
            return self.handleGetStatus(stream);
        }

        // GET /network
        if (req.method == .GET and mem.eql(u8, req.path, "/network")) {
            return self.handleGetNetworks(stream);
        }

        // POST /network/{id} or DELETE /network/{id}
        if (mem.startsWith(u8, req.path, "/network/")) {
            const id_str = req.path["/network/".len..];
            if (id_str.len == 16) {
                const nwid = std.fmt.parseInt(u64, id_str, 16) catch {
                    try sendResponse(stream, 400, "Bad Request", "{\"error\":\"invalid network id\"}");
                    return;
                };
                if (req.method == .POST) {
                    return self.handlePostNetwork(stream, nwid);
                } else if (req.method == .DELETE) {
                    return self.handleDeleteNetwork(stream, nwid);
                }
            }
        }

        try sendResponse(stream, 404, "Not Found", "{\"error\":\"not found\"}");
    }

    fn handleGetStatus(self: *HttpApi, stream: net.Stream) !void {
        var addr_buf: [10]u8 = undefined;
        const addr = self.node.identity.address().toString(&addr_buf);
        const now = std.time.milliTimestamp();

        var resp_buf: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&resp_buf,
            \\{{"online":{s},"address":"{s}","version":"{s}","clock":{d}}}
        , .{
            if (self.node.online) "true" else "false",
            addr,
            version_string,
            now,
        });

        try sendResponse(stream, 200, "OK", body);
    }

    fn handleGetNetworks(self: *HttpApi, stream: net.Stream) !void {
        const nwids = self.node.listNetworks(self.allocator) catch {
            try sendResponse(stream, 500, "Internal Server Error", "{\"error\":\"failed to list networks\"}");
            return;
        };
        defer self.allocator.free(nwids);

        if (nwids.len == 0) {
            try sendResponse(stream, 200, "OK", "[]");
            return;
        }

        // Build JSON array manually
        var resp = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer resp.deinit(self.allocator);

        try resp.append(self.allocator, '[');
        for (nwids, 0..) |nwid, i| {
            if (i > 0) try resp.append(self.allocator, ',');
            try self.appendNetworkJson(&resp, nwid);
        }
        try resp.append(self.allocator, ']');

        try sendResponse(stream, 200, "OK", resp.items);
    }

    fn handlePostNetwork(self: *HttpApi, stream: net.Stream, nwid: u64) !void {
        _ = self.node.joinNetwork(nwid) catch {
            try sendResponse(stream, 500, "Internal Server Error", "{\"error\":\"failed to join\"}");
            return;
        };

        // Return the network object
        var resp = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer resp.deinit(self.allocator);
        try self.appendNetworkJson(&resp, nwid);
        try sendResponse(stream, 200, "OK", resp.items);
    }

    fn handleDeleteNetwork(self: *HttpApi, stream: net.Stream, nwid: u64) !void {
        self.node.leaveNetwork(null, nwid, null);
        try sendResponse(stream, 200, "OK", "{\"result\":true}");
    }

    fn appendNetworkJson(self: *HttpApi, list: *std.ArrayList(u8), nwid: u64) !void {
        const writer = list.writer(self.allocator);

        // Format network ID as 16-char hex
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{x:0>16}", .{nwid}) catch "????????????????";

        // Get network details
        const network = self.node.getNetwork(nwid);

        // Default values if no config
        var name_str: []const u8 = "";
        var status_str: []const u8 = "REQUESTING_CONFIGURATION";
        var ip_strs: [16][]const u8 = undefined;
        var ip_bufs: [16][64]u8 = undefined;
        var ip_count: usize = 0;

        if (network) |net_ptr| {
            // Access config (behind lock)
            const config = &net_ptr._config;
            name_str = mem.sliceTo(&config.name, 0);

            // Determine status from netconf failure
            status_str = switch (net_ptr._netconf_failure) {
                .none => if (net_ptr._last_config_update > 0) "OK" else "REQUESTING_CONFIGURATION",
                .access_denied => "ACCESS_DENIED",
                .not_found => "NOT_FOUND",
                .authentication_required => "AUTHENTICATION_REQUIRED",
                .init_failed => "PORT_ERROR",
            };

            // Assigned addresses
            var j: usize = 0;
            while (j < config.static_ip_count and j < 16) : (j += 1) {
                ip_strs[j] = config.static_ips[j].toString(&ip_bufs[j]);
                ip_count += 1;
            }
        }

        try writer.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"status\":\"{s}\",\"assignedAddresses\":[", .{
            id_str, name_str, status_str,
        });

        for (0..ip_count) |k| {
            if (k > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{ip_strs[k]});
        }

        try writer.writeAll("]}");
    }

    fn checkAuth(self: *HttpApi, req: *const HttpRequest) bool {
        return mem.eql(u8, req.auth_token, self.auth_token);
    }

    fn sendResponse(stream: net.Stream, code: u16, reason: []const u8, body: []const u8) !void {
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ code, reason, body.len },
        );
        try stream.writeAll(header);
        try stream.writeAll(body);
    }

    fn parseRequest(data: []const u8) ?HttpRequest {
        // Find end of first line
        const line_end = mem.indexOf(u8, data, "\r\n") orelse return null;
        const request_line = data[0..line_end];

        // Parse "METHOD /path HTTP/1.1"
        var parts = mem.splitScalar(u8, request_line, ' ');
        const method_str = parts.next() orelse return null;
        const path = parts.next() orelse return null;

        const method: HttpMethod = if (mem.eql(u8, method_str, "GET"))
            .GET
        else if (mem.eql(u8, method_str, "POST"))
            .POST
        else if (mem.eql(u8, method_str, "DELETE"))
            .DELETE
        else
            return null;

        // Extract auth token from headers
        var auth_token: []const u8 = "";
        var header_start = line_end + 2;
        while (header_start < data.len) {
            const next_end = mem.indexOf(u8, data[header_start..], "\r\n") orelse break;
            const header_line = data[header_start .. header_start + next_end];
            if (header_line.len == 0) break; // empty line = end of headers

            if (mem.startsWith(u8, header_line, "X-ZT1-Auth: ") or
                mem.startsWith(u8, header_line, "x-zt1-auth: "))
            {
                auth_token = header_line["X-ZT1-Auth: ".len..];
            }

            header_start += next_end + 2;
        }

        return HttpRequest{
            .method = method,
            .path = path,
            .auth_token = auth_token,
        };
    }
};

const HttpMethod = enum { GET, POST, DELETE };

const HttpRequest = struct {
    method: HttpMethod,
    path: []const u8,
    auth_token: []const u8,
};
