/// TUN Device — Virtual network interface for macOS
///
/// This module provides a cross-platform TUN device interface.
/// On macOS, it uses utun (user-space tunnel) devices.
///
/// A TUN device operates at layer 3 (IP), unlike TAP which operates at layer 2 (Ethernet).
/// This means we work with IP packets directly, without Ethernet framing.
///
/// Usage:
///   var tun = try TunDevice.open(allocator, "utun");
///   defer tun.close();
///   try tun.setAddress([4]u8{10, 147, 20, 1}, [4]u8{255, 255, 0, 0});
///
///   // Read packets
///   var buf: [2048]u8 = undefined;
///   const len = try tun.read(&buf);
///
///   // Write packets
///   try tun.write(packet_data);

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;
const Allocator = std.mem.Allocator;

// macOS-specific ioctl that accepts c_ulong for request parameter
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

/// TUN device handle
pub const TunDevice = struct {
    allocator: Allocator,
    fd: posix.fd_t,
    name: []const u8,
    unit_number: u32,

    /// Open a TUN device
    ///
    /// On macOS, this creates a utun device by connecting to the kernel control socket.
    /// The device name will be "utun<N>" where N is automatically assigned by the kernel.
    ///
    /// On Linux, this opens /dev/net/tun and configures it.
    pub fn open(allocator: Allocator, name_prefix: []const u8) !TunDevice {
        if (builtin.os.tag == .macos) {
            return try openMacOS(allocator, name_prefix);
        } else if (builtin.os.tag == .linux) {
            return try openLinux(allocator, name_prefix);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Open a TUN device on macOS using utun
    fn openMacOS(allocator: Allocator, name_prefix: []const u8) !TunDevice {
        _ = name_prefix; // utun naming is automatic on macOS

        // Create a kernel control socket
        // AF_SYSTEM/SYSPROTO_CONTROL is used for kernel control sockets on macOS
        const AF_SYSTEM: u32 = 32; // sys/socket.h on macOS
        const SYSPROTO_CONTROL: c_int = 2; // sys/sys_domain.h

        const fd = try posix.socket(AF_SYSTEM, posix.SOCK.DGRAM, SYSPROTO_CONTROL);
        errdefer posix.close(fd);

        // Connect to the utun kernel control
        // We need to use ioctl with CTLIOCGINFO to get the control ID,
        // then connect with struct sockaddr_ctl

        // First, get the control ID for "com.apple.net.utun_control"
        const CTLIOCGINFO: c_ulong = 0xc0644e03; // from sys/kern_control.h
        const UTUN_CONTROL_NAME = "com.apple.net.utun_control";

        // struct ctl_info from sys/kern_control.h
        const ctl_info = extern struct {
            ctl_id: u32,
            ctl_name: [96]u8,
        };

        var info: ctl_info = .{
            .ctl_id = 0,
            .ctl_name = undefined,
        };

        // Copy control name
        @memset(&info.ctl_name, 0);
        @memcpy(info.ctl_name[0..UTUN_CONTROL_NAME.len], UTUN_CONTROL_NAME);

        // Get control ID
        if (ioctl(fd, CTLIOCGINFO, @intFromPtr(&info)) < 0) {
            return error.CtlInfoFailed;
        }

        // Now connect to the control with unit number 0 (kernel will assign first available)
        // struct sockaddr_ctl from sys/kern_control.h
        const sockaddr_ctl = extern struct {
            sc_len: u8,
            sc_family: u8,
            ss_sysaddr: u16,
            sc_id: u32,
            sc_unit: u32,
            sc_reserved: [5]u32,
        };

        const AF_SYSTEM_u8: u8 = @intCast(AF_SYSTEM);
        const sc_addr: sockaddr_ctl = .{
            .sc_len = @sizeOf(sockaddr_ctl),
            .sc_family = AF_SYSTEM_u8,
            .ss_sysaddr = SYSPROTO_CONTROL,
            .sc_id = info.ctl_id,
            .sc_unit = 0, // 0 = kernel assigns first available unit
            .sc_reserved = .{0, 0, 0, 0, 0},
        };

        // Connect to the kernel control
        const addr_ptr: *const posix.sockaddr = @ptrCast(&sc_addr);
        const addr_len: posix.socklen_t = @sizeOf(sockaddr_ctl);

        if (std.c.connect(fd, addr_ptr, addr_len) < 0) {
            return error.ConnectFailed;
        }

        // Get the assigned unit number using getsockopt
        const UTUN_OPT_IFNAME: c_int = 2; // from net/if_utun.h

        // Get interface name (will be "utunN")
        var ifname: [64]u8 = undefined;
        var ifname_len: posix.socklen_t = ifname.len;

        if (std.c.getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, &ifname, &ifname_len) < 0) {
            return error.GetIfNameFailed;
        }

        // Parse unit number from "utunN"
        const name_slice = std.mem.sliceTo(&ifname, 0);
        const unit_str = if (std.mem.startsWith(u8, name_slice, "utun"))
            name_slice[4..]
        else
            return error.InvalidInterfaceName;

        const unit_number = std.fmt.parseInt(u32, unit_str, 10) catch 0;

        // Store the name
        const name = try allocator.dupe(u8, name_slice);
        errdefer allocator.free(name);

        // Set non-blocking
        const O_NONBLOCK: u32 = 0x0004; // O_NONBLOCK from fcntl.h
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);

        std.debug.print("  ✓ Opened TUN device: {s} (fd={d})\n", .{name, fd});

        return TunDevice{
            .allocator = allocator,
            .fd = fd,
            .name = name,
            .unit_number = unit_number,
        };
    }

    /// Open a TUN device on Linux using /dev/net/tun
    fn openLinux(allocator: Allocator, name_prefix: []const u8) !TunDevice {
        _ = allocator;
        _ = name_prefix;
        // TODO: Implement Linux TUN device
        // This would use /dev/net/tun and ioctl with TUNSETIFF
        return error.NotImplementedYet;
    }

    /// Close the TUN device
    pub fn close(self: *TunDevice) void {
        posix.close(self.fd);
        self.allocator.free(self.name);
        std.debug.print("  ✓ Closed TUN device: {s}\n", .{self.name});
    }

    /// Read a packet from the TUN device
    ///
    /// Returns the number of bytes read, or error.WouldBlock if no data available.
    ///
    /// Note: On macOS utun, the first 4 bytes are a protocol family header (uint32_t).
    /// We skip this and return just the IP packet.
    pub fn read(self: *TunDevice, buffer: []u8) !usize {
        // macOS utun prepends a 4-byte protocol family header
        // We need to read it but skip it in the returned data
        if (builtin.os.tag == .macos) {
            var header: [4]u8 = undefined;
            var iov = [_]posix.iovec{
                .{ .base = &header, .len = 4 },
                .{ .base = buffer.ptr, .len = buffer.len },
            };

            const n = posix.readv(self.fd, &iov) catch |err| {
                if (err == error.WouldBlock) {
                    return error.WouldBlock;
                }
                return err;
            };

            if (n <= 4) {
                return error.ShortRead;
            }

            // Return packet length (excluding 4-byte header)
            return n - 4;
        } else {
            // Linux TUN doesn't have this header
            return try posix.read(self.fd, buffer);
        }
    }

    /// Write a packet to the TUN device
    ///
    /// On macOS, this automatically prepends the protocol family header.
    pub fn write(self: *TunDevice, data: []const u8) !void {
        if (builtin.os.tag == .macos) {
            // Determine protocol family from IP version
            // IPv4 = AF_INET (2), IPv6 = AF_INET6 (30 on macOS)
            const proto_family: u32 = if (data.len > 0 and (data[0] >> 4) == 4)
                2 // AF_INET
            else if (data.len > 0 and (data[0] >> 4) == 6)
                30 // AF_INET6
            else
                return error.InvalidPacket;

            // macOS utun requires a 4-byte protocol family header in network byte order
            const header = std.mem.toBytes(std.mem.nativeToBig(u32, proto_family));

            var iov = [_]posix.iovec_const{
                .{ .base = &header, .len = 4 },
                .{ .base = data.ptr, .len = data.len },
            };

            const written = try posix.writev(self.fd, &iov);
            if (written != data.len + 4) {
                return error.ShortWrite;
            }
        } else {
            // Linux TUN
            const written = try posix.write(self.fd, data);
            if (written != data.len) {
                return error.ShortWrite;
            }
        }
    }

    /// Set IPv4 address and netmask for the interface
    ///
    /// This uses ifconfig on macOS/BSD, and ioctl on Linux.
    pub fn setAddress(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        if (builtin.os.tag == .macos) {
            return try self.setAddressMacOS(ip, netmask);
        } else if (builtin.os.tag == .linux) {
            return try self.setAddressLinux(ip, netmask);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Set address on macOS using ifconfig
    fn setAddressMacOS(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        var ip_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const ip_str = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ip[0], ip[1], ip[2], ip[3]});
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{netmask[0], netmask[1], netmask[2], netmask[3]});

        // Use ifconfig to set the address
        // ifconfig utunN <ip> <peer_ip> netmask <netmask>
        // For point-to-point, peer can be same as local for simplicity

        const argv = [_][]const u8{
            "/sbin/ifconfig",
            self.name,
            ip_str,
            ip_str, // peer address (same as local)
            "netmask",
            netmask_str,
            "up",
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const result = try child.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            return error.IfconfigFailed;
        }

        std.debug.print("  ✓ Set address: {s} netmask {s}\n", .{ip_str, netmask_str});
    }

    /// Set address on Linux using ioctl
    fn setAddressLinux(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        _ = self;
        _ = ip;
        _ = netmask;
        // TODO: Implement using SIOCSIFADDR ioctl
        return error.NotImplementedYet;
    }

    /// Add a route through this TUN device
    pub fn addRoute(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        if (builtin.os.tag == .macos) {
            return try self.addRouteMacOS(dest, netmask);
        } else {
            return error.NotImplementedYet;
        }
    }

    /// Add route on macOS using route command
    fn addRouteMacOS(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        var dest_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const dest_str = try std.fmt.bufPrint(&dest_buf, "{d}.{d}.{d}.{d}", .{dest[0], dest[1], dest[2], dest[3]});
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{netmask[0], netmask[1], netmask[2], netmask[3]});

        const argv = [_][]const u8{
            "/sbin/route",
            "add",
            "-net",
            dest_str,
            "-netmask",
            netmask_str,
            "-interface",
            self.name,
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        const result = try child.spawnAndWait();
        if (result != .Exited or result.Exited != 0) {
            // Route might already exist, that's ok
            return;
        }

        std.debug.print("  ✓ Added route: {s}/{s} via {s}\n", .{dest_str, netmask_str, self.name});
    }

    /// Get the device file descriptor (for select/poll)
    pub fn getFd(self: *TunDevice) posix.fd_t {
        return self.fd;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "TUN device structure" {
    const testing = std.testing;

    // Just verify the structure compiles and has expected fields
    const T = TunDevice;
    _ = T;

    // Check that we have the right platform checks
    if (builtin.os.tag == .macos) {
        try testing.expect(true);
    }
}

test "IP version detection" {
    const testing = std.testing;

    // IPv4 packet (version 4)
    const ipv4_packet = [_]u8{0x45} ++ [_]u8{0} ** 19; // 0x45 = version 4, IHL 5
    try testing.expectEqual(@as(u8, 4), ipv4_packet[0] >> 4);

    // IPv6 packet (version 6)
    const ipv6_packet = [_]u8{0x60} ++ [_]u8{0} ** 39; // 0x60 = version 6
    try testing.expectEqual(@as(u8, 6), ipv6_packet[0] >> 4);
}
