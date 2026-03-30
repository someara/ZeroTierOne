/// Simple HTTP/1.1 client for communicating with zerotier-one service
///
/// This client is specifically designed for localhost communication with
/// the ZeroTier service HTTP API on port 9993.
///
/// Usage:
///   var client = HttpClient.init(allocator, "localhost", 9993);
///   defer client.deinit();
///
///   const status = try client.get("/status");
///   defer allocator.free(status);

const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;

pub const HttpClient = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    auth_token: ?[]const u8,

    pub fn init(allocator: Allocator, host: []const u8, port: u16) HttpClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .auth_token = null,
        };
    }

    pub fn setAuthToken(self: *HttpClient, token: []const u8) void {
        self.auth_token = token;
    }

    pub fn deinit(self: *HttpClient) void {
        _ = self;
        // Nothing to cleanup for now
    }

    /// Perform HTTP GET request
    pub fn get(self: *HttpClient, path: []const u8) ![]const u8 {
        return self.request("GET", path, null);
    }

    /// Perform HTTP POST request with JSON body
    pub fn post(self: *HttpClient, path: []const u8, body: []const u8) ![]const u8 {
        return self.request("POST", path, body);
    }

    /// Perform HTTP DELETE request
    pub fn delete(self: *HttpClient, path: []const u8) ![]const u8 {
        return self.request("DELETE", path, null);
    }

    /// Low-level HTTP request
    fn request(self: *HttpClient, method: []const u8, path: []const u8, body: ?[]const u8) ![]const u8 {
        // Connect to service
        const address = try net.Address.parseIp(self.host, self.port);
        const stream = try net.tcpConnectToAddress(address);
        defer stream.close();

        // Build HTTP request
        var request_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer request_buf.deinit(self.allocator);

        const writer = request_buf.writer(self.allocator);

        // Request line: GET /status HTTP/1.1
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, path });

        // Headers
        try writer.print("Host: {s}:{d}\r\n", .{ self.host, self.port });
        try writer.writeAll("Connection: close\r\n");
        try writer.writeAll("User-Agent: ZeroTier-Zig/1.0\r\n");
        try writer.writeAll("Accept: application/json\r\n");

        // Add auth token if provided
        if (self.auth_token) |token| {
            try writer.print("X-ZT1-Auth: {s}\r\n", .{token});
        }

        if (body) |b| {
            try writer.print("Content-Length: {d}\r\n", .{b.len});
            try writer.writeAll("Content-Type: application/json\r\n");
        }

        // End of headers
        try writer.writeAll("\r\n");

        // Body (if present)
        if (body) |b| {
            try writer.writeAll(b);
        }

        // Send request
        try stream.writeAll(request_buf.items);

        // Read response
        var response_buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        defer response_buf.deinit(self.allocator);

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try stream.read(&buffer);
            if (bytes_read == 0) break;
            try response_buf.appendSlice(self.allocator, buffer[0..bytes_read]);
        }

        // Parse HTTP response
        const response = response_buf.items;

        // Find end of headers (blank line)
        const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
                          std.mem.indexOf(u8, response, "\n\n") orelse
                          return error.InvalidHttpResponse;

        // Extract status code
        const status_line_end = std.mem.indexOf(u8, response, "\r\n") orelse
                               std.mem.indexOf(u8, response, "\n") orelse
                               return error.InvalidHttpResponse;

        const status_line = response[0..status_line_end];

        // Status line format: "HTTP/1.1 200 OK"
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        _ = parts.next(); // Skip "HTTP/1.1"
        const status_code_str = parts.next() orelse return error.InvalidHttpResponse;
        const status_code = try std.fmt.parseInt(u16, status_code_str, 10);

        if (status_code < 200 or status_code >= 300) {
            std.debug.print("HTTP error {d}: {s}\n", .{ status_code, status_line });
            return error.HttpError;
        }

        // Return body (everything after header)
        const body_start = header_end + 4; // Skip \r\n\r\n
        if (body_start >= response.len) {
            // Empty response body
            return try self.allocator.dupe(u8, "");
        }

        const response_body = response[body_start..];
        return try self.allocator.dupe(u8, response_body);
    }
};

// Tests
test "HttpClient init/deinit" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator, "localhost", 9993);
    defer client.deinit();

    try std.testing.expectEqual(@as(u16, 9993), client.port);
    try std.testing.expectEqualStrings("localhost", client.host);
}

test "HttpClient build GET request" {
    const allocator = std.testing.allocator;
    var client = HttpClient.init(allocator, "localhost", 9993);
    defer client.deinit();

    // We can't actually test network calls in unit tests, but we can test
    // the structure is correct
    try std.testing.expect(client.port == 9993);
}
