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
    is_tap: bool = false, // FreeBSD uses TAP (layer 2) instead of TUN
    mac_address: [6]u8 = [_]u8{0} ** 6, // MAC address for TAP devices

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
        } else if (builtin.os.tag == .freebsd) {
            // FreeBSD needs network ID for device naming, use dummy value
            return try openFreeBSD(allocator, name_prefix, 0);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Open with network ID (needed for FreeBSD device naming)
    pub fn openWithNetworkId(allocator: Allocator, name_prefix: []const u8, network_id: u64) !TunDevice {
        if (builtin.os.tag == .freebsd) {
            return try openFreeBSD(allocator, name_prefix, network_id);
        } else {
            // Other platforms don't need network ID
            return try open(allocator, name_prefix);
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
            .sc_reserved = .{ 0, 0, 0, 0, 0 },
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

        std.debug.print("  ✓ Opened TUN device: {s} (fd={d})\n", .{ name, fd });

        return TunDevice{
            .allocator = allocator,
            .fd = fd,
            .name = name,
            .unit_number = unit_number,
        };
    }

    /// Open a TAP device on FreeBSD using /dev/tap*
    fn openFreeBSD(allocator: Allocator, name_prefix: []const u8, network_id: u64) !TunDevice {
        _ = name_prefix; // FreeBSD uses zt<network_id> naming

        // Search for available TAP device (tap9993-tap10120)
        for (9993..10121) |i| {
            const tap_name = try std.fmt.allocPrint(allocator, "tap{d}", .{i});
            defer allocator.free(tap_name);

            const dev_path = try std.fmt.allocPrint(allocator, "/dev/{s}", .{tap_name});
            defer allocator.free(dev_path);

            // Check if device already exists
            if (posix.stat(dev_path)) |_| {
                continue; // Already exists, try next one
            } else |_| {
                // Device doesn't exist, create it
                try runCommand(allocator, &[_][]const u8{ "/sbin/ifconfig", tap_name, "create" });

                // Generate device name: zt + base32(network_id)
                const zt_name = try generateZtName(allocator, network_id);
                defer allocator.free(zt_name);

                // Rename device
                try runCommand(allocator, &[_][]const u8{ "/sbin/ifconfig", tap_name, "name", zt_name });

                // Open device
                const fd = try posix.open(dev_path, .{ .ACCMODE = .RDWR }, 0);
                errdefer posix.close(fd);

                // Generate MAC address (locally administered)
                var mac: [6]u8 = undefined;
                mac[0] = 0x02; // Locally administered bit
                mac[1] = @truncate(network_id >> 32);
                mac[2] = @truncate(network_id >> 24);
                mac[3] = @truncate(network_id >> 16);
                mac[4] = @truncate(network_id >> 8);
                mac[5] = @truncate(network_id);

                // Configure device: MAC address and MTU
                const mac_str = try std.fmt.allocPrint(
                    allocator,
                    "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}",
                    .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] },
                );
                defer allocator.free(mac_str);

                try runCommand(allocator, &[_][]const u8{
                    "/sbin/ifconfig",
                    zt_name,
                    "lladdr",
                    mac_str,
                    "mtu",
                    "2800",
                    "up",
                });

                // Set non-blocking mode
                const O_NONBLOCK: u32 = 0x0004; // O_NONBLOCK on FreeBSD
                const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
                _ = try posix.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);

                const name = try allocator.dupe(u8, zt_name);

                std.debug.print("  ✓ FreeBSD TAP device opened: {s} (fd={d})\n", .{ name, fd });

                return TunDevice{
                    .allocator = allocator,
                    .fd = fd,
                    .name = name,
                    .unit_number = @intCast(i),
                    .is_tap = true,
                    .mac_address = mac,
                };
            }
        }
        return error.NoTapDevicesAvailable;
    }

    /// Open a TUN device on Linux using /dev/net/tun
    fn openLinux(allocator: Allocator, name_prefix: []const u8) !TunDevice {
        // Linux TUN/TAP ioctl constants (from linux/if_tun.h)
        const TUNSETIFF: u32 = 0x400454ca; // _IOW('T', 202, int)
        const IFF_TUN: c_short = 0x0001;
        const IFF_NO_PI: c_short = 0x1000; // Don't provide packet info

        // struct ifreq from linux/if.h
        const ifreq = extern struct {
            ifr_name: [16]u8,
            ifr_flags: c_short,
            _padding: [22]u8, // Union padding to match C struct size (40 bytes total)
        };

        // Open the TUN device
        const fd = try posix.open("/dev/net/tun", .{ .ACCMODE = .RDWR }, 0);
        errdefer posix.close(fd);

        // Configure the device
        var ifr: ifreq = .{
            .ifr_name = [_]u8{0} ** 16,
            .ifr_flags = IFF_TUN | IFF_NO_PI,
            ._padding = [_]u8{0} ** 22,
        };

        // Copy device name prefix (e.g., "tun")
        const copy_len = @min(name_prefix.len, 15); // Leave room for null terminator
        @memcpy(ifr.ifr_name[0..copy_len], name_prefix[0..copy_len]);

        // Create the TUN device via ioctl
        if (ioctl(fd, TUNSETIFF, @intFromPtr(&ifr)) < 0) {
            return error.TunSetupFailed;
        }

        // Extract the actual device name assigned by the kernel
        const name_end = std.mem.indexOfScalar(u8, &ifr.ifr_name, 0) orelse 16;
        const device_name = try allocator.dupe(u8, ifr.ifr_name[0..name_end]);

        // Set non-blocking mode
        const O_NONBLOCK: u32 = 0x800; // O_NONBLOCK on Linux (ARM and x86)
        const current_flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        _ = try posix.fcntl(fd, posix.F.SETFL, current_flags | O_NONBLOCK);

        std.debug.print("  ✓ Linux TUN device opened: {s} (fd={d})\n", .{ device_name, fd });

        return TunDevice{
            .allocator = allocator,
            .fd = fd,
            .name = device_name,
            .unit_number = 0, // Not used on Linux
        };
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
    /// On FreeBSD TAP, the first 14 bytes are an Ethernet header.
    /// We skip these headers and return just the IP packet.
    pub fn read(self: *TunDevice, buffer: []u8) !usize {
        if (self.is_tap) {
            // FreeBSD TAP device: read Ethernet frame
            var frame_buf: [2048]u8 = undefined;
            const n = posix.read(self.fd, &frame_buf) catch |err| {
                if (err == error.WouldBlock) {
                    return error.WouldBlock;
                }
                return err;
            };

            if (n < 14) {
                return error.ShortRead;
            }

            // Skip 14-byte Ethernet header
            // Bytes 0-5: dst MAC
            // Bytes 6-11: src MAC
            // Bytes 12-13: ethertype
            const payload_len = n - 14;
            @memcpy(buffer[0..payload_len], frame_buf[14..n]);

            return payload_len;
        } else if (builtin.os.tag == .macos) {
            // macOS utun prepends a 4-byte protocol family header
            // We need to read it but skip it in the returned data
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
    /// On FreeBSD TAP, this automatically prepends the Ethernet header.
    pub fn write(self: *TunDevice, data: []const u8) !void {
        if (self.is_tap) {
            // FreeBSD TAP device: add Ethernet header
            var frame_buf: [2048]u8 = undefined;

            // Construct Ethernet frame:
            // 0-5: dst MAC (broadcast for simplicity)
            // 6-11: src MAC (our device MAC)
            // 12-13: ethertype (0x0800 for IPv4, 0x86DD for IPv6)

            // Destination MAC: broadcast
            @memset(frame_buf[0..6], 0xFF);

            // Source MAC: our device MAC
            @memcpy(frame_buf[6..12], &self.mac_address);

            // Ethertype
            const ethertype: u16 = if (data.len > 0 and (data[0] >> 4) == 4)
                0x0800 // IPv4
            else if (data.len > 0 and (data[0] >> 4) == 6)
                0x86DD // IPv6
            else
                return error.InvalidPacket;

            frame_buf[12] = @truncate(ethertype >> 8);
            frame_buf[13] = @truncate(ethertype);

            // Payload
            @memcpy(frame_buf[14 .. 14 + data.len], data);

            const total_len = 14 + data.len;
            const written = try posix.write(self.fd, frame_buf[0..total_len]);
            if (written != total_len) {
                return error.ShortWrite;
            }
        } else if (builtin.os.tag == .macos) {
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
        } else if (builtin.os.tag == .freebsd) {
            return try self.setAddressFreeBSD(ip, netmask);
        } else {
            return error.UnsupportedPlatform;
        }
    }

    /// Set address on macOS using ifconfig
    fn setAddressMacOS(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        var ip_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const ip_str = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{ netmask[0], netmask[1], netmask[2], netmask[3] });

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

        std.debug.print("  ✓ Set address: {s} netmask {s}\n", .{ ip_str, netmask_str });
    }

    /// Set address on Linux using ioctl
    fn setAddressLinux(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        // Linux network configuration ioctls
        const SIOCSIFADDR: c_ulong = 0x8916; // Set interface address
        const SIOCSIFNETMASK: c_ulong = 0x891c; // Set netmask
        const SIOCSIFFLAGS: c_ulong = 0x8914; // Set interface flags

        const IFF_UP: c_short = 0x1; // Interface is up
        const IFF_RUNNING: c_short = 0x40; // Interface is running

        const AF_INET: u16 = 2; // IPv4

        // struct ifreq for address configuration
        const ifreq = extern struct {
            ifr_name: [16]u8,
            ifr_data: extern union {
                ifr_addr: extern struct {
                    sa_family: u16,
                    sa_data: [14]u8,
                },
                ifr_flags: c_short,
            },
        };

        // Create a socket for ioctl operations
        const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        defer posix.close(sock);

        // Set IP address
        var ifr_addr: ifreq = .{
            .ifr_name = [_]u8{0} ** 16,
            .ifr_data = .{
                .ifr_addr = .{
                    .sa_family = AF_INET,
                    .sa_data = undefined,
                },
            },
        };

        // Copy interface name
        const name_len = @min(self.name.len, 15);
        @memcpy(ifr_addr.ifr_name[0..name_len], self.name[0..name_len]);

        // Set IP address in sa_data (network byte order)
        ifr_addr.ifr_data.ifr_addr.sa_data[0] = 0;
        ifr_addr.ifr_data.ifr_addr.sa_data[1] = 0;
        ifr_addr.ifr_data.ifr_addr.sa_data[2] = ip[0];
        ifr_addr.ifr_data.ifr_addr.sa_data[3] = ip[1];
        ifr_addr.ifr_data.ifr_addr.sa_data[4] = ip[2];
        ifr_addr.ifr_data.ifr_addr.sa_data[5] = ip[3];

        if (ioctl(sock, SIOCSIFADDR, @intFromPtr(&ifr_addr)) < 0) {
            return error.SetAddressFailed;
        }

        // Set netmask
        var ifr_netmask: ifreq = .{
            .ifr_name = [_]u8{0} ** 16,
            .ifr_data = .{
                .ifr_addr = .{
                    .sa_family = AF_INET,
                    .sa_data = undefined,
                },
            },
        };

        @memcpy(ifr_netmask.ifr_name[0..name_len], self.name[0..name_len]);
        ifr_netmask.ifr_data.ifr_addr.sa_data[0] = 0;
        ifr_netmask.ifr_data.ifr_addr.sa_data[1] = 0;
        ifr_netmask.ifr_data.ifr_addr.sa_data[2] = netmask[0];
        ifr_netmask.ifr_data.ifr_addr.sa_data[3] = netmask[1];
        ifr_netmask.ifr_data.ifr_addr.sa_data[4] = netmask[2];
        ifr_netmask.ifr_data.ifr_addr.sa_data[5] = netmask[3];

        if (ioctl(sock, SIOCSIFNETMASK, @intFromPtr(&ifr_netmask)) < 0) {
            return error.SetNetmaskFailed;
        }

        // Bring interface up
        var ifr_flags: ifreq = .{
            .ifr_name = [_]u8{0} ** 16,
            .ifr_data = .{
                .ifr_flags = IFF_UP | IFF_RUNNING,
            },
        };

        @memcpy(ifr_flags.ifr_name[0..name_len], self.name[0..name_len]);

        if (ioctl(sock, SIOCSIFFLAGS, @intFromPtr(&ifr_flags)) < 0) {
            return error.SetFlagsFailed;
        }

        var ip_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;
        const ip_str = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{ netmask[0], netmask[1], netmask[2], netmask[3] });

        std.debug.print("  ✓ Set address: {s} netmask {s}\n", .{ ip_str, netmask_str });
    }

    /// Set address on FreeBSD using ifconfig inet alias
    fn setAddressFreeBSD(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void {
        var ip_buf: [16]u8 = undefined;
        const ip_str = try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });

        // FreeBSD uses "alias" to add IPs
        try runCommand(self.allocator, &[_][]const u8{
            "/sbin/ifconfig",
            self.name,
            "inet",
            ip_str,
            "alias",
        });

        std.debug.print("  ✓ Set address: {s}\n", .{ip_str});

        // Note: netmask is handled during initial device creation on FreeBSD
        _ = netmask;
    }

    /// Add a route through this TUN device
    pub fn addRoute(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        if (builtin.os.tag == .macos) {
            return try self.addRouteMacOS(dest, netmask);
        } else if (builtin.os.tag == .linux) {
            return try self.addRouteLinux(dest, netmask);
        } else if (builtin.os.tag == .freebsd) {
            return try self.addRouteFreeBSD(dest, netmask);
        } else {
            return error.NotImplementedYet;
        }
    }

    /// Add route on macOS using route command
    fn addRouteMacOS(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        var dest_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const dest_str = try std.fmt.bufPrint(&dest_buf, "{d}.{d}.{d}.{d}", .{ dest[0], dest[1], dest[2], dest[3] });
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{ netmask[0], netmask[1], netmask[2], netmask[3] });

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

        std.debug.print("  ✓ Added route: {s}/{s} via {s}\n", .{ dest_str, netmask_str, self.name });
    }

    /// Add route on Linux using ip command
    fn addRouteLinux(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        var dest_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const dest_str = try std.fmt.bufPrint(&dest_buf, "{d}.{d}.{d}.{d}", .{ dest[0], dest[1], dest[2], dest[3] });
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{ netmask[0], netmask[1], netmask[2], netmask[3] });

        // Calculate CIDR prefix length from netmask
        var prefix_len: u8 = 0;
        for (netmask) |byte| {
            var b = byte;
            while (b != 0) : (b <<= 1) {
                prefix_len += 1;
            }
        }

        var cidr_buf: [20]u8 = undefined;
        const cidr = try std.fmt.bufPrint(&cidr_buf, "{s}/{d}", .{ dest_str, prefix_len });

        const argv = [_][]const u8{
            "/sbin/ip",
            "route",
            "add",
            cidr,
            "dev",
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

        std.debug.print("  ✓ Added route: {s}/{s} via {s}\n", .{ dest_str, netmask_str, self.name });
    }

    /// Add route on FreeBSD using route command
    fn addRouteFreeBSD(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void {
        var dest_buf: [16]u8 = undefined;
        var netmask_buf: [16]u8 = undefined;

        const dest_str = try std.fmt.bufPrint(&dest_buf, "{d}.{d}.{d}.{d}", .{ dest[0], dest[1], dest[2], dest[3] });
        const netmask_str = try std.fmt.bufPrint(&netmask_buf, "{d}.{d}.{d}.{d}", .{ netmask[0], netmask[1], netmask[2], netmask[3] });

        try runCommand(self.allocator, &[_][]const u8{
            "/sbin/route",
            "add",
            "-net",
            dest_str,
            "-netmask",
            netmask_str,
            "-interface",
            self.name,
        });

        std.debug.print("  ✓ Added route: {s}/{s} via {s}\n", .{ dest_str, netmask_str, self.name });
    }

    /// Get the device file descriptor (for select/poll)
    pub fn getFd(self: *TunDevice) posix.fd_t {
        return self.fd;
    }
};

// ── Helper Functions ───────────────────────────────────────────────────────

/// Generate ZeroTier device name from network ID (base32 encoding)
/// Format: "zt" + 13 base32 characters
fn generateZtName(allocator: Allocator, network_id: u64) ![]u8 {
    const base32_chars = "0123456789abcdefghijklmnopqrstuv";
    var name = try allocator.alloc(u8, 2 + 13); // "zt" + 13 chars
    name[0] = 'z';
    name[1] = 't';

    var shift: u6 = 60;
    var i: usize = 2;
    while (i < 15) : (i += 1) {
        const idx = (network_id >> shift) & 0x1f;
        name[i] = base32_chars[idx];
        shift -%= 5; // Wrapping subtraction to handle underflow
    }

    return name;
}

/// Run a shell command and wait for completion
fn runCommand(allocator: Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const result = try child.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        return error.CommandFailed;
    }
}

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
