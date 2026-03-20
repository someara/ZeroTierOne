/// DNS configuration serialization methods.
///
/// Converted from `node/DNS.hpp`. Provides serialize and deserialize
/// functions for `ZT_VirtualNetworkDNS` structures to/from the wire
/// format used in network configurations.
///
/// No heap allocation is performed.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Buffer = @import("buffer.zig").Buffer;
const InetAddress = @import("inet_address.zig").InetAddress;
const constants = @import("constants.zig");
const c_api = constants.c_api;

/// Maximum number of DNS server addresses per configuration.
pub const MAX_DNS_SERVERS: u32 = c_api.ZT_MAX_DNS_SERVERS;

/// DNS configuration for a virtual network.
/// Wraps `ZT_VirtualNetworkDNS` from the C API.
pub const VirtualNetworkDNS = c_api.ZT_VirtualNetworkDNS;

/// Size of a sockaddr_storage, used for raw byte copies between
/// the C API's type and our InetAddress wrapper (layout-compatible).
const SS_SIZE = @sizeOf(std.c.sockaddr.storage);

// ── Serialization ──────────────────────────────────────────────────

/// Serialize a DNS configuration into a Buffer.
///
/// Wire format: 128 bytes of domain name (null-padded), followed by
/// each of the `ZT_MAX_DNS_SERVERS` server addresses serialized via
/// `InetAddress.serialize`.
pub fn serializeDNS(comptime C: u32, buf: *Buffer(C), dns: *const VirtualNetworkDNS) Buffer(C).Error!void {
    // Domain: 128 bytes, null-padded
    try buf.appendBytes(&dns.domain);

    // Server addresses — copy raw bytes from the C struct's sockaddr_storage
    // into an InetAddress (which wraps std.c.sockaddr.storage, same layout)
    // then serialize.
    for (0..MAX_DNS_SERVERS) |j| {
        var tmp = InetAddress.zero();
        const src: *const [SS_SIZE]u8 = @ptrCast(&dns.server_addr[j]);
        const dst: *[SS_SIZE]u8 = @ptrCast(&tmp.storage);
        @memcpy(dst, src);
        try tmp.serialize(C, buf);
    }
}

/// Deserialize a DNS configuration from a Buffer starting at position `p`.
///
/// Returns the updated position after deserialization.
pub fn deserializeDNS(comptime C: u32, buf: *const Buffer(C), start_p: u32, dns: *VirtualNetworkDNS) Buffer(C).Error!u32 {
    // Zero the output struct
    const dns_bytes: *[@sizeOf(VirtualNetworkDNS)]u8 = @ptrCast(dns);
    @memset(dns_bytes, 0);

    var p = start_p;

    // Domain: 128 bytes
    const domain_src = try buf.field(p, 128);
    @memcpy(&dns.domain, domain_src);
    dns.domain[127] = 0; // Ensure null termination
    p += 128;

    // Server addresses — deserialize into InetAddress, then copy raw bytes
    // back into the C struct's sockaddr_storage.
    for (0..MAX_DNS_SERVERS) |j| {
        var tmp = InetAddress.zero();
        const consumed = try tmp.deserialize(C, buf, p);
        const src: *const [SS_SIZE]u8 = @ptrCast(&tmp.storage);
        const dst: *[SS_SIZE]u8 = @ptrCast(&dns.server_addr[j]);
        @memcpy(dst, src);
        p += consumed;
    }

    return p;
}

// ── Test helpers ───────────────────────────────────────────────────

/// Copy an InetAddress into a C API sockaddr_storage (byte-level).
fn testSetServerAddr(dns: *VirtualNetworkDNS, idx: usize, addr: *const InetAddress) void {
    const src: *const [SS_SIZE]u8 = @ptrCast(&addr.storage);
    const dst: *[SS_SIZE]u8 = @ptrCast(&dns.server_addr[idx]);
    @memcpy(dst, src);
}

/// Read a C API sockaddr_storage back into an InetAddress (byte-level).
fn testGetServerAddr(dns: *const VirtualNetworkDNS, idx: usize) InetAddress {
    var result = InetAddress.zero();
    const src: *const [SS_SIZE]u8 = @ptrCast(&dns.server_addr[idx]);
    const dst: *[SS_SIZE]u8 = @ptrCast(&result.storage);
    @memcpy(dst, src);
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────

test "DNS: serialize/deserialize round-trip empty" {
    var dns: VirtualNetworkDNS = undefined;
    const dns_bytes: *[@sizeOf(VirtualNetworkDNS)]u8 = @ptrCast(&dns);
    @memset(dns_bytes, 0);

    // Set a domain name
    const domain = "example.com";
    @memcpy(dns.domain[0..domain.len], domain);

    var buf = Buffer(4096){};
    try serializeDNS(4096, &buf, &dns);

    // Should have at least 128 bytes for domain + MAX_DNS_SERVERS * 1 byte each
    try testing.expect(buf.size() >= 128 + MAX_DNS_SERVERS);

    var restored: VirtualNetworkDNS = undefined;
    _ = try deserializeDNS(4096, &buf, 0, &restored);

    // Domain should match
    const restored_domain = mem.sliceTo(&restored.domain, 0);
    try testing.expectEqualStrings(domain, restored_domain);
}

test "DNS: serialize/deserialize with IPv4 servers" {
    var dns: VirtualNetworkDNS = undefined;
    const dns_bytes: *[@sizeOf(VirtualNetworkDNS)]u8 = @ptrCast(&dns);
    @memset(dns_bytes, 0);

    const domain = "zt.example";
    @memcpy(dns.domain[0..domain.len], domain);

    // Set first server to 8.8.8.8:53
    const addr1 = InetAddress.initV4(.{ 8, 8, 8, 8 }, 53);
    testSetServerAddr(&dns, 0, &addr1);

    // Set second server to 1.1.1.1:53
    const addr2 = InetAddress.initV4(.{ 1, 1, 1, 1 }, 53);
    testSetServerAddr(&dns, 1, &addr2);

    var buf = Buffer(4096){};
    try serializeDNS(4096, &buf, &dns);

    var restored: VirtualNetworkDNS = undefined;
    _ = try deserializeDNS(4096, &buf, 0, &restored);

    // Check domain
    const restored_domain = mem.sliceTo(&restored.domain, 0);
    try testing.expectEqualStrings(domain, restored_domain);

    // Check first server
    const r1 = testGetServerAddr(&restored, 0);
    try testing.expect(r1.isV4());
    try testing.expectEqual(@as(u16, 53), r1.port());
    try testing.expect(addr1.ipsEqual(&r1));

    // Check second server
    const r2 = testGetServerAddr(&restored, 1);
    try testing.expect(r2.isV4());
    try testing.expectEqual(@as(u16, 53), r2.port());
    try testing.expect(addr2.ipsEqual(&r2));

    // Third and fourth should be unset
    const r3 = testGetServerAddr(&restored, 2);
    try testing.expect(!r3.isSet());
}

test "DNS: null domain preserved" {
    var dns: VirtualNetworkDNS = undefined;
    const dns_bytes: *[@sizeOf(VirtualNetworkDNS)]u8 = @ptrCast(&dns);
    @memset(dns_bytes, 0);

    var buf = Buffer(4096){};
    try serializeDNS(4096, &buf, &dns);

    var restored: VirtualNetworkDNS = undefined;
    _ = try deserializeDNS(4096, &buf, 0, &restored);

    // Domain should be empty
    try testing.expectEqual(@as(u8, 0), restored.domain[0]);
}

test "DNS: serialize/deserialize with IPv6 server" {
    var dns: VirtualNetworkDNS = undefined;
    const dns_bytes: *[@sizeOf(VirtualNetworkDNS)]u8 = @ptrCast(&dns);
    @memset(dns_bytes, 0);

    const domain = "ipv6.test";
    @memcpy(dns.domain[0..domain.len], domain);

    // Set first server to [2001:4860:4860::8888]:53
    const addr1 = InetAddress.initV6(
        .{ 0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88 },
        53,
    );
    testSetServerAddr(&dns, 0, &addr1);

    var buf = Buffer(4096){};
    try serializeDNS(4096, &buf, &dns);

    var restored: VirtualNetworkDNS = undefined;
    _ = try deserializeDNS(4096, &buf, 0, &restored);

    const r1 = testGetServerAddr(&restored, 0);
    try testing.expect(r1.isV6());
    try testing.expectEqual(@as(u16, 53), r1.port());
    try testing.expect(addr1.ipsEqual(&r1));
}
