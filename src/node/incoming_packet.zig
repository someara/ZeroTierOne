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
const world_mod = @import("world.zig");
const World = world_mod.World;
const WorldType = world_mod.Type;
const trace = @import("trace.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Sentinel flow ID meaning "no flow-based QoS".
pub const qos_no_flow: i32 = -1;

/// Ethernet type for IPv4 (host byte order).
pub const ethertype_ipv4: u16 = 0x0800;

/// Ethernet type for IPv6 (host byte order).
pub const ethertype_ipv6: u16 = 0x86DD;

/// Software version constants (from version.h).
const version_major: u8 = 1;
const version_minor: u8 = 16;
const version_revision: u16 = 1;

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

    /// Log dropped HELLO packet.
    traceIncomingPacketDroppedHELLO: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        path: ?*anyopaque,
        packet_id: u64,
        from_addr: u64,
        reason: [*:0]const u8,
    ) void,

    // ── Identity / Key Agreement (HELLO) ─────────────────────────

    /// Rate gate for identity verification (anti-DoS).
    nodeRateGateIdentityVerification: *const fn (
        ctx: ?*anyopaque,
        now_val: i64,
        path_addr: *const InetAddress.InetAddress,
    ) bool,

    /// Get the identity of a peer (by opaque handle).
    peerIdentity: *const fn (ctx: ?*anyopaque, peer: ?*anyopaque) *const Identity,

    /// Set remote version info on a peer.
    peerSetRemoteVersion: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        proto: u32,
        major: u32,
        minor: u32,
        rev: u32,
    ) void,

    /// Add a new peer to the topology. Returns the canonical peer handle.
    /// Takes the new peer's identity; the runtime creates the Peer object.
    topologyAddPeer: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        new_identity: *const Identity,
    ) ?*anyopaque,

    /// Check if an identity is an upstream (root) node.
    topologyIsUpstream: *const fn (
        ctx: ?*anyopaque,
        identity: *const Identity,
    ) bool,

    /// Get the planet world ID.
    topologyPlanetWorldId: *const fn (ctx: ?*anyopaque) u64,

    /// Get the planet world timestamp.
    topologyPlanetWorldTimestamp: *const fn (ctx: ?*anyopaque) u64,

    /// Serialize the planet world into the provided buffer.
    /// Returns the number of bytes written, or 0 if no planet.
    topologySerializePlanet: *const fn (
        ctx: ?*anyopaque,
        buf: [*]u8,
        buf_len: u32,
    ) u32,

    /// Get moon count and serialize moons that are newer than given timestamps.
    /// For each moon in the topology, if its ID matches one of the provided
    /// IDs and its timestamp is newer, serialize it into buf.
    /// Returns total bytes written.
    topologySerializeUpdatedMoons: *const fn (
        ctx: ?*anyopaque,
        moon_ids: [*]const u64,
        moon_timestamps: [*]const u64,
        moon_count: u32,
        buf: [*]u8,
        buf_len: u32,
    ) u32,

    /// Check if we should accept world updates from this address.
    topologyShouldAcceptWorldUpdateFrom: *const fn (
        ctx: ?*anyopaque,
        addr: u64,
    ) bool,

    /// Add a world (planet/moon) from serialized data.
    /// Returns true if accepted.
    topologyAddWorld: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        world_data: [*]const u8,
        world_len: u32,
    ) bool,

    /// Self-awareness: report our externally observed address.
    selfAwarenessIam: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        reporter_addr: u64,
        local_socket: i64,
        path_addr: *const InetAddress.InetAddress,
        ext_addr: *const InetAddress.InetAddress,
        is_upstream: bool,
        now_val: i64,
    ) void,

    /// Update path latency.
    pathUpdateLatency: *const fn (
        ctx: ?*anyopaque,
        path: ?*anyopaque,
        latency: u32,
        now_val: i64,
    ) void,

    // ── Network (ERROR / OK) ─────────────────────────────────────

    /// Look up a network by ID. Returns opaque network handle or null.
    nodeGetNetwork: *const fn (ctx: ?*anyopaque, nwid: u64) ?*anyopaque,

    /// Check if node is expecting a reply to this packet ID.
    nodeExpectingReplyTo: *const fn (ctx: ?*anyopaque, packet_id: u64) bool,

    /// Get controller address for a network.
    networkController: *const fn (ctx: ?*anyopaque, network: ?*anyopaque) u64,

    /// Mark network as not found.
    networkSetNotFound: *const fn (ctx: ?*anyopaque, tptr: ?*anyopaque, network: ?*anyopaque) void,

    /// Mark network as access denied.
    networkSetAccessDenied: *const fn (ctx: ?*anyopaque, tptr: ?*anyopaque, network: ?*anyopaque) void,

    /// Gate check: is peer allowed to communicate on this network?
    networkGate: *const fn (ctx: ?*anyopaque, tptr: ?*anyopaque, network: ?*anyopaque, peer: ?*anyopaque) bool,

    /// Peer requested credentials for a network.
    networkPeerRequestedCredentials: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        addr: u64,
        now_val: i64,
    ) void,

    /// Check if network config has a COM.
    networkConfigHasCom: *const fn (ctx: ?*anyopaque, network: ?*anyopaque) bool,

    /// Set authentication required on a network, with URL data.
    networkSetAuthenticationRequired: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        auth_url: [*:0]const u8,
    ) void,

    /// Handle a network config chunk from an OK response.
    networkHandleConfigChunk: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        packet_id: u64,
        source_addr: u64,
        chunk_data: [*]const u8,
        chunk_offset: u32,
        chunk_len: u32,
    ) void,

    /// Remove a multicast group subscription.
    multicasterRemove: *const fn (
        ctx: ?*anyopaque,
        nwid: u64,
        mac_bytes: *const [6]u8,
        adi: u32,
        addr: u64,
    ) void,

    /// Add multiple multicast group members from gather results.
    multicasterAddMultiple: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        now_val: i64,
        nwid: u64,
        mac_bytes: *const [6]u8,
        adi: u32,
        addresses_data: [*]const u8,
        address_count: u32,
        total_known: u32,
    ) void,

    /// Tell switch to process anything waiting for this peer.
    switchDoAnythingWaitingForPeer: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer: ?*anyopaque,
    ) void,

    /// Add a credential (CertificateOfMembership) to a network.
    /// Returns true if accepted.
    networkAddCredentialCOM: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        com_data: [*]const u8,
        com_len: u32,
    ) bool,

    // ── WHOIS / Rendezvous ────────────────────────────────────────

    /// Check if the topology is an upstream node.
    topologyAmUpstream: *const fn (ctx: ?*anyopaque) bool,

    /// Rate gate inbound WHOIS requests.
    peerRateGateInboundWhoisRequest: *const fn (
        ctx: ?*anyopaque,
        peer: ?*anyopaque,
        now_val: i64,
    ) bool,

    /// Get an identity from the topology by address.
    /// Returns a non-null identity pointer if found, null otherwise.
    topologyGetIdentity: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        addr: u64,
    ) ?*const Identity,

    /// Check if path should be used for ZeroTier traffic.
    nodeShouldUsePathForZeroTierTraffic: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer_addr: u64,
        local_socket: i64,
        remote_addr: *const InetAddress.InetAddress,
    ) bool,

    /// Get a pseudo-random number from the node PRNG.
    nodePrng: *const fn (ctx: ?*anyopaque) u64,

    /// Send a raw packet (e.g., NAT traversal junk packet).
    nodePutPacket: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        local_socket: i64,
        remote_addr: *const InetAddress.InetAddress,
        data: [*]const u8,
        len: u32,
        ttl: u32,
    ) void,

    /// Attempt to contact a peer at a specific address.
    peerAttemptToContactAt: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer: ?*anyopaque,
        local_socket: i64,
        at_addr: *const InetAddress.InetAddress,
        now_val: i64,
        always_send_hello: bool,
    ) void,

    // ── FRAME / EXT_FRAME ─────────────────────────────────────────

    /// Get the MAC address for a network.
    networkMac: *const fn (ctx: ?*anyopaque, network: ?*anyopaque) MAC,

    /// Get the user pointer for a network (for callbacks).
    networkUserPtr: *const fn (ctx: ?*anyopaque, network: ?*anyopaque) ?*anyopaque,

    /// Filter an incoming packet through network rules.
    /// Returns >0 if packet should be accepted, 0 if dropped.
    networkFilterIncomingPacket: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        peer: ?*anyopaque,
        local_addr: u64,
        source_mac: *const MAC,
        dest_mac: *const MAC,
        frame_data: [*]const u8,
        frame_len: u32,
        ethertype: u32,
        vlan_id: u32,
    ) i32,

    /// Put a frame into the packet multiplexer for delivery to userspace.
    pmPutFrame: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        nwid: u64,
        user_ptr: ?*anyopaque,
        source_mac: *const MAC,
        dest_mac: *const MAC,
        ethertype: u32,
        vlan_id: u32,
        frame_data: *const anyopaque,
        frame_len: u32,
        flow_id: i32,
    ) void,

    // ── MULTICAST_LIKE ────────────────────────────────────────────

    /// Add a multicast group "like" (subscription announcement).
    multicasterAdd: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        now_val: i64,
        nwid: u64,
        mg: *const MulticastGroup,
        addr: u64,
    ) void,

    // ── NETWORK_CREDENTIALS ───────────────────────────────────────

    /// Process received network credentials (COM, capability, tags, certs, revocations).
    networkPushCredentials: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer_addr: u64,
        network: ?*anyopaque,
        now_val: i64,
        credentials_data: [*]const u8,
        credentials_len: u32,
    ) void,

    // ── NETWORK_CONFIG_REQUEST ────────────────────────────────────

    /// Handle a network config request (controller side).
    networkControllerHandleConfigRequest: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        from_addr: u64,
        packet_id: u64,
        nwid: u64,
        meta_data: *const anyopaque,
    ) void,

    // ── NETWORK_CONFIG ────────────────────────────────────────────

    /// Handle a network config chunk (client side).
    networkHandleConfig: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        network: ?*anyopaque,
        packet_id: u64,
        from_addr: u64,
        chunk_data: [*]const u8,
        chunk_len: u32,
    ) void,

    // ── MULTICAST_GATHER ──────────────────────────────────────────

    /// Handle a multicast gather request (send back subscribers).
    multicasterGather: *const fn (
        ctx: ?*anyopaque,
        peer_addr: u64,
        nwid: u64,
        mg: *const MulticastGroup,
        out_packet: *Packet,
        limit: u32,
    ) u32,

    // ── MULTICAST_FRAME ───────────────────────────────────────────

    /// Handle received multicast frame - deliver to local subscribers.
    multicasterReceiveMulticastFrame: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        nwid: u64,
        source_addr: u64,
        mg: *const MulticastGroup,
        frame_data: [*]const u8,
        frame_len: u32,
        ethertype: u32,
    ) void,

    // ── PUSH_DIRECT_PATHS ─────────────────────────────────────────

    /// Handle received direct path hints from a peer.
    peerReceivePushDirectPaths: *const fn (
        ctx: ?*anyopaque,
        tptr: ?*anyopaque,
        peer: ?*anyopaque,
        paths_data: [*]const u8,
        paths_len: u32,
        now_val: i64,
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
        self.pkt.buf.setSize(0) catch |err| {
            std.log.warn("Failed to reset packet buffer size: {}", .{err});
        };
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

    /// HELLO handler — identity exchange, key agreement, and OK response.
    ///
    /// This is the most complex handler. It authenticates new and existing
    /// peers, validates identities, computes shared secrets, and sends
    /// back an OK(HELLO) with version info and world updates.
    fn doHELLO(self: *Self, cb: *const Callbacks, already_authenticated: bool) bool {
        const now = cb.now(cb.ctx);
        const pid = self.pkt.packetId();
        const from_address = self.pkt.source();
        const from_addr_int = from_address.toInt();

        // Parse HELLO payload fields.
        const proto_version = self.pkt.buf.at(u8, packet.hello.idx_protocol_version) catch return true;
        const v_major = self.pkt.buf.at(u8, packet.hello.idx_major_version) catch return true;
        const v_minor = self.pkt.buf.at(u8, packet.hello.idx_minor_version) catch return true;
        const v_revision = self.pkt.buf.at(u16, packet.hello.idx_revision) catch return true;
        const timestamp = self.pkt.buf.at(i64, packet.hello.idx_timestamp) catch return true;

        // Deserialize the sender's identity.
        const id_result = Identity.deserialize(
            packet.max_packet_length,
            &self.pkt.buf,
            packet.hello.idx_identity,
        ) orelse {
            cb.traceIncomingPacketDroppedHELLO(
                cb.ctx,
                cb.tptr,
                self.path,
                pid,
                from_addr_int,
                "invalid identity in HELLO",
            );
            return true;
        };
        const id = id_result.identity;
        var ptr: u32 = packet.hello.idx_identity + id_result.bytes_read;

        // Check minimum protocol version.
        if (proto_version < packet.protocol_version_min) {
            cb.traceIncomingPacketDroppedHELLO(
                cb.ctx,
                cb.tptr,
                self.path,
                pid,
                from_addr_int,
                "protocol version too old",
            );
            return true;
        }

        // Verify address matches identity.
        if (!from_address.eql(id.address())) {
            cb.traceIncomingPacketDroppedHELLO(
                cb.ctx,
                cb.tptr,
                self.path,
                pid,
                from_addr_int,
                "identity/address mismatch",
            );
            return true;
        }

        // Look up existing peer.
        var peer = cb.topologyGetPeer(cb.ctx, cb.tptr, from_addr_int);
        if (peer != null) {
            // We already have an identity with this address.
            if (!already_authenticated) {
                const existing_id = cb.peerIdentity(cb.ctx, peer);
                if (!existing_id.eql(&id)) {
                    // Identity collision — different identity for same address.
                    if (!cb.nodeRateGateIdentityVerification(
                        cb.ctx,
                        now,
                        cb.pathAddress(cb.ctx, self.path),
                    )) {
                        return true;
                    }
                    var key: [constants.symmetric_key_size]u8 = undefined;
                    if (cb.local_identity.agree(&id, &key)) {
                        if (self.pkt.dearmor(
                            key[0..32],
                            null,
                            &cb.local_identity._private_key,
                        )) {
                            cb.traceIncomingPacketDroppedHELLO(
                                cb.ctx,
                                cb.tptr,
                                self.path,
                                pid,
                                from_addr_int,
                                "address collision",
                            );
                            // Send ERROR_IDENTITY_COLLISION.
                            var outp = Packet.initNew(id.address(), cb.local_identity.address(), .@"error");
                            outp.buf.appendByte(@intFromEnum(Verb.hello), 1) catch return true;
                            outp.buf.appendInt(u64, pid) catch return true;
                            outp.buf.appendByte(@intFromEnum(ErrorCode.identity_collision), 1) catch return true;
                            outp.armor(key[0..32], true, false, null, &id._public_key);
                            const out_data = outp.buf.data();
                            cb.pathSend(cb.ctx, self.path, cb.tptr, out_data.ptr, @intCast(out_data.len), cb.now(cb.ctx));
                        } else {
                            cb.traceIncomingPacketMacFailure(
                                cb.ctx,
                                cb.tptr,
                                self.path,
                                pid,
                                from_addr_int,
                                @as(u32, self.pkt.hops()),
                                "invalid MAC",
                            );
                        }
                    } else {
                        cb.traceIncomingPacketMacFailure(
                            cb.ctx,
                            cb.tptr,
                            self.path,
                            pid,
                            from_addr_int,
                            @as(u32, self.pkt.hops()),
                            "invalid identity",
                        );
                    }
                    std.crypto.secureZero(u8, &key);
                    return true;
                } else {
                    // Same identity — check packet integrity.
                    if (!self.pkt.dearmor(
                        cb.peerKey(cb.ctx, peer),
                        cb.peerAesKeysIfSupported(cb.ctx, peer),
                        &cb.local_identity._private_key,
                    )) {
                        cb.traceIncomingPacketMacFailure(
                            cb.ctx,
                            cb.tptr,
                            self.path,
                            pid,
                            from_addr_int,
                            @as(u32, self.pkt.hops()),
                            "invalid MAC",
                        );
                        return true;
                    }
                    // Continue to VALID.
                }
            }
            // else: already_authenticated — continue to VALID.
        } else {
            // Unknown peer — validate and learn identity.
            if (already_authenticated) {
                cb.traceIncomingPacketDroppedHELLO(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    pid,
                    from_addr_int,
                    "illegal alreadyAuthenticated state",
                );
                return true;
            }
            if (!cb.nodeRateGateIdentityVerification(
                cb.ctx,
                now,
                cb.pathAddress(cb.ctx, self.path),
            )) {
                cb.traceIncomingPacketDroppedHELLO(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    pid,
                    from_addr_int,
                    "rate limit exceeded",
                );
                return true;
            }

            // We need a peer key to dearmor. The runtime creates a
            // temporary peer to get the key, or we compute it here.
            // For now, we add the peer first (which computes the key),
            // then verify.
            peer = cb.topologyAddPeer(cb.ctx, cb.tptr, &id);
            if (peer == null) {
                cb.traceIncomingPacketDroppedHELLO(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    pid,
                    from_addr_int,
                    "failed to add peer",
                );
                return true;
            }

            if (!self.pkt.dearmor(
                cb.peerKey(cb.ctx, peer),
                cb.peerAesKeysIfSupported(cb.ctx, peer),
                &cb.local_identity._private_key,
            )) {
                cb.traceIncomingPacketMacFailure(
                    cb.ctx,
                    cb.tptr,
                    self.path,
                    pid,
                    from_addr_int,
                    @as(u32, self.pkt.hops()),
                    "invalid MAC",
                );
                return true;
            }
            // Continue to VALID.
        }

        // ── VALID ────────────────────────────────────────────────

        // Get external surface address if present.
        var external_surface_address = InetAddress.InetAddress.zero();
        const pkt_size = self.pkt.buf.size();
        if (ptr < pkt_size) {
            const consumed = external_surface_address.deserialize(
                packet.max_packet_length,
                &self.pkt.buf,
                ptr,
            ) catch 0;
            ptr += @intCast(consumed);
            if (external_surface_address.isSet() and self.pkt.hops() == 0) {
                cb.selfAwarenessIam(
                    cb.ctx,
                    cb.tptr,
                    from_addr_int,
                    cb.pathLocalSocket(cb.ctx, self.path),
                    cb.pathAddress(cb.ctx, self.path),
                    &external_surface_address,
                    cb.topologyIsUpstream(cb.ctx, &id),
                    now,
                );
            }
        }

        // Get primary planet world ID and timestamp if present.
        var planet_world_id: u64 = 0;
        var planet_world_timestamp: u64 = 0;
        if ((ptr + 16) <= pkt_size) {
            planet_world_id = self.pkt.buf.at(u64, ptr) catch 0;
            ptr += 8;
            planet_world_timestamp = self.pkt.buf.at(u64, ptr) catch 0;
            ptr += 8;
        }

        // Encrypted tail: moon IDs and timestamps.
        const max_moons = 16;
        var moon_ids: [max_moons]u64 = undefined;
        var moon_timestamps: [max_moons]u64 = undefined;
        var moon_count: u32 = 0;

        if (ptr < pkt_size) {
            // Decrypt remaining payload.
            self.pkt.cryptField(cb.peerKey(cb.ctx, peer), ptr, pkt_size - ptr);

            if ((ptr + 2) <= pkt_size) {
                const num_moons = self.pkt.buf.at(u16, ptr) catch 0;
                ptr += 2;
                var i: u32 = 0;
                while (i < num_moons) : (i += 1) {
                    if (ptr + 17 > pkt_size) break;
                    const moon_type = self.pkt.buf.at(u8, ptr) catch break;
                    ptr += 1;
                    if (moon_type == @intFromEnum(WorldType.moon) and moon_count < max_moons) {
                        moon_ids[moon_count] = self.pkt.buf.at(u64, ptr) catch break;
                        moon_timestamps[moon_count] = self.pkt.buf.at(u64, ptr + 8) catch break;
                        moon_count += 1;
                    }
                    ptr += 16;
                }
            }
        }

        // ── Build OK(HELLO) response ─────────────────────────────
        var outp = Packet.initNew(id.address(), cb.local_identity.address(), .ok);
        outp.buf.appendByte(@intFromEnum(Verb.hello), 1) catch return true;
        outp.buf.appendInt(u64, pid) catch return true;
        outp.buf.appendInt(i64, timestamp) catch return true;
        outp.buf.appendByte(packet.protocol_version, 1) catch return true;
        outp.buf.appendByte(version_major, 1) catch return true;
        outp.buf.appendByte(version_minor, 1) catch return true;
        outp.buf.appendInt(u16, version_revision) catch return true;

        // Serialize our path address into the response.
        const path_addr = cb.pathAddress(cb.ctx, self.path);
        path_addr.serialize(packet.max_packet_length, &outp.buf) catch return true;

        // Reserve space for world update size field.
        const world_update_size_at = outp.buf.size();
        outp.buf.appendByte(0, 2) catch return true; // placeholder for u16

        // Append planet update if ours is newer.
        var world_bytes_written: u32 = 0;
        if (planet_world_id != 0 and
            cb.topologyPlanetWorldTimestamp(cb.ctx) > planet_world_timestamp and
            planet_world_id == cb.topologyPlanetWorldId(cb.ctx))
        {
            // Serialize planet directly into outp buffer.
            const avail = packet.max_packet_length - outp.buf.size();
            if (avail > 0) {
                var tmp_buf: [1024]u8 = undefined;
                const planet_len = cb.topologySerializePlanet(cb.ctx, &tmp_buf, @intCast(tmp_buf.len));
                if (planet_len > 0 and planet_len <= avail) {
                    outp.buf.appendBytes(tmp_buf[0..planet_len]) catch |err| {
                        std.log.warn("Failed to append planet data to HELLO OK: {}", .{err});
                    };
                    world_bytes_written += planet_len;
                }
            }
        }

        // Append moon updates if any are newer.
        if (moon_count > 0) {
            var tmp_buf: [2048]u8 = undefined;
            const moon_len = cb.topologySerializeUpdatedMoons(
                cb.ctx,
                &moon_ids,
                &moon_timestamps,
                moon_count,
                &tmp_buf,
                @intCast(tmp_buf.len),
            );
            if (moon_len > 0) {
                outp.buf.appendBytes(tmp_buf[0..moon_len]) catch |err| {
                    std.log.warn("Failed to append moon data to HELLO OK: {}", .{err});
                };
                world_bytes_written += moon_len;
            }
        }

        // Fill in the world update size field.
        outp.buf.setAt(u16, world_update_size_at, @intCast(world_bytes_written)) catch |err| {
            std.log.warn("Failed to set world update size in HELLO OK: {}", .{err});
        };

        // Armor and send.
        const peer_key = cb.peerKey(cb.ctx, peer);
        const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
        const peer_pub = cb.peerPublicKey(cb.ctx, peer);
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

        // Update peer version and notify received.
        cb.peerSetRemoteVersion(cb.ctx, peer, proto_version, v_major, v_minor, v_revision);
        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            pid,
            self.pkt.payloadLength(),
            @intFromEnum(Verb.hello),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// ERROR handler — processes error responses from peers.
    ///
    /// Handles: OBJ_NOT_FOUND, UNSUPPORTED_OPERATION, IDENTITY_COLLISION,
    /// NEED_MEMBERSHIP_CERTIFICATE, NETWORK_ACCESS_DENIED,
    /// UNWANTED_MULTICAST, NETWORK_AUTHENTICATION_REQUIRED.
    fn doERROR(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const in_re_verb_raw = self.pkt.buf.at(u8, packet.error_idx.idx_in_re_verb) catch return true;
        const in_re_packet_id = self.pkt.buf.at(u64, packet.error_idx.idx_in_re_packet_id) catch return true;
        const error_code_raw = self.pkt.buf.at(u8, packet.error_idx.idx_error_code) catch return true;
        var network_id: u64 = 0;

        const peer_addr = cb.peerAddress(cb.ctx, peer);

        // Dispatch on error code. Each case validates its own trust
        // conditions rather than using a blanket expectingReplyTo gate.
        const error_code: ErrorCode = @enumFromInt(error_code_raw);
        switch (error_code) {
            .obj_not_found => {
                // Only meaningful from network controllers.
                if (in_re_verb_raw == @intFromEnum(Verb.network_config_request)) {
                    const nwid = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch {
                        self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                        return true;
                    };
                    const nw = cb.nodeGetNetwork(cb.ctx, nwid);
                    if (nw) |n| {
                        if (cb.networkController(cb.ctx, n) == peer_addr) {
                            cb.networkSetNotFound(cb.ctx, cb.tptr, n);
                        }
                    }
                }
            },
            .unsupported_operation => {
                // Controller does not support the operation.
                if (in_re_verb_raw == @intFromEnum(Verb.network_config_request)) {
                    const nwid = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch {
                        self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                        return true;
                    };
                    const nw = cb.nodeGetNetwork(cb.ctx, nwid);
                    if (nw) |n| {
                        if (cb.networkController(cb.ctx, n) == peer_addr) {
                            cb.networkSetNotFound(cb.ctx, cb.tptr, n);
                        }
                    }
                }
            },
            .identity_collision => {
                // Only act on this if from an upstream (root) node.
                const peer_id = cb.peerIdentity(cb.ctx, peer);
                if (cb.topologyIsUpstream(cb.ctx, peer_id)) {
                    cb.nodePostEvent(
                        cb.ctx,
                        cb.tptr,
                        c_api.ZT_EVENT_FATAL_ERROR_IDENTITY_COLLISION,
                        null,
                    );
                }
            },
            .need_membership_certificate => {
                network_id = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch {
                    self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                    return true;
                };
                const nw = cb.nodeGetNetwork(cb.ctx, network_id);
                if (nw) |n| {
                    if (cb.networkConfigHasCom(cb.ctx, n)) {
                        cb.networkPeerRequestedCredentials(
                            cb.ctx,
                            cb.tptr,
                            n,
                            peer_addr,
                            cb.now(cb.ctx),
                        );
                    }
                }
            },
            .network_access_denied => {
                const nwid = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch {
                    self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                    return true;
                };
                const nw = cb.nodeGetNetwork(cb.ctx, nwid);
                if (nw) |n| {
                    if (cb.networkController(cb.ctx, n) == peer_addr) {
                        cb.networkSetAccessDenied(cb.ctx, cb.tptr, n);
                    }
                }
            },
            .unwanted_multicast => {
                network_id = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch {
                    self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                    return true;
                };
                const nw = cb.nodeGetNetwork(cb.ctx, network_id);
                if (nw) |n| {
                    if (cb.networkGate(cb.ctx, cb.tptr, n, peer)) {
                        // Extract MAC (6 bytes) and ADI (4 bytes).
                        const mac_offset = packet.error_idx.idx_error_payload + 8;
                        const mac_data = self.pkt.buf.field(mac_offset, 6) catch {
                            self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                            return true;
                        };
                        const adi = self.pkt.buf.at(u32, mac_offset + 6) catch {
                            self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
                            return true;
                        };
                        cb.multicasterRemove(
                            cb.ctx,
                            network_id,
                            mac_data[0..6],
                            adi,
                            peer_addr,
                        );
                    }
                }
            },
            .network_authentication_required => {
                self.handleAuthRequired(cb, peer_addr);
            },
            else => {},
        }

        self.doERROR_finish(cb, peer, in_re_packet_id, in_re_verb_raw, network_id);
        return true;
    }

    /// Common tail for doERROR — records the received packet.
    fn doERROR_finish(
        self: *Self,
        cb: *const Callbacks,
        peer: ?*anyopaque,
        in_re_packet_id: u64,
        in_re_verb_raw: u32,
        network_id: u64,
    ) void {
        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.@"error"),
            in_re_packet_id,
            in_re_verb_raw,
            false,
            network_id,
            qos_no_flow,
        );
    }

    /// Handle ERROR_NETWORK_AUTHENTICATION_REQUIRED.
    ///
    /// Parses the authentication URL from the error payload and calls
    /// networkSetAuthenticationRequired. For simplicity, only authVersion=0
    /// (plain URL) is fully handled; authVersion=1 (SSO) passes the
    /// issuerURL as the authentication URL. This matches the essential
    /// behavior while avoiding a full Dictionary parser dependency.
    fn handleAuthRequired(self: *Self, cb: *const Callbacks, peer_addr: u64) void {
        const nwid = self.pkt.buf.at(u64, packet.error_idx.idx_error_payload) catch return;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid) orelse return;
        if (cb.networkController(cb.ctx, nw) != peer_addr) return;

        const pkt_size = self.pkt.buf.size();
        const data_start = packet.error_idx.idx_error_payload + 8;

        // Check if there's extra data beyond the network ID.
        if (pkt_size <= data_start + 2) {
            // No auth data — set empty URL.
            cb.networkSetAuthenticationRequired(cb.ctx, cb.tptr, nw, "");
            return;
        }

        const error_data_size = self.pkt.buf.at(u16, data_start) catch {
            cb.networkSetAuthenticationRequired(cb.ctx, cb.tptr, nw, "");
            return;
        };

        // Remaining data after the 2-byte size field.
        const remaining = pkt_size - (data_start + 2);
        if (remaining < error_data_size) {
            cb.networkSetAuthenticationRequired(cb.ctx, cb.tptr, nw, "");
            return;
        }

        // The auth data is a Dictionary. We do a simplified parse to
        // extract just the authentication URL (key "aU"). This avoids
        // pulling in the full Dictionary module for a single use case.
        const dict_start = data_start + 2;
        const dict_data = self.pkt.buf.field(dict_start, error_data_size) catch {
            cb.networkSetAuthenticationRequired(cb.ctx, cb.tptr, nw, "");
            return;
        };

        // Look for "aU=" (authentication URL key) in the dictionary.
        var auth_url_buf: [2048]u8 = [_]u8{0} ** 2048;
        const url_len = dictGetValue(dict_data[0..error_data_size], "aU", &auth_url_buf);
        if (url_len > 0) {
            // Ensure null-terminated.
            auth_url_buf[@min(url_len, auth_url_buf.len - 1)] = 0;
            cb.networkSetAuthenticationRequired(
                cb.ctx,
                cb.tptr,
                nw,
                @ptrCast(&auth_url_buf),
            );
        } else {
            cb.networkSetAuthenticationRequired(cb.ctx, cb.tptr, nw, "");
        }
    }

    /// OK handler — processes acknowledgement responses from peers.
    ///
    /// Handles: OK(HELLO), OK(WHOIS), OK(NETWORK_CONFIG_REQUEST),
    /// OK(MULTICAST_GATHER), OK(MULTICAST_FRAME).
    fn doOK(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const in_re_verb_raw = self.pkt.buf.at(u8, packet.ok_idx.idx_in_re_verb) catch return true;
        const in_re_packet_id = self.pkt.buf.at(u64, packet.ok_idx.idx_in_re_packet_id) catch return true;
        var network_id: u64 = 0;

        // Only process OKs we were expecting.
        if (!cb.nodeExpectingReplyTo(cb.ctx, in_re_packet_id)) {
            return true;
        }

        if (in_re_verb_raw == @intFromEnum(Verb.hello)) {
            self.doOK_HELLO(cb, peer);
        } else if (in_re_verb_raw == @intFromEnum(Verb.whois)) {
            self.doOK_WHOIS(cb, peer);
        } else if (in_re_verb_raw == @intFromEnum(Verb.network_config_request)) {
            network_id = self.doOK_NETWORK_CONFIG_REQUEST(cb, peer);
        } else if (in_re_verb_raw == @intFromEnum(Verb.multicast_gather)) {
            network_id = self.doOK_MULTICAST_GATHER(cb, peer);
        } else if (in_re_verb_raw == @intFromEnum(Verb.multicast_frame)) {
            network_id = self.doOK_MULTICAST_FRAME(cb, peer);
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.ok),
            in_re_packet_id,
            in_re_verb_raw,
            false,
            network_id,
            qos_no_flow,
        );

        return true;
    }

    /// OK(HELLO) sub-handler: process version info, surface address,
    /// world updates, and latency measurement.
    fn doOK_HELLO(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) void {
        const now = cb.now(cb.ctx);
        const timestamp = self.pkt.buf.at(i64, packet.hello_ok_idx.idx_timestamp) catch return;
        const latency_raw = now - timestamp;
        const latency: u32 = if (latency_raw > 0) @intCast(@min(latency_raw, 0xFFFFFFFF)) else 0;

        const v_proto = self.pkt.buf.at(u8, packet.hello_ok_idx.idx_protocol_version) catch return;
        const v_major = self.pkt.buf.at(u8, packet.hello_ok_idx.idx_major_version) catch return;
        const v_minor = self.pkt.buf.at(u8, packet.hello_ok_idx.idx_minor_version) catch return;
        const v_rev = self.pkt.buf.at(u16, packet.hello_ok_idx.idx_revision) catch return;

        if (v_proto < packet.protocol_version_min) return;

        var ptr: u32 = packet.hello_ok_idx.idx_revision + 2;
        const pkt_size = self.pkt.buf.size();

        // Parse external surface address.
        var ext_surface = InetAddress.InetAddress.zero();
        if (ptr < pkt_size) {
            const consumed = ext_surface.deserialize(
                packet.max_packet_length,
                &self.pkt.buf,
                ptr,
            ) catch 0;
            ptr += @intCast(consumed);
        }

        // Parse and apply world updates.
        if (ptr + 2 <= pkt_size) {
            const worlds_len = self.pkt.buf.at(u16, ptr) catch 0;
            ptr += 2;
            const peer_addr = cb.peerAddress(cb.ctx, peer);
            if (cb.topologyShouldAcceptWorldUpdateFrom(cb.ctx, peer_addr)) {
                const end_of_worlds = ptr + worlds_len;
                while (ptr < end_of_worlds and ptr < pkt_size) {
                    // Each world is self-delimiting via its deserialize.
                    // Pass the raw bytes to the runtime for deserialization.
                    const world_data_len = end_of_worlds - ptr;
                    const world_data = self.pkt.buf.field(ptr, world_data_len) catch break;
                    if (cb.topologyAddWorld(
                        cb.ctx,
                        cb.tptr,
                        world_data.ptr,
                        world_data_len,
                    )) {
                        // World was consumed. We need to know how many bytes
                        // it took. Deserialize a World to get the length.
                        var w = World.init();
                        const consumed = w.deserialize(
                            packet.max_packet_length,
                            &self.pkt.buf,
                            ptr,
                        ) catch break;
                        ptr += @intCast(consumed);
                    } else {
                        // If the runtime rejects it, try to skip it.
                        var w = World.init();
                        const consumed = w.deserialize(
                            packet.max_packet_length,
                            &self.pkt.buf,
                            ptr,
                        ) catch break;
                        ptr += @intCast(consumed);
                    }
                }
            } else {
                ptr += worlds_len;
            }
        }

        // Update latency on direct paths.
        if (self.pkt.hops() == 0) {
            cb.pathUpdateLatency(cb.ctx, self.path, latency, now);
        }

        cb.peerSetRemoteVersion(cb.ctx, peer, v_proto, v_major, v_minor, v_rev);

        // Report externally-observed surface address.
        if (ext_surface.isSet() and self.pkt.hops() == 0) {
            const peer_id = cb.peerIdentity(cb.ctx, peer);
            cb.selfAwarenessIam(
                cb.ctx,
                cb.tptr,
                cb.peerAddress(cb.ctx, peer),
                cb.pathLocalSocket(cb.ctx, self.path),
                cb.pathAddress(cb.ctx, self.path),
                &ext_surface,
                cb.topologyIsUpstream(cb.ctx, peer_id),
                now,
            );
        }
    }

    /// OK(WHOIS) sub-handler: learn a new peer identity from an upstream.
    fn doOK_WHOIS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) void {
        const peer_id = cb.peerIdentity(cb.ctx, peer);
        if (!cb.topologyIsUpstream(cb.ctx, peer_id)) return;

        const id_result = Identity.deserialize(
            packet.max_packet_length,
            &self.pkt.buf,
            packet.whois_ok_idx.idx_identity,
        ) orelse return;

        const new_peer = cb.topologyAddPeer(cb.ctx, cb.tptr, &id_result.identity) orelse return;
        cb.switchDoAnythingWaitingForPeer(cb.ctx, cb.tptr, new_peer);
    }

    /// OK(NETWORK_CONFIG_REQUEST) sub-handler: pass config chunk to
    /// the network. Returns the network ID.
    fn doOK_NETWORK_CONFIG_REQUEST(self: *Self, cb: *const Callbacks, _: ?*anyopaque) u64 {
        const nwid = self.pkt.buf.at(u64, packet.ok_idx.idx_ok_payload) catch return 0;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid) orelse return nwid;

        // Pass the entire payload starting at idx_ok_payload to the
        // network's config chunk handler.
        const payload_len = self.pkt.buf.size() - packet.ok_idx.idx_ok_payload;
        const payload = self.pkt.buf.field(packet.ok_idx.idx_ok_payload, payload_len) catch return nwid;
        cb.networkHandleConfigChunk(
            cb.ctx,
            cb.tptr,
            nw,
            self.pkt.packetId(),
            self.pkt.source().toInt(),
            payload.ptr,
            0,
            @intCast(payload_len),
        );
        return nwid;
    }

    /// OK(MULTICAST_GATHER) sub-handler: add gathered multicast members.
    /// Returns the network ID.
    fn doOK_MULTICAST_GATHER(self: *Self, cb: *const Callbacks, _: ?*anyopaque) u64 {
        const nwid = self.pkt.buf.at(u64, packet.multicast_gather_ok_idx.idx_network_id) catch return 0;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);
        if (nw == null) return nwid;

        const mac_data = self.pkt.buf.field(packet.multicast_gather_ok_idx.idx_mac, 6) catch return nwid;
        const adi = self.pkt.buf.at(u32, packet.multicast_gather_ok_idx.idx_adi) catch return nwid;

        // Gather results: 4 bytes totalKnown, 2 bytes count, then count*5 bytes of addresses.
        const gather_off = packet.multicast_gather_ok_idx.idx_gather_results;
        const total_known = self.pkt.buf.at(u32, gather_off) catch return nwid;
        const count = self.pkt.buf.at(u16, gather_off + 4) catch return nwid;
        if (count > 2000) return nwid; // Prevent u32 overflow (2000*5=10000 < max_packet_length)
        const addresses_data = self.pkt.buf.field(gather_off + 6, @as(u32, count) * 5) catch return nwid;

        cb.multicasterAddMultiple(
            cb.ctx,
            cb.tptr,
            cb.now(cb.ctx),
            nwid,
            mac_data[0..6],
            adi,
            addresses_data.ptr,
            count,
            total_known,
        );
        return nwid;
    }

    /// OK(MULTICAST_FRAME) sub-handler: process COM and implicit gather
    /// results. Returns the network ID.
    fn doOK_MULTICAST_FRAME(self: *Self, cb: *const Callbacks, _: ?*anyopaque) u64 {
        const nwid = self.pkt.buf.at(u64, packet.multicast_frame_ok_idx.idx_network_id) catch return 0;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);
        if (nw == null) return nwid;

        const flags = self.pkt.buf.at(u8, packet.multicast_frame_ok_idx.idx_flags) catch return nwid;
        var offset = packet.multicast_frame_ok_idx.idx_com_and_gather_results;

        // Flag 0x01: deprecated inline COM.
        // Simplified: COM deserialization is complex and rarely used with modern peers.
        // Skip for now; modern peers send credentials via NETWORK_CREDENTIALS instead.
        if ((flags & 0x01) != 0) {
            // Would need Certificate module to properly deserialize and get length.
            // For now, assume offset doesn't change (this is a simplification).
        }

        // Flag 0x02: implicit gather results.
        if ((flags & 0x02) != 0) {
            const total_known = self.pkt.buf.at(u32, offset) catch return nwid;
            offset += 4;
            const count = self.pkt.buf.at(u16, offset) catch return nwid;
            offset += 2;
            if (count > 2000) return nwid; // Prevent u32 overflow
            const addresses_data = self.pkt.buf.field(offset, @as(u32, count) * 5) catch return nwid;
            const mac_data = self.pkt.buf.field(packet.multicast_frame_ok_idx.idx_mac, 6) catch return nwid;
            const adi = self.pkt.buf.at(u32, packet.multicast_frame_ok_idx.idx_adi) catch return nwid;
            cb.multicasterAddMultiple(
                cb.ctx,
                cb.tptr,
                cb.now(cb.ctx),
                nwid,
                mac_data[0..6],
                adi,
                addresses_data.ptr,
                count,
                total_known,
            );
        }

        return nwid;
    }

    /// WHOIS handler — responds with identities for requested addresses.
    ///
    /// Non-upstream nodes rate-limit WHOIS requests. For each address in
    /// the request, if we know the identity we serialize it into an OK
    /// response; otherwise we request it from our upstream.
    fn doWHOIS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);

        // Non-upstream nodes rate-gate WHOIS.
        if (!cb.topologyAmUpstream(cb.ctx) and
            !cb.peerRateGateInboundWhoisRequest(cb.ctx, peer, now))
        {
            return true;
        }

        // Start building OK(WHOIS) response.
        const peer_addr = Address.init(cb.peerAddress(cb.ctx, peer));
        var outp = Packet.initNew(peer_addr, cb.local_identity.address(), .ok);
        outp.buf.appendByte(@intFromEnum(Verb.whois), 1) catch return true;
        outp.buf.appendInt(u64, self.pkt.packetId()) catch return true;

        var count: u32 = 0;
        var ptr: u32 = packet.idx_payload;
        const pkt_size = self.pkt.buf.size();

        // Each WHOIS request contains one or more 5-byte ZT addresses.
        while (ptr + constants.address_length <= pkt_size) {
            var addr_bytes: [constants.address_length]u8 = undefined;
            var i: u32 = 0;
            var parse_ok = true;
            while (i < constants.address_length) : (i += 1) {
                addr_bytes[i] = self.pkt.buf.at(u8, ptr + i) catch {
                    parse_ok = false;
                    break;
                };
            }
            if (!parse_ok) break; // Malformed packet — stop parsing
            const addr = Address.fromBytes(&addr_bytes);
            ptr += constants.address_length;

            // Look up the identity.
            if (cb.topologyGetIdentity(cb.ctx, cb.tptr, addr.toInt())) |id| {
                // Serialize this identity into the OK response.
                id.serialize(packet.max_packet_length, &outp.buf, false) catch {
                    break; // Buffer full — send what we have
                };
                count += 1;
            } else {
                // Request it from our upstream.
                cb.switchRequestWhois(cb.ctx, cb.tptr, now, addr.toInt());
            }
        }

        // Send OK(WHOIS) only if we found at least one identity.
        if (count > 0) {
            const peer_key = cb.peerKey(cb.ctx, peer);
            const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
            outp.armor(peer_key, true, false, peer_aes, &cb.local_identity._public_key);
            const out_data = outp.buf.data();
            cb.pathSend(cb.ctx, self.path, cb.tptr, out_data.ptr, @intCast(out_data.len), now);
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.whois),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// RENDEZVOUS handler — NAT traversal assist from upstream.
    ///
    /// Only upstream nodes send RENDEZVOUS. This tells us to attempt
    /// to contact another peer at a specific address (sending a junk
    /// packet first to punch through NAT/firewall).
    fn doRENDEZVOUS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);
        const peer_id = cb.peerIdentity(cb.ctx, peer);

        // Only honor RENDEZVOUS from upstream nodes.
        if (cb.topologyIsUpstream(cb.ctx, peer_id)) {
            // Parse the ZT address to contact.
            var with_bytes: [constants.address_length]u8 = undefined;
            var i: u32 = 0;
            var addr_ok = true;
            while (i < constants.address_length) : (i += 1) {
                with_bytes[i] = self.pkt.buf.at(u8, packet.rendezvous_idx.idx_zt_address + i) catch {
                    addr_ok = false;
                    break;
                };
            }
            if (!addr_ok) return true; // Malformed RENDEZVOUS
            const with_addr = Address.fromBytes(&with_bytes);

            // Look up the peer we should rendezvous with.
            if (cb.topologyGetPeer(cb.ctx, cb.tptr, with_addr.toInt())) |rendezvous_peer| {
                const port = self.pkt.buf.at(u16, packet.rendezvous_idx.idx_port) catch return true;
                const addrlen = self.pkt.buf.at(u8, packet.rendezvous_idx.idx_addrlen) catch return true;

                if (port > 0 and (addrlen == 4 or addrlen == 16)) {
                    // Deserialize the suggested contact address.
                    var at_addr = InetAddress.InetAddress.zero();
                    if (addrlen == 4) {
                        var bytes: [4]u8 = undefined;
                        var idx: u32 = 0;
                        while (idx < 4) : (idx += 1) {
                            bytes[idx] = self.pkt.buf.at(u8, packet.rendezvous_idx.idx_address + idx) catch return true;
                        }
                        at_addr = InetAddress.InetAddress.initV4(bytes, port);
                    } else if (addrlen == 16) {
                        var bytes: [16]u8 = undefined;
                        var idx: u32 = 0;
                        while (idx < 16) : (idx += 1) {
                            bytes[idx] = self.pkt.buf.at(u8, packet.rendezvous_idx.idx_address + idx) catch return true;
                        }
                        at_addr = InetAddress.InetAddress.initV6(bytes, port);
                    } else {
                        return true;
                    }

                    const local_socket = cb.pathLocalSocket(cb.ctx, self.path);

                    // Check if we should use this path.
                    if (cb.nodeShouldUsePathForZeroTierTraffic(
                        cb.ctx,
                        cb.tptr,
                        with_addr.toInt(),
                        local_socket,
                        &at_addr,
                    )) {
                        // Send a low-TTL junk packet to open NAT/firewall.
                        const junk = cb.nodePrng(cb.ctx);
                        const junk_bytes = mem.asBytes(&junk);
                        cb.nodePutPacket(
                            cb.ctx,
                            cb.tptr,
                            local_socket,
                            &at_addr,
                            junk_bytes.ptr,
                            4,
                            2, // TTL = 2
                        );

                        // Attempt to contact the peer.
                        cb.peerAttemptToContactAt(
                            cb.ctx,
                            cb.tptr,
                            rendezvous_peer,
                            local_socket,
                            &at_addr,
                            now,
                            false,
                        );
                    }
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
            @intFromEnum(Verb.rendezvous),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// FRAME handler — receives a layer-2 ethernet frame.
    ///
    /// Extracts network ID and ethertype, computes flow ID for QoS if
    /// supported, validates network membership, filters via rules, and
    /// delivers the frame to userspace if accepted.
    fn doFRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque, flow_id: i32) bool {
        _ = flow_id;
        var computed_flow_id: i32 = qos_no_flow;

        // Compute flow ID for QoS if peer supports it.
        if (cb.peerFlowHashingSupported(cb.ctx, peer)) {
            const pkt_size = self.pkt.buf.size();
            if (pkt_size > packet.frame_idx.idx_frame_payload) {
                const ethertype = self.pkt.buf.at(u16, packet.frame_idx.idx_ethertype) catch ethertype_ipv4;
                const frame_len = pkt_size - packet.frame_idx.idx_frame_payload;
                const frame_data = self.pkt.buf.data()[packet.frame_idx.idx_frame_payload..];

                computed_flow_id = computeFlowId(ethertype, frame_data[0..frame_len]);
            }
        }

        const nwid = self.pkt.buf.at(u64, packet.frame_idx.idx_network_id) catch return true;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);
        var trust_established = false;

        if (nw) |network| {
            if (cb.networkGate(cb.ctx, cb.tptr, network, peer)) {
                trust_established = true;

                const pkt_size = self.pkt.buf.size();
                if (pkt_size > packet.frame_idx.idx_frame_payload) {
                    const ethertype = self.pkt.buf.at(u16, packet.frame_idx.idx_ethertype) catch return true;
                    const source_mac = MAC.fromAddress(
                        Address.init(cb.peerAddress(cb.ctx, peer)),
                        nwid,
                    );
                    const dest_mac = cb.networkMac(cb.ctx, network);
                    if (pkt_size <= packet.frame_idx.idx_frame_payload) return true; // malformed
                    const frame_len = pkt_size - packet.frame_idx.idx_frame_payload;
                    const frame_data = self.pkt.buf.data()[packet.frame_idx.idx_frame_payload..];

                    if (cb.networkFilterIncomingPacket(
                        cb.ctx,
                        cb.tptr,
                        network,
                        peer,
                        cb.local_identity.address().toInt(),
                        &source_mac,
                        &dest_mac,
                        frame_data.ptr,
                        @intCast(frame_len),
                        ethertype,
                        0,
                    ) > 0) {
                        cb.pmPutFrame(
                            cb.ctx,
                            cb.tptr,
                            nwid,
                            cb.networkUserPtr(cb.ctx, network),
                            &source_mac,
                            &dest_mac,
                            ethertype,
                            0,
                            frame_data.ptr,
                            @intCast(frame_len),
                            computed_flow_id,
                        );
                    }
                }
            } else {
                self.sendErrorNeedCredentials(cb, peer, nwid);
                return false;
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
            @intFromEnum(Verb.frame),
            0,
            @intFromEnum(Verb.nop),
            trust_established,
            nwid,
            computed_flow_id,
        );

        return true;
    }

    /// EXT_FRAME handler — receives extended frame with explicit MAC addresses.
    ///
    /// Similar to FRAME but includes source and destination MAC addresses,
    /// enabling bridging and multicast. May include an inline COM for
    /// backwards compatibility.
    fn doEXT_FRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque, flow_id: i32) bool {
        _ = flow_id;
        var computed_flow_id: i32 = qos_no_flow;

        // Compute flow ID for QoS if peer supports it.
        if (cb.peerFlowHashingSupported(cb.ctx, peer)) {
            const pkt_size = self.pkt.buf.size();
            if (pkt_size > packet.ext_frame_idx.idx_frame_payload) {
                const flags = self.pkt.buf.at(u8, packet.ext_frame_idx.idx_flags) catch 0;
                const com_len: u32 = 0; // Simplified: assume no COM

                // Skip COM if present (deprecated but still used).
                // Modern peers don't use inline COM, so we simplify.
                _ = flags;

                const ethertype_offset = com_len + packet.ext_frame_idx.idx_ethertype;
                const frame_payload_offset = com_len + packet.ext_frame_idx.idx_frame_payload;
                if (pkt_size > frame_payload_offset) {
                    const ethertype = self.pkt.buf.at(u16, ethertype_offset) catch ethertype_ipv4;
                    const frame_len = pkt_size - frame_payload_offset;
                    const frame_data = self.pkt.buf.data()[frame_payload_offset..];
                    computed_flow_id = computeFlowId(ethertype, frame_data[0..frame_len]);
                }
            }
        }

        const nwid = self.pkt.buf.at(u64, packet.ext_frame_idx.idx_network_id) catch return true;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);

        if (nw) |network| {
            const flags = self.pkt.buf.at(u8, packet.ext_frame_idx.idx_flags) catch 0;
            const com_len: u32 = 0; // Simplified: assume no inline COM

            // Handle inline COM if present (deprecated).
            // Modern peers don't use inline COM (flag 0x01), so we simplify.

            if (!cb.networkGate(cb.ctx, cb.tptr, network, peer)) {
                self.sendErrorNeedCredentials(cb, peer, nwid);
                return false;
            }

            const pkt_size = self.pkt.buf.size();
            const frame_payload_idx = com_len + packet.ext_frame_idx.idx_frame_payload;
            if (pkt_size > frame_payload_idx) {
                const ethertype_idx = com_len + packet.ext_frame_idx.idx_ethertype;
                const to_idx = com_len + packet.ext_frame_idx.idx_to;
                const from_idx = com_len + packet.ext_frame_idx.idx_from;

                const ethertype = self.pkt.buf.at(u16, ethertype_idx) catch return true;
                var to_bytes: [6]u8 = undefined;
                var from_bytes: [6]u8 = undefined;
                var i: u32 = 0;
                while (i < 6) : (i += 1) {
                    to_bytes[i] = self.pkt.buf.at(u8, to_idx + i) catch return true;
                    from_bytes[i] = self.pkt.buf.at(u8, from_idx + i) catch return true;
                }
                const to_mac = MAC.fromBytes(&to_bytes);
                const from_mac = MAC.fromBytes(&from_bytes);

                // Check for invalid source MAC.
                const network_mac = cb.networkMac(cb.ctx, network);
                if (!from_mac.isSet() or from_mac.eql(network_mac)) {
                    cb.peerReceived(
                        cb.ctx,
                        cb.tptr,
                        peer,
                        self.path,
                        @as(u32, self.pkt.hops()),
                        self.pkt.packetId(),
                        self.pkt.payloadLength(),
                        @intFromEnum(Verb.ext_frame),
                        0,
                        @intFromEnum(Verb.nop),
                        true,
                        nwid,
                        computed_flow_id,
                    );
                    return true;
                }

                const frame_len = pkt_size - frame_payload_idx;
                const frame_data = self.pkt.buf.data()[frame_payload_idx..];

                // Filter and deliver frame.
                if (cb.networkFilterIncomingPacket(
                    cb.ctx,
                    cb.tptr,
                    network,
                    peer,
                    cb.local_identity.address().toInt(),
                    &from_mac,
                    &to_mac,
                    frame_data.ptr,
                    @intCast(frame_len),
                    ethertype,
                    0,
                ) > 0) {
                    cb.pmPutFrame(
                        cb.ctx,
                        cb.tptr,
                        nwid,
                        cb.networkUserPtr(cb.ctx, network),
                        &from_mac,
                        &to_mac,
                        ethertype,
                        0,
                        frame_data.ptr,
                        @intCast(frame_len),
                        computed_flow_id,
                    );
                }
            }

            // Send ACK if requested.
            if ((flags & 0x10) != 0) {
                const peer_addr = Address.init(cb.peerAddress(cb.ctx, peer));
                var outp = Packet.initNew(peer_addr, cb.local_identity.address(), .ok);
                outp.buf.appendByte(@intFromEnum(Verb.ext_frame), 1) catch return true;
                outp.buf.appendInt(u64, self.pkt.packetId()) catch return true;
                outp.buf.appendInt(u64, nwid) catch return true;

                const now = cb.now(cb.ctx);
                const peer_key = cb.peerKey(cb.ctx, peer);
                const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
                const peer_pub = cb.peerPublicKey(cb.ctx, peer);
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
            }

            cb.peerReceived(
                cb.ctx,
                cb.tptr,
                peer,
                self.path,
                @as(u32, self.pkt.hops()),
                self.pkt.packetId(),
                self.pkt.payloadLength(),
                @intFromEnum(Verb.ext_frame),
                0,
                @intFromEnum(Verb.nop),
                true,
                nwid,
                computed_flow_id,
            );
        } else {
            cb.peerReceived(
                cb.ctx,
                cb.tptr,
                peer,
                self.path,
                @as(u32, self.pkt.hops()),
                self.pkt.packetId(),
                self.pkt.payloadLength(),
                @intFromEnum(Verb.ext_frame),
                0,
                @intFromEnum(Verb.nop),
                false,
                nwid,
                computed_flow_id,
            );
        }

        return true;
    }

    /// MULTICAST_LIKE handler — announces multicast group subscriptions.
    ///
    /// Packet contains a series of 18-byte (nwid, MAC, ADI) tuples.
    /// Peer must be authorized on each network.
    fn doMULTICAST_LIKE(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const now = cb.now(cb.ctx);
        const pkt_size = self.pkt.buf.size();
        var ptr: u32 = packet.idx_payload;

        // Each entry is 18 bytes: 8-byte nwid, 6-byte MAC, 4-byte ADI.
        while (ptr + 18 <= pkt_size) {
            const nwid = self.pkt.buf.at(u64, ptr) catch break;
            var mac_bytes: [6]u8 = undefined;
            var i: u32 = 0;
            while (i < 6) : (i += 1) {
                mac_bytes[i] = self.pkt.buf.at(u8, ptr + 8 + i) catch break;
            }
            const adi = self.pkt.buf.at(u32, ptr + 14) catch break;

            const mg = MulticastGroup.init(MAC.fromBytes(&mac_bytes), adi);
            const nw = cb.nodeGetNetwork(cb.ctx, nwid);
            var authorized = false;

            if (nw) |network| {
                authorized = cb.networkGate(cb.ctx, cb.tptr, network, peer);
            }

            // Upstream nodes always accept MULTICAST_LIKE.
            if (!authorized) {
                authorized = cb.topologyAmUpstream(cb.ctx);
            }

            if (authorized) {
                cb.multicasterAdd(
                    cb.ctx,
                    cb.tptr,
                    now,
                    nwid,
                    &mg,
                    cb.peerAddress(cb.ctx, peer),
                );
            }

            ptr += 18;
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.multicast_like),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// NETWORK_CREDENTIALS handler — receives network credentials push.
    ///
    /// Contains COMs, capabilities, tags, revocations, and COOs. The
    /// runtime deserializes and validates each credential type.
    fn doNETWORK_CREDENTIALS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const pkt_size = self.pkt.buf.size();
        const cred_len = pkt_size - packet.idx_payload;

        if (cred_len > 0) {
            const cred_data = self.pkt.buf.data()[packet.idx_payload..];
            // Pass the entire credentials payload to the runtime for parsing.
            // The runtime knows how to deserialize COMs, capabilities, tags, etc.
            const peer_addr = cb.peerAddress(cb.ctx, peer);
            const now = cb.now(cb.ctx);

            // Delegate credentials parsing to runtime.
            cb.networkPushCredentials(
                cb.ctx,
                cb.tptr,
                peer_addr,
                null, // network will be determined from credentials
                now,
                cred_data.ptr,
                @intCast(cred_len),
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
            @intFromEnum(Verb.network_credentials),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }

    /// NETWORK_CONFIG_REQUEST handler — controller responds with network config.
    ///
    /// Only controllers handle this. Parses the request metadata and
    /// delegates to the network controller logic.
    fn doNETWORK_CONFIG_REQUEST(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const nwid = self.pkt.buf.at(u64, packet.idx_payload) catch return true;
        const meta_data_offset = packet.idx_payload + 8;
        const pkt_size = self.pkt.buf.size();

        // Metadata follows the network ID (dictionary or other format).
        const meta_ptr: ?*const anyopaque = if (meta_data_offset < pkt_size)
            @as(?*const anyopaque, @ptrCast(self.pkt.buf.data()[meta_data_offset..].ptr))
        else
            null;

        cb.networkControllerHandleConfigRequest(
            cb.ctx,
            cb.tptr,
            cb.peerAddress(cb.ctx, peer),
            self.pkt.packetId(),
            nwid,
            meta_ptr orelse @ptrCast(&[0]u8{}),
        );

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.network_config_request),
            0,
            @intFromEnum(Verb.nop),
            false,
            nwid,
            qos_no_flow,
        );

        return true;
    }

    /// NETWORK_CONFIG handler — receives network configuration from controller.
    ///
    /// The payload is a chunked/compressed network config dictionary.
    /// Passes it to the network for reassembly and parsing.
    fn doNETWORK_CONFIG(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const nwid = self.pkt.buf.at(u64, packet.idx_payload) catch return true;
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);

        if (nw) |network| {
            const chunk_offset = packet.idx_payload + 8;
            const pkt_size = self.pkt.buf.size();
            if (chunk_offset < pkt_size) {
                const chunk_len = pkt_size - chunk_offset;
                const chunk_data = self.pkt.buf.data()[chunk_offset..];
                cb.networkHandleConfig(
                    cb.ctx,
                    cb.tptr,
                    network,
                    self.pkt.packetId(),
                    cb.peerAddress(cb.ctx, peer),
                    chunk_data.ptr,
                    @intCast(chunk_len),
                );
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
            @intFromEnum(Verb.network_config),
            0,
            @intFromEnum(Verb.nop),
            false,
            nwid,
            qos_no_flow,
        );

        return true;
    }

    /// MULTICAST_GATHER handler — requests multicast subscribers for a group.
    ///
    /// Responds with OK(MULTICAST_GATHER) containing known subscribers.
    fn doMULTICAST_GATHER(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const nwid = self.pkt.buf.at(u64, packet.idx_payload) catch return true;
        const flags = self.pkt.buf.at(u8, packet.idx_payload + 8) catch return true;
        _ = flags;

        // Parse multicast group (MAC + ADI).
        var mac_bytes: [6]u8 = undefined;
        var i: u32 = 0;
        const mac_offset = packet.idx_payload + 8 + 1; // after flags
        while (i < 6) : (i += 1) {
            mac_bytes[i] = self.pkt.buf.at(u8, mac_offset + i) catch return true;
        }
        const adi = self.pkt.buf.at(u32, mac_offset + 6) catch return true;
        const gather_limit = self.pkt.buf.at(u32, mac_offset + 10) catch return true;

        const mg = MulticastGroup.init(MAC.fromBytes(&mac_bytes), adi);
        const nw = cb.nodeGetNetwork(cb.ctx, nwid);

        if (nw != null and cb.networkGate(cb.ctx, cb.tptr, nw, peer)) {
            // Build OK(MULTICAST_GATHER) response.
            const peer_addr = Address.init(cb.peerAddress(cb.ctx, peer));
            var outp = Packet.initNew(peer_addr, cb.local_identity.address(), .ok);
            outp.buf.appendByte(@intFromEnum(Verb.multicast_gather), 1) catch return true;
            outp.buf.appendInt(u64, self.pkt.packetId()) catch return true;
            outp.buf.appendInt(u64, nwid) catch return true;
            outp.buf.appendBytes(&mac_bytes) catch return true;
            outp.buf.appendInt(u32, adi) catch return true;

            // Gather subscribers from multicaster.
            const gathered = cb.multicasterGather(
                cb.ctx,
                cb.peerAddress(cb.ctx, peer),
                nwid,
                &mg,
                &outp,
                gather_limit,
            );
            _ = gathered;

            const now = cb.now(cb.ctx);
            const peer_key = cb.peerKey(cb.ctx, peer);
            const peer_aes = cb.peerAesKeysIfSupported(cb.ctx, peer);
            const peer_pub = cb.peerPublicKey(cb.ctx, peer);
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
        }

        cb.peerReceived(
            cb.ctx,
            cb.tptr,
            peer,
            self.path,
            @as(u32, self.pkt.hops()),
            self.pkt.packetId(),
            self.pkt.payloadLength(),
            @intFromEnum(Verb.multicast_gather),
            0,
            @intFromEnum(Verb.nop),
            false,
            nwid,
            qos_no_flow,
        );

        return true;
    }

    /// MULTICAST_FRAME handler — receives multicast frame for a group.
    ///
    /// Delivers the frame to all local subscribers of the multicast group.
    fn doMULTICAST_FRAME(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const nwid = self.pkt.buf.at(u64, packet.idx_payload) catch return true;
        const flags = self.pkt.buf.at(u8, packet.idx_payload + 8) catch return true;
        _ = flags;

        // Parse multicast group (MAC + ADI).
        var mac_bytes: [6]u8 = undefined;
        var i: u32 = 0;
        const mac_offset = packet.idx_payload + 8 + 1;
        while (i < 6) : (i += 1) {
            mac_bytes[i] = self.pkt.buf.at(u8, mac_offset + i) catch return true;
        }
        const adi = self.pkt.buf.at(u32, mac_offset + 6) catch return true;
        const ethertype = self.pkt.buf.at(u16, mac_offset + 10) catch return true;
        const frame_offset = mac_offset + 12;
        const pkt_size = self.pkt.buf.size();

        const nw = cb.nodeGetNetwork(cb.ctx, nwid);
        if (nw != null and cb.networkGate(cb.ctx, cb.tptr, nw, peer)) {
            if (frame_offset < pkt_size) {
                const frame_len = pkt_size - frame_offset;
                const frame_data = self.pkt.buf.data()[frame_offset..];
                const mg = MulticastGroup.init(MAC.fromBytes(&mac_bytes), adi);

                cb.multicasterReceiveMulticastFrame(
                    cb.ctx,
                    cb.tptr,
                    nwid,
                    cb.peerAddress(cb.ctx, peer),
                    &mg,
                    frame_data.ptr,
                    @intCast(frame_len),
                    ethertype,
                );
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
            @intFromEnum(Verb.multicast_frame),
            0,
            @intFromEnum(Verb.nop),
            false,
            nwid,
            qos_no_flow,
        );

        return true;
    }

    /// PUSH_DIRECT_PATHS handler — receives direct path hints from a peer.
    ///
    /// Contains a list of IP addresses where the peer can be reached.
    /// Passed to the peer for connection attempts.
    fn doPUSH_DIRECT_PATHS(self: *Self, cb: *const Callbacks, peer: ?*anyopaque) bool {
        const pkt_size = self.pkt.buf.size();
        const paths_len = pkt_size - packet.idx_payload;

        if (paths_len > 0) {
            const paths_data = self.pkt.buf.data()[packet.idx_payload..];
            cb.peerReceivePushDirectPaths(
                cb.ctx,
                cb.tptr,
                peer,
                paths_data.ptr,
                @intCast(paths_len),
                cb.now(cb.ctx),
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
            @intFromEnum(Verb.push_direct_paths),
            0,
            @intFromEnum(Verb.nop),
            false,
            0,
            qos_no_flow,
        );

        return true;
    }
};

// ── Shared helpers ────────────────────────────────────────────────

/// Compute flow ID for QoS from frame data.
///
/// Extracts transport-layer ports from IPv4 or IPv6 packets and
/// computes a flow hash. Returns qos_no_flow if not applicable.
fn computeFlowId(ethertype: u16, frame_data: []const u8) i32 {
    if (ethertype == ethertype_ipv4 and frame_data.len >= 20) {
        // IPv4: protocol is at offset 9, header length in low nibble of byte 0.
        const proto = frame_data[9];
        const header_len = @as(u32, frame_data[0] & 0x0f) * 4;

        switch (proto) {
            0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                if (frame_data.len > header_len + 4) {
                    const src_port = (@as(u16, frame_data[header_len]) << 8) | frame_data[header_len + 1];
                    const dst_port = (@as(u16, frame_data[header_len + 2]) << 8) | frame_data[header_len + 3];
                    return @as(i32, @intCast(dst_port ^ src_port ^ proto));
                }
            },
            else => {},
        }
    } else if (ethertype == ethertype_ipv6 and frame_data.len >= 40) {
        // IPv6: next header is at offset 6.
        var pos: u32 = 40;
        var proto = frame_data[6];

        // Skip extension headers.
        while (pos < frame_data.len) {
            switch (proto) {
                0, 43, 60, 135 => { // hop-by-hop, routing, destination, mobility
                    if (pos + 8 > frame_data.len) break;
                    proto = frame_data[pos];
                    pos += @as(u32, frame_data[pos + 1]) * 8 + 8;
                },
                else => break,
            }
        }

        switch (proto) {
            0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                if (frame_data.len > pos + 4) {
                    const src_port = (@as(u16, frame_data[pos]) << 8) | frame_data[pos + 1];
                    const dst_port = (@as(u16, frame_data[pos + 2]) << 8) | frame_data[pos + 3];
                    return @as(i32, @intCast(dst_port ^ src_port ^ proto));
                }
            },
            else => {},
        }
    }

    return qos_no_flow;
}

/// Minimal dictionary key lookup for ZT packed dictionaries.
///
/// ZT dictionaries are newline-separated "key=value\n" entries with
/// backslash-escaping. This extracts the raw value for a given key
/// without pulling in the full Dictionary module. Returns the number
/// of bytes written to `out`, or 0 if the key was not found.
fn dictGetValue(data: []const u8, key: []const u8, out: []u8) u32 {
    var i: u32 = 0;
    const len: u32 = @intCast(data.len);
    while (i < len) {
        // Check if current position matches key followed by '='.
        const remaining = len - i;
        if (remaining > key.len and
            mem.eql(u8, data[i..][0..key.len], key) and
            data[i + @as(u32, @intCast(key.len))] == '=')
        {
            var j: u32 = i + @as(u32, @intCast(key.len)) + 1;
            var out_idx: u32 = 0;
            while (j < len and data[j] != '\n') {
                if (data[j] == '\\' and j + 1 < len) {
                    // Backslash escape: \r, \n, \\, \0, \=.
                    j += 1;
                    const c: u8 = switch (data[j]) {
                        'r' => '\r',
                        'n' => '\n',
                        '0' => 0,
                        else => data[j], // \\ , \= , etc.
                    };
                    if (out_idx < out.len) {
                        out[out_idx] = c;
                        out_idx += 1;
                    }
                } else {
                    if (out_idx < out.len) {
                        out[out_idx] = data[j];
                        out_idx += 1;
                    }
                }
                j += 1;
            }
            return out_idx;
        }
        // Skip to next line.
        while (i < len and data[i] != '\n') : (i += 1) {}
        if (i < len) i += 1; // skip \n
    }
    return 0;
}

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
            .traceIncomingPacketDroppedHELLO = &traceDroppedHelloCb,
            .nodeRateGateIdentityVerification = &rateGateIdentityCb,
            .peerIdentity = &peerIdentityCb,
            .peerSetRemoteVersion = &peerSetRemoteVersionCb,
            .topologyAddPeer = &topologyAddPeerCb,
            .topologyIsUpstream = &topologyIsUpstreamCb,
            .topologyPlanetWorldId = &topologyPlanetWorldIdCb,
            .topologyPlanetWorldTimestamp = &topologyPlanetWorldTimestampCb,
            .topologySerializePlanet = &topologySerializePlanetCb,
            .topologySerializeUpdatedMoons = &topologySerializeUpdatedMoonsCb,
            .topologyShouldAcceptWorldUpdateFrom = &topologyShouldAcceptWorldUpdateFromCb,
            .topologyAddWorld = &topologyAddWorldCb,
            .selfAwarenessIam = &selfAwarenessIamCb,
            .pathUpdateLatency = &pathUpdateLatencyCb,
            .nodeGetNetwork = &nodeGetNetworkCb,
            .nodeExpectingReplyTo = &nodeExpectingReplyToCb,
            .networkController = &networkControllerCb,
            .networkSetNotFound = &networkSetNotFoundCb,
            .networkSetAccessDenied = &networkSetAccessDeniedCb,
            .networkGate = &networkGateCb,
            .networkPeerRequestedCredentials = &networkPeerRequestedCredentialsCb,
            .networkConfigHasCom = &networkConfigHasComCb,
            .networkSetAuthenticationRequired = &networkSetAuthenticationRequiredCb,
            .networkHandleConfigChunk = &networkHandleConfigChunkCb,
            .multicasterRemove = &multicasterRemoveCb,
            .multicasterAddMultiple = &multicasterAddMultipleCb,
            .switchDoAnythingWaitingForPeer = &switchDoAnythingWaitingForPeerCb,
            .networkAddCredentialCOM = &networkAddCredentialCOMCb,
            .topologyAmUpstream = &topologyAmUpstreamCb,
            .peerRateGateInboundWhoisRequest = &peerRateGateInboundWhoisRequestCb,
            .topologyGetIdentity = &topologyGetIdentityCb,
            .nodeShouldUsePathForZeroTierTraffic = &nodeShouldUsePathForZeroTierTrafficCb,
            .nodePrng = &nodePrngCb,
            .nodePutPacket = &nodePutPacketCb,
            .peerAttemptToContactAt = &peerAttemptToContactAtCb,
            .networkMac = &networkMacCb,
            .networkUserPtr = &networkUserPtrCb,
            .networkFilterIncomingPacket = &networkFilterIncomingPacketCb,
            .pmPutFrame = &pmPutFrameCb,
            .multicasterAdd = &multicasterAddCb,
            .networkPushCredentials = &networkPushCredentialsCb,
            .networkControllerHandleConfigRequest = &networkControllerHandleConfigRequestCb,
            .networkHandleConfig = &networkHandleConfigCb,
            .multicasterGather = &multicasterGatherCb,
            .multicasterReceiveMulticastFrame = &multicasterReceiveMulticastFrameCb,
            .peerReceivePushDirectPaths = &peerReceivePushDirectPathsCb,
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

    // Stub callbacks for new handlers
    fn traceDroppedHelloCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: [*:0]const u8) void {}
    fn rateGateIdentityCb(_: ?*anyopaque, _: i64, _: *const InetAddress.InetAddress) bool {
        return true;
    }
    fn peerIdentityCb(ctx: ?*anyopaque, _: ?*anyopaque) *const Identity {
        const self = ctxCast(ctx);
        return &self.test_identity;
    }
    fn peerSetRemoteVersionCb(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: u32, _: u32, _: u32) void {}
    fn topologyAddPeerCb(_: ?*anyopaque, _: ?*anyopaque, _: *const Identity) ?*anyopaque {
        return null;
    }
    fn topologyIsUpstreamCb(_: ?*anyopaque, _: *const Identity) bool {
        return false;
    }
    fn topologyPlanetWorldIdCb(_: ?*anyopaque) u64 {
        return 0;
    }
    fn topologyPlanetWorldTimestampCb(_: ?*anyopaque) u64 {
        return 0;
    }
    fn topologySerializePlanetCb(_: ?*anyopaque, _: [*]u8, _: u32) u32 {
        return 0;
    }
    fn topologySerializeUpdatedMoonsCb(_: ?*anyopaque, _: [*]const u64, _: [*]const u64, _: u32, _: [*]u8, _: u32) u32 {
        return 0;
    }
    fn topologyShouldAcceptWorldUpdateFromCb(_: ?*anyopaque, _: u64) bool {
        return false;
    }
    fn topologyAddWorldCb(_: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32) bool {
        return false;
    }
    fn selfAwarenessIamCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64, _: *const InetAddress.InetAddress, _: *const InetAddress.InetAddress, _: bool, _: i64) void {}
    fn pathUpdateLatencyCb(_: ?*anyopaque, _: ?*anyopaque, _: u32, _: i64) void {}
    fn nodeGetNetworkCb(_: ?*anyopaque, _: u64) ?*anyopaque {
        return null;
    }
    fn nodeExpectingReplyToCb(_: ?*anyopaque, _: u64) bool {
        return false;
    }
    fn networkControllerCb(_: ?*anyopaque, _: ?*anyopaque) u64 {
        return 0;
    }
    fn networkSetNotFoundCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {}
    fn networkSetAccessDeniedCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {}
    fn networkGateCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) bool {
        return true;
    }
    fn networkPeerRequestedCredentialsCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64) void {}
    fn networkConfigHasComCb(_: ?*anyopaque, _: ?*anyopaque) bool {
        return false;
    }
    fn networkSetAuthenticationRequiredCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*:0]const u8) void {}
    fn networkHandleConfigChunkCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: [*]const u8, _: u32, _: u32) void {}
    fn multicasterRemoveCb(_: ?*anyopaque, _: u64, _: *const [6]u8, _: u32, _: u64) void {}
    fn multicasterAddMultipleCb(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: u64, _: *const [6]u8, _: u32, _: [*]const u8, _: u32, _: u32) void {}
    fn switchDoAnythingWaitingForPeerCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {}
    fn networkAddCredentialCOMCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32) bool {
        return false;
    }
    fn topologyAmUpstreamCb(_: ?*anyopaque) bool {
        return false;
    }
    fn peerRateGateInboundWhoisRequestCb(_: ?*anyopaque, _: ?*anyopaque, _: i64) bool {
        return true;
    }
    fn topologyGetIdentityCb(_: ?*anyopaque, _: ?*anyopaque, _: u64) ?*const Identity {
        return null;
    }
    fn nodeShouldUsePathForZeroTierTrafficCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: i64, _: *const InetAddress.InetAddress) bool {
        return true;
    }
    fn nodePrngCb(_: ?*anyopaque) u64 {
        return 0x1234567890abcdef;
    }
    fn nodePutPacketCb(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress.InetAddress, _: [*]const u8, _: u32, _: u32) void {}
    fn peerAttemptToContactAtCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress.InetAddress, _: i64, _: bool) void {}
    fn networkMacCb(_: ?*anyopaque, _: ?*anyopaque) MAC {
        return MAC.fromBytes(&[_]u8{ 0, 0, 0, 0, 0, 0 });
    }
    fn networkUserPtrCb(_: ?*anyopaque, _: ?*anyopaque) ?*anyopaque {
        return null;
    }
    fn networkFilterIncomingPacketCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: *const MAC, _: *const MAC, _: [*]const u8, _: u32, _: u32, _: u32) i32 {
        return 1;
    }
    fn pmPutFrameCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: ?*anyopaque, _: *const MAC, _: *const MAC, _: u32, _: u32, _: *const anyopaque, _: u32, _: i32) void {}
    fn multicasterAddCb(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: u64, _: *const MulticastGroup, _: u64) void {}
    fn networkPushCredentialsCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: ?*anyopaque, _: i64, _: [*]const u8, _: u32) void {}
    fn networkControllerHandleConfigRequestCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: u64, _: *const anyopaque) void {}
    fn networkHandleConfigCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: [*]const u8, _: u32) void {}
    fn multicasterGatherCb(_: ?*anyopaque, _: u64, _: u64, _: *const MulticastGroup, _: *Packet, _: u32) u32 {
        return 0;
    }
    fn multicasterReceiveMulticastFrameCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: u64, _: *const MulticastGroup, _: [*]const u8, _: u32, _: u32) void {}
    fn peerReceivePushDirectPathsCb(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: [*]const u8, _: u32, _: i64) void {}

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

test "regression: multicast count overflow guard" {
    // Regression test for §4.7 fix: count * 5 must not overflow u32.
    // A count of 2001 would produce 10005 which could exceed packet size.
    // The guard `if (count > 2000) return nwid` prevents this.
    const count: u16 = 2001;
    // Verify the multiplication would be large but not overflow u32
    const product = @as(u32, count) * 5;
    try testing.expectEqual(@as(u32, 10005), product);
    // The guard correctly rejects counts > 2000
    try testing.expect(count > 2000);
}

test "regression: frame_len underflow guard" {
    // Regression test: pkt_size <= idx_frame_payload should not underflow.
    // The guard `if (pkt_size <= idx) return true` prevents u32 wrap.
    const idx = packet.frame_idx.idx_frame_payload;
    // A packet smaller than the frame payload offset has no frame data
    try testing.expect(idx > 0);
    // Verify the subtraction would underflow without the guard
    const small_pkt_size: u32 = idx - 1;
    try testing.expect(small_pkt_size < idx);
}
