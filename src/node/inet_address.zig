/// An IP address (v4 or v6) with port, wrapping the platform sockaddr_storage.
///
/// Converted from `node/InetAddress.hpp` and `node/InetAddress.cpp`. This
/// uses a wrapper struct containing `std.posix.sockaddr.storage` rather than
/// inheriting from it (Zig has no inheritance). The interface preserves
/// compatibility with the C++ API and wire protocol.
///
/// Platform differences (macOS `sa_family_t` = u8 with `len` prefix;
/// Linux `sa_family_t` = u16, no `len`) are handled by using the
/// `std.posix.sockaddr` type family.
///
/// No heap allocation is performed. This is a value type.
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const testing = std.testing;
const native_endian = @import("builtin").cpu.arch.endian();

const Buffer = @import("buffer.zig").Buffer;
const MAC = @import("mac.zig").MAC;
const utils = @import("utils.zig");

// ── Platform types ─────────────────────────────────────────────────

const AF = std.c.AF;
const sockaddr = std.c.sockaddr;
const sa_family_t = std.c.sa_family_t;

// ── IpScope ────────────────────────────────────────────────────────

/// IP address scope classification.
///
/// Values are in ascending order of path preference. This ordering is
/// significant — Path selection logic depends on it.
pub const IpScope = enum(u8) {
    none = 0,
    multicast = 1,
    loopback = 2,
    pseudoprivate = 3,
    global = 4,
    link_local = 5,
    shared = 6,
    private = 7,
};

/// Maximum integer value of IpScope.
pub const MAX_SCOPE: u8 = 7;

// ── InetAddress ────────────────────────────────────────────────────

pub const InetAddress = struct {
    /// Underlying platform sockaddr_storage.
    storage: sockaddr.storage,

    // ── Static constants ───────────────────────────────────────────

    /// Loopback IPv4 address (127.0.0.1), no port.
    pub const LO4 = initV4(.{ 0x7f, 0x00, 0x00, 0x01 }, 0);

    /// Loopback IPv6 address (::1), no port.
    pub const LO6 = initV6(.{
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 1,
    }, 0);

    // ── Construction ───────────────────────────────────────────────

    /// Create a zero/null address.
    pub fn zero() InetAddress {
        return .{ .storage = mem.zeroes(sockaddr.storage) };
    }

    /// Create an IPv4 address from 4 raw bytes and a port.
    pub fn initV4(addr_bytes: [4]u8, port_val: u16) InetAddress {
        var self = InetAddress.zero();
        const sin = self.asIn();
        setFamily(sin, AF.INET);
        const addr_ptr: *[4]u8 = @ptrCast(&sin.addr);
        addr_ptr.* = addr_bytes;
        sin.port = mem.nativeToBig(u16, port_val);
        return self;
    }

    /// Create an IPv6 address from 16 raw bytes and a port.
    pub fn initV6(addr_bytes: [16]u8, port_val: u16) InetAddress {
        var self = InetAddress.zero();
        const sin6 = self.asIn6();
        setFamily6(sin6, AF.INET6);
        sin6.addr = addr_bytes;
        sin6.port = mem.nativeToBig(u16, port_val);
        return self;
    }

    /// Set from raw IP bytes (4 for IPv4, 16 for IPv6) and port.
    pub fn set(self: *InetAddress, ip_bytes: []const u8, port_val: u16) void {
        self.* = InetAddress.zero();
        if (ip_bytes.len == 4) {
            const sin = self.asIn();
            setFamily(sin, AF.INET);
            const addr_ptr: *[4]u8 = @ptrCast(&sin.addr);
            @memcpy(addr_ptr, ip_bytes[0..4]);
            sin.port = mem.nativeToBig(u16, port_val);
        } else if (ip_bytes.len == 16) {
            const sin6 = self.asIn6();
            setFamily6(sin6, AF.INET6);
            @memcpy(&sin6.addr, ip_bytes[0..16]);
            sin6.port = mem.nativeToBig(u16, port_val);
        }
    }

    /// Create from a sockaddr.in (IPv4).
    pub fn fromSockaddrIn(sin: sockaddr.in) InetAddress {
        var self = InetAddress.zero();
        const dst = self.asIn();
        dst.* = sin;
        return self;
    }

    /// Create from a sockaddr.in6 (IPv6).
    pub fn fromSockaddrIn6(sin6: sockaddr.in6) InetAddress {
        var self = InetAddress.zero();
        const dst = self.asIn6();
        dst.* = sin6;
        return self;
    }

    // ── Accessors ──────────────────────────────────────────────────

    /// Return the address family.
    pub fn family(self: *const InetAddress) sa_family_t {
        return self.storage.family;
    }

    /// Return true if this is an IPv4 address.
    pub fn isV4(self: *const InetAddress) bool {
        return self.storage.family == AF.INET;
    }

    /// Return true if this is an IPv6 address.
    pub fn isV6(self: *const InetAddress) bool {
        return self.storage.family == AF.INET6;
    }

    /// Return true if the address family is non-zero (i.e. address is set).
    pub fn isSet(self: *const InetAddress) bool {
        return self.storage.family != 0;
    }

    /// Return the port (in host byte order).
    pub fn port(self: *const InetAddress) u16 {
        return switch (self.storage.family) {
            AF.INET => mem.bigToNative(u16, self.asConstIn().port),
            AF.INET6 => mem.bigToNative(u16, self.asConstIn6().port),
            else => 0,
        };
    }

    /// Alias for port() — used when the port field stores netmask bits.
    pub fn netmaskBits(self: *const InetAddress) u16 {
        return self.port();
    }

    /// Return true if netmask bits is valid for the address type.
    pub fn netmaskBitsValid(self: *const InetAddress) bool {
        const n = self.port();
        return switch (self.storage.family) {
            AF.INET => n <= 32,
            AF.INET6 => n <= 128,
            else => false,
        };
    }

    /// Alias for port() — used when the port field stores a gateway metric.
    pub fn metric(self: *const InetAddress) u16 {
        return self.port();
    }

    /// Set the port number.
    pub fn setPort(self: *InetAddress, port_val: u16) void {
        switch (self.storage.family) {
            AF.INET => {
                self.asIn().port = mem.nativeToBig(u16, port_val);
            },
            AF.INET6 => {
                self.asIn6().port = mem.nativeToBig(u16, port_val);
            },
            else => {},
        }
    }

    /// Return a pointer to the raw IP address bytes, or null.
    pub fn rawIpData(self: *const InetAddress) ?[]const u8 {
        return switch (self.storage.family) {
            AF.INET => blk: {
                const addr_ptr: *const [4]u8 = @ptrCast(&self.asConstIn().addr);
                break :blk addr_ptr[0..4];
            },
            AF.INET6 => &self.asConstIn6().addr,
            else => null,
        };
    }

    /// Set to zero/null.
    pub fn clear(self: *InetAddress) void {
        self.* = InetAddress.zero();
    }

    // ── IP scope classification ────────────────────────────────────

    pub fn ipScope(self: *const InetAddress) IpScope {
        switch (self.storage.family) {
            AF.INET => {
                const ip = mem.bigToNative(u32, self.asConstIn().addr);
                switch (ip >> 24) {
                    0x00 => return .none,
                    0x06 => return .pseudoprivate,
                    0x0a => return .private,
                    0x0b => return .pseudoprivate,
                    0x15 => return .pseudoprivate,
                    0x16 => return .pseudoprivate,
                    0x19 => return .pseudoprivate,
                    0x1a => return .pseudoprivate,
                    0x1c => return .pseudoprivate,
                    0x1d => return .pseudoprivate,
                    0x1e => return .pseudoprivate,
                    0x33 => return .pseudoprivate,
                    0x37 => return .pseudoprivate,
                    0x38 => return .pseudoprivate,
                    0x64 => {
                        if ((ip & 0xffc00000) == 0x64400000) return .private;
                    },
                    0x7f => return .loopback,
                    0xa9 => {
                        if ((ip & 0xffff0000) == 0xa9fe0000) return .link_local;
                    },
                    0xac => {
                        if ((ip & 0xfff00000) == 0xac100000) return .private;
                    },
                    0xc0 => {
                        if ((ip & 0xffff0000) == 0xc0a80000) return .private;
                        if ((ip & 0xffffff00) == 0xc0000200) return .private;
                    },
                    0xc6 => {
                        if ((ip & 0xfffe0000) == 0xc6120000) return .private;
                        if ((ip & 0xffffff00) == 0xc6336400) return .private;
                    },
                    0xcb => {
                        if ((ip & 0xffffff00) == 0xcb007100) return .private;
                    },
                    0xff => return .none,
                    else => {},
                }
                switch (ip >> 28) {
                    0xe => return .multicast,
                    0xf => return .pseudoprivate,
                    else => {},
                }
                return .global;
            },
            AF.INET6 => {
                const ip6 = &self.asConstIn6().addr;
                if ((ip6[0] & 0xf0) == 0xf0) {
                    if (ip6[0] == 0xff) return .multicast;
                    if (ip6[0] == 0xfe and (ip6[1] & 0xc0) == 0x80) {
                        // Check for fe80::1 (loopback)
                        var k: usize = 2;
                        while (k < 15 and ip6[k] == 0) : (k += 1) {}
                        if (k == 15 and ip6[15] == 0x01) return .loopback;
                        return .link_local;
                    }
                    if ((ip6[0] & 0xfe) == 0xfc) return .private;
                }
                // ::ffff:127.x.x.x (IPv4-mapped loopback)
                {
                    var k: usize = 0;
                    while (k < 9 and ip6[k] == 0) : (k += 1) {}
                    if (k == 9 and ip6[10] == 0xff and ip6[11] == 0xff and ip6[12] == 0x7f) {
                        return .loopback;
                    }
                }
                // ::1 or ::0
                {
                    var k: usize = 0;
                    while (k < 15 and ip6[k] == 0) : (k += 1) {}
                    if (k == 15) {
                        if (ip6[15] == 0x01) return .loopback;
                        if (ip6[15] == 0x00) return .none;
                    }
                }
                return .global;
            },
            else => return .none,
        }
    }

    // ── String conversion ──────────────────────────────────────────

    /// Write the IP portion (no port) to a FixedStream.
    pub fn writeIpTo(self: *const InetAddress, stream: *FixedStream) void {
        writeIpToImpl(self, stream);
    }

    /// Format as "ip/port" string into a caller-provided buffer.
    /// Returns the written slice.
    pub fn toString(self: *const InetAddress, buf: *[64]u8) []const u8 {
        var stream = FixedStream.init(buf);
        self.writeIpTo(&stream);
        if (stream.pos > 0) {
            stream.writeByte('/');
            writeDecimal(&stream, self.port());
        }
        return buf[0..stream.pos];
    }

    /// Format just the IP portion into a caller-provided buffer.
    /// Returns the written slice.
    pub fn toIpString(self: *const InetAddress, buf: *[64]u8) []const u8 {
        var stream = FixedStream.init(buf);
        self.writeIpTo(&stream);
        return buf[0..stream.pos];
    }

    /// Parse an "ip/port" or bare "ip" string.
    /// Returns true if the address appeared valid.
    pub fn fromString(self: *InetAddress, s: []const u8) bool {
        self.* = InetAddress.zero();
        if (s.len == 0) return true;

        // Split on '/' for optional port
        var ip_part = s;
        var port_val: u16 = 0;
        if (mem.indexOfScalar(u8, s, '/')) |slash_pos| {
            ip_part = s[0..slash_pos];
            if (slash_pos + 1 < s.len) {
                port_val = std.fmt.parseUnsigned(u16, s[slash_pos + 1 ..], 10) catch 0;
            }
        }

        // Detect v6 (contains ':') vs v4 (contains '.')
        if (mem.indexOfScalar(u8, ip_part, ':') != null) {
            // IPv6
            if (std.net.Address.parseIp6(ip_part, port_val)) |addr| {
                const sin6 = self.asIn6();
                sin6.* = addr.in6.sa;
                return true;
            } else |_| {
                return false;
            }
        } else if (mem.indexOfScalar(u8, ip_part, '.') != null) {
            // IPv4
            if (std.net.Address.parseIp4(ip_part, port_val)) |addr| {
                const sin = self.asIn();
                sin.* = addr.in.sa;
                return true;
            } else |_| {
                return false;
            }
        }
        return false;
    }

    // ── Default route check ────────────────────────────────────────

    /// Return true if this represents a default route (0.0.0.0/0 or ::/0).
    pub fn isDefaultRoute(self: *const InetAddress) bool {
        return switch (self.storage.family) {
            AF.INET => blk: {
                const sin = self.asConstIn();
                break :blk (sin.addr == 0 and sin.port == 0);
            },
            AF.INET6 => blk: {
                const sin6 = self.asConstIn6();
                for (sin6.addr) |b| {
                    if (b != 0) break :blk false;
                }
                break :blk sin6.port == 0;
            },
            else => false,
        };
    }

    // ── Subnet operations ──────────────────────────────────────────

    /// Construct a netmask from this address's port (netmask bits).
    /// Returns an InetAddress with the netmask in the IP portion and
    /// the original port preserved.
    pub fn netmask(self: *const InetAddress) InetAddress {
        var r = self.*;
        const bits = self.netmaskBits();
        switch (r.storage.family) {
            AF.INET => {
                const mask: u32 = if (bits >= 32) 0xffffffff else if (bits == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - bits));
                r.asIn().addr = mem.nativeToBig(u32, mask);
            },
            AF.INET6 => {
                var nm: [16]u8 = undefined;
                if (bits == 0) {
                    nm = mem.zeroes([16]u8);
                } else {
                    const nm_u64: *[2]u64 = @ptrCast(@alignCast(&nm));
                    nm_u64[0] = mem.nativeToBig(u64, if (bits >= 64) @as(u64, 0xffffffffffffffff) else @as(u64, 0xffffffffffffffff) << @as(u6, @intCast(64 - bits)));
                    nm_u64[1] = mem.nativeToBig(u64, if (bits <= 64) @as(u64, 0) else @as(u64, 0xffffffffffffffff) << @as(u6, @intCast(128 - bits)));
                }
                r.asIn6().addr = nm;
            },
            else => {},
        }
        return r;
    }

    /// Construct a broadcast address from this network/netmask (IPv4 only).
    /// Returns a zero address for non-IPv4.
    pub fn broadcast(self: *const InetAddress) InetAddress {
        if (self.storage.family != AF.INET) return InetAddress.zero();
        var r = self.*;
        const bits = self.netmaskBits();
        const host_mask: u32 = if (bits >= 32) 0 else @as(u32, 0xffffffff) >> @as(u5, @intCast(bits));
        r.asIn().addr |= mem.nativeToBig(u32, host_mask);
        return r;
    }

    /// Return the network address — IP ANDed with the netmask.
    pub fn network(self: *const InetAddress) InetAddress {
        var r = self.*;
        const bits = self.netmaskBits();
        switch (r.storage.family) {
            AF.INET => {
                const mask: u32 = if (bits >= 32) 0xffffffff else if (bits == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - bits));
                r.asIn().addr &= mem.nativeToBig(u32, mask);
            },
            AF.INET6 => {
                var nm: [2]u64 = undefined;
                const addr_ptr: *[2]u64 = @ptrCast(@alignCast(&r.asIn6().addr));
                nm[0] = addr_ptr[0] & mem.nativeToBig(u64, if (bits >= 64) @as(u64, 0xffffffffffffffff) else if (bits == 0) @as(u64, 0) else @as(u64, 0xffffffffffffffff) << @as(u6, @intCast(64 - bits)));
                nm[1] = addr_ptr[1] & mem.nativeToBig(u64, if (bits <= 64) @as(u64, 0) else @as(u64, 0xffffffffffffffff) << @as(u6, @intCast(128 - bits)));
                addr_ptr[0] = nm[0];
                addr_ptr[1] = nm[1];
            },
            else => {},
        }
        return r;
    }

    /// Test whether this IPv6 prefix matches the prefix of a given address.
    pub fn isEqualPrefix(self: *const InetAddress, addr: *const InetAddress) bool {
        if (self.storage.family != addr.storage.family) return false;
        switch (self.storage.family) {
            AF.INET6 => {
                const mask_a = self.netmask();
                const mask_b = addr.netmask();
                const m = mask_a.asConstIn6().addr;
                const n = mask_b.asConstIn6().addr;
                const a = addr.asConstIn6().addr;
                const b = self.asConstIn6().addr;
                for (0..16) |i| {
                    if ((a[i] & m[i]) != (b[i] & n[i])) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Test whether this IP/netmask contains the given address.
    pub fn containsAddress(self: *const InetAddress, addr: *const InetAddress) bool {
        if (self.storage.family != addr.storage.family) return false;
        switch (self.storage.family) {
            AF.INET => {
                const bits = self.netmaskBits();
                if (bits == 0) return true;
                const shift_amt: u5 = @intCast(32 - bits);
                return (mem.bigToNative(u32, addr.asConstIn().addr) >> shift_amt) ==
                    (mem.bigToNative(u32, self.asConstIn().addr) >> shift_amt);
            },
            AF.INET6 => {
                const mask_addr = self.netmask();
                const m = mask_addr.asConstIn6().addr;
                const a = addr.asConstIn6().addr;
                const b = self.asConstIn6().addr;
                for (0..16) |i| {
                    if ((a[i] & m[i]) != b[i]) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Check if this is a network/route (everything after netmask bits is zero).
    pub fn isNetwork(self: *const InetAddress) bool {
        switch (self.storage.family) {
            AF.INET => {
                const bits = self.netmaskBits();
                if (bits == 0 or bits >= 32) return false;
                const ip = mem.bigToNative(u32, self.asConstIn().addr);
                const shift_amt: u5 = @intCast(bits);
                return (ip & ((@as(u32, 0xffffffff) >> shift_amt))) == 0;
            },
            AF.INET6 => {
                const bits = self.netmaskBits();
                if (bits == 0 or bits >= 128) return false;
                const ip6 = &self.asConstIn6().addr;
                var p: usize = bits / 8;
                const bit_offset: u3 = @intCast(bits % 8);
                if ((ip6[p] & (@as(u8, 0xff) >> bit_offset)) != 0) return false;
                p += 1;
                while (p < 16) : (p += 1) {
                    if (ip6[p] != 0) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    /// Count matching prefix bits between this IP and another.
    pub fn matchingPrefixBits(self: *const InetAddress, other: *const InetAddress) u8 {
        if (self.storage.family != other.storage.family) return 0;
        var count: u8 = 0;
        switch (self.storage.family) {
            AF.INET => {
                var ip0 = mem.bigToNative(u32, self.asConstIn().addr);
                var ip1 = mem.bigToNative(u32, other.asConstIn().addr);
                while ((ip0 >> 31) == (ip1 >> 31)) {
                    ip0 <<= 1;
                    ip1 <<= 1;
                    count += 1;
                    if (count == 32) break;
                }
            },
            AF.INET6 => {
                const ip0 = &self.asConstIn6().addr;
                const ip1 = &other.asConstIn6().addr;
                for (0..16) |i| {
                    if (ip0[i] == ip1[i]) {
                        count += 8;
                    } else {
                        var bit: u8 = 0x80;
                        while (bit != 0) {
                            if ((ip0[i] & bit) != (ip1[i] & bit)) break;
                            count += 1;
                            bit >>= 1;
                        }
                        break;
                    }
                }
            },
            else => {},
        }
        return count;
    }

    /// Return a 14-bit hash of the first 24 (v4) or 48 (v6) bits for rate limiting.
    pub fn rateGateHash(self: *const InetAddress) u16 {
        var h: u32 = 0;
        switch (self.storage.family) {
            AF.INET => {
                h = (mem.bigToNative(u32, self.asConstIn().addr) & 0xffffff00) >> 8;
                h ^= (h >> 14);
            },
            AF.INET6 => {
                const ip6 = &self.asConstIn6().addr;
                h = @as(u32, ip6[0]);
                h = (h << 1) + @as(u32, ip6[1]);
                h = (h << 1) + @as(u32, ip6[2]);
                h = (h << 1) + @as(u32, ip6[3]);
                h = (h << 1) + @as(u32, ip6[4]);
                h = (h << 1) + @as(u32, ip6[5]);
            },
            else => {},
        }
        return @truncate(h & 0x3fff);
    }

    // ── IP-only comparison ─────────────────────────────────────────

    /// Compare IPs only (ignoring port). Returns false for different families.
    pub fn ipsEqual(self: *const InetAddress, other: *const InetAddress) bool {
        if (self.storage.family != other.storage.family) return false;
        return switch (self.storage.family) {
            AF.INET => self.asConstIn().addr == other.asConstIn().addr,
            AF.INET6 => mem.eql(u8, &self.asConstIn6().addr, &other.asConstIn6().addr),
            else => mem.eql(u8, mem.asBytes(&self.storage), mem.asBytes(&other.storage)),
        };
    }

    /// Compare IPs only, but for v6 only compare first 64 bits.
    pub fn ipsEqual2(self: *const InetAddress, other: *const InetAddress) bool {
        if (self.storage.family != other.storage.family) return false;
        return switch (self.storage.family) {
            AF.INET => self.asConstIn().addr == other.asConstIn().addr,
            AF.INET6 => blk: {
                const a = self.asConstIn6().addr;
                const b = other.asConstIn6().addr;
                break :blk mem.eql(u8, a[0..8], b[0..8]);
            },
            else => mem.eql(u8, mem.asBytes(&self.storage), mem.asBytes(&other.storage)),
        };
    }

    /// Return address with only the IP portion (port zeroed).
    pub fn ipOnly(self: *const InetAddress) InetAddress {
        return switch (self.storage.family) {
            AF.INET => blk: {
                const addr_ptr: *const [4]u8 = @ptrCast(&self.asConstIn().addr);
                break :blk initV4(addr_ptr.*, 0);
            },
            AF.INET6 => initV6(self.asConstIn6().addr, 0),
            else => InetAddress.zero(),
        };
    }

    // ── Wire protocol serialization ────────────────────────────────

    /// Serialize to a Buffer in ZeroTier wire format.
    /// Type byte 0x04 = IPv4 (4 addr bytes + 2 port), 0x06 = IPv6 (16 + 2), 0x00 = none.
    pub fn serialize(self: *const InetAddress, comptime C: u32, buf: *Buffer(C)) Buffer(C).Error!void {
        switch (self.storage.family) {
            AF.INET => {
                try buf.appendByte(0x04, 1);
                const addr_bytes: *const [4]u8 = @ptrCast(&self.asConstIn().addr);
                try buf.appendBytes(addr_bytes);
                try buf.appendInt(u16, self.port());
            },
            AF.INET6 => {
                try buf.appendByte(0x06, 1);
                try buf.appendBytes(&self.asConstIn6().addr);
                try buf.appendInt(u16, self.port());
            },
            else => {
                try buf.appendByte(0x00, 1);
            },
        }
    }

    /// Deserialize from a Buffer at the given position.
    /// Returns the number of bytes consumed.
    pub fn deserialize(self: *InetAddress, comptime C: u32, buf: *const Buffer(C), start_at: u32) Buffer(C).Error!u32 {
        self.* = InetAddress.zero();
        var p = start_at;
        const type_byte = try buf.getByte(p);
        p += 1;
        switch (type_byte) {
            0x00 => return 1,
            0x01, 0x02 => return 7, // Ethernet/Bluetooth (forward compat)
            0x03 => {
                // Variable-length other address types
                const extra_len = try buf.at(u16, p);
                return extra_len + 3;
            },
            0x04 => {
                const sin = self.asIn();
                setFamily(sin, AF.INET);
                const addr_ptr: *[4]u8 = @ptrCast(&sin.addr);
                const src = try buf.field(p, 4);
                @memcpy(addr_ptr, src);
                p += 4;
                sin.port = mem.nativeToBig(u16, try buf.at(u16, p));
                p += 2;
            },
            0x06 => {
                const sin6 = self.asIn6();
                setFamily6(sin6, AF.INET6);
                const src = try buf.field(p, 16);
                @memcpy(&sin6.addr, src);
                p += 16;
                sin6.port = mem.nativeToBig(u16, try buf.at(u16, p));
                p += 2;
            },
            else => return error.OutOfBounds,
        }
        return p - start_at;
    }

    // ── Hash and comparison ────────────────────────────────────────

    pub fn hashCode(self: *const InetAddress) u64 {
        if (self.storage.family == AF.INET) {
            const sin = self.asConstIn();
            return @as(u64, sin.addr) +% @as(u64, sin.port);
        } else if (self.storage.family == AF.INET6) {
            const sin6 = self.asConstIn6();
            var tmp: u64 = @as(u64, sin6.port);
            const a = &sin6.addr;
            for (0..16) |i| {
                const bytes: *[8]u8 = @ptrCast(@constCast(&tmp));
                bytes[i % 8] ^= a[i];
            }
            return tmp;
        } else {
            var tmp: u64 = 0;
            const raw = mem.asBytes(&self.storage);
            for (0..@sizeOf(sockaddr.storage)) |i| {
                const bytes: *[8]u8 = @ptrCast(@constCast(&tmp));
                bytes[i % 8] ^= raw[i];
            }
            return tmp;
        }
    }

    pub fn eql(self: *const InetAddress, other: *const InetAddress) bool {
        if (self.storage.family != other.storage.family) return false;
        return switch (self.storage.family) {
            AF.INET => blk: {
                const a = self.asConstIn();
                const b = other.asConstIn();
                break :blk (a.port == b.port and a.addr == b.addr);
            },
            AF.INET6 => blk: {
                const a = self.asConstIn6();
                const b = other.asConstIn6();
                break :blk (a.port == b.port and
                    a.flowinfo == b.flowinfo and
                    mem.eql(u8, &a.addr, &b.addr) and
                    a.scope_id == b.scope_id);
            },
            else => mem.eql(u8, mem.asBytes(&self.storage), mem.asBytes(&other.storage)),
        };
    }

    pub fn lessThan(self: *const InetAddress, other: *const InetAddress) bool {
        if (self.storage.family < other.storage.family) return true;
        if (self.storage.family != other.storage.family) return false;
        switch (self.storage.family) {
            AF.INET => {
                const a = self.asConstIn();
                const b = other.asConstIn();
                if (a.port < b.port) return true;
                if (a.port > b.port) return false;
                return a.addr < b.addr;
            },
            AF.INET6 => {
                const a = self.asConstIn6();
                const b = other.asConstIn6();
                if (a.port < b.port) return true;
                if (a.port > b.port) return false;
                if (a.flowinfo < b.flowinfo) return true;
                if (a.flowinfo > b.flowinfo) return false;
                const cmp = mem.order(u8, &a.addr, &b.addr);
                if (cmp == .lt) return true;
                if (cmp == .gt) return false;
                return a.scope_id < b.scope_id;
            },
            else => {
                return mem.order(u8, mem.asBytes(&self.storage), mem.asBytes(&other.storage)) == .lt;
            },
        }
    }

    pub fn order(self: *const InetAddress, other: *const InetAddress) std.math.Order {
        if (self.eql(other)) return .eq;
        if (self.lessThan(other)) return .lt;
        return .gt;
    }

    // ── Static constructors for special addresses ──────────────────

    /// Construct an IPv6 link-local address from a MAC.
    pub fn makeIpv6LinkLocal(mac: MAC) InetAddress {
        var addr: [16]u8 = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 0 };
        addr[8] = mac.getByte(0) & 0xfd;
        addr[9] = mac.getByte(1);
        addr[10] = mac.getByte(2);
        addr[13] = mac.getByte(3);
        addr[14] = mac.getByte(4);
        addr[15] = mac.getByte(5);
        return initV6(addr, 64);
    }

    /// Compute a private IPv6 unicast address per RFC4193 from network ID
    /// and ZeroTier address.
    pub fn makeIpv6rfc4193(nwid: u64, zt_addr: u64) InetAddress {
        var addr: [16]u8 = undefined;
        addr[0] = 0xfd;
        addr[1] = @truncate(nwid >> 56);
        addr[2] = @truncate(nwid >> 48);
        addr[3] = @truncate(nwid >> 40);
        addr[4] = @truncate(nwid >> 32);
        addr[5] = @truncate(nwid >> 24);
        addr[6] = @truncate(nwid >> 16);
        addr[7] = @truncate(nwid >> 8);
        addr[8] = @truncate(nwid);
        addr[9] = 0x99;
        addr[10] = 0x93;
        addr[11] = @truncate(zt_addr >> 32);
        addr[12] = @truncate(zt_addr >> 24);
        addr[13] = @truncate(zt_addr >> 16);
        addr[14] = @truncate(zt_addr >> 8);
        addr[15] = @truncate(zt_addr);
        return initV6(addr, 88);
    }

    /// Compute a private IPv6 "6plane" unicast address from network ID
    /// and ZeroTier address.
    pub fn makeIpv66plane(nwid_raw: u64, zt_addr: u64) InetAddress {
        const nwid = nwid_raw ^ (nwid_raw >> 32);
        var addr: [16]u8 = mem.zeroes([16]u8);
        addr[0] = 0xfc;
        addr[1] = @truncate(nwid >> 24);
        addr[2] = @truncate(nwid >> 16);
        addr[3] = @truncate(nwid >> 8);
        addr[4] = @truncate(nwid);
        addr[5] = @truncate(zt_addr >> 32);
        addr[6] = @truncate(zt_addr >> 24);
        addr[7] = @truncate(zt_addr >> 16);
        addr[8] = @truncate(zt_addr >> 8);
        addr[9] = @truncate(zt_addr);
        addr[15] = 0x01;
        return initV6(addr, 40);
    }

    // ── Internal helpers ───────────────────────────────────────────

    fn asIn(self: *InetAddress) *sockaddr.in {
        return @ptrCast(@alignCast(&self.storage));
    }

    fn asIn6(self: *InetAddress) *sockaddr.in6 {
        return @ptrCast(@alignCast(&self.storage));
    }

    fn asConstIn(self: *const InetAddress) *const sockaddr.in {
        return @ptrCast(@alignCast(&self.storage));
    }

    fn asConstIn6(self: *const InetAddress) *const sockaddr.in6 {
        return @ptrCast(@alignCast(&self.storage));
    }

    /// Set the family field on a sockaddr.in in a platform-portable way.
    fn setFamily(sin: *sockaddr.in, fam: sa_family_t) void {
        sin.family = fam;
        // On macOS/BSD, sockaddr has a `len` field. Set it if present.
        if (@hasField(sockaddr.in, "len")) {
            sin.len = @sizeOf(sockaddr.in);
        }
    }

    /// Set the family field on a sockaddr.in6 in a platform-portable way.
    fn setFamily6(sin6: *sockaddr.in6, fam: sa_family_t) void {
        sin6.family = fam;
        if (@hasField(sockaddr.in6, "len")) {
            sin6.len = @sizeOf(sockaddr.in6);
        }
    }
};

// ── FixedStream: a tiny fixed-buffer string writer ─────────────────

/// Minimal fixed-buffer writer used for IP string formatting.
/// Avoids the complexity of `std.io.Writer` for simple appends.
const FixedStream = struct {
    buf: *[64]u8,
    pos: usize,

    fn init(buf: *[64]u8) FixedStream {
        return .{ .buf = buf, .pos = 0 };
    }

    fn writeByte(self: *FixedStream, c: u8) void {
        if (self.pos < 64) {
            self.buf[self.pos] = c;
            self.pos += 1;
        }
    }

    fn writeSlice(self: *FixedStream, s: []const u8) void {
        for (s) |c| self.writeByte(c);
    }
};

/// Write a decimal number to the stream.
fn writeDecimal(stream: *FixedStream, n: u16) void {
    if (n == 0) {
        stream.writeByte('0');
        return;
    }
    var val = n;
    var digits: [5]u8 = undefined;
    var len: usize = 0;
    while (val > 0) {
        digits[len] = '0' + @as(u8, @truncate(val % 10));
        val /= 10;
        len += 1;
    }
    // Write in reverse
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        stream.writeByte(digits[i]);
    }
}

/// Write IPv4 address bytes as "d.d.d.d" to the stream.
fn writeIpv4(stream: *FixedStream, bytes: *const [4]u8) void {
    for (bytes, 0..) |byte, i| {
        if (i > 0) stream.writeByte('.');
        writeU8Decimal(stream, byte);
    }
}

fn writeU8Decimal(stream: *FixedStream, n: u8) void {
    if (n >= 100) {
        stream.writeByte('0' + n / 100);
        stream.writeByte('0' + (n / 10) % 10);
        stream.writeByte('0' + n % 10);
    } else if (n >= 10) {
        stream.writeByte('0' + n / 10);
        stream.writeByte('0' + n % 10);
    } else {
        stream.writeByte('0' + n);
    }
}

/// Write IPv6 address bytes in canonical compressed form.
fn writeIpv6(stream: *FixedStream, addr: *const [16]u8) void {
    // Convert to 8 groups of u16
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = (@as(u16, addr[i * 2]) << 8) | @as(u16, addr[i * 2 + 1]);
    }

    // Find the longest run of consecutive zero groups
    var best_start: usize = 8;
    var best_len: usize = 0;
    var cur_start: usize = 0;
    var cur_len: usize = 0;
    for (0..8) |i| {
        if (groups[i] == 0) {
            if (cur_len == 0) cur_start = i;
            cur_len += 1;
        } else {
            if (cur_len > best_len and cur_len >= 2) {
                best_start = cur_start;
                best_len = cur_len;
            }
            cur_len = 0;
        }
    }
    if (cur_len > best_len and cur_len >= 2) {
        best_start = cur_start;
        best_len = cur_len;
    }

    // Write the groups
    var i: usize = 0;
    while (i < 8) {
        if (i == best_start) {
            stream.writeSlice(if (i == 0) "::" else ":");
            i += best_len;
            if (i >= 8) break;
        }
        if (i > 0 and i != best_start) {
            stream.writeByte(':');
        }
        writeHex16(stream, groups[i]);
        i += 1;
    }
}

/// Write a u16 as lowercase hex without leading zeros.
fn writeHex16(stream: *FixedStream, val: u16) void {
    const H = utils.HEXCHARS;
    if (val >= 0x1000) {
        stream.writeByte(H[@as(u4, @truncate(val >> 12))]);
        stream.writeByte(H[@as(u4, @truncate(val >> 8))]);
        stream.writeByte(H[@as(u4, @truncate(val >> 4))]);
        stream.writeByte(H[@as(u4, @truncate(val))]);
    } else if (val >= 0x100) {
        stream.writeByte(H[@as(u4, @truncate(val >> 8))]);
        stream.writeByte(H[@as(u4, @truncate(val >> 4))]);
        stream.writeByte(H[@as(u4, @truncate(val))]);
    } else if (val >= 0x10) {
        stream.writeByte(H[@as(u4, @truncate(val >> 4))]);
        stream.writeByte(H[@as(u4, @truncate(val))]);
    } else {
        stream.writeByte(H[@as(u4, @truncate(val))]);
    }
}

/// Implementation of IP formatting dispatched by family.
fn writeIpToImpl(addr: *const InetAddress, stream: *FixedStream) void {
    switch (addr.storage.family) {
        AF.INET => {
            const bytes: *const [4]u8 = @ptrCast(&addr.asConstIn().addr);
            writeIpv4(stream, bytes);
        },
        AF.INET6 => {
            writeIpv6(stream, &addr.asConstIn6().addr);
        },
        else => {},
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "InetAddress: zero" {
    const z = InetAddress.zero();
    try testing.expect(!z.isSet());
    try testing.expect(!z.isV4());
    try testing.expect(!z.isV6());
    try testing.expectEqual(@as(u16, 0), z.port());
}

test "InetAddress: initV4" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 8080);
    try testing.expect(addr.isV4());
    try testing.expect(!addr.isV6());
    try testing.expect(addr.isSet());
    try testing.expectEqual(@as(u16, 8080), addr.port());

    const raw = addr.rawIpData().?;
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 100 }, raw);
}

test "InetAddress: initV6" {
    const addr = InetAddress.initV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 443);
    try testing.expect(addr.isV6());
    try testing.expect(!addr.isV4());
    try testing.expectEqual(@as(u16, 443), addr.port());

    const raw = addr.rawIpData().?;
    try testing.expectEqual(@as(u8, 0xfe), raw[0]);
    try testing.expectEqual(@as(u8, 0x80), raw[1]);
    try testing.expectEqual(@as(u8, 1), raw[15]);
}

test "InetAddress: setPort" {
    var addr = InetAddress.initV4(.{ 10, 0, 0, 1 }, 0);
    try testing.expectEqual(@as(u16, 0), addr.port());
    addr.setPort(9993);
    try testing.expectEqual(@as(u16, 9993), addr.port());
}

test "InetAddress: ipScope v4" {
    // Loopback
    try testing.expectEqual(IpScope.loopback, InetAddress.LO4.ipScope());
    try testing.expectEqual(IpScope.loopback, InetAddress.initV4(.{ 127, 0, 0, 1 }, 0).ipScope());

    // Private
    try testing.expectEqual(IpScope.private, InetAddress.initV4(.{ 10, 0, 0, 1 }, 0).ipScope());
    try testing.expectEqual(IpScope.private, InetAddress.initV4(.{ 192, 168, 1, 1 }, 0).ipScope());
    try testing.expectEqual(IpScope.private, InetAddress.initV4(.{ 172, 16, 0, 1 }, 0).ipScope());
    try testing.expectEqual(IpScope.private, InetAddress.initV4(.{ 100, 64, 0, 1 }, 0).ipScope());

    // Link-local
    try testing.expectEqual(IpScope.link_local, InetAddress.initV4(.{ 169, 254, 1, 1 }, 0).ipScope());

    // Multicast
    try testing.expectEqual(IpScope.multicast, InetAddress.initV4(.{ 224, 0, 0, 1 }, 0).ipScope());

    // Global
    try testing.expectEqual(IpScope.global, InetAddress.initV4(.{ 8, 8, 8, 8 }, 0).ipScope());

    // Pseudoprivate (US DoD etc)
    try testing.expectEqual(IpScope.pseudoprivate, InetAddress.initV4(.{ 6, 0, 0, 1 }, 0).ipScope());

    // None
    try testing.expectEqual(IpScope.none, InetAddress.initV4(.{ 0, 0, 0, 0 }, 0).ipScope());
}

test "InetAddress: ipScope v6" {
    // Loopback (::1)
    try testing.expectEqual(IpScope.loopback, InetAddress.LO6.ipScope());

    // Link-local (fe80::)
    try testing.expectEqual(IpScope.link_local, InetAddress.initV6(
        .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 },
        0,
    ).ipScope());

    // Multicast (ff00::)
    try testing.expectEqual(IpScope.multicast, InetAddress.initV6(
        .{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        0,
    ).ipScope());

    // Private (fc00::/7)
    try testing.expectEqual(IpScope.private, InetAddress.initV6(
        .{ 0xfd, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        0,
    ).ipScope());

    // Global (2001:db8::1)
    try testing.expectEqual(IpScope.global, InetAddress.initV6(
        .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        0,
    ).ipScope());

    // None (::)
    try testing.expectEqual(IpScope.none, InetAddress.initV6(
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        0,
    ).ipScope());
}

test "InetAddress: toString / fromString round-trip v4" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 8080);
    var buf: [64]u8 = undefined;
    const s = addr.toString(&buf);
    try testing.expectEqualStrings("192.168.1.100/8080", s);

    var parsed = InetAddress.zero();
    try testing.expect(parsed.fromString(s));
    try testing.expect(parsed.isV4());
    try testing.expectEqual(@as(u16, 8080), parsed.port());
    try testing.expect(addr.ipsEqual(&parsed));
}

test "InetAddress: toString / fromString round-trip v6" {
    const addr = InetAddress.initV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 443);
    var buf: [64]u8 = undefined;
    const s = addr.toString(&buf);
    try testing.expectEqualStrings("2001:db8::1/443", s);
}

test "InetAddress: fromString bare IP" {
    var addr = InetAddress.zero();
    try testing.expect(addr.fromString("10.0.0.1"));
    try testing.expect(addr.isV4());
    try testing.expectEqual(@as(u16, 0), addr.port());
}

test "InetAddress: serialize/deserialize v4 round-trip" {
    const addr = InetAddress.initV4(.{ 10, 20, 30, 40 }, 9993);
    var buf = Buffer(128){};
    try addr.serialize(128, &buf);
    // Should be 1 + 4 + 2 = 7 bytes
    try testing.expectEqual(@as(u32, 7), buf.size());

    var restored = InetAddress.zero();
    const consumed = try restored.deserialize(128, &buf, 0);
    try testing.expectEqual(@as(u32, 7), consumed);
    try testing.expect(addr.eql(&restored));
}

test "InetAddress: serialize/deserialize v6 round-trip" {
    const addr = InetAddress.initV6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 443);
    var buf = Buffer(128){};
    try addr.serialize(128, &buf);
    // Should be 1 + 16 + 2 = 19 bytes
    try testing.expectEqual(@as(u32, 19), buf.size());

    var restored = InetAddress.zero();
    const consumed = try restored.deserialize(128, &buf, 0);
    try testing.expectEqual(@as(u32, 19), consumed);
    try testing.expect(addr.eql(&restored));
}

test "InetAddress: serialize/deserialize null" {
    const addr = InetAddress.zero();
    var buf = Buffer(128){};
    try addr.serialize(128, &buf);
    try testing.expectEqual(@as(u32, 1), buf.size());

    var restored = InetAddress.initV4(.{ 1, 2, 3, 4 }, 80);
    const consumed = try restored.deserialize(128, &buf, 0);
    try testing.expectEqual(@as(u32, 1), consumed);
    try testing.expect(!restored.isSet());
}

test "InetAddress: netmask v4" {
    var addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 24);
    const nm = addr.netmask();
    const raw = nm.rawIpData().?;
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 0 }, raw);
}

test "InetAddress: broadcast v4" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 24);
    const bc = addr.broadcast();
    const raw = bc.rawIpData().?;
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 255 }, raw);
}

test "InetAddress: network v4" {
    const addr = InetAddress.initV4(.{ 192, 168, 1, 100 }, 24);
    const net = addr.network();
    const raw = net.rawIpData().?;
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 0 }, raw);
}

test "InetAddress: containsAddress v4" {
    const net = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    const addr1 = InetAddress.initV4(.{ 10, 1, 2, 3 }, 0);
    const addr2 = InetAddress.initV4(.{ 11, 0, 0, 1 }, 0);
    try testing.expect(net.containsAddress(&addr1));
    try testing.expect(!net.containsAddress(&addr2));
}

test "InetAddress: isNetwork" {
    const net = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    try testing.expect(net.isNetwork());

    const host = InetAddress.initV4(.{ 10, 0, 0, 1 }, 8);
    try testing.expect(!host.isNetwork());
}

test "InetAddress: isDefaultRoute" {
    const v4_default = InetAddress.initV4(.{ 0, 0, 0, 0 }, 0);
    try testing.expect(v4_default.isDefaultRoute());

    const v4_non = InetAddress.initV4(.{ 10, 0, 0, 1 }, 0);
    try testing.expect(!v4_non.isDefaultRoute());
}

test "InetAddress: matchingPrefixBits" {
    const a = InetAddress.initV4(.{ 192, 168, 1, 100 }, 0);
    const b = InetAddress.initV4(.{ 192, 168, 1, 200 }, 0);
    // First 25 bits match: 192.168.1 = 24 bits, then 0b011 vs 0b110 -> bit 24 differs
    // Actually 192.168.1.100 = C0.A8.01.64, 192.168.1.200 = C0.A8.01.C8
    // 0x64 = 01100100, 0xC8 = 11001000 -> first bit differs
    try testing.expectEqual(@as(u8, 24), a.matchingPrefixBits(&b));
}

test "InetAddress: comparison" {
    const a = InetAddress.initV4(.{ 10, 0, 0, 1 }, 80);
    const b = InetAddress.initV4(.{ 10, 0, 0, 2 }, 80);
    const c = InetAddress.initV4(.{ 10, 0, 0, 1 }, 80);

    try testing.expect(a.eql(&c));
    try testing.expect(!a.eql(&b));
    try testing.expect(a.lessThan(&b));
    try testing.expect(!b.lessThan(&a));
}

test "InetAddress: makeIpv6LinkLocal" {
    const mac = MAC.fromOctets(0x02, 0x11, 0x22, 0x33, 0x44, 0x55);
    const addr = InetAddress.makeIpv6LinkLocal(mac);
    try testing.expect(addr.isV6());
    try testing.expectEqual(@as(u16, 64), addr.port());
    const raw = addr.rawIpData().?;
    try testing.expectEqual(@as(u8, 0xfe), raw[0]);
    try testing.expectEqual(@as(u8, 0x80), raw[1]);
    // Byte 8 = mac[0] & 0xfd = 0x02 & 0xfd = 0x00
    try testing.expectEqual(@as(u8, 0x00), raw[8]);
    try testing.expectEqual(@as(u8, 0x11), raw[9]);
    try testing.expectEqual(@as(u8, 0x22), raw[10]);
    try testing.expectEqual(@as(u8, 0xff), raw[11]);
    try testing.expectEqual(@as(u8, 0xfe), raw[12]);
    try testing.expectEqual(@as(u8, 0x33), raw[13]);
    try testing.expectEqual(@as(u8, 0x44), raw[14]);
    try testing.expectEqual(@as(u8, 0x55), raw[15]);
}

test "InetAddress: makeIpv6rfc4193" {
    const nwid: u64 = 0x0102030405060708;
    const zt_addr: u64 = 0xABCDEF0123;
    const addr = InetAddress.makeIpv6rfc4193(nwid, zt_addr);
    try testing.expect(addr.isV6());
    try testing.expectEqual(@as(u16, 88), addr.port());
    const raw = addr.rawIpData().?;
    try testing.expectEqual(@as(u8, 0xfd), raw[0]);
    try testing.expectEqual(@as(u8, 0x01), raw[1]);
    try testing.expectEqual(@as(u8, 0x08), raw[8]);
    try testing.expectEqual(@as(u8, 0x99), raw[9]);
    try testing.expectEqual(@as(u8, 0x93), raw[10]);
}

test "InetAddress: makeIpv66plane" {
    const nwid: u64 = 0x0102030405060708;
    const zt_addr: u64 = 0xABCDEF0123;
    const addr = InetAddress.makeIpv66plane(nwid, zt_addr);
    try testing.expect(addr.isV6());
    try testing.expectEqual(@as(u16, 40), addr.port());
    const raw = addr.rawIpData().?;
    try testing.expectEqual(@as(u8, 0xfc), raw[0]);
    try testing.expectEqual(@as(u8, 0x01), raw[15]);
}

test "InetAddress: ipsEqual and ipsEqual2" {
    const a = InetAddress.initV4(.{ 10, 0, 0, 1 }, 80);
    const b = InetAddress.initV4(.{ 10, 0, 0, 1 }, 443);
    const c = InetAddress.initV4(.{ 10, 0, 0, 2 }, 80);

    // Same IP, different ports
    try testing.expect(a.ipsEqual(&b));
    try testing.expect(!a.ipsEqual(&c));

    // v6 ipsEqual2 only compares first 64 bits
    const v6a = InetAddress.initV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0);
    const v6b = InetAddress.initV6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }, 0);
    try testing.expect(v6a.ipsEqual2(&v6b));
    try testing.expect(!v6a.ipsEqual(&v6b)); // full compare differs
}

test "InetAddress: LO4 and LO6 constants" {
    try testing.expect(InetAddress.LO4.isV4());
    try testing.expectEqual(IpScope.loopback, InetAddress.LO4.ipScope());
    try testing.expectEqual(@as(u16, 0), InetAddress.LO4.port());

    try testing.expect(InetAddress.LO6.isV6());
    try testing.expectEqual(IpScope.loopback, InetAddress.LO6.ipScope());
    try testing.expectEqual(@as(u16, 0), InetAddress.LO6.port());
}

test "InetAddress: set from raw bytes" {
    var addr = InetAddress.zero();
    addr.set(&[_]u8{ 10, 0, 0, 1 }, 80);
    try testing.expect(addr.isV4());
    try testing.expectEqual(@as(u16, 80), addr.port());

    addr.set(&[_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 443);
    try testing.expect(addr.isV6());
    try testing.expectEqual(@as(u16, 443), addr.port());

    // Invalid length clears
    addr.set(&[_]u8{ 1, 2, 3 }, 80);
    try testing.expect(!addr.isSet());
}
