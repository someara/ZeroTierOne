/// An outbound multicast packet.
///
/// Converted from `node/OutboundMulticast.hpp` and `node/OutboundMulticast.cpp`.
///
/// This represents a pending multicast frame that needs to be sent to multiple
/// peers. It stores a pre-built MULTICAST_FRAME packet, the raw frame data
/// (for filtering), and a dedup list of addresses already sent to.
///
/// NOT thread-safe — callers must synchronize externally.
///
/// Design notes for Phase 5:
///   - `sendOnly` depends on Network/Node/Switch (Phase 6), so it is modeled
///     as a callback (`SendFn`). The caller provides the function that handles
///     filtering, credential pushing, and actual packet delivery.
///   - `init` builds the MULTICAST_FRAME packet using the Zig Packet API.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const constants = @import("constants.zig");
const MAC = @import("mac.zig").MAC;
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
const nc = @import("network_config.zig");
const packet_mod = @import("packet.zig");
const Packet = packet_mod.Packet;
const Verb = packet_mod.Verb;

/// Maximum number of addresses to track for dedup.
///
/// The C++ version uses `std::vector<Address>` which grows dynamically.
/// We use a fixed-size array with a count, sized to handle the largest
/// reasonable multicast limit. ZT_MULTICAST_DEFAULT_LIMIT is 32.
const max_already_sent: u32 = 256;

/// Maximum payload size for a multicast frame (MTU).
const max_frame_len: u32 = nc.max_mtu;

/// Callback for sending a multicast packet to a specific peer.
///
/// The callback should:
///   1. Look up the Network by nwid
///   2. Call filterOutgoingPacket on the network
///   3. Push credentials if needed
///   4. Generate a new IV, set destination, and send via Switch
///
/// Parameters:
///   - ctx: Opaque context pointer (RuntimeEnvironment, etc.)
///   - to_addr: Destination peer address
///   - nwid: Network ID
///   - mac_src: Source MAC
///   - mac_dest: Destination MAC
///   - frame_data: Raw frame payload
///   - frame_len: Length of frame payload
///   - ether_type: Ethernet type
///   - packet: Pointer to the pre-built packet (caller should copy, set dest, new IV, then send)
pub const SendFn = *const fn (
    ctx: ?*anyopaque,
    to_addr: Address,
    nwid: u64,
    mac_src: MAC,
    mac_dest: MAC,
    frame_data: []const u8,
    frame_len: u32,
    ether_type: u32,
    packet: *const Packet,
) void;

/// An outbound multicast packet pending delivery.
pub const OutboundMulticast = struct {
    /// Multicast creation timestamp.
    _timestamp: u64,

    /// Network ID.
    _nwid: u64,

    /// Source MAC address.
    _mac_src: MAC,

    /// Destination MAC address.
    _mac_dest: MAC,

    /// Maximum number of recipients.
    _limit: u32,

    /// Length of frame data.
    _frame_len: u32,

    /// Ethernet type.
    _ether_type: u32,

    /// Pre-built MULTICAST_FRAME packet.
    _packet: Packet,

    /// Addresses already sent to (dedup list).
    _already_sent_to: [max_already_sent]Address,

    /// Number of addresses in the dedup list.
    _already_sent_count: u32,

    /// Raw frame data copy (for filtering in sendOnly).
    _frame_data: [max_frame_len]u8,

    // ── Constructor ───────────────────────────────────────

    /// Create an uninitialized outbound multicast.
    pub fn initEmpty() OutboundMulticast {
        return .{
            ._timestamp = 0,
            ._nwid = 0,
            ._mac_src = MAC.init(0),
            ._mac_dest = MAC.init(0),
            ._limit = 0,
            ._frame_len = 0,
            ._ether_type = 0,
            ._packet = Packet.initEmpty(),
            ._already_sent_to = [_]Address{Address.zero()} ** max_already_sent,
            ._already_sent_count = 0,
            ._frame_data = [_]u8{0} ** max_frame_len,
        };
    }

    /// Initialize this outbound multicast.
    ///
    /// Builds the MULTICAST_FRAME packet from the given parameters.
    ///
    /// Parameters:
    ///   - my_address: Our ZeroTier address (for packet source and default MAC)
    ///   - timestamp_val: Creation time
    ///   - nwid: Network ID
    ///   - disable_compression: If true, skip LZ4 compression
    ///   - limit: Maximum number of recipients
    ///   - gather_limit: Number to lazily gather, or 0 for none
    ///   - src: Source MAC (zero to derive from my_address + nwid)
    ///   - dest: Destination multicast group (MAC + ADI)
    ///   - ether_type: 16-bit Ethernet type ID
    ///   - payload: Frame data
    pub fn initMulticast(
        self: *OutboundMulticast,
        my_address: Address,
        timestamp_val: u64,
        network_id: u64,
        disable_compression: bool,
        limit_val: u32,
        gather_limit: u32,
        src: MAC,
        dest: MulticastGroup,
        ether_type: u32,
        payload: []const u8,
    ) void {
        var flags: u8 = 0;

        self._timestamp = timestamp_val;
        self._nwid = network_id;

        if (src.isSet()) {
            self._mac_src = src;
            flags |= 0x04;
        } else {
            self._mac_src = MAC.fromAddress(my_address, network_id);
        }

        self._mac_dest = dest.mac();
        self._limit = limit_val;
        self._frame_len = @min(@as(u32, @intCast(payload.len)), max_frame_len);
        self._ether_type = ether_type;

        if (gather_limit > 0) {
            flags |= 0x02;
        }

        // Build the MULTICAST_FRAME packet
        // Packet header: destination is set per-send, source is our address
        self._packet = Packet.initNew(Address.zero(), my_address, .multicast_frame);

        // Append: network ID (u64)
        self._packet.buf.appendInt(u64, network_id) catch return;
        // Append: flags (u8)
        self._packet.buf.appendInt(u8, flags) catch return;
        // Append: gather limit (u32) if requesting gather
        if (gather_limit > 0) {
            self._packet.buf.appendInt(u32, gather_limit) catch return;
        }
        // Append: source MAC (6 bytes) if explicit source
        if (src.isSet()) {
            src.appendTo(packet_mod.max_packet_length, &self._packet.buf) catch return;
        }
        // Append: destination MAC (6 bytes)
        dest.mac().appendTo(packet_mod.max_packet_length, &self._packet.buf) catch return;
        // Append: destination ADI (u32)
        self._packet.buf.appendInt(u32, dest.adi()) catch return;
        // Append: ether type (u16)
        self._packet.buf.appendInt(u16, @as(u16, @intCast(ether_type & 0xFFFF))) catch return;
        // Append: payload data
        self._packet.buf.appendBytes(payload[0..self._frame_len]) catch return;

        // Compress unless disabled
        if (!disable_compression) {
            _ = self._packet.compress();
        }

        // Copy frame data for filtering
        @memcpy(self._frame_data[0..self._frame_len], payload[0..self._frame_len]);

        // Reset dedup list
        self._already_sent_count = 0;
    }

    // ── Accessors ─────────────────────────────────────────

    /// Return the multicast creation timestamp.
    pub fn timestamp(self: *const OutboundMulticast) u64 {
        return self._timestamp;
    }

    /// Return the network ID.
    pub fn nwid(self: *const OutboundMulticast) u64 {
        return self._nwid;
    }

    /// Check if this multicast has expired.
    pub fn expired(self: *const OutboundMulticast, now: i64) bool {
        const ts_signed: i64 = @intCast(self._timestamp);
        return (now - ts_signed) >= constants.multicast_transmit_timeout;
    }

    /// Check if we've reached the send limit.
    pub fn atLimit(self: *const OutboundMulticast) bool {
        return self._already_sent_count >= self._limit;
    }

    /// Return the number of addresses already sent to.
    pub fn sentCount(self: *const OutboundMulticast) u32 {
        return self._already_sent_count;
    }

    /// Return the limit.
    pub fn limit(self: *const OutboundMulticast) u32 {
        return self._limit;
    }

    // ── Send methods ──────────────────────────────────────

    /// Send to an address without checking the dedup log.
    ///
    /// Uses the callback to handle Network/Switch interactions.
    pub fn sendOnly(
        self: *const OutboundMulticast,
        send_fn: SendFn,
        ctx: ?*anyopaque,
        to_addr: Address,
    ) void {
        send_fn(
            ctx,
            to_addr,
            self._nwid,
            self._mac_src,
            self._mac_dest,
            self._frame_data[0..self._frame_len],
            self._frame_len,
            self._ether_type,
            &self._packet,
        );
    }

    /// Send to an address and log it in the dedup list.
    pub fn sendAndLog(
        self: *OutboundMulticast,
        send_fn: SendFn,
        ctx: ?*anyopaque,
        to_addr: Address,
    ) void {
        self.logAsSent(to_addr);
        self.sendOnly(send_fn, ctx, to_addr);
    }

    /// Log an address as sent without actually sending.
    pub fn logAsSent(self: *OutboundMulticast, to_addr: Address) void {
        if (self._already_sent_count < max_already_sent) {
            self._already_sent_to[self._already_sent_count] = to_addr;
            self._already_sent_count += 1;
        }
    }

    /// Check if an address is already in the dedup log.
    pub fn alreadySentTo(self: *const OutboundMulticast, addr: Address) bool {
        for (self._already_sent_to[0..self._already_sent_count]) |sent| {
            if (sent.eql(addr)) return true;
        }
        return false;
    }

    /// Send if not already sent to this address.
    ///
    /// Returns true if the address is new and the send callback was invoked.
    pub fn sendIfNew(
        self: *OutboundMulticast,
        send_fn: SendFn,
        ctx: ?*anyopaque,
        to_addr: Address,
    ) bool {
        if (!self.alreadySentTo(to_addr)) {
            self.sendAndLog(send_fn, ctx, to_addr);
            return true;
        }
        return false;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "initEmpty creates valid defaults" {
    const om = OutboundMulticast.initEmpty();
    try testing.expectEqual(@as(u64, 0), om.timestamp());
    try testing.expectEqual(@as(u64, 0), om.nwid());
    // limit=0 and sent_count=0 means 0 >= 0 => at limit (correct: no sends allowed)
    try testing.expect(om.atLimit());
    try testing.expectEqual(@as(u32, 0), om.sentCount());
}

test "expired checks against multicast_transmit_timeout" {
    var om = OutboundMulticast.initEmpty();
    om._timestamp = 100_000;

    // Before timeout
    try testing.expect(!om.expired(100_000 + constants.multicast_transmit_timeout - 1));
    // At timeout
    try testing.expect(om.expired(100_000 + constants.multicast_transmit_timeout));
    // After timeout
    try testing.expect(om.expired(100_000 + constants.multicast_transmit_timeout + 1));
}

test "logAsSent and alreadySentTo track addresses" {
    var om = OutboundMulticast.initEmpty();

    const addr1 = Address.init(0x1234567890);
    const addr2 = Address.init(0xABCDEF0123);

    try testing.expect(!om.alreadySentTo(addr1));
    try testing.expect(!om.alreadySentTo(addr2));

    om.logAsSent(addr1);

    try testing.expect(om.alreadySentTo(addr1));
    try testing.expect(!om.alreadySentTo(addr2));
    try testing.expectEqual(@as(u32, 1), om.sentCount());

    om.logAsSent(addr2);
    try testing.expect(om.alreadySentTo(addr2));
    try testing.expectEqual(@as(u32, 2), om.sentCount());
}

test "atLimit respects limit" {
    var om = OutboundMulticast.initEmpty();
    om._limit = 2;

    try testing.expect(!om.atLimit());

    om.logAsSent(Address.init(0x0000000001));
    try testing.expect(!om.atLimit());

    om.logAsSent(Address.init(0x0000000002));
    try testing.expect(om.atLimit());
}

test "sendIfNew deduplicates" {
    // Track sends via a simple counter
    const TestContext = struct {
        var send_count: u32 = 0;

        fn sendFn(
            _: ?*anyopaque,
            _: Address,
            _: u64,
            _: MAC,
            _: MAC,
            _: []const u8,
            _: u32,
            _: u32,
            _: *const Packet,
        ) void {
            send_count += 1;
        }
    };

    TestContext.send_count = 0;
    var om = OutboundMulticast.initEmpty();
    om._limit = 10;

    const addr = Address.init(0x1234567890);

    // First send should succeed
    try testing.expect(om.sendIfNew(TestContext.sendFn, null, addr));
    try testing.expectEqual(@as(u32, 1), TestContext.send_count);

    // Second send to same address should be a no-op
    try testing.expect(!om.sendIfNew(TestContext.sendFn, null, addr));
    try testing.expectEqual(@as(u32, 1), TestContext.send_count);

    // Different address should succeed
    const addr2 = Address.init(0xABCDEF0123);
    try testing.expect(om.sendIfNew(TestContext.sendFn, null, addr2));
    try testing.expectEqual(@as(u32, 2), TestContext.send_count);
}

test "initMulticast builds packet and stores frame data" {
    var om = OutboundMulticast.initEmpty();

    const my_addr = Address.init(0x1234567890);
    const dest_mac = MAC.init(0xFFFFFF000001);
    const dest = MulticastGroup.init(dest_mac, 42);
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    om.initMulticast(
        my_addr,
        1000,
        0xABCD1234EFAB,
        false,
        32,
        0,
        MAC.init(0), // zero = derive from address
        dest,
        0x0800,
        &payload,
    );

    try testing.expectEqual(@as(u64, 1000), om.timestamp());
    try testing.expectEqual(@as(u64, 0xABCD1234EFAB), om.nwid());
    try testing.expectEqual(@as(u32, 4), om._frame_len);
    try testing.expectEqual(@as(u32, 32), om.limit());
    try testing.expect(!om.atLimit());
    try testing.expectEqual(@as(u32, 0), om.sentCount());

    // Check frame data was copied
    try testing.expectEqual(@as(u8, 0xDE), om._frame_data[0]);
    try testing.expectEqual(@as(u8, 0xAD), om._frame_data[1]);
    try testing.expectEqual(@as(u8, 0xBE), om._frame_data[2]);
    try testing.expectEqual(@as(u8, 0xEF), om._frame_data[3]);

    // Packet should have some data (header + fields)
    try testing.expect(om._packet.buf.size() > packet_mod.min_packet_length);
}

test "initMulticast with explicit source MAC sets flag" {
    var om = OutboundMulticast.initEmpty();

    const my_addr = Address.init(0x1234567890);
    const src_mac = MAC.init(0x001122334455);
    const dest = MulticastGroup.init(MAC.init(0xFFFFFF000001), 0);
    const payload = [_]u8{0x42};

    om.initMulticast(
        my_addr,
        2000,
        0xFFFF00001111,
        true, // disable compression
        16,
        100, // gather limit > 0
        src_mac, // explicit source
        dest,
        0x86DD, // IPv6
        &payload,
    );

    try testing.expectEqual(@as(u64, 2000), om.timestamp());
    // Source MAC should be the explicit one, not derived
    try testing.expect(om._mac_src.eql(src_mac));
}
