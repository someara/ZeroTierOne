/// Core packet routing and switching logic.
///
/// Converted from `node/Switch.hpp` and `node/Switch.cpp`.
///
/// The Switch is where everything meets: transport-layer ZT packets come in
/// here from the network, virtual network packets come in from tap devices,
/// and this module routes them to their destinations, handling encryption,
/// compression, queuing, fragmentation, and QoS.
///
/// Key responsibilities:
/// - Receive packets from network (onRemotePacket)
/// - Receive frames from local tap devices (onLocalEthernet)
/// - Route packets to appropriate peers
/// - Manage WHOIS requests for unknown addresses
/// - Handle packet fragmentation and reassembly
/// - Implement AQM (Active Queue Management) with CoDel for QoS
/// - Manage TX/RX queues

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const packet_mod = @import("packet.zig");
const Packet = packet_mod.Packet;
const Fragment = packet_mod.Fragment;
const IncomingPacket = @import("incoming_packet.zig").IncomingPacket;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;
const Mutex = @import("mutex.zig");
const Hashtable = @import("hashtable.zig").Hashtable;
const AtomicCounter = @import("atomic_counter.zig");
const constants = @import("constants.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Ethernet type constants
pub const ethertype_ipv4: u16 = 0x0800;
pub const ethertype_arp: u16 = 0x0806;
pub const ethertype_rarp: u16 = 0x8035;
pub const ethertype_atalk: u16 = 0x809b;
pub const ethertype_aarp: u16 = 0x80f3;
pub const ethertype_ipx_a: u16 = 0x8137;
pub const ethertype_ipx_b: u16 = 0x8138;
pub const ethertype_ipv6: u16 = 0x86dd;

// Packet verb constants (from Packet module)
const verb_frame: u8 = 0x02;
const verb_ext_frame: u8 = 0x03;

/// RX queue size for packet reassembly
const rx_queue_size = constants.rx_queue_size;

/// Maximum packet fragments
const max_packet_fragments = constants.max_packet_fragments;

/// AQM quantum (bytes)
const aqm_quantum: i32 = 1500;

/// No QoS flow ID sentinel
pub const qos_no_flow: i32 = -1;

// ── RX Queue Entry ───────────────────────────────────────────────

/// Stored fragment data
const FragmentData = struct {
    data: [packet_mod.max_packet_length]u8,
    len: u32,

    pub fn init() FragmentData {
        return .{
            .data = [_]u8{0} ** packet_mod.max_packet_length,
            .len = 0,
        };
    }

    pub fn payload(self: *const FragmentData) []const u8 {
        if (self.len > packet_mod.min_fragment_length) {
            return self.data[packet_mod.min_fragment_length..self.len];
        }
        return &[_]u8{};
    }

    pub fn payloadLength(self: *const FragmentData) u32 {
        if (self.len > packet_mod.min_fragment_length) {
            return self.len - packet_mod.min_fragment_length;
        }
        return 0;
    }
};

/// Entry in the receive queue for packet reassembly.
///
/// Holds fragments of a packet until all pieces arrive, then the
/// complete packet can be decoded.
const RXQueueEntry = struct {
    timestamp: i64,
    packet_id: u64,
    frag0: IncomingPacket,
    frags: [max_packet_fragments - 1]FragmentData,
    total_fragments: u32,
    have_fragments: u32, // bitmask
    complete: bool,
    flow_id: i32,
    lock: Mutex,

    pub fn init() RXQueueEntry {
        return .{
            .timestamp = 0,
            .packet_id = 0,
            .frag0 = IncomingPacket.initEmpty(),
            .frags = [_]FragmentData{FragmentData.init()} ** (max_packet_fragments - 1),
            .total_fragments = 0,
            .have_fragments = 0,
            .complete = false,
            .flow_id = qos_no_flow,
            .lock = .{},
        };
    }
};

// ── TX Queue Entry ───────────────────────────────────────────────

/// Entry in the transmit queue waiting to be sent.
const TXQueueEntry = struct {
    dest: Address,
    nwid: u64,
    creation_time: u64,
    packet: Packet,
    encrypt: bool,
    flow_id: i32,

    pub fn init(
        dest: Address,
        nwid: u64,
        creation_time: u64,
        pkt: Packet,
        encrypt: bool,
        flow_id: i32,
    ) TXQueueEntry {
        return .{
            .dest = dest,
            .nwid = nwid,
            .creation_time = creation_time,
            .packet = pkt,
            .encrypt = encrypt,
            .flow_id = flow_id,
        };
    }
};

// ── Managed Queue (for AQM) ──────────────────────────────────────

/// Queue with flow state for CoDel AQM.
const ManagedQueue = struct {
    id: i32,
    byte_credit: i32,
    byte_length: i32,
    first_above_time: u64,
    count: u32,
    drop_next: u64,
    dropping: bool,
    drop_next_time: u64,
    // Queue of TX entries (in real impl, would be a list)
    // For now, stub with a fixed-size array
    entries: [256]?*TXQueueEntry,
    entry_count: u32,

    pub fn init(id: i32) ManagedQueue {
        return .{
            .id = id,
            .byte_credit = aqm_quantum,
            .byte_length = 0,
            .first_above_time = 0,
            .count = 0,
            .drop_next = 0,
            .dropping = false,
            .drop_next_time = 0,
            .entries = [_]?*TXQueueEntry{null} ** 256,
            .entry_count = 0,
        };
    }
};

// ── Network QoS Control Block ────────────────────────────────────

/// Per-network QoS state for fq_codel.
const NetworkQoSControlBlock = struct {
    curr_enqueued_packets: i32,
    new_queues: std.ArrayList(*ManagedQueue),
    old_queues: std.ArrayList(*ManagedQueue),
    inactive_queues: std.ArrayList(*ManagedQueue),

    pub fn init(allocator: mem.Allocator) NetworkQoSControlBlock {
        return .{
            .curr_enqueued_packets = 0,
            .new_queues = std.ArrayList(*ManagedQueue).init(allocator),
            .old_queues = std.ArrayList(*ManagedQueue).init(allocator),
            .inactive_queues = std.ArrayList(*ManagedQueue).init(allocator),
        };
    }

    pub fn deinit(self: *NetworkQoSControlBlock) void {
        self.new_queues.deinit();
        self.old_queues.deinit();
        self.inactive_queues.deinit();
    }
};

// ── Last Unite Key ───────────────────────────────────────────────

/// Key for tracking RENDEZVOUS relay attempts.
const LastUniteKey = struct {
    x: u64,
    y: u64,

    pub fn init(a1: Address, a2: Address) LastUniteKey {
        if (a1.toInt() > a2.toInt()) {
            return .{ .x = a2.toInt(), .y = a1.toInt() };
        } else {
            return .{ .x = a1.toInt(), .y = a2.toInt() };
        }
    }

    pub fn hashCode(self: LastUniteKey) u64 {
        return self.x ^ self.y;
    }

    pub fn eql(self: LastUniteKey, other: LastUniteKey) bool {
        return self.x == other.x and self.y == other.y;
    }
};

// ── Switch ───────────────────────────────────────────────────────

/// Core packet routing and switching logic.
///
/// This is where everything meets: packets from the network, frames from
/// tap devices, WHOIS requests, fragmentation, QoS, etc.
pub const Switch = struct {
    allocator: mem.Allocator,

    // Timestamps
    last_beacon_response: i64,
    last_checked_queues: i64,

    // WHOIS tracking
    last_sent_whois_request: Hashtable(Address, i64),
    last_sent_whois_request_mutex: Mutex,

    // RX queue for fragmentation/reassembly
    rx_queue: [rx_queue_size]RXQueueEntry,
    rx_queue_ptr: AtomicCounter,

    // TX queue
    tx_queue: std.ArrayList(TXQueueEntry),
    tx_queue_mutex: Mutex,

    // AQM
    aqm_mutex: Mutex,
    net_queue_control_block: std.AutoHashMap(u64, *NetworkQoSControlBlock),

    // RENDEZVOUS tracking
    last_unite_attempt: Hashtable(LastUniteKey, u64),
    last_unite_attempt_mutex: Mutex,

    const Self = @This();

    /// Create a new Switch instance.
    pub fn init(allocator: mem.Allocator) !Self {
        var rx_queue: [rx_queue_size]RXQueueEntry = undefined;
        for (&rx_queue) |*entry| {
            entry.* = RXQueueEntry.init();
        }

        return .{
            .allocator = allocator,
            .last_beacon_response = 0,
            .last_checked_queues = 0,
            .last_sent_whois_request = Hashtable(Address, i64).init(64),
            .last_sent_whois_request_mutex = .{},
            .rx_queue = rx_queue,
            .rx_queue_ptr = AtomicCounter.init(),
            .tx_queue = std.ArrayList(TXQueueEntry).init(allocator),
            .tx_queue_mutex = .{},
            .aqm_mutex = .{},
            .net_queue_control_block = std.AutoHashMap(u64, *NetworkQoSControlBlock).init(allocator),
            .last_unite_attempt = Hashtable(LastUniteKey, u64).init(8),
            .last_unite_attempt_mutex = .{},
        };
    }

    /// Destroy the Switch instance.
    pub fn deinit(self: *Self) void {
        self.last_sent_whois_request.deinit();

        self.tx_queue.deinit();

        var iter = self.net_queue_control_block.valueIterator();
        while (iter.next()) |block_ptr| {
            block_ptr.*.deinit();
            self.allocator.destroy(block_ptr.*);
        }
        self.net_queue_control_block.deinit();

        self.last_unite_attempt.deinit();
    }

    /// Called when a packet is received from the real network.
    ///
    /// This is the entry point for all packets arriving over UDP/IP.
    /// The packet will be authenticated, decrypted (if needed), and
    /// dispatched to the appropriate handler.
    pub fn onRemotePacket(
        self: *Self,
        t_ptr: ?*anyopaque,
        local_socket: i64,
        from_addr: *const InetAddress,
        data: [*]const u8,
        len: u32,
        callbacks: *const Callbacks,
    ) void {
        const now = callbacks.now(t_ptr);

        // Update path received timestamp
        callbacks.pathReceived(t_ptr, local_socket, from_addr, now);

        if (len > constants.proto_min_fragment_length) {
            // Check if this is a fragment
            if (data[constants.packet_fragment_idx_fragment_indicator] == constants.packet_fragment_indicator) {
                self.handleFragment(t_ptr, data, len, from_addr, local_socket, now, callbacks);
            } else if (len >= constants.proto_min_packet_length) {
                self.handlePacketHead(t_ptr, data, len, from_addr, local_socket, now, callbacks);
            }
        }
    }

    /// Called when a packet comes from a local Ethernet tap device.
    ///
    /// This wraps the Ethernet frame in a ZeroTier packet and routes it
    /// to the appropriate peer(s) on the virtual network.
    pub fn onLocalEthernet(
        self: *Self,
        t_ptr: ?*anyopaque,
        network: *anyopaque,
        from: *const MAC,
        to: *const MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
        callbacks: *const Callbacks,
    ) void {
        if (!callbacks.networkHasConfig(network)) {
            return;
        }

        const network_mac = callbacks.networkMac(network);
        const from_bridged = !from.eql(&network_mac);

        if (from_bridged) {
            const my_addr = callbacks.myAddress(t_ptr);
            if (!callbacks.networkPermitsBridging(network, my_addr)) {
                return;
            }
        }

        // Compute flow ID for QoS
        const flow_id = computeFlowId(@intCast(ether_type), data[0..len]);

        const my_addr = callbacks.myAddress(t_ptr);
        const nwid = callbacks.networkId(network);

        if (to.isMulticast()) {
            // Multicast/broadcast handling
            callbacks.multicastSend(t_ptr, network, from, to, ether_type, vlan_id, data, len, from_bridged);
        } else if (to.eql(&network_mac)) {
            // Packet is for us, reinject
            callbacks.putFrame(t_ptr, nwid, network, from, to, ether_type, vlan_id, data, len);
        } else {
            // Unicast to another peer
            const dest_addr = callbacks.macToAddress(to, nwid);

            if (!from_bridged) {
                // Regular FRAME packet
                var pkt = callbacks.createPacket(dest_addr, my_addr, verb_frame);
                callbacks.packetAppendNetworkId(&pkt, nwid);
                callbacks.packetAppendEtherType(&pkt, @intCast(ether_type));
                callbacks.packetAppendData(&pkt, data, len);
                self.aqmEnqueue(t_ptr, network, &pkt, true, nwid, flow_id, callbacks);
            } else {
                // Bridged, use EXT_FRAME
                var pkt = callbacks.createPacket(dest_addr, my_addr, verb_ext_frame);
                callbacks.packetAppendNetworkId(&pkt, nwid);
                callbacks.packetAppendByte(&pkt, 0x00);
                callbacks.packetAppendMAC(&pkt, to);
                callbacks.packetAppendMAC(&pkt, from);
                callbacks.packetAppendEtherType(&pkt, @intCast(ether_type));
                callbacks.packetAppendData(&pkt, data, len);
                self.aqmEnqueue(t_ptr, network, &pkt, true, nwid, flow_id, callbacks);
            }
        }
    }

    /// Send a packet to a ZeroTier address.
    ///
    /// If the peer is known, send immediately. Otherwise, queue the packet
    /// and dispatch a WHOIS request.
    pub fn send(
        self: *Self,
        t_ptr: ?*anyopaque,
        packet: *Packet,
        encrypt: bool,
        nwid: u64,
        flow_id: i32,
        callbacks: *const Callbacks,
    ) void {
        const dest = packet.destination();
        const my_addr = callbacks.myAddress(t_ptr);

        if (dest.eql(&my_addr)) {
            return;
        }

        const now = callbacks.now(t_ptr);

        if (!self.trySend(t_ptr, packet, encrypt, nwid, flow_id, now, callbacks)) {
            // Couldn't send, queue it
            self.tx_queue_mutex.lock();
            defer self.tx_queue_mutex.unlock();

            // Drop oldest if queue is full
            if (self.tx_queue.items.len >= constants.tx_queue_size) {
                _ = self.tx_queue.orderedRemove(0);
            }

            const entry = TXQueueEntry.init(dest, nwid, @intCast(now), packet.*, encrypt, flow_id);
            self.tx_queue.append(entry) catch return;

            // Request WHOIS if we don't know this peer
            if (callbacks.lookupPeer(t_ptr, dest) == null) {
                self.requestWhois(t_ptr, now, dest, callbacks);
            }
        }
    }

    /// Request WHOIS for an unknown address.
    pub fn requestWhois(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
        addr: Address,
        callbacks: *const Callbacks,
    ) void {
        self.last_sent_whois_request_mutex.lock();
        defer self.last_sent_whois_request_mutex.unlock();

        // Check if we've recently requested this address
        if (self.last_sent_whois_request.get(addr)) |last_time| {
            // Don't spam WHOIS requests
            if (now - last_time < 1000) { // 1 second throttle
                return;
            }
        }

        // Send WHOIS to upstream nodes
        _ = t_ptr;
        _ = callbacks;
        // TODO: Actually send WHOIS packet

        // Record this request
        self.last_sent_whois_request.put(addr, now) catch {};
    }

    /// Process anything waiting for this peer's identity.
    ///
    /// Called when we learn a peer's identity (from HELLO, OK(WHOIS), etc.)
    pub fn doAnythingWaitingForPeer(
        self: *Self,
        t_ptr: ?*anyopaque,
        peer: *anyopaque,
        callbacks: *const Callbacks,
    ) void {
        const peer_addr = callbacks.peerAddress(peer);
        const now = callbacks.now(t_ptr);

        // Remove from WHOIS tracking
        self.last_sent_whois_request_mutex.lock();
        _ = self.last_sent_whois_request.remove(peer_addr);
        self.last_sent_whois_request_mutex.unlock();

        // Try to decode any RX queue entries waiting for this peer
        for (&self.rx_queue) |*rq| {
            rq.lock.lock();
            if (rq.timestamp != 0 and rq.complete) {
                if (rq.frag0.tryDecode(t_ptr, rq.flow_id, callbacks) or (now - rq.timestamp) > constants.receive_queue_timeout) {
                    rq.timestamp = 0;
                }
            }
            rq.lock.unlock();
        }

        // Try to send any TX queue entries for this peer
        self.tx_queue_mutex.lock();
        defer self.tx_queue_mutex.unlock();

        var i: usize = 0;
        while (i < self.tx_queue.items.len) {
            if (self.tx_queue.items[i].dest.eql(&peer_addr)) {
                const entry = &self.tx_queue.items[i];
                var pkt = entry.packet;
                if (self.trySend(t_ptr, &pkt, entry.encrypt, entry.nwid, entry.flow_id, now, callbacks)) {
                    _ = self.tx_queue.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Periodic timer tasks.
    ///
    /// Handles retries, queue cleanup, etc.
    /// Returns milliseconds until next call should be made.
    pub fn doTimerTasks(
        self: *Self,
        t_ptr: ?*anyopaque,
        now: i64,
        callbacks: *const Callbacks,
    ) u64 {
        const time_since_last_check = now - self.last_checked_queues;
        if (time_since_last_check < constants.whois_retry_delay) {
            return @intCast(constants.whois_retry_delay - time_since_last_check);
        }
        self.last_checked_queues = now;

        // Try to send queued packets
        var need_whois = std.ArrayList(Address).init(self.allocator);
        defer need_whois.deinit();

        self.tx_queue_mutex.lock();
        var i: usize = 0;
        while (i < self.tx_queue.items.len) {
            const entry = &self.tx_queue.items[i];
            var pkt = entry.packet;

            if (self.trySend(t_ptr, &pkt, entry.encrypt, 0, entry.flow_id, now, callbacks)) {
                _ = self.tx_queue.orderedRemove(i);
                continue;
            } else if ((now - @as(i64, @intCast(entry.creation_time))) > constants.transmit_queue_timeout) {
                _ = self.tx_queue.orderedRemove(i);
                continue;
            } else {
                if (callbacks.lookupPeer(t_ptr, entry.dest) == null) {
                    need_whois.append(entry.dest) catch {};
                }
            }
            i += 1;
        }
        self.tx_queue_mutex.unlock();

        // Request WHOIS for unknown peers
        for (need_whois.items) |addr| {
            self.requestWhois(t_ptr, now, addr, callbacks);
        }

        // Process RX queue entries
        for (&self.rx_queue) |*rq| {
            rq.lock.lock();
            if (rq.timestamp != 0 and rq.complete) {
                if (rq.frag0.tryDecode(t_ptr, rq.flow_id, callbacks) or (now - rq.timestamp) > constants.receive_queue_timeout) {
                    rq.timestamp = 0;
                } else {
                    const src = rq.frag0.source();
                    if (callbacks.lookupPeer(t_ptr, src) == null) {
                        self.requestWhois(t_ptr, now, src, callbacks);
                    }
                }
            }
            rq.lock.unlock();
        }

        // Clean up old WHOIS requests
        self.last_sent_whois_request_mutex.lock();
        var whois_iter = self.last_sent_whois_request.iterator();
        while (whois_iter.next()) |entry| {
            if ((now - entry.value_ptr.*) > (constants.whois_retry_delay * 2)) {
                _ = self.last_sent_whois_request.remove(entry.key_ptr.*);
            }
        }
        self.last_sent_whois_request_mutex.unlock();

        // Clean up old UNITE attempts
        self.last_unite_attempt_mutex.lock();
        var unite_iter = self.last_unite_attempt.iterator();
        while (unite_iter.next()) |entry| {
            if ((now - @as(i64, @intCast(entry.value_ptr.*))) >= (constants.min_unite_interval * 8)) {
                _ = self.last_unite_attempt.remove(entry.key_ptr.*);
            }
        }
        self.last_unite_attempt_mutex.unlock();

        return constants.whois_retry_delay;
    }

    /// Find or allocate RX queue entry for packet reassembly.
    fn findRXQueueEntry(self: *Self, packet_id: u64) *RXQueueEntry {
        const current = self.rx_queue_ptr.load();
        // Look for existing entry with this packet ID
        var k: u32 = 1;
        while (k <= rx_queue_size) : (k += 1) {
            const idx = (current -% k) % rx_queue_size;
            const rq = &self.rx_queue[idx];
            if (rq.packet_id == packet_id and rq.timestamp != 0) {
                return rq;
            }
        }
        // Allocate new entry
        _ = self.rx_queue_ptr.increment();
        return &self.rx_queue[current % rx_queue_size];
    }

    /// Get next RX queue entry (ring buffer).
    fn nextRXQueueEntry(self: *Self) *RXQueueEntry {
        const idx = self.rx_queue_ptr.increment() - 1;
        return &self.rx_queue[idx % rx_queue_size];
    }

    /// Handle a packet fragment.
    fn handleFragment(
        self: *Self,
        t_ptr: ?*anyopaque,
        data: [*]const u8,
        len: u32,
        _: *const InetAddress,
        _: i64,
        now: i64,
        callbacks: *const Callbacks,
    ) void {

        if (len < constants.proto_min_fragment_length) return;

        // Parse fragment header
        const dest_addr = Address.fromBytes(data + 8);
        const my_addr = callbacks.myAddress(t_ptr);

        if (!dest_addr.eql(&my_addr)) {
            // Fragment is for someone else - relay if appropriate
            return;
        }

        // Extract fragment metadata
        const packet_id = extractPacketId(data);
        const frag_num = data[constants.packet_fragment_idx_fragment_no];
        const total_frags = data[constants.packet_fragment_idx_fragment_total];

        if (total_frags > max_packet_fragments or frag_num >= max_packet_fragments or frag_num == 0 or total_frags <= 1) {
            return;
        }

        const rq = self.findRXQueueEntry(packet_id);
        rq.lock.lock();
        defer rq.lock.unlock();

        if (rq.packet_id != packet_id) {
            // New fragment sequence without head
            rq.flow_id = qos_no_flow;
            rq.timestamp = now;
            rq.packet_id = packet_id;
            @memcpy(rq.frags[frag_num - 1].data[0..len], data[0..len]);
            rq.frags[frag_num - 1].len = len;
            rq.total_fragments = total_frags;
            rq.have_fragments = @as(u32, 1) << @intCast(frag_num);
            rq.complete = false;
        } else if ((rq.have_fragments & (@as(u32, 1) << @intCast(frag_num))) == 0) {
            // Add this fragment
            @memcpy(rq.frags[frag_num - 1].data[0..len], data[0..len]);
            rq.frags[frag_num - 1].len = len;
            rq.total_fragments = total_frags;
            rq.have_fragments |= @as(u32, 1) << @intCast(frag_num);

            // Check if complete
            if (countBits(rq.have_fragments) == total_frags) {
                // Assemble - need fragment 0 first
                // For now, mark as incomplete since we don't have frag0 yet
                rq.complete = false;
            }
        }
    }

    /// Handle a packet head (possibly fragmented or complete).
    fn handlePacketHead(
        self: *Self,
        t_ptr: ?*anyopaque,
        data: [*]const u8,
        len: u32,
        from_addr: *const InetAddress,
        local_socket: i64,
        now: i64,
        callbacks: *const Callbacks,
    ) void {
        const dest_addr = Address.fromBytes(data + 8);
        const src_addr = Address.fromBytes(data + 13);
        const my_addr = callbacks.myAddress(t_ptr);

        if (src_addr.eql(&my_addr)) {
            return;
        }

        if (!dest_addr.eql(&my_addr)) {
            // Packet is for someone else - relay if appropriate
            // TODO: Implement packet relaying
            return;
        }

        const flags = data[constants.packet_idx_flags];
        const is_fragmented = (flags & constants.proto_flag_fragmented) != 0;

        if (is_fragmented) {
            // This is fragment 0 (the head)
            const packet_id = extractPacketId(data);
            const rq = self.findRXQueueEntry(packet_id);
            rq.lock.lock();
            defer rq.lock.unlock();

            if (rq.packet_id != packet_id) {
                // New fragmented packet
                rq.flow_id = qos_no_flow;
                rq.timestamp = now;
                rq.packet_id = packet_id;
                rq.frag0 = IncomingPacket.initFromBytes(data, len, from_addr, local_socket, now);
                rq.total_fragments = 0;
                rq.have_fragments = 1;
                rq.complete = false;
            } else if ((rq.have_fragments & 1) == 0) {
                // We have other fragments, add the head
                rq.frag0 = IncomingPacket.initFromBytes(data, len, from_addr, local_socket, now);
                rq.have_fragments |= 1;

                if (rq.total_fragments > 1 and countBits(rq.have_fragments) == rq.total_fragments) {
                    // Complete, assemble by appending fragment payloads
                    var f: u32 = 1;
                    while (f < rq.total_fragments) : (f += 1) {
                        const frag = &rq.frags[f - 1];
                        const payload_data = frag.payload();
                        rq.frag0.pkt.buf.appendBytes(payload_data) catch {};
                    }

                    if (rq.frag0.tryDecode(t_ptr, rq.flow_id, callbacks)) {
                        rq.timestamp = 0;
                    } else {
                        rq.complete = true;
                    }
                }
            }
        } else {
            // Complete unfragmented packet
            var pkt = IncomingPacket.initFromBytes(data, len, from_addr, local_socket, now);
            if (!pkt.tryDecode(t_ptr, qos_no_flow, callbacks)) {
                // Couldn't decode (maybe needs WHOIS), queue it
                const rq = self.nextRXQueueEntry();
                rq.lock.lock();
                defer rq.lock.unlock();

                rq.flow_id = qos_no_flow;
                rq.timestamp = now;
                rq.packet_id = pkt.packetId();
                rq.frag0 = pkt;
                rq.total_fragments = 1;
                rq.have_fragments = 1;
                rq.complete = true;
            }
        }
    }

    /// Try to send a packet immediately.
    fn trySend(
        self: *Self,
        t_ptr: ?*anyopaque,
        packet: *Packet,
        encrypt: bool,
        nwid: u64,
        flow_id: i32,
        now: i64,
        callbacks: *const Callbacks,
    ) bool {
        _ = self;
        _ = nwid;

        const dest = packet.destination();
        const peer = callbacks.lookupPeer(t_ptr, dest) orelse return false;

        // Try to send via peer
        callbacks.sendViaPeer(t_ptr, peer, packet, encrypt, now, flow_id);
        return true;
    }

    /// Extract packet ID from packet header.
    fn extractPacketId(data: [*]const u8) u64 {
        var id: u64 = 0;
        id |= @as(u64, data[0]) << 56;
        id |= @as(u64, data[1]) << 48;
        id |= @as(u64, data[2]) << 40;
        id |= @as(u64, data[3]) << 32;
        id |= @as(u64, data[4]) << 24;
        id |= @as(u64, data[5]) << 16;
        id |= @as(u64, data[6]) << 8;
        id |= @as(u64, data[7]);
        return id;
    }

    /// Count bits set in a u32.
    fn countBits(x: u32) u32 {
        var n = x;
        var count: u32 = 0;
        while (n != 0) {
            count += 1;
            n &= n - 1;
        }
        return count;
    }

    /// Compute flow ID from ethernet frame for QoS.
    fn computeFlowId(ethertype: u16, frame_data: []const u8) i32 {
        if (ethertype == ethertype_ipv4 and frame_data.len >= 20) {
            const proto = frame_data[9];
            const header_len = 4 * (frame_data[0] & 0xf);

            switch (proto) {
                0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                    if (frame_data.len > header_len + 4) {
                        const pos = header_len;
                        const src_port = (@as(u16, frame_data[pos]) << 8) | frame_data[pos + 1];
                        const dst_port = (@as(u16, frame_data[pos + 2]) << 8) | frame_data[pos + 3];
                        return @as(i32, @intCast(dst_port ^ src_port ^ proto));
                    }
                },
                else => {},
            }
        } else if (ethertype == ethertype_ipv6 and frame_data.len >= 40) {
            var pos: u32 = 40;
            var proto: u32 = frame_data[6];

            // Parse IPv6 extension headers
            while (pos <= frame_data.len) {
                switch (proto) {
                    0, 43, 60, 135 => {
                        if (pos + 8 > frame_data.len) break;
                        proto = frame_data[pos];
                        pos += (@as(u32, frame_data[pos + 1]) * 8) + 8;
                    },
                    else => break,
                }
            }

            switch (proto) {
                0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                    if (frame_data.len > pos + 4) {
                        const src_port = (@as(u16, frame_data[pos]) << 8) | frame_data[pos + 1];
                        const dst_port = (@as(u16, frame_data[pos + 2]) << 8) | frame_data[pos + 3];
                        return @as(i32, @intCast(dst_port ^ src_port ^ @as(u16, @intCast(proto))));
                    }
                },
                else => {},
            }
        }

        return qos_no_flow;
    }

    /// AQM enqueue for QoS-enabled networks.
    fn aqmEnqueue(
        self: *Self,
        t_ptr: ?*anyopaque,
        network: *anyopaque,
        packet: *Packet,
        encrypt: bool,
        nwid: u64,
        flow_id: i32,
        callbacks: *const Callbacks,
    ) void {
        if (!callbacks.networkQosEnabled(network)) {
            self.send(t_ptr, packet, encrypt, nwid, flow_id, callbacks);
            return;
        }

        // For now, skip QoS and send directly
        // Full AQM/CoDel implementation would manage queues here
        self.send(t_ptr, packet, encrypt, nwid, flow_id, callbacks);
    }
};

// ── Callbacks ─────────────────────────────────────────────────────

/// Runtime callbacks needed by Switch.
///
/// The Switch doesn't directly depend on Node, Topology, etc.
/// Instead, it uses this callback interface for decoupling.
pub const Callbacks = struct {
    ctx: ?*anyopaque,

    // Peer operations
    lookupPeer: *const fn (ctx: ?*anyopaque, addr: Address) ?*anyopaque,
    sendViaPeer: *const fn (
        ctx: ?*anyopaque,
        peer: *anyopaque,
        packet: *const Packet,
        encrypt: bool,
        now: i64,
        flow_id: i32,
    ) void,
    peerAddress: *const fn (peer: *anyopaque) Address,

    // Topology operations
    isUpstream: *const fn (ctx: ?*anyopaque, addr: Address) bool,

    // Network operations
    getNetwork: *const fn (ctx: ?*anyopaque, nwid: u64) ?*anyopaque,
    networkHasConfig: *const fn (network: *anyopaque) bool,
    networkMac: *const fn (network: *anyopaque) MAC,
    networkId: *const fn (network: *anyopaque) u64,
    networkPermitsBridging: *const fn (network: *anyopaque, addr: Address) bool,
    networkQosEnabled: *const fn (network: *anyopaque) bool,

    // Address/MAC operations
    myAddress: *const fn (ctx: ?*anyopaque) Address,
    macToAddress: *const fn (mac: *const MAC, nwid: u64) Address,

    // Packet operations
    createPacket: *const fn (dest: Address, src: Address, verb: u8) Packet,
    packetAppendNetworkId: *const fn (pkt: *Packet, nwid: u64) void,
    packetAppendEtherType: *const fn (pkt: *Packet, et: u16) void,
    packetAppendData: *const fn (pkt: *Packet, data: [*]const u8, len: u32) void,
    packetAppendByte: *const fn (pkt: *Packet, b: u8) void,
    packetAppendMAC: *const fn (pkt: *Packet, mac: *const MAC) void,

    // Frame operations
    putFrame: *const fn (
        ctx: ?*anyopaque,
        nwid: u64,
        network: *anyopaque,
        from: *const MAC,
        to: *const MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
    ) void,
    multicastSend: *const fn (
        ctx: ?*anyopaque,
        network: *anyopaque,
        from: *const MAC,
        to: *const MAC,
        ether_type: u32,
        vlan_id: u32,
        data: [*]const u8,
        len: u32,
        from_bridged: bool,
    ) void,

    // Path operations
    pathReceived: *const fn (ctx: ?*anyopaque, local_socket: i64, from_addr: *const InetAddress, now: i64) void,

    // Time
    now: *const fn (ctx: ?*anyopaque) i64,
};

// ── Tests ─────────────────────────────────────────────────────────

test "Switch: init/deinit" {
    var sw = try Switch.init(testing.allocator);
    defer sw.deinit();

    try testing.expectEqual(@as(i64, 0), sw.last_beacon_response);
    try testing.expectEqual(@as(i64, 0), sw.last_checked_queues);
}

test "Switch: RX queue entry allocation" {
    var sw = try Switch.init(testing.allocator);
    defer sw.deinit();

    const entry1 = sw.nextRXQueueEntry();
    try testing.expect(entry1.timestamp == 0);

    const entry2 = sw.nextRXQueueEntry();
    try testing.expect(entry2 != entry1);
}

test "Switch: WHOIS request tracking" {
    var sw = try Switch.init(testing.allocator);
    defer sw.deinit();

    const addr = Address.init(0x1234567890);

    // Mock callbacks - minimal set for this test
    var mock_ctx: u32 = 0;
    const callbacks = Callbacks{
        .ctx = @ptrCast(&mock_ctx),
        .lookupPeer = struct {
            fn f(_: ?*anyopaque, _: Address) ?*anyopaque {
                return null;
            }
        }.f,
        .sendViaPeer = struct {
            fn f(_: ?*anyopaque, _: *anyopaque, _: *const Packet, _: bool, _: i64, _: i32) void {}
        }.f,
        .peerAddress = struct {
            fn f(_: *anyopaque) Address {
                return Address.init(0);
            }
        }.f,
        .isUpstream = struct {
            fn f(_: ?*anyopaque, _: Address) bool {
                return false;
            }
        }.f,
        .getNetwork = struct {
            fn f(_: ?*anyopaque, _: u64) ?*anyopaque {
                return null;
            }
        }.f,
        .networkHasConfig = struct {
            fn f(_: *anyopaque) bool {
                return false;
            }
        }.f,
        .networkMac = struct {
            fn f(_: *anyopaque) MAC {
                return MAC.init(0);
            }
        }.f,
        .networkId = struct {
            fn f(_: *anyopaque) u64 {
                return 0;
            }
        }.f,
        .networkPermitsBridging = struct {
            fn f(_: *anyopaque, _: Address) bool {
                return false;
            }
        }.f,
        .networkQosEnabled = struct {
            fn f(_: *anyopaque) bool {
                return false;
            }
        }.f,
        .myAddress = struct {
            fn f(_: ?*anyopaque) Address {
                return Address.init(0);
            }
        }.f,
        .macToAddress = struct {
            fn f(_: *const MAC, _: u64) Address {
                return Address.init(0);
            }
        }.f,
        .createPacket = struct {
            fn f(_: Address, _: Address, _: u8) Packet {
                return Packet.init();
            }
        }.f,
        .packetAppendNetworkId = struct {
            fn f(_: *Packet, _: u64) void {}
        }.f,
        .packetAppendEtherType = struct {
            fn f(_: *Packet, _: u16) void {}
        }.f,
        .packetAppendData = struct {
            fn f(_: *Packet, _: [*]const u8, _: u32) void {}
        }.f,
        .packetAppendByte = struct {
            fn f(_: *Packet, _: u8) void {}
        }.f,
        .packetAppendMAC = struct {
            fn f(_: *Packet, _: *const MAC) void {}
        }.f,
        .putFrame = struct {
            fn f(_: ?*anyopaque, _: u64, _: *anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: [*]const u8, _: u32) void {}
        }.f,
        .multicastSend = struct {
            fn f(_: ?*anyopaque, _: *anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: [*]const u8, _: u32, _: bool) void {}
        }.f,
        .pathReceived = struct {
            fn f(_: ?*anyopaque, _: i64, _: *const InetAddress, _: i64) void {}
        }.f,
        .now = struct {
            fn f(_: ?*anyopaque) i64 {
                return 1000;
            }
        }.f,
    };

    // First WHOIS should succeed
    sw.requestWhois(null, 1000, addr, &callbacks);

    // Immediate retry should be throttled (no-op)
    sw.requestWhois(null, 1001, addr, &callbacks);

    // After timeout, should succeed again
    sw.requestWhois(null, 2001, addr, &callbacks);
}

test "Switch: computeFlowId IPv4 TCP" {
    // IPv4 TCP packet with ports
    var data: [40]u8 = undefined;
    data[0] = 0x45; // IPv4, 5-word header
    data[9] = 0x06; // TCP protocol
    data[20] = 0x12; // src port high
    data[21] = 0x34; // src port low
    data[22] = 0x56; // dst port high
    data[23] = 0x78; // dst port low

    const flow_id = Switch.computeFlowId(ethertype_ipv4, &data);
    try testing.expect(flow_id != qos_no_flow);
}

test "Switch: computeFlowId IPv6 UDP" {
    // IPv6 UDP packet
    var data: [60]u8 = undefined;
    @memset(&data, 0);
    data[6] = 0x11; // Next header = UDP
    data[40] = 0xAB; // src port high
    data[41] = 0xCD; // src port low
    data[42] = 0xEF; // dst port high
    data[43] = 0x01; // dst port low

    const flow_id = Switch.computeFlowId(ethertype_ipv6, &data);
    try testing.expect(flow_id != qos_no_flow);
}

test "Switch: computeFlowId unknown protocol" {
    var data: [60]u8 = undefined;
    @memset(&data, 0);

    const flow_id = Switch.computeFlowId(0x9999, &data);
    try testing.expectEqual(qos_no_flow, flow_id);
}

test "Switch: findRXQueueEntry" {
    var sw = try Switch.init(testing.allocator);
    defer sw.deinit();

    const packet_id: u64 = 0x123456789ABCDEF;

    const rq1 = sw.findRXQueueEntry(packet_id);
    rq1.packet_id = packet_id;
    rq1.timestamp = 1000;

    // Should find the same entry
    const rq2 = sw.findRXQueueEntry(packet_id);
    try testing.expect(rq1 == rq2);
    try testing.expectEqual(packet_id, rq2.packet_id);
}

test "Switch: countBits" {
    try testing.expectEqual(@as(u32, 0), Switch.countBits(0));
    try testing.expectEqual(@as(u32, 1), Switch.countBits(1));
    try testing.expectEqual(@as(u32, 1), Switch.countBits(2));
    try testing.expectEqual(@as(u32, 2), Switch.countBits(3));
    try testing.expectEqual(@as(u32, 4), Switch.countBits(0xF));
    try testing.expectEqual(@as(u32, 8), Switch.countBits(0xFF));
    try testing.expectEqual(@as(u32, 32), Switch.countBits(0xFFFFFFFF));
}
