/// Test program for HTTP client
///
/// This tests the HTTP client against a running zerotier-one service.
///
/// Prerequisites:
///   1. Build and start zerotier-one: make && sudo ./zerotier-one
///   2. Run this test: zig build test-http-client
///
/// The test will:
///   - Connect to localhost:9993
///   - Call GET /status
///   - Parse and display the JSON response

const std = @import("std");
const HttpClient = @import("http_client.zig").HttpClient;

/// Read auth token from ZeroTier home directory
fn readAuthToken(allocator: std.mem.Allocator) ![]const u8 {
    // Try common locations for auth token
    const token_paths = [_][]const u8{
        "/tmp/zt-home/authtoken.secret",
        "/var/lib/zerotier-one/authtoken.secret",
        "/Library/Application Support/ZeroTier/One/authtoken.secret",
    };

    for (token_paths) |path| {
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);

        // Trim whitespace
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            // Return a copy of the trimmed string (before freeing content)
            return try allocator.dupe(u8, trimmed);
        }
    }

    return error.TokenNotFound;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║         ZeroTier HTTP Client Test                    ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("║  Testing HTTP communication with zerotier-one service ║\n", .{});
    std.debug.print("║                                                       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    // Initialize HTTP client
    var client = HttpClient.init(allocator, "127.0.0.1", 9993);
    defer client.deinit();

    // Try to read auth token from home directory
    std.debug.print("→ Reading auth token...\n", .{});
    const token = readAuthToken(allocator) catch |err| blk: {
        std.debug.print("⚠ Could not read auth token: {}\n", .{err});
        std.debug.print("  Trying without authentication...\n\n", .{});
        break :blk null;
    };
    defer if (token) |t| allocator.free(t);

    if (token) |t| {
        std.debug.print("✓ Auth token loaded\n", .{});
        client.setAuthToken(t);
    }

    std.debug.print("→ Connecting to 127.0.0.1:9993...\n", .{});

    // Test GET /status
    std.debug.print("→ Calling GET /status...\n\n", .{});

    const status_response = client.get("/status") catch |err| {
        std.debug.print("✗ Failed to connect to zerotier-one service: {}\n\n", .{err});
        std.debug.print("Make sure zerotier-one is running:\n", .{});
        std.debug.print("  1. Build: make\n", .{});
        std.debug.print("  2. Run:   sudo ./zerotier-one\n\n", .{});
        return err;
    };
    defer allocator.free(status_response);

    std.debug.print("✓ Response received ({d} bytes)\n\n", .{status_response.len});

    // Pretty-print JSON response
    std.debug.print("Response body:\n", .{});
    std.debug.print("{s}\n\n", .{status_response});

    // Try to parse JSON to verify it's valid
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        status_response,
        .{},
    ) catch |err| {
        std.debug.print("⚠ Warning: Response is not valid JSON: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    // Extract some fields if they exist
    if (parsed.value == .object) {
        const obj = parsed.value.object;

        if (obj.get("address")) |addr| {
            if (addr == .string) {
                std.debug.print("  Node Address: {s}\n", .{addr.string});
            }
        }

        if (obj.get("online")) |online| {
            if (online == .bool) {
                std.debug.print("  Online: {}\n", .{online.bool});
            }
        }

        if (obj.get("version")) |version| {
            if (version == .string) {
                std.debug.print("  Version: {s}\n", .{version.string});
            }
        }
    }

    std.debug.print("\n✓ HTTP client test passed!\n\n", .{});
}
