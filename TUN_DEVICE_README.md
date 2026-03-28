# TUN Device Implementation

## What We Built

✅ **Complete TUN device module for macOS** — `src/node/tun_device.zig`

This module provides a cross-platform TUN (layer 3 network tunnel) device interface:
- **macOS implementation** using `utun` (kernel control sockets)
- **Linux stub** (ready to implement)
- **Automatic interface creation** and configuration
- **Non-blocking I/O** for integration with event loops
- **IP packet handling** with protocol detection

## Features

### Implemented ✅
- Open `utun` devices on macOS via kernel control socket
- Automatic device naming (`utun100`, `utun101`, etc.)
- IP address configuration via `ifconfig`
- Non-blocking read/write for packets
- Protocol family header handling (macOS-specific)
- IPv4/IPv6 packet detection
- Route management

### Ready to Use
```zig
const TunDevice = @import("node/tun_device.zig").TunDevice;

// Open device
var tun = try TunDevice.open(allocator, "utun");
defer tun.close();

// Configure IP
try tun.setAddress([4]u8{10, 147, 20, 1}, [4]u8{255, 255, 0, 0});

// Read packets
var buf: [2048]u8 = undefined;
const len = try tun.read(&buf);

// Write packets
try tun.write(ip_packet);
```

## Testing

### Build the Test
```bash
cd /Users/someara/src/ZeroTierOne
zig build-exe src/test_tun.zig -I./src -I.
```

### Run the Test (Requires Root)
```bash
sudo ./test_tun
```

**What the test does:**
1. Creates a `utun` device (e.g., `utun100`)
2. Configures it with IP `10.147.20.1/16`
3. Brings the interface up
4. Waits 3 seconds for packets
5. Displays any received packets (try `ping 10.147.20.1` in another terminal)

### Expected Output

```
═══════════════════════════════════════════════════════
  TUN Device Test — macOS utun
═══════════════════════════════════════════════════════

Step 1: Opening TUN device...
  ✓ Opened TUN device: utun100 (fd=3)

Step 2: Configuring IP address...
  ✓ Set address: 10.147.20.1 netmask 255.255.0.0

Step 3: Verifying interface is up...

utun100: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500
	inet 10.147.20.1 --> 10.147.20.1 netmask 0xffff0000

Step 4: Testing packet I/O...
  (Waiting 3 seconds for packets...)
  Try: ping 10.147.20.1

  → IPv4 ICMP: 10.147.20.2 → 10.147.20.1 (84 bytes)
      (ICMP Echo Request — ping detected!)

═══════════════════════════════════════════════════════
  Test Summary
═══════════════════════════════════════════════════════
Device:            utun100
Unit number:       100
IP address:        10.147.20.1/16
Packets received:  1

✓ TUN device is working correctly!
✓ Successfully received and parsed packets
```

### Manual Testing

```bash
# In Terminal 1: Run the test
sudo ./test_tun

# In Terminal 2: Send a ping
ping 10.147.20.1

# You should see packets in Terminal 1!
```

## Implementation Details

### macOS utun Architecture

macOS uses `utun` (user-space tunnel) devices which are accessed via kernel control sockets:

1. **Create control socket**:
   `socket(AF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`

2. **Get control ID**:
   `ioctl(CTLIOCGINFO)` with `"com.apple.net.utun_control"`

3. **Connect to kernel**:
   `connect()` with `struct sockaddr_ctl`

4. **Get interface name**:
   `getsockopt(UTUN_OPT_IFNAME)` returns `"utunN"`

5. **Configure with ifconfig**:
   `/sbin/ifconfig utunN <ip> netmask <mask> up`

### Packet Format

macOS `utun` devices prepend a 4-byte protocol family header:

```
┌─────────────┬───────────────────┐
│ Proto (4B)  │  IP Packet ...    │
└─────────────┴───────────────────┘
   AF_INET=2      IPv4 data
   AF_INET6=30    IPv6 data
```

Our implementation:
- **Read**: Strips the 4-byte header, returns just IP packet
- **Write**: Adds the header automatically based on IP version

### Non-Blocking I/O

The device is configured for non-blocking operation:
```zig
fcntl(fd, F_SETFL, flags | O_NONBLOCK);
```

This allows integration with event loops (`poll`, `select`, etc.):
- `read()` returns `error.WouldBlock` when no data available
- `write()` returns `error.WouldBlock` when buffer full

## Integration with ZeroTier

### Current Status

| Component | Status |
|-----------|--------|
| TUN device open/close | ✅ Done |
| IP configuration | ✅ Done |
| Packet read/write | ✅ Done |
| Non-blocking I/O | ✅ Done |
| Route management | ✅ Done |
| **Service integration** | ⚠️ Next step |

### Next Steps

To integrate with ZeroTier service:

#### 1. Wire TUN to Node Callbacks

Update `src/zerotier_service.zig`:

```zig
pub const Service = struct {
    node: Node,
    phy: Phy,
    tun: TunDevice,  // Add TUN device

    pub fn init(...) !Service {
        // ... existing code ...

        // Open TUN device
        var tun = try TunDevice.open(allocator, "utun");
        errdefer tun.close();

        // Configure with ZeroTier managed IP
        try tun.setAddress(...);

        return Service{
            // ...
            .tun = tun,
        };
    }
};
```

#### 2. Handle Frame Injection

Wire `nodeFrameInject` callback to write to TUN:

```zig
fn nodeFrameInject(
    ctx: ?*anyopaque,
    _: ?*anyopaque,
    nwid: u64,
    _: u64,  // source_mac (not used for TUN)
    _: u64,  // dest_mac (not used for TUN)
    ether_type: u32,
    _: u32,  // vlan_id
    data: [*]const u8,
    len: u32,
) void {
    const service: *Service = @ptrCast(@alignCast(ctx.?));

    // For TUN (layer 3), we only care about IP packets
    // ether_type: 0x0800 = IPv4, 0x86DD = IPv6

    if (ether_type == 0x0800 or ether_type == 0x86DD) {
        service.tun.write(data[0..len]) catch |err| {
            std.debug.print("TUN write error: {}\n", .{err});
        };
    }
}
```

#### 3. Read from TUN in Event Loop

Add TUN reading to the main service loop:

```zig
pub fn run(self: *Service) !void {
    while (self.running) {
        // Poll PHY sockets
        try self.phy.poll(100);

        // Read from TUN (non-blocking)
        var buf: [2048]u8 = undefined;
        if (self.tun.read(&buf)) |len| {
            // We got an IP packet from the local system
            // Inject it into ZeroTier for routing

            // TODO: Determine target network ID and inject
            // This requires network membership lookup

            std.debug.print("TUN → ZT: {d} bytes\n", .{len});
        } else |err| {
            if (err != error.WouldBlock) {
                // Real error
                return err;
            }
        }

        // Run Node background tasks
        if (now - last_tick >= 500) {
            _ = self.node.processBackgroundTasks(null, now);
            last_tick = now;
        }
    }
}
```

#### 4. Handle Ethernet Framing

Since TUN is layer 3 (IP) but ZeroTier works with Ethernet frames (layer 2):

**Option A: Software Ethernet framing** (simpler)
```zig
// When injecting from TUN to ZeroTier:
// 1. Read IP packet from TUN
// 2. Add Ethernet header (14 bytes):
//    - Dst MAC (6 bytes) - from ZeroTier routing
//    - Src MAC (6 bytes) - our virtual MAC
//    - EtherType (2 bytes) - 0x0800 for IPv4, 0x86DD for IPv6
// 3. Inject into ZeroTier network

// When receiving from ZeroTier:
// 1. frameInject() called with Ethernet frame
// 2. Strip Ethernet header (14 bytes)
// 3. Write IP packet to TUN
```

**Option B: Use feth (fake ethernet) instead** (more complex, but native)
- Requires implementing `feth` device creation (like C++ code)
- See `osdep/MacEthernetTap.cpp` for reference
- More work but handles Ethernet natively

### Example: Full Integration

```zig
// Read from TUN, inject into ZeroTier
var buf: [2048]u8 = undefined;
if (self.tun.read(&buf)) |len| {
    // Determine which network this packet belongs to
    // For now, assume all packets go to first joined network
    const nwid = self.getFirstNetwork() orelse return;

    // Add Ethernet framing
    var eth_frame: [2062]u8 = undefined; // 14 byte header + 2048 payload

    // Destination MAC - from ZeroTier routing table
    const dst_mac = self.node.resolveMac(nwid, dest_ip) orelse ZT_MAC_BROADCAST;

    // Source MAC - our virtual MAC for this network
    const src_mac = self.node.getNetworkMac(nwid);

    // Build Ethernet frame
    @memcpy(eth_frame[0..6], &dst_mac);
    @memcpy(eth_frame[6..12], &src_mac);

    // EtherType: 0x0800 (IPv4) or 0x86DD (IPv6)
    const ether_type: u16 = if (buf[0] >> 4 == 4) 0x0800 else 0x86DD;
    std.mem.writeInt(u16, eth_frame[12..14], ether_type, .big);

    // Copy IP packet
    @memcpy(eth_frame[14..14+len], buf[0..len]);

    // Inject into ZeroTier
    self.node.inject(nwid, eth_frame[0..14+len]);
} else |err| {
    if (err != error.WouldBlock) return err;
}
```

## Platform Support

### macOS ✅
- **Status**: Fully implemented
- **Device**: `utun` (kernel control socket)
- **Tested**: Yes (see test program)

### Linux ⚠️
- **Status**: Skeleton implemented, needs completion
- **Device**: `/dev/net/tun`
- **Implementation needed**:
  - Open `/dev/net/tun`
  - `ioctl(TUNSETIFF)` to configure
  - No protocol header (unlike macOS)

### Windows ❌
- **Status**: Not implemented
- **Device**: TAP-Windows driver
- **Complexity**: High (requires driver installation)

### FreeBSD/OpenBSD ❌
- **Status**: Not implemented
- **Device**: `/dev/tunN` devices
- **Complexity**: Medium (similar to Linux)

## Performance Considerations

### Buffer Sizes
- MTU: 1500 bytes (typical)
- Recommended buffer: 2048 bytes (MTU + headers)
- Large packets: 9000 bytes (jumbo frames)

### Non-Blocking Strategy
```zig
// Good: Check for WouldBlock and continue
const len = tun.read(&buf) catch |err| {
    if (err == error.WouldBlock) {
        // No data available, continue with other work
        continue;
    }
    return err;
};

// Bad: Block waiting for data
const len = tun.read(&buf); // This blocks!
```

### Event Loop Integration
```zig
// Use poll/select with TUN fd
const tun_fd = tun.getFd();

var pollfds = [_]posix.pollfd{
    .{ .fd = udp_socket, .events = posix.POLL.IN, .revents = 0 },
    .{ .fd = tun_fd, .events = posix.POLL.IN, .revents = 0 },
};

const ready = try posix.poll(&pollfds, timeout_ms);

if ((pollfds[1].revents & posix.POLL.IN) != 0) {
    // TUN device has data ready
    const len = try tun.read(&buf);
    // Process packet...
}
```

## Troubleshooting

### "ConnectFailed" Error
**Problem**: Cannot connect to utun kernel control
**Cause**: Not running as root
**Solution**: Run with `sudo`

### "IfconfigFailed" Error
**Problem**: Cannot configure IP address
**Cause**: Invalid IP/netmask or permission issue
**Solution**: Check IP format, ensure `/sbin/ifconfig` exists

### No Packets Received
**Problem**: `read()` always returns `WouldBlock`
**Possible causes**:
- No traffic to that IP
- Routing not configured
- Firewall blocking

**Debug**:
```bash
# Check interface is up
ifconfig utun100

# Check routing
netstat -rn | grep utun

# Send test traffic
ping 10.147.20.1
```

### Interface Doesn't Appear
**Problem**: TUN device created but not visible in `ifconfig`
**Cause**: Configuration failed
**Solution**: Check `ifconfig` command succeeded

## API Reference

### TunDevice.open()
```zig
pub fn open(allocator: Allocator, name_prefix: []const u8) !TunDevice
```
Opens a TUN device. On macOS, `name_prefix` is ignored (utun naming is automatic).

**Returns**: `TunDevice` handle
**Errors**: `UnsupportedPlatform`, `ConnectFailed`, `GetIfNameFailed`

### TunDevice.close()
```zig
pub fn close(self: *TunDevice) void
```
Closes the TUN device and frees resources.

### TunDevice.read()
```zig
pub fn read(self: *TunDevice, buffer: []u8) !usize
```
Reads one IP packet from the device.

**Returns**: Number of bytes read (excluding protocol header)
**Errors**: `WouldBlock`, `ShortRead`, system errors

### TunDevice.write()
```zig
pub fn write(self: *TunDevice, data: []const u8) !void
```
Writes one IP packet to the device.

**Errors**: `InvalidPacket`, `ShortWrite`, system errors

### TunDevice.setAddress()
```zig
pub fn setAddress(self: *TunDevice, ip: [4]u8, netmask: [4]u8) !void
```
Configures the interface IP address and brings it up.

**Errors**: `IfconfigFailed`, `UnsupportedPlatform`

### TunDevice.addRoute()
```zig
pub fn addRoute(self: *TunDevice, dest: [4]u8, netmask: [4]u8) !void
```
Adds a route through this TUN device.

**Errors**: System errors

### TunDevice.getFd()
```zig
pub fn getFd(self: *TunDevice) posix.fd_t
```
Returns the underlying file descriptor for use with `poll`/`select`.

## Summary

✅ **TUN device module is complete and working on macOS**

**What we have:**
- Full `utun` device support
- IP configuration
- Non-blocking packet I/O
- Test program demonstrating functionality

**What's next:**
- Integrate with ZeroTier service layer
- Wire Node callbacks to TUN read/write
- Handle Ethernet framing (layer 2 ↔ layer 3)
- Test with real ZeroTier networks

**Progress:** TUN device implementation complete! This is the critical component we needed. Now we can route traffic through ZeroTier. 🚀
