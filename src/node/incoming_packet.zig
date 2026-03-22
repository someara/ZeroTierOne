/// Incoming packet decoder and verb handler dispatch.
///
/// Converted from `node/IncomingPacket.hpp` and `node/IncomingPacket.cpp`.
///
/// An IncomingPacket wraps a mutable `Packet` with receive metadata and
/// provides `tryDecode()` which authenticates, decrypts, decompresses,
/// and dispatches to verb-specific handlers. Each handler returns `true`
/// when processing is complete (success or rejection) or `false` to
/// signal that decoding should be retried later (e.g. awaiting WHOIS).
///
/// All runtime interactions (peer lookup, path operations, topology
/// queries, etc.) are abstracted behind a `Callbacks` struct of function
/// pointers, keeping this module decoupled from concrete runtime types.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const constants = @import("constants.zig");
const c_api = constants.c_api;
const packet = @import("packet.zig");
const Packet = packet.Packet;
const Verb = packet.Verb;
const ErrorCode = packet.ErrorCode;
const CipherSuite = packet.CipherSuite;
const Buffer = @import("buffer.zig").Buffer;
const Address = @import("address.zig").Address;
const MAC = @import("mac.zig").MAC;
const InetAddress = @import("inet_address.zig");
const ecc = @import("ecc.zig");
const Aes = @import("aes.zig").Aes;
const Identity = @import("identity.zig").Identity;
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
const trace = @import("trace.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Sentinel flow ID meaning "no flow-based QoS".
pub const qos_no_flow: i32 = -1;

/// Ethernet type for IPv4 (host byte order).
pub const ethertype_ipv4: u16 = 0x0800;

/// Ethernet type for IPv6 (host byte order).
pub const ethertype_ipv6: u16 = 0x86DD;

// ── Callbacks ─────────────────────────────────────────────────────

/// Function-pointer table for all runtime interactions required by
/// IncomingPacket. The runtime context (`ctx`) is threaded through
/// every call. Peer, path, and network handles are opaque pointers.
pub const Callbacks = struct {
    ctx: ?*anyopaque,
    tptr: ?*anyopaque,

    /// Local node identity (needed for dearmor, address checks, agree).
    local_identity: *const Identity,

    // ── Time ──────────────────────────────────────────────────────

    /// Return the current time in milliseconds.
    now: *const fn (ctx: ?*anyopaque) i64,

    // ── Topology ──────────────────────────────────────────────────

    /// Check if an inbound path should be treated as trusted.
    topologyShouldInboundPathBeTrusted: *const fn (
        ctx: ?*anyopaque,
        path_address: *const InetAddress.InetAddress,
        tpid: u64,
    ) bool,

    /// Look up a peer by address. Returns opaque peer handle or null.
    topologyGetPeer: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        addr: u64,
    ) ?*anyopaque,

    // ── Switch ────────────────────────────────────────────────────

    /// Request WHOIS for an unknown address.
    switchRequestWhois: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        now_val: i64,
        addr: u64,
    ) void,

    // ── Node ──────────────────────────────────────────────────────

    /// Log a verb for statistics.
    nodeStatsLogVerb: *const fn (
        ctx: ?*anyopaque,
        verb_val: u32,
        size_val: u32,
    ) void,

    /// Post an event to the application.
    nodePostEvent: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        event: u32,
        data: ?*const anyopaque,
    ) void,

    // ── Peer ──────────────────────────────────────────────────────

    /// Get the shared symmetric key for this peer (32 bytes).
    peerKey: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) *const [32]u8,

    /// Get AES key pair for this peer, or null if not available.
    peerAesKeys: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) ?*const [2]Aes,

    /// Get AES keys only if the peer supports AES.
    peerAesKeysIfSupported: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) ?*const [2]Aes,

    /// Get peer's public key.
    peerPublicKey: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) *const ecc.Public,

    /// Get peer's ZeroTier address as a u64.
    peerAddress: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) u64,

    /// Notify peer of a received packet.
    peerReceived: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer: ?*anyopaque,
        path: ?*anyopaque,
        hops_val: u32,
        packet_id: u64,
        payload_len: u32,
        verb_val: u32,
        in_re_packet_id: u64,
        in_re_verb: u32,
        trust_established: bool,
        network_id: u64,
        flow_id: i32,
    ) void,

    /// Record an invalid incoming packet for rate limiting.
    peerRecordIncomingInvalidPacket: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        path: ?*anyopaque,
    ) void,

    /// Record an outgoing packet for QoS tracking.
    peerRecordOutgoingPacket: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        path: ?*anyopaque,
        packet_id: u64,
        payload_len: u32,
        verb_val: u32,
        flow_id: i32,
        now_val: i64,
    ) void,

    /// Rate gate for QoS measurement packets.
    peerRateGateQoS: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        now_val: i64,
        path: ?*anyopaque,
    ) bool,

    /// Pass received QoS data to peer.
    peerReceivedQoS: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        path: ?*anyopaque,
        now_val: i64,
        count: u32,
        rx_ids: [*]const u64,
        rx_ts: [*]const u16,
    ) void,

    /// Rate gate for path negotiation requests.
    peerRateGatePathNegotiation: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        now_val: i64,
        path: ?*anyopaque,
    ) bool,

    /// Process an incoming path negotiation request.
    peerProcessIncomingPathNegotiationRequest: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        now_val: i64,
        path: ?*anyopaque,
        remote_utility: i16,
    ) void,

    /// Check if peer supports flow hashing.
    peerFlowHashingSupported: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
    ) bool,

    // ── Path ──────────────────────────────────────────────────────

    /// Send raw data via a path.
    pathSend: *const fn (
        ctx: ?*anyopaque,
        path: ?*anyopaque,
        tptr: ?*anyopaque,
        data: [*]const u8,
        len: u32,
        now_val: i64,
    ) void,

    /// Get the InetAddress of a path.
    pathAddress: *const fn (
        ctx: ?*anyopaque,
        path: ?*anyopaque,
    ) *const InetAddress.InetAddress,

    /// Get the local socket handle of a path.
    pathLocalSocket: *const fn (
        ctx: ?*anyopaque,
        path: ?*anyopaque,
    ) i64,

    /// Rate gate for echo requests on a path.
    pathRateGateEchoRequest: *const fn (
        ctx: ?*anyopaque,
        path: ?*anyopaque,
        now_val: i64,
    ) bool,

    // ── Trace ─────────────────────────────────────────────────────

    /// Log MAC authentication failure.
    traceIncomingPacketMacFailure: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        path: ?*anyopaque,
        packet_id: u64,
        source_addr: u64,
        hops_val: u32,
        reason: [*:0]const u8,
    ) void,

    /// Log invalid incoming packet.
    traceIncomingPacketInvalid: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        path: ?*anyopaque,
        packet_id: u64,
        source_addr: u64,
        hops_val: u32,
        verb_val: u32,
        reason: [*:0]const u8,
    ) void,
};

// ── IncomingPacket ────────────────────────────────────────────────

/// A received packet awaiting decode. Wraps a `Packet` with metadata
/// about receive time, path, and authentication state.
pub const IncomingPacket = struct {
    pkt: Packet,
    receive_time: i64,
    path: ?*anyopaque,
    authenticated: bool,

    const Self = @This();

    /// Create an empty IncomingPacket.
    pub fn initEmpty() Self {
        return .{
            .pkt = Packet.initEmpty(),
            .receive_time = 0,
            .path = null,
            .authenticated = false,
        };
    }

    /// Create an IncomingPacket from raw data.
    pub fn init(
        data: []const u8,
        path: ?*anyopaque,
        now: i64,
    ) !Self {
        return .{
            .pkt = try Packet.initFromData(data),
            .receive_time = now,
            .path = path,
            .authenticated = false,
        };
    }

    /// Re-initialize in place (reuses the existing buffer).
    pub fn reinit(
        self: *Self,
        data: []const u8,
        path: ?*anyopaque,
        now: i64,
    ) !void {
        self.pkt.buf.setSize(0) catch {};
        try self.pkt.buf.copyFrom(data);
        self.receive_time = now;
        self.path = path;
        self.authenticated = false;
    }

    /// Time of packet receipt.
    pub fn receiveTime(self: *const Self) i64 {
        return self.receive_time;
    }

    // ── tryDecode ─────────────────────────────────────────────────

    /// Attempt to decode and process this packet.
    ///
    /// Returns `true` if processing is complete (packet accepted or
    /// rejected). Returns `false` if the caller should retry later
    /// (e.g. awaiting WHOIS response for the source peer).
    pub fn tryDecode(
        self: *Self,
        cb: *const Callbacks,
        flow_id: i32,
    ) bool {
        const source_address = self.pkt.source();

        // Check for trusted paths or unencrypted HELLOs
        const cs = self.pkt.cipher();
        if (cs == .no_crypto_trusted_path) {
            const tpid = self.pkt.trustedPathId();
            const path_addr = cb.pathAddress(cb.ctx, self.path);
            if (cb.topologyShouldInboundPathBeTrusted(cb.ctx, path_addr, tpid)) {
                self.authenticated = true;
            } else {
                cb.traceIncomingPacketMacFailure(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    self.pkt.packetId(),
                    source_address.toInt(),
                    @as(u32, self.pkt.hops()),
                    "path not trusted",
                );
                return true;
            }
        } else if (cs == .c25519_poly1305_none and self.pkt.verb() == .hello) {
            // Only HELLO is allowed in the clear, but still has a MAC.
            // doHELLO is a Chunk 2 handler — stubbed for now.
            return self.doHELLO(cb, false);
        }

        const peer = cb.topologyGetPeer(cb.ctx, cb.tptr, source_address.toInt());
        if (peer) |p| {
            if (!self.authenticated) {
                const peer_key = cb.peerKey(cb.ctx, p);
                const peer_aes = cb.peerAesKeys(cb.ctx, p);
                if (!self.pkt.dearmor(peer_key, peer_aes, &cb.local_identity._private_key)) {
                    cb.traceIncomingPacketMacFailure(
                        cb.ctx,
                        cb.tptr,
                        self.path,
                        self.pkt.packetId(),
                        source_address.toInt(),
                        @as(u32, self.pkt.hops()),
                        "invalid MAC",
                    );
                    cb.peerRecordIncomingInvalidPacket(cb.ctx, p, self.path);
                    return true;
                }
            }

            if (!self.pkt.uncompress()) {
                cb.traceIncomingPacketInvalid(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    self.pkt.packetId(),
                    source_address.toInt(),
                    @as(u32, self.pkt.hops()),
                    @intFromEnum(Verb.nop),
                    "LZ4 decompression failed",
                );
                return true;
            }

            self.authenticated = true;
            const v = self.pkt.verb();

            const r: bool = switch (v) {
                .nop => true, // No-op: nothing to do.
                .hello => self.doHELLO(cb, true),
                .@"error" => self.doERROR(cb, p),
                .ok => self.doOK(cb, p),
                .whois => self.doWHOIS(cb, p),
                .rendezvous => self.doRENDEZVOUS(cb, p),
                .frame => self.doFRAME(cb, p, flow_id),
                .ext_frame => self.doEXT_FRAME(cb, p, flow_id),
                .echo => self.doECHO(cb, p),
                .ack => self.doACK(cb, p),
                .qos_measurement => self.doQosMeasurement(cb, p),
                .multicast_like => self.doMULTICAST_LIKE(cb, p),
                .network_credentials => self.doNETWORK_CREDENTIALS(cb, p),
                .network_config_request => self.doNETWORK_CONFIG_REQUEST(cb, p),
                .network_config => self.doNETWORK_CONFIG(cb, p),
                .multicast_gather => self.doMULTICAST_GATHER(cb, p),
                .multicast_frame => self.doMULTICAST_FRAME(cb, p),
                .push_direct_paths => self.doPUSH_DIRECT_PATHS(cb, p),
                .user_message => self.doUSER_MESSAGE(cb, p),
                .remote_trace => self.doREMOTE_TRACE(cb, p),
                .path_negotiation_request => self.doPATH_NEGOTIATION_REQUEST(cb, p),
                _ => blk: {
                    // Unknown verb — if authenticated, count as received.
                    cb.peerReceived(
                        cb.ctx,
                        cb.tptr,
                        p,
                        self.path,
                        @as(u32, self.pkt.hops()),
                        self.pkt.packetId(),
                        self.pkt.payloadLength(),
                        @intFromEnum(v),
                        0,
                        @intFromEnum(Verb.nop),
                        false,
                        0,
                        qos_no_flow,
                    );
                    break :blk true;
                },
            };

            if (r) {
                cb.nodeStatsLogVerb(cb.ctx, @intFromEnum(v), self.pkt.buf.size());
                return true;
            }
            return false;
        } else {
            // Unknown peer — request WHOIS and retry later.
            cb.switchRequestWhois(
                cb.ctx,
                cb.tptr,
                cb.now(cb.ctx),
                source_address.toInt(),
            );
            return false;
        }
    }

    // ── Simple verb handlers (Chunk 1) ────────────────────────────

    /// ACK handler — currently a no-op (flow control is commented out in C++).
    fn doACK(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        // ACK handling is commented out in C++. Just accept.
        return true;
    }

    /// QoS measurement handler — parses packet ID / timestamp pairs and
    /// passes them to the peer for latency tracking.
    fn doQosMeasurement(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);

        if (!cb.peerRateGateQoS(cb.ctx, peer, now, self.path)) {
            return true;
        }

        const pl = self.pkt.payloadLength();
        if (pl > constants.qos_max_packet_size or pl < constants.qos_min_packet_size) {
            return true;
        }

        var rx_id: [constants.qos_table_size]u64 = undefined;
        var rx_ts: [constants.qos_table_size]u16 = undefined;
        var count: u32 = 0;

        // Each QoS record is 10 bytes: 8 (packet ID) + 2 (timestamp).
        const record_size: u32 = 8 + 2;
        var offset: u32 = packet.idx_payload;
        const end = packet.idx_payload + pl;

        while (offset + record_size <= end and count < constants.qos_table_size) {
            const pkt_id = self.pkt.buf.at(u64, offset) catch break;
            offset += 8;
            const ts = self.pkt.buf.at(u16, offset) catch break;
            offset += 2;
            rx_id[count] = pkt_id;
            rx_ts[count] = ts;
            count += 1;
        }

        if (count > 0) {
            cb.peerReceivedQoS(
                cb.ctx,
                peer,
                self.path,
                now,
                count,
                &rx_id,
                &rx_ts,
            );
        }

        return true;
    }

    /// ECHO handler — reflects payload back in an OK response.
    fn doECHO(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);
        if (!cb.pathRateGateEchoRequest(cb.ctx, self.path, now)) {
            return true;
        }

        const pid = self.pkt.packetId();
        const peer_key = cb.peerKey(cb.ctx, peer);
        const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
        const peer_pub = cb.peerPublicKey(cb.ctx, peer);
        const peer_addr = Address.init(cb.peerAddress(cb.ctx, peer));

        var outp = Packet.initNew(peer_addr, cb.local_identity.address(), .ok);
        outp.buf.appendByte(@intFromEnum(Verb.echo), 1) catch return true;
        outp.buf.appendInt(u64, pid) catch return true;

        // Echo back the payload if present.
        if (self.pkt.buf.size() > packet.idx_payload) {
            const payload_len = self.pkt.buf.size() - packet.idx_payload;
            const payload_data = self.pkt.buf.field(packet.idx_payload, payload_len) catch
                return true;
            outp.buf.appendBytes(payload_data) catch return true;
        }

        outp.armor(peer_key, true, false, peer_aes, peer_pub);
        cb.peerRecordOutgoingPacket(
            cb.ctx,
            peer,
            self.path,
            outp.packetId(),
            outp.payloadLength(),
            @intFromEnum(outp.verb()),
            qos_no_flow,
            now,
        );

        const out_data = outp.buf.data();
        cb.pathSend(cb.ctx, self.path, cb.tptr, out_data.ptr, @intCast(out_data.len), now);

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            pid,
            self.pkt.payloadLength(),
            @intFromEnum(Verb.echo),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// USER_MESSAGE handler — posts user message event to application.
    fn doUSER_MESSAGE(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        if (self.pkt.buf.size() >= (packet.idx_payload + 8)) {
            const type_id = self.pkt.buf.at(u64, packet.idx_payload) catch {
                return true;
            };
            const data_offset = packet.idx_payload + 8;
            const data_len = self.pkt.buf.size() - data_offset;

            // Build ZT_UserMessage on the stack.
            var um: c_api.ZT_UserMessage = .{
                .origin = cb.peerAddress(cb.ctx, peer),
                .typeId = type_id,
                .data = null,
                .length = @intCast(data_len),
            };

            if (data_len > 0) {
                if (self.pkt.buf.field(data_offset, data_len)) |slice| {
                    um.data = @ptrCast(slice.ptr);
                } else |_| {}
            }

            cb.nodePostEvent(
                cb.ctx,
                cb.tptr,
                c_api.ZT_EVENT_USER_MESSAGE,
                @ptrCast(&um),
            );
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.user_message),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// REMOTE_TRACE handler — extracts null-terminated strings and
    /// posts each as a ZT_EVENT_REMOTE_TRACE event.
    fn doREMOTE_TRACE(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const pkt_size = self.pkt.buf.size();
        if (pkt_size > packet.idx_payload) {
            const payload_len = pkt_size - packet.idx_payload;
            const payload_data = self.pkt.buf.field(packet.idx_payload, payload_len) catch
                return true;

            var start: u32 = 0;
            var i: u32 = 0;
            while (i < payload_len) : (i += 1) {
                if (payload_data[i] == 0) {
                    const str_len = i - start;
                    if (str_len > 0 and str_len <= c_api.ZT_MAX_REMOTE_TRACE_SIZE) {
                        var rt: c_api.ZT_RemoteTrace = .{
                            .origin = cb.peerAddress(cb.ctx, peer),
                            .data = @ptrCast(@constCast(payload_data[start..].ptr)),
                            .len = @intCast(str_len),
                        };
                        cb.nodePostEvent(
                            cb.ctx,
                            cb.tptr,
                            c_api.ZT_EVENT_REMOTE_TRACE,
                            @ptrCast(&rt),
                        );
                    }
                    start = i + 1;
                }
            }
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.remote_trace),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// PATH_NEGOTIATION_REQUEST handler — passes remote utility to peer.
    fn doPATH_NEGOTIATION_REQUEST(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);

        if (!cb.peerRateGatePathNegotiation(cb.ctx, peer, now, self.path)) {
            return true;
        }

        // Payload must be exactly 2 bytes (int16_t).
        if (self.pkt.payloadLength() != 2) {
            return true;
        }

        const remote_utility = self.pkt.buf.at(i16, packet.idx_payload) catch return true;
        cb.peerProcessIncomingPathNegotiationRequest(cb.ctx, peer, now, self.path, remote_utility);

        return true;
    }

    /// Send ERROR_NEED_MEMBERSHIP_CERTIFICATE to a peer.
    fn sendErrorNeedCredentials(
        self: *Self,
        cb: *const Callbacks,
        peer: ?*anyopaque,
        nwid: u64,
    ) void {
        const peer_key = cb.peerKey(cb.ctx, peer);
        const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
        const peer_pub = cb.peerPublicKey(cb.ctx, peer);
        const peer_addr = Address.init(cb.peerAddress(cb.ctx, peer));

        var outp = Packet.initNew(
            peer_addr,
            cb.local_identity.address(),
            .@"error",
        );
        outp.buf.appendByte(@intFromEnum(self.pkt.verb()), 1) catch return;
        outp.buf.appendInt(u64, self.pkt.packetId()) catch return;
        outp.buf.appendByte(@intFromEnum(ErrorCode.need_membership_certificate), 1) catch return;
        outp.buf.appendInt(u64, nwid) catch return;
        outp.armor(peer_key, true, false, peer_aes, peer_pub);

        const out_data = outp.buf.data();
        cb.pathSend(
            cb.ctx,
            self.path,
            cb.tptr,
            out_data.ptr,
            @intCast(out_data.len),
            cb.now(cb.ctx),
        );
    }

    // ── Stub handlers (Chunks 2 & 3) ─────────────────────────────
    // These return true (accepted) as stubs. They will be implemented
    // in subsequent chunks.

    fn doHELLO(self: *Self, cb: *const Callbacks, already_authenticated: bool) bool {
        _ = self;
        _ = cb;
        _ = already_authenticated;
        return true; // STUB — Chunk 2
    }

    fn doERROR(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 2
    }

    fn doOK(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 2
    }

    fn doWHOIS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doRENDEZVOUS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doFRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque, flow_id: i32) bool {
        _ = self;
        _ = cb;
        _ = peer;
        _ = flow_id;
        return true; // STUB — Chunk 3
    }

    fn doEXT_FRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque, flow_id: i32) bool {
        _ = self;
        _ = cb;
        _ = peer;
        _ = flow_id;
        return true; // STUB — Chunk 3
    }

    fn doMULTICAST_LIKE(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doNETWORK_CREDENTIALS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doNETWORK_CONFIG_REQUEST(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doNETWORK_CONFIG(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doMULTICAST_GATHER(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doMULTICAST_FRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }

    fn doPUSH_DIRECT_PATHS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        _ = self;
        _ = cb;
        _ = peer;
        return true; // STUB — Chunk 3
    }
};

// ── Shared helpers ────────────────────────────────────────────────

/// Parse an IPv6 packet to find the transport-layer header position and
/// next-header protocol number, skipping extension headers.
///
/// Returns `true` if a valid transport header was found, with `pos` and
/// `proto` updated. Returns `false` if the frame is too short or
/// malformed.
pub fn ipv6GetPayload(
    frame_data: []const u8,
    pos_out: *u32,
    proto_out: *u32,
) bool {
    if (frame_data.len < 40) {
        return false;
    }
    var pos: u32 = 40;
    var proto: u32 = frame_data[6];

    while (pos <= frame_data.len) {
        switch (proto) {
            0, // hop-by-hop options
            43, // routing
            60, // destination options
            135, // mobility
            => {
                if (pos + 8 > frame_data.len) {
                    return false; // truncated extension header
                }
                proto = frame_data[pos];
                pos += (@as(u32, frame_data[pos + 1]) * 8) + 8;
            },
            else => {
                pos_out.* = pos;
                proto_out.* = proto;
                return true;
            },
        }
    }
    return false; // overflow
}

/// Compute a flow hash from an Ethernet frame for QoS flow tracking.
///
/// Examines IPv4/IPv6 headers to extract src/dst port for TCP, UDP,
/// SCTP, and UDPLite, returning `dst_port XOR src_port XOR protocol`.
/// Returns `qos_no_flow` if the frame is not a recognized flow type.
pub fn computeFlowHash(
    frame_data: []const u8,
    ether_type: u16,
) i32 {
    if (ether_type == ethertype_ipv4 and frame_data.len >= 20) {
        const proto: u8 = frame_data[9];
        const header_len: u32 = @as(u32, frame_data[0] & 0x0f) * 4;

        switch (proto) {
            0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                if (frame_data.len > header_len + 4) {
                    const src_port = (@as(u16, frame_data[header_len]) << 8) |
                        @as(u16, frame_data[header_len + 1]);
                    const dst_port = (@as(u16, frame_data[header_len + 2]) << 8) |
                        @as(u16, frame_data[header_len + 3]);
                    return @as(i32, @intCast(dst_port ^ src_port ^ @as(u16, proto)));
                }
            },
            else => {},
        }
    }

    if (ether_type == ethertype_ipv6 and frame_data.len >= 40) {
        var pos: u32 = 0;
        var proto: u32 = 0;
        if (ipv6GetPayload(frame_data, &pos, &proto)) {
            switch (proto) {
                0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                    if (frame_data.len > pos + 4) {
                        const src_port = (@as(u16, frame_data[pos]) << 8) |
                            @as(u16, frame_data[pos + 1]);
                        const dst_port = (@as(u16, frame_data[pos + 2]) << 8) |
                            @as(u16, frame_data[pos + 3]);
                        return @as(i32, @intCast(dst_port ^ src_port ^ @as(u16, @truncate(proto))));
                    }
                },
                else => {},
            }
        }
    }

    return qos_no_flow;
}

// ── Tests ─────────────────────────────────────────────────────────

// Test mock context that records callback invocations.
const TestContext = struct {
    // Tracking fields
    now_value: i64 = 1000000,
    trusted_path: bool = false,
    peer_handle: ?*anyopaque = null,
    whois_requested: bool = false,
    whois_addr: u64 = 0,
    stats_logged: bool = false,
    stats_verb: u32 = 0,
    stats_size: u32 = 0,
    mac_failure_logged: bool = false,
    mac_failure_reason: [64]u8 = [_]u8{0} ** 64,
    invalid_logged: bool = false,
    invalid_reason: [64]u8 = [_]u8{0} ** 64,
    received_count: u32 = 0,
    received_verb: u32 = 0,
    received_flow_id: i32 = 0,
    received_packet_id: u64 = 0,
    received_trust: bool = false,
    invalid_packet_recorded: bool = false,
    qos_rate_ok: bool = true,
    qos_received_count: u32 = 0,
    echo_rate_ok: bool = true,
    path_neg_rate_ok: bool = true,
    path_neg_received: bool = false,
    path_neg_utility: i16 = 0,
    outgoing_recorded: bool = false,
    outgoing_packet_id: u64 = 0,
    outgoing_verb: u32 = 0,
    sent_data_len: u32 = 0,
    event_posted: bool = false,
    event_type: u32 = 0,
    flow_hashing_supported: bool = false,

    // Fixed test data
    test_key: [32]u8 = [_]u8{0x42} ** 32,
    test_identity: Identity = undefined,
    test_aes_keys: ?*const [2]Aes = null,
    test_pub_key: ecc.Public = [_]u8{0} ** 64,
    test_peer_addr: u64 = 0xAABBCCDDEE,
    test_path_addr: InetAddress.InetAddress = InetAddress.InetAddress.zero(),
    test_local_socket: i64 = 42,

    fn getCallbacks(self: *TestContext) Callbacks {
        return .{
            .ctx = @ptrCast(self),
            .tptr = null,
            .local_identity = &self.test_identity,
            .now = &nowCb,
            .topologyShouldInboundPathBeTrusted = &trustedCb,
            .topologyGetPeer = &getPeerCb,
            .switchRequestWhois = &whoisCb,
            .nodeStatsLogVerb = &statsLogCb,
            .nodePostEvent = &postEventCb,
            .peerKey = &peerKeyCb,
            .peerAesKeys = &peerAesCb,
            .peerAesKeysIfSupported = &peerAesSupportedCb,
            .peerPublicKey = &peerPubCb,
            .peerAddress = &peerAddrCb,
            .peerReceived = &peerReceivedCb,
            .peerRecordIncomingInvalidPacket = &peerInvalidCb,
            .peerRecordOutgoingPacket = &peerOutgoingCb,
            .peerRateGateQoS = &peerQoSGateCb,
            .peerReceivedQoS = &peerQoSReceivedCb,
            .peerRateGatePathNegotiation = &peerPathNegGateCb,
            .peerProcessIncomingPathNegotiationRequest = &peerPathNegCb,
            .peerFlowHashingSupported = &peerFlowHashCb,
            .pathSend = &pathSendCb,
            .pathAddress = &pathAddrCb,
            .pathLocalSocket = &pathSocketCb,
            .pathRateGateEchoRequest = &pathEchoGateCb,
            .traceIncomingPacketMacFailure = &traceMacFailCb,
            .traceIncomingPacketInvalid = &traceInvalidCb,
        };
    }

    // ── Callback implementations ──────────────────────────────────

    fn nowCb(ctx: ?*anyopaque) i64 {
        const self = ctxCast(ctx);
        return self.now_value;
    }

    fn trustedCb(ctx: ?*anyopaque, _: *const InetAddress.InetAddress, _: u64) bool {
        const self = ctxCast(ctx);
        return self.trusted_path;
    }

    fn getPeerCb(ctx: ?*anyopaque, _: ?*anyopaque, _: u64) ?*anyopaque {
        const self = ctxCast(ctx);
        return self.peer_handle;
    }

    fn whoisCb(ctx: ?*anyopaque, _: ?*anyopaque, _: i64, addr: u64) void {
        const self = ctxCast(ctx);
        self.whois_requested = true;
        self.whois_addr = addr;
    }

    fn statsLogCb(ctx: ?*anyopaque, verb_val: u32, size_val: u32) void {
        const self = ctxCast(ctx);
        self.stats_logged = true;
        self.stats_verb = verb_val;
        self.stats_size = size_val;
    }

    fn postEventCb(ctx: ?*anyopaque, _: ?*anyopaque, event: u32, _: ?*const anyopaque) void {
        const self = ctxCast(ctx);
        self.event_posted = true;
        self.event_type = event;
    }

    fn peerKeyCb(ctx: ?*anyopaque, _: ?*anyopaque) *const [32]u8 {
        const self = ctxCast(ctx);
        return &self.test_key;
    }

    fn peerAesCb(_: ?*anyopaque, _: ?*anyopaque) ?*const [2]Aes {
        return null;
    }

    fn peerAesSupportedCb(_: ?*anyopaque, _: ?*anyopaque) ?*const [2]Aes {
        return null;
    }

    fn peerPubCb(ctx: ?*anyopaque, _: ?*anyopaque) *const ecc.Public {
        const self = ctxCast(ctx);
        return &self.test_pub_key;
    }

    fn peerAddrCb(ctx: ?*anyopaque, _: ?*anyopaque) u64 {
        const self = ctxCast(ctx);
        return self.test_peer_addr;
    }

    fn peerReceivedCb(
        ctx: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*anyopaque,
        _: u32,
        pkt_id: u64,
        _: u32,
        verb_val: u32,
        _: u64,
        _: u32,
        trust: bool,
        _: u64,
        flow_id: i32,
    ) void {
        const self = ctxCast(ctx);
        self.received_count += 1;
        self.received_verb = verb_val;
        self.received_flow_id = flow_id;
        self.received_packet_id = pkt_id;
        self.received_trust = trust;
    }

    fn peerInvalidCb(ctx: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
        const self = ctxCast(ctx);
        self.invalid_packet_recorded = true;
    }

    fn peerOutgoingCb(
        ctx: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*anyopaque,
        pkt_id: u64,
        _: u32,
        verb_val: u32,
        _: i32,
        _: i64,
    ) void {
        const self = ctxCast(ctx);
        self.outgoing_recorded = true;
        self.outgoing_packet_id = pkt_id;
        self.outgoing_verb = verb_val;
    }

    fn peerQoSGateCb(ctx: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque) bool {
        const self = ctxCast(ctx);
        return self.qos_rate_ok;
    }

    fn peerQoSReceivedCb(
        ctx: ?*anyopaque,
        _: ?*anyopaque,
        _: ?*anyopaque,
        _: i64,
        count: u32,
        _: [*]const u64,
        _: [*]const u16,
    ) void {
        const self = ctxCast(ctx);
        self.qos_received_count = count;
    }

    fn peerPathNegGateCb(ctx: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque) bool {
        const self = ctxCast(ctx);
        return self.path_neg_rate_ok;
    }

    fn peerPathNegCb(ctx: ?*anyopaque, _: ?*anyopaque, _: i64, _: ?*anyopaque, util: i16) void {
        const self = ctxCast(ctx);
        self.path_neg_received = true;
        self.path_neg_utility = util;
    }

    fn peerFlowHashCb(ctx: ?*anyopaque, _: ?*anyopaque) bool {
        const self = ctxCast(ctx);
        return self.flow_hashing_supported;
    }

    fn pathSendCb(ctx: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, len: u32, _: i64) void {
        const self = ctxCast(ctx);
        self.sent_data_len = len;
    }

    fn pathAddrCb(ctx: ?*anyopaque, _: ?*anyopaque) *const InetAddress.InetAddress {
        const self = ctxCast(ctx);
        return &self.test_path_addr;
    }

    fn pathSocketCb(ctx: ?*anyopaque, _: ?*anyopaque) i64 {
        const self = ctxCast(ctx);
        return self.test_local_socket;
    }

    fn pathEchoGateCb(ctx: ?*anyopaque, _: ?*anyopaque, _: i64) bool {
        const self = ctxCast(ctx);
        return self.echo_rate_ok;
    }

    fn traceMacFailCb(ctx: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u32, reason: [*:0]const u8) void {
        const self = ctxCast(ctx);
        self.mac_failure_logged = true;
        const len = mem.len(reason);
        const copy_len = @min(len, self.mac_failure_reason.len - 1);
        @memcpy(self.mac_failure_reason[0..copy_len], reason[0..copy_len]);
        self.mac_failure_reason[copy_len] = 0;
    }

    fn traceInvalidCb(ctx: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u32, _: u32, reason: [*:0]const u8) void {
        const self = ctxCast(ctx);
        self.invalid_logged = true;
        const len = mem.len(reason);
        const copy_len = @min(len, self.invalid_reason.len - 1);
        @memcpy(self.invalid_reason[0..copy_len], reason[0..copy_len]);
        self.invalid_reason[copy_len] = 0;
    }

    fn ctxCast(ctx: ?*anyopaque) *TestContext {
        return @ptrCast(@alignCast(ctx.?));
    }
};

/// Helper: build a minimal valid packet with the given verb, armored
/// with the test key so dearmor succeeds.
fn buildTestPacket(
    source: Address,
    dest: Address,
    verb_val: Verb,
    key: *const [32]u8,
) Packet {
    var pkt = Packet.initNew(dest, source, verb_val);
    // Armor with Salsa20/Poly1305, no encryption (like HELLO).
    pkt.armor(key, true, false, null, null);
    return pkt;
}

test "IncomingPacket: initEmpty" {
    const ip = IncomingPacket.initEmpty();
    try testing.expectEqual(@as(i64, 0), ip.receive_time);
    try testing.expect(ip.path == null);
    try testing.expect(!ip.authenticated);
}

test "IncomingPacket: init from data" {
    const dest = Address.init(0xAABBCCDDEE);
    const src = Address.init(0x1122334455);
    var pkt = Packet.initNew(dest, src, .hello);
    const raw = pkt.buf.data();
    var dummy_path: u8 = 0;

    var ip = try IncomingPacket.init(raw, @ptrCast(&dummy_path), 12345);
    try testing.expectEqual(@as(i64, 12345), ip.receive_time);
    try testing.expect(ip.path != null);
    try testing.expect(!ip.authenticated);
    try testing.expect(ip.pkt.destination().eql(dest));
    try testing.expect(ip.pkt.source().eql(src));
}

test "IncomingPacket: tryDecode trusted path" {
    var tctx = TestContext{};
    tctx.trusted_path = true;
    // Set up a sentinel peer handle.
    var peer_sentinel: u8 = 0xAB;
    tctx.peer_handle = @ptrCast(&peer_sentinel);

    var cb = tctx.getCallbacks();

    // Build a packet with trusted-path cipher suite.
    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    var pkt = Packet.initNew(dest, src, .nop);
    pkt.setTrusted(0x12345678);

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = false,
    };

    const result = ip.tryDecode(&cb, qos_no_flow);
    try testing.expect(result);
    try testing.expect(ip.authenticated);
    try testing.expect(tctx.stats_logged);
}

test "IncomingPacket: tryDecode untrusted path rejected" {
    var tctx = TestContext{};
    tctx.trusted_path = false;

    var cb = tctx.getCallbacks();

    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    var pkt = Packet.initNew(dest, src, .nop);
    pkt.setTrusted(0x12345678);

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = false,
    };

    const result = ip.tryDecode(&cb, qos_no_flow);
    try testing.expect(result); // complete (rejected)
    try testing.expect(tctx.mac_failure_logged);
    try testing.expect(!ip.authenticated);
}

test "IncomingPacket: tryDecode unknown peer requests WHOIS" {
    var tctx = TestContext{};
    tctx.peer_handle = null; // no peer found

    var cb = tctx.getCallbacks();

    // Build a normal (non-trusted, non-HELLO) packet.
    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    var pkt = Packet.initNew(dest, src, .frame);
    // Set cipher to something that won't match trusted path or unencrypted HELLO.
    pkt.setCipher(.c25519_poly1305_salsa2012);

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = false,
    };

    const result = ip.tryDecode(&cb, qos_no_flow);
    try testing.expect(!result); // should retry
    try testing.expect(tctx.whois_requested);
    try testing.expectEqual(src.toInt(), tctx.whois_addr);
}

test "IncomingPacket: tryDecode invalid MAC" {
    var tctx = TestContext{};
    var peer_sentinel: u8 = 0xAB;
    tctx.peer_handle = @ptrCast(&peer_sentinel);
    // Use wrong key so dearmor fails.
    tctx.test_key = [_]u8{0x99} ** 32;

    var cb = tctx.getCallbacks();

    // Build a packet armored with a different key.
    const armor_key: [32]u8 = [_]u8{0x42} ** 32;
    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    var pkt = Packet.initNew(dest, src, .frame);
    pkt.armor(&armor_key, true, false, null, null);

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = false,
    };

    const result = ip.tryDecode(&cb, qos_no_flow);
    try testing.expect(result); // complete (rejected)
    try testing.expect(tctx.mac_failure_logged);
    try testing.expect(tctx.invalid_packet_recorded);
}

test "IncomingPacket: tryDecode successful dearmor dispatches to verb" {
    var tctx = TestContext{};
    var peer_sentinel: u8 = 0xAB;
    tctx.peer_handle = @ptrCast(&peer_sentinel);
    const key: [32]u8 = [_]u8{0x42} ** 32;
    tctx.test_key = key;

    var cb = tctx.getCallbacks();

    // Build and armor a packet.
    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    const pkt = buildTestPacket(src, dest, .ack, &key);

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = false,
    };

    const result = ip.tryDecode(&cb, qos_no_flow);
    try testing.expect(result);
    try testing.expect(ip.authenticated);
    try testing.expect(tctx.stats_logged);
    try testing.expectEqual(@intFromEnum(Verb.ack), tctx.stats_verb);
}

test "IncomingPacket: doQosMeasurement parses records" {
    var tctx = TestContext{};
    tctx.qos_rate_ok = true;

    var cb = tctx.getCallbacks();

    // Build a QoS packet with 3 records: (8-byte ID + 2-byte TS) * 3 = 30 bytes.
    const dest = Address.init(0x1122334455);
    const src = Address.init(0xAABBCCDDEE);
    var pkt = Packet.initNew(dest, src, .qos_measurement);

    // Append 3 QoS records.
    const ids = [_]u64{ 0x1000, 0x2000, 0x3000 };
    const tss = [_]u16{ 100, 200, 300 };
    for (0..3) |i| {
        pkt.buf.appendInt(u64, ids[i]) catch unreachable;
        pkt.buf.appendInt(u16, tss[i]) catch unreachable;
    }

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doQosMeasurement(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expectEqual(@as(u32, 3), tctx.qos_received_count);
}

test "IncomingPacket: doQosMeasurement rate limited" {
    var tctx = TestContext{};
    tctx.qos_rate_ok = false;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .qos_measurement,
    );
    pkt.buf.appendInt(u64, 0x1234) catch unreachable;
    pkt.buf.appendInt(u16, 100) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doQosMeasurement(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expectEqual(@as(u32, 0), tctx.qos_received_count);
}

test "IncomingPacket: doQosMeasurement rejects oversized" {
    var tctx = TestContext{};
    tctx.qos_rate_ok = true;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .qos_measurement,
    );
    // Add more than qos_max_packet_size bytes of payload.
    var big_payload: [1401]u8 = [_]u8{0} ** 1401;
    pkt.buf.appendBytes(&big_payload) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doQosMeasurement(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expectEqual(@as(u32, 0), tctx.qos_received_count);
}

test "IncomingPacket: doECHO sends OK response" {
    var tctx = TestContext{};
    tctx.echo_rate_ok = true;
    tctx.test_peer_addr = 0xAABBCCDDEE;
    tctx.test_identity = Identity.init();

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .echo,
    );
    pkt.buf.appendBytes("echo payload") catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doECHO(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(tctx.outgoing_recorded);
    try testing.expect(tctx.sent_data_len > 0);
    try testing.expect(tctx.received_count > 0);
    try testing.expectEqual(@intFromEnum(Verb.echo), tctx.received_verb);
}

test "IncomingPacket: doECHO rate limited" {
    var tctx = TestContext{};
    tctx.echo_rate_ok = false;

    var cb = tctx.getCallbacks();

    const pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .echo,
    );

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doECHO(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(!tctx.outgoing_recorded);
}

test "IncomingPacket: doUSER_MESSAGE posts event" {
    var tctx = TestContext{};
    tctx.test_peer_addr = 0xAABBCCDDEE;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .user_message,
    );
    // typeId (8 bytes) + data
    pkt.buf.appendInt(u64, 0x1234) catch unreachable;
    pkt.buf.appendBytes("user data") catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doUSER_MESSAGE(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(tctx.event_posted);
    try testing.expectEqual(@as(u32, c_api.ZT_EVENT_USER_MESSAGE), tctx.event_type);
    try testing.expect(tctx.received_count > 0);
}

test "IncomingPacket: doUSER_MESSAGE too short is no-op" {
    var tctx = TestContext{};

    var cb = tctx.getCallbacks();

    // Packet with payload < 8 bytes — no event should be posted.
    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .user_message,
    );
    pkt.buf.appendInt(u32, 0x1234) catch unreachable; // only 4 bytes

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doUSER_MESSAGE(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(!tctx.event_posted);
    try testing.expect(tctx.received_count > 0);
}

test "IncomingPacket: doREMOTE_TRACE posts events" {
    var tctx = TestContext{};
    tctx.test_peer_addr = 0xAABBCCDDEE;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .remote_trace,
    );
    // Append two null-terminated strings.
    pkt.buf.appendBytes("trace msg 1") catch unreachable;
    pkt.buf.appendByte(0, 1) catch unreachable;
    pkt.buf.appendBytes("trace msg 2") catch unreachable;
    pkt.buf.appendByte(0, 1) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doREMOTE_TRACE(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(tctx.event_posted);
    try testing.expectEqual(@as(u32, c_api.ZT_EVENT_REMOTE_TRACE), tctx.event_type);
    try testing.expect(tctx.received_count > 0);
}

test "IncomingPacket: doPATH_NEGOTIATION_REQUEST dispatches" {
    var tctx = TestContext{};
    tctx.path_neg_rate_ok = true;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .path_negotiation_request,
    );
    // Payload: int16 remote utility (big-endian).
    pkt.buf.appendInt(i16, 42) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doPATH_NEGOTIATION_REQUEST(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(tctx.path_neg_received);
    try testing.expectEqual(@as(i16, 42), tctx.path_neg_utility);
}

test "IncomingPacket: doPATH_NEGOTIATION_REQUEST rate limited" {
    var tctx = TestContext{};
    tctx.path_neg_rate_ok = false;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .path_negotiation_request,
    );
    pkt.buf.appendInt(i16, 42) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doPATH_NEGOTIATION_REQUEST(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(!tctx.path_neg_received);
}

test "IncomingPacket: doPATH_NEGOTIATION_REQUEST wrong payload size" {
    var tctx = TestContext{};
    tctx.path_neg_rate_ok = true;

    var cb = tctx.getCallbacks();

    var pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .path_negotiation_request,
    );
    // Wrong payload size — 4 bytes instead of 2.
    pkt.buf.appendInt(u32, 42) catch unreachable;

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    const result = ip.doPATH_NEGOTIATION_REQUEST(&cb, @ptrCast(&tctx));
    try testing.expect(result);
    try testing.expect(!tctx.path_neg_received);
}

test "IncomingPacket: sendErrorNeedCredentials" {
    var tctx = TestContext{};
    tctx.test_peer_addr = 0xAABBCCDDEE;
    tctx.test_identity = Identity.init();

    var cb = tctx.getCallbacks();

    const pkt = Packet.initNew(
        Address.init(0x1122334455),
        Address.init(0xAABBCCDDEE),
        .frame,
    );

    var ip = IncomingPacket{
        .pkt = pkt,
        .receive_time = 1000,
        .path = null,
        .authenticated = true,
    };

    ip.sendErrorNeedCredentials(&cb, @ptrCast(&tctx), 0xDEADBEEF);
    try testing.expect(tctx.sent_data_len > 0);
}

test "IncomingPacket: doACK is no-op" {
    var tctx = TestContext{};
    var cb = tctx.getCallbacks();
    var ip = IncomingPacket.initEmpty();

    const result = ip.doACK(&cb, null);
    try testing.expect(result);
}

// ── Helper function tests ─────────────────────────────────────────

test "ipv6GetPayload: basic TCP" {
    // Minimal IPv6 header (40 bytes): next header = TCP (6).
    var frame: [60]u8 = [_]u8{0} ** 60;
    frame[6] = 6; // next header = TCP
    // Bytes 40..59 = TCP header (20 bytes).

    var pos: u32 = 0;
    var proto: u32 = 0;
    try testing.expect(ipv6GetPayload(&frame, &pos, &proto));
    try testing.expectEqual(@as(u32, 40), pos);
    try testing.expectEqual(@as(u32, 6), proto);
}

test "ipv6GetPayload: with hop-by-hop extension" {
    // IPv6 header with hop-by-hop extension then UDP.
    var frame: [80]u8 = [_]u8{0} ** 80;
    frame[6] = 0; // next header = hop-by-hop
    // Hop-by-hop at offset 40:
    frame[40] = 17; // next header = UDP
    frame[41] = 0; // length = 0 => 8 bytes total
    // UDP at offset 48.

    var pos: u32 = 0;
    var proto: u32 = 0;
    try testing.expect(ipv6GetPayload(&frame, &pos, &proto));
    try testing.expectEqual(@as(u32, 48), pos);
    try testing.expectEqual(@as(u32, 17), proto);
}

test "ipv6GetPayload: too short" {
    var frame: [20]u8 = [_]u8{0} ** 20;
    var pos: u32 = 0;
    var proto: u32 = 0;
    try testing.expect(!ipv6GetPayload(&frame, &pos, &proto));
}

test "computeFlowHash: IPv4 TCP" {
    // Minimal IPv4 header (20 bytes) + TCP ports (4 bytes) + 1 extra byte
    // so that len > headerLen + 4 (the C++ check uses strict >).
    var frame: [25]u8 = [_]u8{0} ** 25;
    frame[0] = 0x45; // version=4, IHL=5 (20 bytes)
    frame[9] = 0x06; // protocol = TCP
    // Source port at offset 20: 1234 (big-endian)
    frame[20] = 0x04;
    frame[21] = 0xD2;
    // Dest port at offset 22: 80 (big-endian)
    frame[22] = 0x00;
    frame[23] = 0x50;

    const result = computeFlowHash(&frame, ethertype_ipv4);
    // Expected: 80 ^ 1234 ^ 6 = 0x50 ^ 0x4D2 ^ 0x06
    const expected: i32 = @intCast(@as(u16, 80) ^ @as(u16, 1234) ^ @as(u16, 6));
    try testing.expectEqual(expected, result);
}

test "computeFlowHash: IPv4 ICMP returns no flow" {
    var frame: [24]u8 = [_]u8{0} ** 24;
    frame[0] = 0x45;
    frame[9] = 0x01; // ICMP

    const result = computeFlowHash(&frame, ethertype_ipv4);
    try testing.expectEqual(qos_no_flow, result);
}

test "computeFlowHash: IPv6 UDP" {
    // IPv6 header (40 bytes) + UDP ports (4 bytes) + 1 extra byte
    // so that len > pos + 4 (the C++ check uses strict >).
    var frame: [45]u8 = [_]u8{0} ** 45;
    frame[0] = 0x60; // version = 6
    frame[6] = 17; // next header = UDP
    // UDP source port at offset 40: 5000
    frame[40] = 0x13;
    frame[41] = 0x88;
    // UDP dest port at offset 42: 53
    frame[42] = 0x00;
    frame[43] = 0x35;

    const result = computeFlowHash(&frame, ethertype_ipv6);
    const expected: i32 = @intCast(@as(u16, 53) ^ @as(u16, 5000) ^ @as(u16, 17));
    try testing.expectEqual(expected, result);
}

test "computeFlowHash: unknown ethertype returns no flow" {
    var frame: [40]u8 = [_]u8{0} ** 40;
    const result = computeFlowHash(&frame, 0x1234);
    try testing.expectEqual(qos_no_flow, result);
}

test "computeFlowHash: IPv4 too short returns no flow" {
    var frame: [10]u8 = [_]u8{0} ** 10;
    const result = computeFlowHash(&frame, ethertype_ipv4);
    try testing.expectEqual(qos_no_flow, result);
}

test "constants: qos_no_flow sentinel" {
    try testing.expectEqual(@as(i32, -1), qos_no_flow);
}
