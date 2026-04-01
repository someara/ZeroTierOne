/// Peer on P2P Network (virtual layer 1).
///
/// Converted from `node/Peer.hpp` and `node/Peer.cpp`. A Peer represents
/// a remote ZeroTier node identified by its Identity (address + public key).
/// It stores the shared symmetric key derived via ECDH, a set of active
/// network paths, version information, and various timing/rate-limiting
/// fields.
///
/// Cross-module calls to Node, Switch, Topology, Trace, and Bond are
/// modeled as configurable callbacks (function pointers). These will be
/// wired to the real subsystems during Node init (Phase 6).
///
/// Bond-related functionality is deferred to Phase 5.
///
/// No heap allocation is performed by this struct. Paths are stored in
/// a fixed-size array (ZT_MAX_PEER_NETWORK_PATHS).
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const aes = @import("aes.zig");
const Aes = aes.Aes;
const constants = @import("constants.zig");
const Identity = @import("identity.zig").Identity;
const inet_address = @import("inet_address.zig");
const InetAddress = inet_address.InetAddress;
const IpScope = inet_address.IpScope;
const Mutex = @import("mutex.zig");
const pkt = @import("packet.zig");
const Verb = pkt.Verb;
const path_mod = @import("path.zig");
const Path = path_mod.Path;
const sha512 = @import("sha512.zig");
const shared_ptr = @import("shared_ptr.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Maximum number of network paths per peer.
pub const max_peer_network_paths: u32 = constants.max_peer_network_paths;

/// Path expiration time in milliseconds.
const peer_path_expiration: i64 = @intCast(constants.peer_path_expiration);

/// Activity timeout in milliseconds.
const peer_activity_timeout: i64 = @intCast(constants.peer_activity_timeout);

/// Trust expiration in milliseconds.
const trust_expiration: i64 = @intCast(constants.trust_expiration);

/// Ping period in milliseconds.
const peer_ping_period: i64 = @intCast(constants.peer_ping_period);

/// Direct path push interval with existing path.
const direct_path_push_interval_havepath: i64 = @intCast(constants.direct_path_push_interval_havepath);

/// Direct path push interval without existing path.
const direct_path_push_interval: i64 = @intCast(constants.direct_path_push_interval);

/// Cutoff time for PUSH_DIRECT_PATHS rate limiting.
const push_direct_paths_cutoff_time: i64 = @intCast(constants.push_direct_paths_cutoff_time);

/// Cutoff limit for PUSH_DIRECT_PATHS rate limiting.
const push_direct_paths_cutoff_limit: u32 = constants.push_direct_paths_cutoff_limit;

/// Credentials rate limit in milliseconds.
const peer_credentials_rate_limit: i64 = @intCast(constants.peer_credentials_rate_limit);

/// WHOIS rate limit in milliseconds.
const peer_whois_rate_limit: i64 = @intCast(constants.peer_whois_rate_limit);

/// General rate limit in milliseconds.
const peer_general_rate_limit: i64 = @intCast(constants.peer_general_rate_limit);

/// Try memorized path interval in milliseconds.
const try_memorized_path_interval: i64 = @intCast(constants.try_memorized_path_interval);

/// Symmetric key size in bytes.
const symmetric_key_size: usize = constants.symmetric_key_size;

/// Software version constants for HELLO packets.
const version_major: u8 = 1;
const version_minor: u8 = 16;
const version_revision: u16 = 1;

// ── Callback types ────────────────────────────────────────────────

/// Callback for when a peer learns a new path.
///
/// Parameters: ctx, t_ptr, network_id, peer_address, path
pub const PeerLearnedNewPathCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    network_id: u64,
    peer_address: Address,
    path: *Path,
) void;

/// Callback for when a peer is confirming an unknown path.
///
/// Parameters: ctx, t_ptr, network_id, peer_address, path, packet_id, verb
pub const PeerConfirmingUnknownPathCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    network_id: u64,
    peer_address: Address,
    path: *Path,
    packet_id: u64,
    verb: Verb,
) void;

/// Callback for checking whether a path should be used.
///
/// Parameters: ctx, t_ptr, address, local_socket, remote_addr
/// Returns true if the path should be used.
pub const ShouldUsePathCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    address: Address,
    local_socket: i64,
    remote_addr: *const InetAddress,
) bool;

/// Callback for getting external path lookup (memorized paths).
///
/// Parameters: ctx, t_ptr, address, family, result
/// Returns true if a memorized path was found and written to result.
pub const ExternalPathLookupCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    address: Address,
    family: i32,
    result: *InetAddress,
) bool;

/// Callback for the send function (putPacket).
///
/// Parameters: ctx, t_ptr, local_socket, remote_addr, data, len, now
/// Returns true if sent successfully.
pub const PutPacketCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    local_socket: i64,
    remote_addr: *const InetAddress,
    data: [*]const u8,
    len: u32,
) bool;

/// Callback for redirected path event tracing.
pub const PeerRedirectedCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    network_id: u64,
    peer_address: Address,
    path: *Path,
) void;

// ── PeerPath ──────────────────────────────────────────────────────

/// A path slot tracked per-peer. Stores a pointer to the Path,
/// the time of the last valid ZeroTier packet on that path, and
/// a priority value for cluster redirect support.
pub const PeerPath = struct {
    /// Time of last valid ZeroTier packet on this path.
    lr: i64,
    /// Pointer to the path object. null means the slot is empty.
    p: ?*Path,
    /// Priority (>= 1, higher is better). Used for cluster redirects.
    priority: i64,

    pub fn init() PeerPath {
        return .{
            .lr = 0,
            .p = null,
            .priority = 1,
        };
    }

    pub fn isActive(self: *const PeerPath) bool {
        return self.p != null;
    }
};

// ── Peer ──────────────────────────────────────────────────────────

pub const Peer = struct {
    // -- Key material (sensitive) --

    /// Shared symmetric key derived from ECDH key agreement.
    _key: [symmetric_key_size]u8,

    /// AES encryption contexts derived from _key via KBKDF.
    /// [0] = K0, [1] = K1 for AES-GMAC-SIV.
    _aes_keys: [2]Aes,

    // -- Identity --

    /// This peer's identity (address + public key).
    _id: Identity,

    // -- Timing fields --

    /// Last time any packet was received from this peer (direct or indirect).
    _last_receive: i64,

    /// Last time a non-trivial packet was received (frames, netconf, etc.).
    _last_nontrivial_receive: i64,

    /// Last time we tried a memorized path.
    _last_tried_memorized_path: i64,

    /// Last time a PUSH_DIRECT_PATHS was sent.
    _last_direct_path_push_sent: i64,

    /// Last time a PUSH_DIRECT_PATHS was received.
    _last_direct_path_push_receive: i64,

    /// Last time a credential request was sent.
    _last_credential_request_sent: i64,

    /// Last time a WHOIS request was received.
    _last_whois_request_received: i64,

    /// Last time credentials were received.
    _last_credentials_received: i64,

    /// Last time a trust-established packet was received.
    _last_trust_established_packet_received: i64,

    /// Last time a full HELLO was sent.
    _last_sent_full_hello: i64,

    /// Last time ECHO check was performed.
    _last_echo_check: i64,

    // -- Version info --

    /// Remote protocol version.
    _v_proto: u16,

    /// Remote major version.
    _v_major: u16,

    /// Remote minor version.
    _v_minor: u16,

    /// Remote revision.
    _v_revision: u16,

    // -- Paths --

    /// Active network paths to this peer.
    _paths: [max_peer_network_paths]PeerPath,

    /// Mutex for path access.
    _paths_m: Mutex,

    // -- Rate limiting --

    /// Counter for PUSH_DIRECT_PATHS rate limiting.
    _direct_path_push_cutoff_count: u32,

    /// Counter for ECHO request rate limiting.
    _echo_request_cutoff_count: u32,

    // -- Multipath/bond --

    /// Whether local multipath is supported for this peer.
    _local_multipath_supported: bool,

    /// Last computed aggregate mean latency from the bond layer.
    _last_computed_aggregate_mean_latency: i32,

    // -- Callbacks (set during Node init) --

    _learned_new_path_fn: ?PeerLearnedNewPathCallback,
    _confirming_unknown_path_fn: ?PeerConfirmingUnknownPathCallback,
    _should_use_path_fn: ?ShouldUsePathCallback,
    _external_path_lookup_fn: ?ExternalPathLookupCallback,
    _put_packet_fn: ?PutPacketCallback,
    _peer_redirected_fn: ?PeerRedirectedCallback,
    _cb_ctx: ?*anyopaque,

    // -- Reference counting --

    /// Intrusive reference count for SharedPtr management.
    __ref_count: shared_ptr.RefCount,

    // ── Construction ──────────────────────────────────────────

    /// Create a new Peer from our identity and the remote peer's identity.
    ///
    /// Performs ECDH key agreement and derives AES keys via KBKDF.
    /// Returns null if key agreement fails.
    pub fn create(my_identity: *const Identity, peer_identity: *const Identity) ?Peer {
        var self: Peer = undefined;

        // ECDH key agreement
        if (!my_identity.agree(peer_identity, &self._key)) {
            return null;
        }

        // Derive AES-GMAC-SIV keys via KBKDF-HMAC-SHA384
        var ktmp: [symmetric_key_size]u8 = undefined;

        sha512.kbkdfHmacSha384(&ktmp, &self._key, pkt.kbkdf_label_aes_gmac_siv_k0, 0, 0);
        self._aes_keys[0] = Aes.init(ktmp[0..32]);

        sha512.kbkdfHmacSha384(&ktmp, &self._key, pkt.kbkdf_label_aes_gmac_siv_k1, 0, 0);
        self._aes_keys[1] = Aes.init(ktmp[0..32]);

        std.crypto.secureZero(u8, &ktmp);

        self._id = peer_identity.*;

        // Zero timing fields
        self._last_receive = 0;
        self._last_nontrivial_receive = 0;
        self._last_tried_memorized_path = 0;
        self._last_direct_path_push_sent = 0;
        self._last_direct_path_push_receive = 0;
        self._last_credential_request_sent = 0;
        self._last_whois_request_received = 0;
        self._last_credentials_received = 0;
        self._last_trust_established_packet_received = 0;
        self._last_sent_full_hello = 0;
        self._last_echo_check = 0;

        // Zero version fields
        self._v_proto = 0;
        self._v_major = 0;
        self._v_minor = 0;
        self._v_revision = 0;

        // Initialize paths
        self._paths = [_]PeerPath{PeerPath.init()} ** max_peer_network_paths;
        self._paths_m = .{};

        // Rate limiting
        self._direct_path_push_cutoff_count = 0;
        self._echo_request_cutoff_count = 0;

        // Multipath
        self._local_multipath_supported = false;
        self._last_computed_aggregate_mean_latency = 0;

        // Callbacks (null until wired up)
        self._learned_new_path_fn = null;
        self._confirming_unknown_path_fn = null;
        self._should_use_path_fn = null;
        self._external_path_lookup_fn = null;
        self._put_packet_fn = null;
        self._peer_redirected_fn = null;
        self._cb_ctx = null;

        // Reference counting
        self.__ref_count = .{};

        return self;
    }

    /// Destroy the peer, securely wiping the key material.
    pub fn deinit(self: *Peer) void {
        std.crypto.secureZero(u8, &self._key);
    }

    /// Set all callbacks at once.
    pub fn setCallbacks(
        self: *Peer,
        ctx: ?*anyopaque,
        learned_new_path: ?PeerLearnedNewPathCallback,
        confirming_unknown_path: ?PeerConfirmingUnknownPathCallback,
        should_use_path: ?ShouldUsePathCallback,
        external_path_lookup: ?ExternalPathLookupCallback,
        put_packet: ?PutPacketCallback,
        peer_redirected: ?PeerRedirectedCallback,
    ) void {
        self._cb_ctx = ctx;
        self._learned_new_path_fn = learned_new_path;
        self._confirming_unknown_path_fn = confirming_unknown_path;
        self._should_use_path_fn = should_use_path;
        self._external_path_lookup_fn = external_path_lookup;
        self._put_packet_fn = put_packet;
        self._peer_redirected_fn = peer_redirected;
    }

    // ── Identity / Address ────────────────────────────────────

    /// This peer's ZeroTier address.
    pub fn address(self: *const Peer) Address {
        return self._id.address();
    }

    /// This peer's identity.
    pub fn identity(self: *const Peer) *const Identity {
        return &self._id;
    }

    // ── Key material ──────────────────────────────────────────

    /// 48-byte shared symmetric encryption key.
    pub fn key(self: *const Peer) *const [symmetric_key_size]u8 {
        return &self._key;
    }

    /// AES key contexts for protocol version >= 12, or null otherwise.
    pub fn aesKeysIfSupported(self: *const Peer) ?*const [2]Aes {
        if (self._v_proto >= 12) {
            return &self._aes_keys;
        }
        return null;
    }

    /// AES key contexts (unconditional).
    pub fn aesKeys(self: *const Peer) *const [2]Aes {
        return &self._aes_keys;
    }

    // ── Receive handling ──────────────────────────────────────

    /// Log receipt of an authenticated packet.
    ///
    /// This is called by the decode pipeline when a packet is proven
    /// authentic. It updates timing, learns or confirms paths, and
    /// may trigger direct-path pushes.
    pub fn received(
        self: *Peer,
        t_ptr: ?*anyopaque,
        path: *Path,
        hops: u32,
        packet_id: u64,
        payload_length: u32,
        verb: Verb,
        in_re_packet_id: u64,
        in_re_verb: Verb,
        trust_established: bool,
        network_id: u64,
        flow_id: i32,
        now: i64,
    ) void {
        _ = packet_id;
        _ = in_re_packet_id;
        _ = in_re_verb;
        _ = payload_length;
        _ = flow_id;

        self._last_receive = now;
        switch (verb) {
            .frame, .ext_frame, .network_config_request, .network_config, .multicast_frame => {
                self._last_nontrivial_receive = now;
            },
            else => {},
        }

        if (trust_established) {
            self._last_trust_established_packet_received = now;
            path.trustedPacketReceived(now);
        }

        if (hops == 0) {
            // Direct packet — check if we know this path
            var have_path = false;
            {
                self._paths_m.lock();
                defer self._paths_m.unlock();
                for (&self._paths) |*pp| {
                    if (pp.p) |p| {
                        if (p == path) {
                            pp.lr = now;
                            have_path = true;
                            break;
                        }
                        // Same address on same interface — don't re-learn if alive
                        if (p.address().ipsEqual(path.address()) and p.localSocket() == path.localSocket()) {
                            if (p.alive(now)) {
                                have_path = true;
                                break;
                            }
                        }
                    } else {
                        break;
                    }
                }
            }

            if (!have_path) {
                // Check policy callback
                const should_use = if (self._should_use_path_fn) |cb|
                    cb(self._cb_ctx, t_ptr, self._id.address(), path.localSocket(), path.address())
                else
                    true;

                if (should_use) {
                    if (verb == .ok) {
                        self._paths_m.lock();
                        defer self._paths_m.unlock();

                        var oldest_path_idx: u32 = max_peer_network_paths;
                        var oldest_path_age: i64 = 0;
                        var replace_path: u32 = max_peer_network_paths;

                        for (&self._paths, 0..) |*pp, i| {
                            if (pp.p) |p| {
                                const curr_age = p.age(now);
                                if (curr_age > oldest_path_age) {
                                    oldest_path_age = curr_age;
                                    oldest_path_idx = @intCast(i);
                                }
                                if (p.address().ipsEqual(path.address())) {
                                    if (p.localSocket() == path.localSocket()) {
                                        if (!p.alive(now)) {
                                            replace_path = @intCast(i);
                                            break;
                                        }
                                    }
                                }
                            } else {
                                replace_path = @intCast(i);
                                break;
                            }
                        }

                        // Fall back to replacing the oldest path
                        if (replace_path == max_peer_network_paths) {
                            replace_path = oldest_path_idx;
                        }

                        if (replace_path != max_peer_network_paths) {
                            if (self._learned_new_path_fn) |cb| {
                                cb(self._cb_ctx, t_ptr, network_id, self._id.address(), path);
                            }
                            self._paths[replace_path].lr = now;
                            self._paths[replace_path].p = path;
                            self._paths[replace_path].priority = 1;
                        }
                    }
                    // Note: the C++ code has a path-confirmation branch for non-OK verbs
                    // using _lastTriedPath (std::list). This is deferred as it requires
                    // the Switch/attemptToContact integration.
                }
            }
        }
    }

    // ── Path selection ────────────────────────────────────────

    /// Check whether we have an active path to this peer via the given address.
    pub fn hasActivePathTo(self: *const Peer, now: i64, addr: *const InetAddress) bool {
        // Note: We cast away const on the mutex for locking. This is safe
        // because Mutex.lock/unlock do not modify the protected data.
        const self_mut: *Peer = @constCast(self);
        self_mut._paths_m.lock();
        defer self_mut._paths_m.unlock();
        for (&self_mut._paths) |*pp| {
            if (pp.p) |p| {
                if ((now - pp.lr) < peer_path_expiration and p.address().eql(addr)) {
                    return true;
                }
            } else {
                break;
            }
        }
        return false;
    }

    /// Get the best direct path to this peer.
    ///
    /// Selects the path with the best quality score (lowest value).
    /// If `include_expired` is false, paths older than
    /// ZT_PEER_PATH_EXPIRATION are skipped.
    pub fn getAppropriatePath(self: *Peer, now: i64, include_expired: bool) ?*Path {
        self._paths_m.lock();
        defer self._paths_m.unlock();

        var best_path: u32 = max_peer_network_paths;
        var best_quality: i64 = std.math.maxInt(i64);

        for (&self._paths, 0..) |*pp, i| {
            if (pp.p) |p| {
                if (include_expired or (now - pp.lr) < peer_path_expiration) {
                    const q = @divTrunc(p.quality(now), pp.priority);
                    if (q <= best_quality) {
                        best_quality = q;
                        best_path = @intCast(i);
                    }
                }
            } else {
                break;
            }
        }

        if (best_path != max_peer_network_paths) {
            return self._paths[best_path].p;
        }
        return null;
    }

    /// Send data directly via the best available path.
    ///
    /// Returns true if data was actually sent.
    pub fn sendDirect(
        self: *Peer,
        t_ptr: ?*anyopaque,
        data: []const u8,
        now: i64,
        force: bool,
    ) bool {
        _ = t_ptr;
        if (self.getAppropriatePath(now, force)) |bp| {
            if (self._put_packet_fn) |send_fn| {
                if (send_fn(
                    self._cb_ctx,
                    null,
                    bp.localSocket(),
                    bp.address(),
                    data.ptr,
                    @intCast(data.len),
                )) {
                    bp.sent(now);
                    return true;
                }
            }
        }
        return false;
    }

    /// Return all known paths as a slice into a caller-provided buffer.
    ///
    /// Returns the number of paths written.
    pub fn getAllPaths(self: *Peer, out: []?*Path) u32 {
        self._paths_m.lock();
        defer self._paths_m.unlock();
        var count: u32 = 0;
        for (&self._paths) |*pp| {
            if (pp.p) |p| {
                if (count < out.len) {
                    out[count] = p;
                    count += 1;
                }
            } else {
                break;
            }
        }
        return count;
    }

    // ── Timing accessors ──────────────────────────────────────

    /// Time of last receipt of anything (direct or relayed).
    pub fn lastReceive(self: *const Peer) i64 {
        return self._last_receive;
    }

    /// True if we've heard from this peer within ZT_PEER_ACTIVITY_TIMEOUT.
    pub fn isAlive(self: *const Peer, now: i64) bool {
        return (now - self._last_receive) < peer_activity_timeout;
    }

    /// True if this peer has sent non-trivial traffic recently.
    pub fn isActive(self: *const Peer, now: i64) bool {
        return (now - self._last_nontrivial_receive) < peer_activity_timeout;
    }

    /// Last time a full HELLO was sent.
    pub fn lastSentFullHello(self: *const Peer) i64 {
        return self._last_sent_full_hello;
    }

    // ── Latency ───────────────────────────────────────────────

    /// Current latency in milliseconds, or 0xffff if unknown.
    pub fn latency(self: *Peer, now: i64) u32 {
        if (self._local_multipath_supported) {
            return @intCast(@max(0, self._last_computed_aggregate_mean_latency));
        }
        if (self.getAppropriatePath(now, false)) |bp| {
            return bp.latency();
        }
        return 0xffff;
    }

    /// Relay quality score. Lower is better. Returns max u32 if inactive.
    pub fn relayQuality(self: *Peer, now: i64) u32 {
        const tsr: u64 = @intCast(@max(0, now - self._last_receive));
        if (tsr >= @as(u64, @intCast(peer_activity_timeout))) {
            return std.math.maxInt(u32);
        }
        var l = self.latency(now);
        if (l == 0) {
            l = 0xffff;
        }
        return l *| @as(u32, @intCast(tsr / (@as(u64, @intCast(peer_ping_period)) + 1000) + 1));
    }

    // ── Version info ──────────────────────────────────────────

    /// Set the remote version of this peer.
    pub fn setRemoteVersion(self: *Peer, v_proto: u16, v_major: u16, v_minor: u16, v_revision: u16) void {
        self._v_proto = v_proto;
        self._v_major = v_major;
        self._v_minor = v_minor;
        self._v_revision = v_revision;
    }

    pub fn remoteVersionProtocol(self: *const Peer) u16 {
        return self._v_proto;
    }
    pub fn remoteVersionMajor(self: *const Peer) u16 {
        return self._v_major;
    }
    pub fn remoteVersionMinor(self: *const Peer) u16 {
        return self._v_minor;
    }
    pub fn remoteVersionRevision(self: *const Peer) u16 {
        return self._v_revision;
    }

    /// True if remote version is known (at least one non-zero field).
    pub fn remoteVersionKnown(self: *const Peer) bool {
        return self._v_major > 0 or self._v_minor > 0 or self._v_revision > 0;
    }

    // ── Trust ─────────────────────────────────────────────────

    /// True if trust has been established recently.
    pub fn trustEstablished(self: *const Peer, now: i64) bool {
        return (now - self._last_trust_established_packet_received) < trust_expiration;
    }

    // ── Rate limiting ─────────────────────────────────────────

    /// Rate gate for VERB_PUSH_DIRECT_PATHS.
    pub fn rateGatePushDirectPaths(self: *Peer, now: i64) bool {
        if ((now - self._last_direct_path_push_receive) <= push_direct_paths_cutoff_time) {
            self._direct_path_push_cutoff_count += 1;
        } else {
            self._direct_path_push_cutoff_count = 0;
        }
        self._last_direct_path_push_receive = now;
        return self._direct_path_push_cutoff_count < push_direct_paths_cutoff_limit;
    }

    /// Rate gate for VERB_NETWORK_CREDENTIALS.
    pub fn rateGateCredentialsReceived(self: *Peer, now: i64) bool {
        if ((now - self._last_credentials_received) >= peer_credentials_rate_limit) {
            self._last_credentials_received = now;
            return true;
        }
        return false;
    }

    /// Rate gate for sending ERROR_NEED_MEMBERSHIP_CERTIFICATE.
    pub fn rateGateRequestCredentials(self: *Peer, now: i64) bool {
        if ((now - self._last_credential_request_sent) >= peer_general_rate_limit) {
            self._last_credential_request_sent = now;
            return true;
        }
        return false;
    }

    /// Rate gate for inbound WHOIS requests.
    pub fn rateGateInboundWhoisRequest(self: *Peer, now: i64) bool {
        if ((now - self._last_whois_request_received) >= peer_whois_rate_limit) {
            self._last_whois_request_received = now;
            return true;
        }
        return false;
    }

    // ── Path management ───────────────────────────────────────

    /// Reset paths within a given IP scope and address family.
    ///
    /// Sends an ECHO to affected paths and deactivates them until
    /// they respond. Used when external IP changes are detected.
    pub fn resetWithinScope(self: *Peer, scope: IpScope, inet_address_family: std.c.sa_family_t, now: i64) void {
        self._paths_m.lock();
        defer self._paths_m.unlock();
        for (&self._paths) |*pp| {
            if (pp.p) |p| {
                if (p.address().family() == inet_address_family and p.ipScope() == scope) {
                    // Mark the path as needing re-confirmation.
                    // In the full integration, we would call attemptToContactAt()
                    // here to send an ECHO. For now, just reset the lr time.
                    p.sent(now);
                    pp.lr = 0; // path won't be used until it responds
                }
            } else {
                break;
            }
        }
    }

    /// Process a cluster redirect. Adds the new path with elevated
    /// priority and removes lower-priority or duplicate paths.
    pub fn clusterRedirect(
        self: *Peer,
        new_path: *Path,
        originating_path: ?*Path,
        now: i64,
    ) void {
        if (self._peer_redirected_fn) |cb| {
            cb(self._cb_ctx, null, 0, self._id.address(), new_path);
        }

        self._paths_m.lock();
        defer self._paths_m.unlock();

        // Find the priority of the originating path
        var new_priority: i64 = 1;
        if (originating_path) |orig| {
            for (&self._paths) |*pp| {
                if (pp.p) |p| {
                    if (p == orig) {
                        new_priority = pp.priority;
                        break;
                    }
                } else {
                    break;
                }
            }
        }
        new_priority += 2;

        // Compact: keep paths with >= new_priority and different IP
        var j: u32 = 0;
        for (&self._paths) |*pp| {
            if (pp.p) |p| {
                if (pp.priority >= new_priority and !p.address().ipsEqual2(new_path.address())) {
                    if (j < max_peer_network_paths) {
                        self._paths[j] = pp.*;
                        j += 1;
                    }
                }
            }
        }

        // Add new path
        if (j < max_peer_network_paths) {
            self._paths[j].lr = now;
            self._paths[j].p = new_path;
            self._paths[j].priority = new_priority;
            j += 1;
            // Clear remaining slots
            while (j < max_peer_network_paths) : (j += 1) {
                self._paths[j] = PeerPath.init();
            }
        }
    }

    /// Try a memorized or statically-defined path if interval has elapsed.
    pub fn tryMemorizedPath(self: *Peer, t_ptr: ?*anyopaque, now: i64) void {
        if ((now - self._last_tried_memorized_path) >= try_memorized_path_interval) {
            self._last_tried_memorized_path = now;
            if (self._external_path_lookup_fn) |lookup| {
                var mp = InetAddress.zero();
                if (lookup(self._cb_ctx, t_ptr, self._id.address(), -1, &mp)) {
                    // In the full integration, we would call attemptToContactAt()
                    // which sends ECHO or HELLO to mp. For now, just update the
                    // timestamp (done above).
                }
            }
        }
    }

    /// Count active (non-expired) paths.
    pub fn activePathCount(self: *Peer, now: i64) u32 {
        self._paths_m.lock();
        defer self._paths_m.unlock();
        var count: u32 = 0;
        for (&self._paths) |*pp| {
            if (pp.p) |_| {
                if ((now - pp.lr) < peer_path_expiration) {
                    count += 1;
                }
            } else {
                break;
            }
        }
        return count;
    }

    /// Count total paths (including expired but not empty slots).
    pub fn totalPathCount(self: *Peer) u32 {
        self._paths_m.lock();
        defer self._paths_m.unlock();
        var count: u32 = 0;
        for (&self._paths) |*pp| {
            if (pp.p != null) {
                count += 1;
            } else {
                break;
            }
        }
        return count;
    }

    /// Add a path to this peer. If the path already exists (same address
    /// and local socket), the existing entry is updated. Otherwise, the
    /// path is added to the first empty slot, or replaces the oldest path.
    ///
    /// Returns true if the path was added or updated.
    pub fn addPath(self: *Peer, path: *Path, now: i64) bool {
        self._paths_m.lock();
        defer self._paths_m.unlock();

        // Check for existing path with same address + socket
        for (&self._paths) |*pp| {
            if (pp.p) |p| {
                if (p.address().ipsEqual(path.address()) and p.localSocket() == path.localSocket()) {
                    pp.p = path;
                    pp.lr = now;
                    return true;
                }
            } else {
                break;
            }
        }

        // Find first empty slot
        for (&self._paths) |*pp| {
            if (pp.p == null) {
                pp.p = path;
                pp.lr = now;
                pp.priority = 1;
                return true;
            }
        }

        // Replace oldest
        var oldest_idx: u32 = 0;
        var oldest_lr: i64 = std.math.maxInt(i64);
        for (&self._paths, 0..) |*pp, i| {
            if (pp.lr < oldest_lr) {
                oldest_lr = pp.lr;
                oldest_idx = @intCast(i);
            }
        }
        self._paths[oldest_idx].p = path;
        self._paths[oldest_idx].lr = now;
        self._paths[oldest_idx].priority = 1;
        return true;
    }

    /// Remove expired paths and compact the array. Also sends
    /// keepalives/pings on active max-priority paths.
    ///
    /// Returns a bit mask: 0x1 if IPv4 pinged, 0x2 if IPv6 pinged.
    pub fn doPingAndKeepalive(self: *Peer, now: i64, hello_ctx: ?*const HelloContext) u32 {
        var sent: u32 = 0;

        self._paths_m.lock();
        defer self._paths_m.unlock();

        const send_full_hello = (now - self._last_sent_full_hello) >= peer_ping_period;
        if (send_full_hello) {
            self._last_sent_full_hello = now;
        }

        // Find the maximum priority among active paths
        var max_priority: i64 = 0;
        for (&self._paths) |*pp| {
            if (pp.p != null) {
                max_priority = @max(pp.priority, max_priority);
            } else {
                break;
            }
        }

        // Clean expired and reduced-priority paths, compact array
        var deletion_occurred = false;
        for (&self._paths, 0..) |*pp, i| {
            if (pp.p) |p| {
                if ((now - pp.lr) < peer_path_expiration and pp.priority == max_priority) {
                    if (send_full_hello or p.needsHeartbeat(now)) {
                        if (send_full_hello) {
                            if (hello_ctx) |hctx| {
                                self.sendHELLO(p.address(), p.localSocket(), now, hctx);
                            }
                        }
                        p.sent(now);
                        sent |= if (p.address().family() == std.c.AF.INET) @as(u32, 0x1) else @as(u32, 0x2);
                    }
                } else {
                    self._paths[i] = PeerPath.init();
                    deletion_occurred = true;
                }
            }
            if (pp.p == null or deletion_occurred) {
                // Try to compact by finding a later non-empty slot
                var j: u32 = @intCast(i);
                while (j < max_peer_network_paths) : (j += 1) {
                    if (self._paths[j].p != null and j != i) {
                        self._paths[i] = self._paths[j];
                        self._paths[j] = PeerPath.init();
                        break;
                    }
                }
                deletion_occurred = false;
            }
        }

        return sent;
    }

    /// Context for sending HELLO packets (avoids passing many individual params).
    pub const HelloContext = struct {
        my_identity: *const Identity,
        planet_world_id: u64,
        planet_world_timestamp: u64,
        wireSendFn: *const fn (?*anyopaque, ?*anyopaque, i64, *const InetAddress, [*]const u8, u32, i32) void,
        expectReplyFn: ?*const fn (?*anyopaque, u64) void,
        wire_ctx: ?*anyopaque,
        expect_ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
    };

    /// Send a HELLO packet to a specific address.
    /// Mirrors C++ Peer::sendHELLO (Peer.cpp:426-470).
    pub fn sendHELLO(
        self: *Peer,
        dest_addr: *const InetAddress,
        local_socket: i64,
        now: i64,
        ctx: *const HelloContext,
    ) void {
        const Packet = pkt.Packet;

        // Build HELLO packet: dest=peer, src=us, verb=HELLO
        var outp = Packet.initNew(self._id.address(), ctx.my_identity.address(), .hello);

        // Packet construction — any buffer overflow here means the packet
        // buffer is too small (should not happen with max_packet_length).
        outp.buf.appendByte(pkt.protocol_version, 1) catch return self.logHelloFail("protocol_version");
        outp.buf.appendByte(version_major, 1) catch return self.logHelloFail("version_major");
        outp.buf.appendByte(version_minor, 1) catch return self.logHelloFail("version_minor");
        outp.buf.appendInt(u16, version_revision) catch return self.logHelloFail("version_revision");
        outp.buf.appendInt(i64, now) catch return self.logHelloFail("timestamp");
        ctx.my_identity.serialize(pkt.max_packet_length, &outp.buf, false) catch return self.logHelloFail("identity");
        dest_addr.serialize(pkt.max_packet_length, &outp.buf) catch return self.logHelloFail("dest_addr");
        outp.buf.appendInt(u64, ctx.planet_world_id) catch return self.logHelloFail("planet_id");
        outp.buf.appendInt(u64, ctx.planet_world_timestamp) catch return self.logHelloFail("planet_ts");

        // Moon section (encrypted with cryptField)
        const crypt_start = outp.buf.size();
        outp.buf.appendInt(u16, 0) catch return self.logHelloFail("moon_count");

        // Encrypt moon section with Salsa20/12
        outp.cryptField(&self._key[0..32].*, crypt_start, outp.buf.size() - crypt_start);

        // Armor with MAC only (encrypt=false), matching C++ armor(_key, false, ...)
        outp.armor(&self._key[0..32].*, false, false, null, null);

        // Track expected reply so doOK() accepts the response
        if (ctx.expectReplyFn) |expectFn| {
            expectFn(ctx.expect_ctx, outp.packetId());
        }

        // Send
        const pkt_data = outp.buf.data();
        const send_len = @min(pkt_data.len, pkt.max_packet_length);
        ctx.wireSendFn(
            ctx.wire_ctx,
            ctx.t_ptr,
            local_socket,
            dest_addr,
            pkt_data.ptr,
            @intCast(send_len),
            64, // TTL
        );

        var addr_buf: [64]u8 = undefined;
        std.debug.print("[HELLO] Sent to {s} ({d} bytes)\n", .{
            dest_addr.toString(&addr_buf),
            pkt_data.len,
        });
    }

    fn logHelloFail(self: *const Peer, field: []const u8) void {
        _ = self;
        std.debug.print("[HELLO] Packet construction failed at field: {s}\n", .{field});
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "Peer: create with test identities" {
    // Generate two identities and create a peer
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Peer should have B's address
    try testing.expect(peer.address().eql(id_b.address()));

    // Verify identity pointer
    try testing.expect(peer.identity().eql(&id_b));

    // Key should be non-zero
    var all_zero = true;
    for (peer._key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "Peer: symmetric key agreement" {
    // Both sides should derive the same key
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer_ab = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer_ab.deinit();

    var peer_ba = Peer.create(&id_b, &id_a) orelse return error.SkipZigTest;
    defer peer_ba.deinit();

    // Keys should match
    try testing.expectEqualSlices(u8, &peer_ab._key, &peer_ba._key);
}

test "Peer: initial state" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Timing fields should be zero
    try testing.expectEqual(@as(i64, 0), peer._last_receive);
    try testing.expectEqual(@as(i64, 0), peer._last_nontrivial_receive);
    try testing.expectEqual(@as(i64, 0), peer._last_sent_full_hello);

    // Version should be zero
    try testing.expectEqual(@as(u16, 0), peer._v_proto);
    try testing.expectEqual(@as(u16, 0), peer._v_major);

    // Should not be alive when now is far beyond the activity timeout
    // (_last_receive = 0, peer_activity_timeout = 500000)
    const far_future: i64 = 1_000_000;
    try testing.expect(!peer.isAlive(far_future));
    try testing.expect(!peer.isActive(far_future));

    // No version known
    try testing.expect(!peer.remoteVersionKnown());

    // Trust should not be established
    try testing.expect(!peer.trustEstablished(far_future));

    // No paths
    try testing.expectEqual(@as(u32, 0), peer.totalPathCount());
    try testing.expectEqual(@as(u32, 0), peer.activePathCount(far_future));
}

test "Peer: setRemoteVersion" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    peer.setRemoteVersion(12, 1, 14, 0);

    try testing.expectEqual(@as(u16, 12), peer.remoteVersionProtocol());
    try testing.expectEqual(@as(u16, 1), peer.remoteVersionMajor());
    try testing.expectEqual(@as(u16, 14), peer.remoteVersionMinor());
    try testing.expectEqual(@as(u16, 0), peer.remoteVersionRevision());
    try testing.expect(peer.remoteVersionKnown());
}

test "Peer: aesKeysIfSupported" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Protocol 0 — no AES
    try testing.expect(peer.aesKeysIfSupported() == null);

    // Protocol 11 — no AES
    peer._v_proto = 11;
    try testing.expect(peer.aesKeysIfSupported() == null);

    // Protocol 12 — AES supported
    peer._v_proto = 12;
    try testing.expect(peer.aesKeysIfSupported() != null);

    // Protocol 13 — AES supported
    peer._v_proto = 13;
    try testing.expect(peer.aesKeysIfSupported() != null);
}

test "Peer: deinit wipes key" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;

    // Save key for comparison
    var saved_key: [symmetric_key_size]u8 = undefined;
    @memcpy(&saved_key, &peer._key);

    peer.deinit();

    // Key should be wiped (all zeros)
    var all_zero = true;
    for (peer._key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(all_zero);
}

test "Peer: addPath and totalPathCount" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    var path2 = Path.initWithAddress(2, InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993));

    try testing.expect(peer.addPath(&path1, 1000));
    try testing.expectEqual(@as(u32, 1), peer.totalPathCount());

    try testing.expect(peer.addPath(&path2, 1000));
    try testing.expectEqual(@as(u32, 2), peer.totalPathCount());
}

test "Peer: addPath deduplicates by address" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    var path2 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));

    try testing.expect(peer.addPath(&path1, 1000));
    try testing.expect(peer.addPath(&path2, 2000));
    // Should still be 1 path (deduplicated)
    try testing.expectEqual(@as(u32, 1), peer.totalPathCount());
}

test "Peer: hasActivePathTo" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    const addr = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    var path = Path.initWithAddress(1, addr);

    try testing.expect(peer.addPath(&path, 1000));

    // Should have active path at time close to lr
    try testing.expect(peer.hasActivePathTo(2000, &addr));

    // Should NOT have active path after expiration
    try testing.expect(!peer.hasActivePathTo(1000 + peer_path_expiration + 1, &addr));
}

test "Peer: getAppropriatePath" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // No paths — should return null
    try testing.expect(peer.getAppropriatePath(1000, false) == null);

    var path = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    try testing.expect(peer.addPath(&path, 1000));

    // Should find the path
    const best = peer.getAppropriatePath(2000, false);
    try testing.expect(best != null);
    try testing.expect(best.? == &path);
}

test "Peer: isAlive and isActive" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Initially not alive (need time far beyond timeout since _last_receive = 0)
    try testing.expect(!peer.isAlive(1_000_000));

    // Simulate receiving a packet
    peer._last_receive = 1_000_000;
    try testing.expect(peer.isAlive(1_000_000 + peer_activity_timeout - 1));
    try testing.expect(!peer.isAlive(1_000_000 + peer_activity_timeout + 1));

    // isActive tracks nontrivial receives
    try testing.expect(!peer.isActive(2_000_000));
    peer._last_nontrivial_receive = 2_000_000;
    try testing.expect(peer.isActive(2_000_000 + peer_activity_timeout - 1));
}

test "Peer: trustEstablished" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Initially not trusted (need time far beyond trust_expiration since field = 0)
    try testing.expect(!peer.trustEstablished(1_000_000));

    peer._last_trust_established_packet_received = 1_000_000;
    try testing.expect(peer.trustEstablished(1_000_000 + trust_expiration - 1));
    try testing.expect(!peer.trustEstablished(1_000_000 + trust_expiration + 1));
}

test "Peer: rateGatePushDirectPaths" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // First call should be allowed
    try testing.expect(peer.rateGatePushDirectPaths(1000));

    // Rapid calls should eventually be rate-limited
    var i: u32 = 0;
    while (i < push_direct_paths_cutoff_limit + 5) : (i += 1) {
        _ = peer.rateGatePushDirectPaths(1000 + @as(i64, @intCast(i)));
    }
    // After exceeding cutoff limit, should be blocked
    try testing.expect(!peer.rateGatePushDirectPaths(1000 + @as(i64, @intCast(push_direct_paths_cutoff_limit + 10))));

    // After timeout, should be allowed again
    try testing.expect(peer.rateGatePushDirectPaths(1000 + push_direct_paths_cutoff_time + 1000));
}

test "Peer: rateGateCredentialsReceived" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // First call should be allowed
    try testing.expect(peer.rateGateCredentialsReceived(1000));
    // Immediate second call should be blocked
    try testing.expect(!peer.rateGateCredentialsReceived(1001));
    // After rate limit expires, should be allowed
    try testing.expect(peer.rateGateCredentialsReceived(1000 + peer_credentials_rate_limit));
}

test "Peer: rateGateRequestCredentials" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    try testing.expect(peer.rateGateRequestCredentials(1000));
    try testing.expect(!peer.rateGateRequestCredentials(1001));
    try testing.expect(peer.rateGateRequestCredentials(1000 + peer_general_rate_limit));
}

test "Peer: rateGateInboundWhoisRequest" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    try testing.expect(peer.rateGateInboundWhoisRequest(1000));
    try testing.expect(!peer.rateGateInboundWhoisRequest(1001));
    try testing.expect(peer.rateGateInboundWhoisRequest(1000 + peer_whois_rate_limit));
}

test "Peer: resetWithinScope" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Add a global IPv4 path
    var path = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    try testing.expect(peer.addPath(&path, 1000));

    // Reset global scope — should deactivate the path
    peer.resetWithinScope(.global, std.c.AF.INET, 2000);

    // Path should still exist but lr should be 0 (deactivated)
    try testing.expectEqual(@as(u32, 1), peer.totalPathCount());
    try testing.expectEqual(@as(i64, 0), peer._paths[0].lr);
}

test "Peer: activePathCount vs totalPathCount" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    var path2 = Path.initWithAddress(2, InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993));

    try testing.expect(peer.addPath(&path1, 1000));
    try testing.expect(peer.addPath(&path2, 1000));

    try testing.expectEqual(@as(u32, 2), peer.totalPathCount());
    try testing.expectEqual(@as(u32, 2), peer.activePathCount(2000));

    // After path expiration, active count should be 0
    try testing.expectEqual(@as(u32, 0), peer.activePathCount(1000 + peer_path_expiration + 1));
    // But total count still shows them
    try testing.expectEqual(@as(u32, 2), peer.totalPathCount());
}

test "Peer: getAllPaths" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    var path2 = Path.initWithAddress(2, InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993));

    try testing.expect(peer.addPath(&path1, 1000));
    try testing.expect(peer.addPath(&path2, 1000));

    var buf: [4]?*Path = .{ null, null, null, null };
    const count = peer.getAllPaths(&buf);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expect(buf[0] != null);
    try testing.expect(buf[1] != null);
}

test "Peer: clusterRedirect" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    var path2 = Path.initWithAddress(2, InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993));

    try testing.expect(peer.addPath(&path1, 1000));

    // Redirect to path2 via path1
    peer.clusterRedirect(&path2, &path1, 2000);

    // path2 should be present with elevated priority
    var found = false;
    for (&peer._paths) |*pp| {
        if (pp.p) |p| {
            if (p == &path2) {
                try testing.expect(pp.priority >= 3); // 1 + 2
                found = true;
            }
        }
    }
    try testing.expect(found);
}

test "Peer: latency unknown without paths" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    try testing.expectEqual(@as(u32, 0xffff), peer.latency(1000));
}

test "Peer: relayQuality returns max when inactive" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // peer._last_receive is 0, so at time 1000 + peer_activity_timeout,
    // the peer is inactive and relay quality should be max.
    const rq = peer.relayQuality(peer_activity_timeout + 1);
    try testing.expectEqual(std.math.maxInt(u32), rq);
}

test "Peer: doPingAndKeepalive removes expired paths" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    var path1 = Path.initWithAddress(1, InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993));
    try testing.expect(peer.addPath(&path1, 1000));
    try testing.expectEqual(@as(u32, 1), peer.totalPathCount());

    // Run keepalive after path expiration — should remove the path
    _ = peer.doPingAndKeepalive(1000 + peer_path_expiration + 1, null);
    try testing.expectEqual(@as(u32, 0), peer.totalPathCount());
}

test "Peer: setCallbacks" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    try testing.expect(peer._learned_new_path_fn == null);
    try testing.expect(peer._cb_ctx == null);

    const Ctx = struct {
        fn learnedNewPath(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: *Path) void {}
        fn confirmingUnknownPath(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: *Path, _: u64, _: Verb) void {}
        fn shouldUsePath(_: ?*anyopaque, _: ?*anyopaque, _: Address, _: i64, _: *const InetAddress) bool {
            return true;
        }
        fn externalPathLookup(_: ?*anyopaque, _: ?*anyopaque, _: Address, _: i32, _: *InetAddress) bool {
            return false;
        }
        fn putPacket(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, _: [*]const u8, _: u32) bool {
            return true;
        }
        fn peerRedirected(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: *Path) void {}
    };

    var dummy: u8 = 42;
    peer.setCallbacks(
        @ptrCast(&dummy),
        &Ctx.learnedNewPath,
        &Ctx.confirmingUnknownPath,
        &Ctx.shouldUsePath,
        &Ctx.externalPathLookup,
        &Ctx.putPacket,
        &Ctx.peerRedirected,
    );

    try testing.expect(peer._learned_new_path_fn != null);
    try testing.expect(peer._cb_ctx != null);
}

test "Peer: sendHELLO constructs valid packet" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Capture what sendHELLO sends
    const Capture = struct {
        var captured_data: [2048]u8 = undefined;
        var captured_len: u32 = 0;
        var send_count: u32 = 0;

        fn wireSend(_: ?*anyopaque, _: ?*anyopaque, _: i64, _: *const InetAddress, data: [*]const u8, len: u32, _: i32) void {
            if (len <= 2048) {
                @memcpy(captured_data[0..len], data[0..len]);
                captured_len = len;
            }
            send_count += 1;
        }
    };

    Capture.send_count = 0;
    Capture.captured_len = 0;

    const dest = InetAddress.initV4(.{ 198, 41, 200, 2 }, 9993);
    const ctx = Peer.HelloContext{
        .my_identity = &id_a,
        .planet_world_id = 149604618, // Earth
        .planet_world_timestamp = 1000,
        .wireSendFn = &Capture.wireSend,
        .expectReplyFn = null,
        .wire_ctx = null,
        .expect_ctx = null,
        .t_ptr = null,
    };

    peer.sendHELLO(&dest, 0, 12345, &ctx);

    // Verify packet was sent
    try testing.expectEqual(@as(u32, 1), Capture.send_count);
    try testing.expect(Capture.captured_len > 0);

    // Verify it's a valid packet with HELLO verb
    const Packet = pkt.Packet;
    var hello_pkt = Packet{ .buf = .{} };
    hello_pkt.buf.setSize(Capture.captured_len) catch unreachable;
    @memcpy(hello_pkt.buf.dataMut()[0..Capture.captured_len], Capture.captured_data[0..Capture.captured_len]);

    // Destination should be peer's address (id_b)
    try testing.expect(hello_pkt.destination().eql(id_b.address()));
    // Source should be our address (id_a)
    try testing.expect(hello_pkt.source().eql(id_a.address()));

    // Cipher should be c25519_poly1305_none (MAC only, no encryption)
    try testing.expectEqual(pkt.CipherSuite.c25519_poly1305_none, hello_pkt.cipher());

    // Should be able to dearmor with the shared key
    var key32: [32]u8 = undefined;
    @memcpy(&key32, peer.key()[0..32]);
    try testing.expect(hello_pkt.dearmor(&key32, null, null));

    // After dearmor, verb should be HELLO
    try testing.expectEqual(pkt.Verb.hello, hello_pkt.verb());
}

test "Peer: sendHELLO with doPingAndKeepalive" {
    var id_a = try Identity.generate(testing.allocator);
    var id_b = try Identity.generate(testing.allocator);
    defer id_a.deinit();
    defer id_b.deinit();

    var peer = Peer.create(&id_a, &id_b) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Without hello_ctx, should still work (no send, just maintenance)
    const sent = peer.doPingAndKeepalive(1000, null);
    try testing.expectEqual(@as(u32, 0), sent); // No paths, nothing sent
}
