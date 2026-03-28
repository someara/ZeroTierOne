/// Virtual network instance — the core representation of a joined ZeroTier network.
///
/// Converted from `node/Network.hpp` and `node/Network.cpp`.
/// Each Network holds its configuration, membership database, multicast
/// subscriptions, bridge routes, and per-peer credential state. Thread
/// safety is provided by an internal mutex; all public methods that access
/// mutable state lock before proceeding.
///
/// This is a very large struct (~several MB) due to NetworkConfig and
/// IncomingConfigChunk arrays. It MUST be heap-allocated. Never place
/// a Network on the stack.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const AtomicCounter = @import("atomic_counter.zig");
const Buffer = @import("buffer.zig").Buffer;
const Capability = @import("capability.zig").Capability;
const com_mod = @import("certificate_of_membership.zig");
const CertificateOfMembership = com_mod.CertificateOfMembership;
const CertificateOfOwnership = @import("certificate_of_ownership.zig").CertificateOfOwnership;
const constants = @import("constants.zig");
const Dictionary = @import("dictionary.zig").Dictionary;
const ecc = @import("ecc.zig");
const Hashtable = @import("hashtable.zig").Hashtable;
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;
const Membership = @import("membership.zig").Membership;
const membership_mod = @import("membership.zig");
const MulticastGroup = @import("multicast_group.zig").MulticastGroup;
const Mutex = @import("mutex.zig");
const network_config = @import("network_config.zig");
const NetworkConfig = network_config.NetworkConfig;
const Revocation = @import("revocation.zig").Revocation;
const Tag = @import("tag.zig").Tag;
const Trace = @import("trace.zig");
const RuleResultLog = Trace.RuleResultLog;
const utils = @import("utils.zig");

const c_api = constants.c_api;

// ── C API types ──────────────────────────────────────────────────

const VirtualNetworkConfig = c_api.ZT_VirtualNetworkConfig;
const VirtualNetworkStatus = c_api.enum_ZT_VirtualNetworkStatus;
const VirtualNetworkType = c_api.enum_ZT_VirtualNetworkType;
const VirtualNetworkConfigOperation = c_api.enum_ZT_VirtualNetworkConfigOperation;

// ── Constants ────────────────────────────────────────────────────

/// Maximum number of in-flight network config chunk reassembly slots.
pub const max_incoming_updates: u32 = 3;

/// Maximum number of chunks per config update.
pub const max_update_chunks: u32 = (network_config.dict_capacity / 1024) + 1;

/// Maximum locally-subscribed multicast groups (matches C API struct limit).
pub const max_multicast_subscriptions: u32 = c_api.ZT_MAX_MULTICAST_SUBSCRIPTIONS;

/// Ethertype: IPv4.
pub const ethertype_ipv4: u16 = 0x0800;

/// Ethertype: IPv6.
pub const ethertype_ipv6: u16 = 0x86dd;

/// Ethertype: ARP.
pub const ethertype_arp: u16 = 0x0806;

// ── Enums ────────────────────────────────────────────────────────

/// Network configuration failure state.
pub const NetconfFailure = enum {
    none,
    access_denied,
    not_found,
    init_failed,
    authentication_required,
};

/// Result from the packet rules engine (`doZtFilter`).
pub const DoZtFilterResult = enum {
    no_match,
    drop,
    redirect,
    accept,
    super_accept,
};

// ── Helper types ─────────────────────────────────────────────────

/// Value-based key wrapper for MulticastGroup, suitable for use as a
/// Hashtable key. MulticastGroup itself uses pointer-based eql/hashCode,
/// which is incompatible with the Hashtable's HashContext expectations.
pub const MulticastGroupKey = struct {
    _mac_int: u64,
    _adi: u32,

    pub fn fromMulticastGroup(mg: *const MulticastGroup) MulticastGroupKey {
        return .{
            ._mac_int = mg.mac().toInt(),
            ._adi = mg.adi(),
        };
    }

    pub fn fromParts(mac_int: u64, adi: u32) MulticastGroupKey {
        return .{
            ._mac_int = mac_int,
            ._adi = adi,
        };
    }

    pub fn eql(self: MulticastGroupKey, other: MulticastGroupKey) bool {
        return self._mac_int == other._mac_int and self._adi == other._adi;
    }

    pub fn hashCode(self: MulticastGroupKey) u64 {
        // Mirrors MulticastGroup.hashCode: mac.hashCode() ^ adi
        const mac_hash = self._mac_int *% 0x9e3779b97f4a7c15;
        return mac_hash ^ @as(u64, self._adi);
    }
};

/// Incoming network config chunk reassembly buffer.
///
/// Three of these are kept per-network to allow concurrent config updates.
/// Each contains a full Dictionary buffer, making this a very large struct.
pub const IncomingConfigChunk = struct {
    ts: u64,
    update_id: u64,
    have_chunk_ids: [max_update_chunks]u64,
    have_chunks: u32,
    have_bytes: u32,
    data: Dictionary(network_config.dict_capacity),

    pub fn init() IncomingConfigChunk {
        return .{
            .ts = 0,
            .update_id = 0,
            .have_chunk_ids = [_]u64{0} ** max_update_chunks,
            .have_chunks = 0,
            .have_bytes = 0,
            .data = Dictionary(network_config.dict_capacity).init(),
        };
    }
};

// ── Callbacks ────────────────────────────────────────────────────

/// External callbacks that Network uses to interact with the host
/// application, the node runtime, and other subsystems. All function
/// pointers are optional — null means the operation is unavailable.
///
/// New fields are added as later chunks implement more methods.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,

    /// Notify host of virtual network port changes (UP/DOWN/CONFIG_UPDATE).
    /// Returns an error code (0 = ok). Matches the ZeroTier C API callback.
    configure_virtual_network_port: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        u_ptr: *?*anyopaque,
        op: c_uint,
        config: ?*const VirtualNetworkConfig,
    ) c_int = null,

    /// Get current time in milliseconds since epoch.
    now: ?*const fn (ctx: ?*anyopaque) i64 = null,

    /// Read a state object from persistent storage. Returns the number of
    /// bytes read into `buf`, or 0/negative on failure.
    state_object_get: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        obj_type: c_uint,
        id: [2]u64,
        buf: [*]u8,
        buf_len: c_uint,
    ) c_int = null,

    /// Write a state object to persistent storage.
    state_object_put: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        obj_type: c_uint,
        id: [2]u64,
        data: [*]const u8,
        data_len: c_int,
    ) void = null,

    /// Return a pseudo-random 64-bit value. Used by MATCH_RANDOM rules.
    prng: ?*const fn (ctx: ?*anyopaque) u64 = null,

    /// Announce multicast groups to a specific peer.
    /// The callee should build and send VERB_MULTICAST_LIKE packets.
    announce_multicast_groups: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        peer_addr: Address,
        groups: []const MulticastGroup,
    ) void = null,

    /// Check whether a peer still exists in topology.
    /// Returns true if the peer is known, false otherwise.
    peer_exists: ?*const fn (ctx: ?*anyopaque, addr: Address) bool = null,

    /// Push credentials to a peer. Called by pushCredentialsIfNeeded
    /// and peerRequestedCredentials when a push is due.
    push_credentials: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        to: Address,
        now: i64,
    ) void = null,

    /// Propagate a revocation to all memberships except the sender and signer.
    /// Called when a fast-propagate revocation is accepted.
    propagate_revocation: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        rev: *const Revocation,
        sent_from: Address,
    ) void = null,

    /// Get the identity of a peer for isAllowedOnNetwork checks.
    /// Returns null if identity is unknown.
    get_identity: ?*const fn (ctx: ?*anyopaque, addr: Address) ?*const Identity = null,

    /// Send an EXT_FRAME verb to a peer. Used by filterOutgoingPacket/filterIncomingPacket
    /// for TEE, REDIRECT, and WATCH operations.
    /// `flags` encodes direction/type: 0x02=outbound tee, 0x04=outbound redirect,
    /// 0x08=inbound tee, 0x0a=inbound redirect, 0x16=outbound watch, 0x1c=inbound watch.
    send_ext_frame: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        to: Address,
        flags: u8,
        mac_dest: MAC,
        mac_source: MAC,
        ether_type: u16,
        frame_data: []const u8,
    ) void = null,

    /// Trace callback for the network packet filter (remote trace target).
    /// `accept` indicates the filter verdict: 0=drop, 1=accept, 2=super-accept.
    network_filter_trace: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        primary_rrl: *const RuleResultLog,
        cap_rrl: ?*const RuleResultLog,
        cap: ?*const Capability,
        zt_source: Address,
        zt_dest: Address,
        mac_source: MAC,
        mac_dest: MAC,
        frame_data: []const u8,
        ether_type: u16,
        vlan_id: u16,
        no_tee: bool,
        inbound: bool,
        accept: i32,
    ) void = null,

    /// Verify a signature using the controller identity. Returns true if valid.
    /// Used by handleConfigChunk to verify chunk signatures.
    verify_controller_signature: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        data: []const u8,
        signature: []const u8,
    ) bool = null,

    /// Forward a config chunk to a peer (viral fast propagation).
    /// `chunk_data` is the raw chunk data from `start` to end of the original buffer.
    send_network_config: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        to: Address,
        chunk_data: []const u8,
    ) void = null,

    /// Trace callback for config request sent event.
    network_config_request_sent: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        controller: Address,
    ) void = null,

    /// Request to the local network controller (when we ARE the controller).
    local_controller_request: ?*const fn (
        ctx: ?*anyopaque,
        nwid: u64,
        my_address: Address,
        metadata: []const u8,
    ) void = null,

    /// Send a NETWORK_CONFIG_REQUEST packet to the controller.
    send_network_config_request: ?*const fn (
        ctx: ?*anyopaque,
        t_ptr: ?*anyopaque,
        nwid: u64,
        controller: Address,
        metadata: []const u8,
        config_revision: u64,
        config_timestamp: u64,
    ) void = null,
};

// ── Network ──────────────────────────────────────────────────────

/// A joined virtual network.
///
/// Fields prefixed with `_` are internal state protected by `_lock`.
/// The `__ref_count` field is used by SharedPtr for reference counting.
pub const Network = struct {
    // ── Immutable (set at init, never changed) ───────────

    /// 64-bit network ID.
    _id: u64,

    /// Locally-derived MAC address for this network (from our address + nwid).
    _mac: MAC,

    /// Our own ZeroTier address (cached at init).
    _my_address: Address,

    // ── User pointer for external API ────────────────────

    _u_ptr: ?*anyopaque,

    // ── Configuration ────────────────────────────────────

    /// Current network configuration. Zero-init means "no config yet".
    _config: NetworkConfig,

    /// Timestamp of last config update (ms), or 0 if never configured.
    _last_config_update: i64,

    /// True once the virtual network port has been notified as UP.
    _port_initialized: bool,

    /// Return value from the last configureVirtualNetworkPort callback.
    _port_error: i32,

    /// Set by destroy(); causes the destructor to skip the DOWN callback.
    _destroyed: bool,

    /// Current network config failure state.
    _netconf_failure: NetconfFailure,

    /// SSO authentication URL (null-terminated in first bytes).
    _authentication_url: [2048]u8,

    // ── Multicast state ──────────────────────────────────

    /// Timestamp of last upstream multicast group announcement.
    _last_announced_multicast_groups_upstream: i64,

    /// Locally-subscribed multicast groups (sorted, from tap device).
    _my_multicast_groups: [max_multicast_subscriptions]MulticastGroup,

    /// Number of entries in `_my_multicast_groups`.
    _my_multicast_group_count: u32,

    /// Multicast groups learned from bridged traffic (key -> last-seen timestamp).
    _multicast_groups_behind_me: Hashtable(MulticastGroupKey, i64),

    // ── Bridge routes ────────────────────────────────────

    /// MAC-to-bridge-address mapping for remote bridge routes.
    _remote_bridge_routes: Hashtable(MAC, Address),

    // ── Membership state ─────────────────────────────────

    /// Per-peer membership/credential state, keyed by peer address.
    _memberships: Hashtable(Address, Membership),

    // ── Config chunk reassembly ──────────────────────────

    /// Incoming config chunks being reassembled (3 concurrent slots).
    _incoming_config_chunks: [max_incoming_updates]IncomingConfigChunk,

    // ── Packet filter counters ───────────────────────────

    _outgoing_packets_accepted: u64,
    _outgoing_packets_dropped: u64,
    _incoming_packets_accepted: u64,
    _incoming_packets_dropped: u64,

    // ── Callbacks ────────────────────────────────────────

    _callbacks: Callbacks,

    // ── Thread safety ────────────────────────────────────

    _lock: Mutex,

    // ── SharedPtr reference counting ─────────────────────

    __ref_count: AtomicCounter,

    // ── Allocator ────────────────────────────────────────

    _allocator: std.mem.Allocator,

    // ── Constants ────────────────────────────────────────

    /// The broadcast multicast group (ff:ff:ff:ff:ff:ff / ADI 0).
    pub const BROADCAST = MulticastGroup.init(MAC.init(0xffffffffffff), 0);

    // ── Constructor / destructor ─────────────────────────

    /// Create a new Network in its initial (unconfigured) state.
    ///
    /// The MAC is derived from `my_address` and `nwid`. The network starts
    /// with no configuration; call `setConfiguration()` or
    /// `requestConfiguration()` to populate it.
    ///
    /// Ownership: the caller owns the returned Network and must call
    /// `deinit()` when done. The `allocator` is retained for internal
    /// hashtable operations and Membership sub-allocations.
    pub fn init(
        allocator: std.mem.Allocator,
        nwid: u64,
        my_address: Address,
        u_ptr: ?*anyopaque,
        callbacks: Callbacks,
    ) Network {
        return .{
            ._id = nwid,
            ._mac = MAC.fromAddress(my_address, nwid),
            ._my_address = my_address,
            ._u_ptr = u_ptr,
            ._config = NetworkConfig.init(),
            ._last_config_update = 0,
            ._port_initialized = false,
            ._port_error = 0,
            ._destroyed = false,
            ._netconf_failure = .none,
            ._authentication_url = [_]u8{0} ** 2048,
            ._last_announced_multicast_groups_upstream = 0,
            ._my_multicast_groups = [_]MulticastGroup{MulticastGroup.zero()} ** max_multicast_subscriptions,
            ._my_multicast_group_count = 0,
            ._multicast_groups_behind_me = Hashtable(MulticastGroupKey, i64).init(allocator),
            ._remote_bridge_routes = Hashtable(MAC, Address).init(allocator),
            ._memberships = Hashtable(Address, Membership).init(allocator),
            ._incoming_config_chunks = [_]IncomingConfigChunk{IncomingConfigChunk.init()} ** max_incoming_updates,
            ._outgoing_packets_accepted = 0,
            ._outgoing_packets_dropped = 0,
            ._incoming_packets_accepted = 0,
            ._incoming_packets_dropped = 0,
            ._callbacks = callbacks,
            ._lock = .{},
            .__ref_count = .{},
            ._allocator = allocator,
        };
    }

    /// Release all internal resources.
    ///
    /// If the network was not `destroy()`ed, fires a DOWN callback to notify
    /// the host that the virtual port is going away.
    pub fn deinit(self: *Network) void {
        // Fire DOWN callback if not already destroyed.
        if (!self._destroyed) {
            if (self._callbacks.configure_virtual_network_port) |cb| {
                var ec: VirtualNetworkConfig = undefined;
                self.externalConfigInternal(&ec);
                _ = cb(
                    self._callbacks.ctx,
                    null, // no tPtr available in deinit
                    self._id,
                    &self._u_ptr,
                    c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_DOWN,
                    &ec,
                );
            }
        }

        // Deinit all Membership entries (they own internal hashtables).
        var it = self._memberships.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self._memberships.deinit();

        self._multicast_groups_behind_me.deinit();
        self._remote_bridge_routes.deinit();
    }

    // ── Simple accessors ─────────────────────────────────

    /// The 64-bit network ID.
    pub fn id(self: *const Network) u64 {
        return self._id;
    }

    /// The controller address (top 40 bits of the network ID).
    pub fn controller(self: *const Network) Address {
        return Address.init(self._id >> 24);
    }

    /// Check if bridging is permitted for the given address
    pub fn permitsBridging(self: *const Network, addr: Address) bool {
        _ = self;
        _ = addr;
        // TODO: Implement bridging permission check
        return false;
    }

    /// Static: derive the controller address from a network ID.
    pub fn controllerFor(nwid: u64) Address {
        return Address.init(nwid >> 24);
    }

    /// The locally-derived MAC address for this network.
    pub fn mac(self: *const Network) MAC {
        return self._mac;
    }

    /// True if multicast is enabled (multicast limit > 0).
    pub fn multicastEnabled(self: *const Network) bool {
        return self._config.multicast_limit > 0;
    }

    /// True if this network has received a valid configuration.
    pub fn hasConfig(self: *const Network) bool {
        return self._config.isSet();
    }

    /// Timestamp of last configuration update (ms since epoch), or 0.
    pub fn lastConfigUpdate(self: *const Network) i64 {
        return self._last_config_update;
    }

    /// Pointer to the current network configuration.
    pub fn config(self: *const Network) *const NetworkConfig {
        return &self._config;
    }

    /// QoS is not implemented; always returns false.
    pub fn qosEnabled(_: *const Network) bool {
        return false;
    }

    // ── Status ───────────────────────────────────────────

    /// Get the current network status (thread-safe, acquires lock).
    pub fn status(self: *Network) VirtualNetworkStatus {
        self._lock.lock();
        defer self._lock.unlock();
        return self.statusInternal();
    }

    /// Internal status computation (caller must hold `_lock`).
    fn statusInternal(self: *const Network) VirtualNetworkStatus {
        if (self._port_error != 0) {
            return c_api.ZT_NETWORK_STATUS_PORT_ERROR;
        }
        return switch (self._netconf_failure) {
            .access_denied => c_api.ZT_NETWORK_STATUS_ACCESS_DENIED,
            .not_found => c_api.ZT_NETWORK_STATUS_NOT_FOUND,
            .authentication_required => c_api.ZT_NETWORK_STATUS_AUTHENTICATION_REQUIRED,
            .none => if (self._config.isSet())
                c_api.ZT_NETWORK_STATUS_OK
            else
                c_api.ZT_NETWORK_STATUS_REQUESTING_CONFIGURATION,
            .init_failed => c_api.ZT_NETWORK_STATUS_PORT_ERROR,
        };
    }

    // ── Mutators ─────────────────────────────────────────

    /// Mark this network as destroyed. The deinit() method will skip
    /// the DOWN callback since DESTROY is handled separately by Node.leave().
    pub fn destroy(self: *Network) void {
        self._lock.lock();
        defer self._lock.unlock();
        self._destroyed = true;
    }

    /// Set network config failure to ACCESS_DENIED and notify host.
    pub fn setAccessDenied(self: *Network, t_ptr: ?*anyopaque) void {
        self._lock.lock();
        defer self._lock.unlock();
        self._netconf_failure = .access_denied;
        self.sendUpdateEvent(t_ptr);
    }

    /// Set network config failure to NOT_FOUND and notify host.
    pub fn setNotFound(self: *Network, t_ptr: ?*anyopaque) void {
        self._lock.lock();
        defer self._lock.unlock();
        self._netconf_failure = .not_found;
        self.sendUpdateEvent(t_ptr);
    }

    /// Set network config failure to AUTHENTICATION_REQUIRED, record the
    /// authentication URL, enable SSO fields, and notify host.
    pub fn setAuthenticationRequired(self: *Network, t_ptr: ?*anyopaque, url: []const u8) void {
        self._lock.lock();
        defer self._lock.unlock();
        self._netconf_failure = .authentication_required;

        // Copy URL into fixed buffer (null-terminate).
        @memset(&self._authentication_url, 0);
        const copy_len = @min(url.len, self._authentication_url.len - 1);
        @memcpy(self._authentication_url[0..copy_len], url[0..copy_len]);

        // Enable SSO in the config.
        self._config.sso_enabled = true;
        self._config.sso_version = 0;

        self.sendUpdateEvent(t_ptr);
    }

    // ── Bridge lookup ────────────────────────────────────

    /// Look up the ZeroTier address to bridge a given MAC through.
    /// Returns a zero Address if not found. Thread-safe (acquires lock).
    pub fn findBridgeTo(self: *Network, mac_val: MAC) Address {
        self._lock.lock();
        defer self._lock.unlock();
        if (self._remote_bridge_routes.get(mac_val)) |addr_ptr| {
            return addr_ptr.*;
        }
        return Address.init(0);
    }

    // ── External config ──────────────────────────────────

    /// Populate a C API VirtualNetworkConfig from internal state.
    /// Thread-safe (acquires lock).
    pub fn externalConfig(self: *Network, ec: *VirtualNetworkConfig) void {
        self._lock.lock();
        defer self._lock.unlock();
        self.externalConfigInternal(ec);
    }

    /// Internal: populate a C API VirtualNetworkConfig. Caller must hold `_lock`.
    fn externalConfigInternal(self: *const Network, ec: *VirtualNetworkConfig) void {
        // Zero the entire struct first to avoid uninitialized padding.
        @memset(mem.asBytes(ec), 0);

        ec.nwid = self._id;
        ec.mac = self._mac.toInt();

        // Name.
        if (self._config.isSet()) {
            @memcpy(&ec.name, &self._config.name);
        } else {
            @memset(&ec.name, 0);
        }

        // Status, type, MTU.
        ec.status = self.statusInternal();
        ec.type = if (self._config.isSet() and self._config.isPublic())
            @intCast(c_api.ZT_NETWORK_TYPE_PUBLIC)
        else
            @intCast(c_api.ZT_NETWORK_TYPE_PRIVATE);

        ec.mtu = if (self._config.isSet()) self._config.mtu else network_config.default_mtu;

        ec.dhcp = 0;

        // Bridge: check if our address is an active bridge.
        ec.bridge = if (self._config.isSet() and self._config.isActiveBridge(self._my_address))
            1
        else
            0;

        ec.broadcastEnabled = if (self._config.isSet() and self._config.enableBroadcast())
            1
        else
            0;

        ec.portError = self._port_error;
        ec.netconfRevision = if (self._config.isSet()) @intCast(self._config.revision) else 0;

        // Assigned addresses.
        if (self._config.isSet()) {
            ec.assignedAddressCount = self._config.static_ip_count;
            const count = @min(self._config.static_ip_count, network_config.max_zt_assigned_addresses);
            for (0..count) |i| {
                const src_bytes = mem.asBytes(&self._config.static_ips[i]);
                const dst_bytes = mem.asBytes(&ec.assignedAddresses[i]);
                @memcpy(dst_bytes[0..src_bytes.len], src_bytes);
            }
        } else {
            ec.assignedAddressCount = 0;
        }

        // Routes.
        if (self._config.isSet()) {
            ec.routeCount = self._config.route_count;
            const rcount = @min(self._config.route_count, network_config.max_network_routes);
            for (0..rcount) |i| {
                const src_bytes = mem.asBytes(&self._config.routes[i]);
                const dst_bytes = mem.asBytes(&ec.routes[i]);
                @memcpy(dst_bytes[0..src_bytes.len], src_bytes);
            }
        } else {
            ec.routeCount = 0;
        }

        // Multicast subscriptions (from local groups).
        {
            const mc_count = @min(self._my_multicast_group_count, max_multicast_subscriptions);
            ec.multicastSubscriptionCount = mc_count;
            for (0..mc_count) |i| {
                ec.multicastSubscriptions[i].mac = self._my_multicast_groups[i].mac().toInt();
                ec.multicastSubscriptions[i].adi = self._my_multicast_groups[i].adi();
            }
        }

        // DNS.
        if (self._config.isSet()) {
            const src_bytes = mem.asBytes(&self._config.dns_conf);
            const dst_bytes = mem.asBytes(&ec.dns);
            @memcpy(dst_bytes[0..src_bytes.len], src_bytes);
        }

        // SSO fields.
        ec.ssoEnabled = if (self._config.isSet()) self._config.sso_enabled else false;
        ec.ssoVersion = if (self._config.isSet()) self._config.sso_version else 0;
        ec.authenticationExpiryTime = if (self._config.isSet()) self._config.authentication_expiry_time else 0;

        copyStrField(&ec.authenticationURL, &self._authentication_url);
        if (self._config.isSet()) {
            copyStrField(&ec.issuerURL, &self._config.issuer_url);
            copyStrField(&ec.centralAuthURL, &self._config.central_auth_url);
            copyStrField(&ec.ssoNonce, &self._config.sso_nonce);
            copyStrField(&ec.ssoState, &self._config.sso_state);
            copyStrField(&ec.ssoClientID, &self._config.sso_client_id);
            copyStrField(&ec.ssoProvider, &self._config.sso_provider);
        }
    }

    // ── Internal helpers ─────────────────────────────────

    /// Build an external config snapshot and fire the host callback with
    /// either UP (first time) or CONFIG_UPDATE.
    fn sendUpdateEvent(self: *Network, t_ptr: ?*anyopaque) void {
        if (self._callbacks.configure_virtual_network_port) |cb| {
            var ec: VirtualNetworkConfig = undefined;
            self.externalConfigInternal(&ec);
            const op: c_uint = if (self._port_initialized)
                c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE
            else
                c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP;
            self._port_error = cb(
                self._callbacks.ctx,
                t_ptr,
                self._id,
                &self._u_ptr,
                op,
                &ec,
            );
        }
    }

    // ── Multicast subscription ───────────────────────────

    /// Check if we're subscribed to a multicast group.
    ///
    /// If `include_bridged` is true, also checks groups learned from
    /// bridged traffic behind us. Thread-safe (acquires lock).
    pub fn subscribedToMulticastGroup(self: *Network, mg: *const MulticastGroup, include_bridged: bool) bool {
        self._lock.lock();
        defer self._lock.unlock();
        return self.subscribedToMulticastGroupInternal(mg, include_bridged);
    }

    /// Internal: check subscription (caller must hold `_lock`).
    fn subscribedToMulticastGroupInternal(self: *const Network, mg: *const MulticastGroup, include_bridged: bool) bool {
        // Binary search the sorted _my_multicast_groups array.
        if (binarySearchMulticastGroup(
            self._my_multicast_groups[0..self._my_multicast_group_count],
            mg,
        ) != null) {
            return true;
        }
        if (include_bridged) {
            const key = MulticastGroupKey.fromMulticastGroup(mg);
            return self._multicast_groups_behind_me.contains(key);
        }
        return false;
    }

    /// Subscribe to a multicast group (sorted insert, dedup).
    ///
    /// If the group is new, optionally fires the announce callback.
    /// Thread-safe (acquires lock).
    pub fn multicastSubscribe(self: *Network, t_ptr: ?*anyopaque, mg: MulticastGroup) void {
        self._lock.lock();
        defer self._lock.unlock();

        // Already subscribed?
        const slice = self._my_multicast_groups[0..self._my_multicast_group_count];
        if (binarySearchMulticastGroup(slice, &mg) != null) return;

        // At capacity?
        if (self._my_multicast_group_count >= max_multicast_subscriptions) return;

        // Find insertion point (upper bound).
        const insert_pos = upperBoundMulticastGroup(slice, &mg);
        const count = self._my_multicast_group_count;

        // Shift elements right to make room.
        var i: u32 = count;
        while (i > insert_pos) : (i -= 1) {
            self._my_multicast_groups[i] = self._my_multicast_groups[i - 1];
        }
        self._my_multicast_groups[insert_pos] = mg;
        self._my_multicast_group_count = count + 1;

        // Announce the new group.
        self.announceMulticastGroups(t_ptr, &[_]MulticastGroup{mg});
    }

    /// Unsubscribe from a multicast group. Silent (no announcement).
    /// Thread-safe (acquires lock).
    pub fn multicastUnsubscribe(self: *Network, mg: *const MulticastGroup) void {
        self._lock.lock();
        defer self._lock.unlock();

        const slice = self._my_multicast_groups[0..self._my_multicast_group_count];
        const idx = binarySearchMulticastGroup(slice, mg) orelse return;

        // Shift elements left.
        const count = self._my_multicast_group_count;
        var i: u32 = idx;
        while (i + 1 < count) : (i += 1) {
            self._my_multicast_groups[i] = self._my_multicast_groups[i + 1];
        }
        // Zero the freed slot.
        self._my_multicast_groups[count - 1] = MulticastGroup.zero();
        self._my_multicast_group_count = count - 1;
    }

    /// Learn a multicast group from bridged traffic.
    ///
    /// Records the group with a timestamp. If new, fires the announce callback.
    /// Thread-safe (acquires lock).
    pub fn learnBridgedMulticastGroup(self: *Network, t_ptr: ?*anyopaque, mg: *const MulticastGroup, now: i64) !void {
        self._lock.lock();
        defer self._lock.unlock();

        const key = MulticastGroupKey.fromMulticastGroup(mg);
        const old_count = self._multicast_groups_behind_me.count();
        try self._multicast_groups_behind_me.set(key, now);
        if (self._multicast_groups_behind_me.count() != old_count) {
            // New group — announce it.
            self.announceMulticastGroups(t_ptr, &[_]MulticastGroup{mg.*});
        }
    }

    /// Collect all multicast groups: direct + bridged + broadcast.
    ///
    /// Returns a sorted, deduplicated array of groups and the count.
    /// Caller must hold `_lock`.
    fn allMulticastGroups(
        self: *const Network,
        buf: *[max_all_multicast_groups]MulticastGroup,
    ) u32 {
        var n: u32 = 0;

        // Copy our direct subscriptions.
        for (0..self._my_multicast_group_count) |i| {
            if (n >= max_all_multicast_groups) break;
            buf[n] = self._my_multicast_groups[i];
            n += 1;
        }

        // Add bridged groups (keys from hashtable).
        var it = self._multicast_groups_behind_me.iterator();
        while (it.next()) |entry| {
            if (n >= max_all_multicast_groups) break;
            const key = entry.key_ptr.*;
            buf[n] = MulticastGroup.init(MAC.init(key._mac_int), key._adi);
            n += 1;
        }

        // Add broadcast if enabled.
        if (self._config.isSet() and self._config.enableBroadcast()) {
            if (n < max_all_multicast_groups) {
                buf[n] = Network.BROADCAST;
                n += 1;
            }
        }

        // Sort and deduplicate.
        if (n > 1) {
            sortMulticastGroups(buf[0..n]);
            n = deduplicateMulticastGroups(buf, n);
        }

        return n;
    }

    // ── Bridge routes ────────────────────────────────────

    /// Learn a bridge route (MAC -> remote peer address).
    ///
    /// Includes anti-DOS eviction: if the table exceeds ZT_MAX_BRIDGE_ROUTES,
    /// the address responsible for the most entries is purged entirely.
    /// Thread-safe (acquires lock).
    pub fn learnBridgeRoute(self: *Network, mac_val: MAC, addr: Address) !void {
        self._lock.lock();
        defer self._lock.unlock();

        try self._remote_bridge_routes.set(mac_val, addr);

        // Anti-DOS circuit breaker.
        while (self._remote_bridge_routes.count() > constants.max_bridge_routes) {
            // Find the address responsible for the most entries.
            var max_addr = Address.init(0);
            var max_count: u64 = 0;

            // We need a temporary count map. Since we can't allocate here without
            // an allocator, we do a two-pass approach using the existing iterator.
            // First pass: find the most common address by scanning all entries.
            // This is O(n^2) in the worst case but the limit is 64M entries,
            // and this path should never be hit in practice.
            var outer_it = self._remote_bridge_routes.iterator();
            while (outer_it.next()) |outer_entry| {
                const candidate = outer_entry.value_ptr.*;
                var cnt: u64 = 0;
                var inner_it = self._remote_bridge_routes.iterator();
                while (inner_it.next()) |inner_entry| {
                    if (inner_entry.value_ptr.*.eql(candidate)) {
                        cnt += 1;
                    }
                }
                if (cnt > max_count) {
                    max_count = cnt;
                    max_addr = candidate;
                }
            }

            // Purge all entries for max_addr.
            if (!max_addr.isSet()) break; // safety: shouldn't happen
            var erase_it = self._remote_bridge_routes.iterator();
            while (erase_it.next()) |entry| {
                if (entry.value_ptr.*.eql(max_addr)) {
                    _ = self._remote_bridge_routes.erase(entry.key_ptr.*);
                }
            }
        }
    }

    // ── Membership management ────────────────────────────

    /// Get or create a Membership for a given address.
    /// Caller must hold `_lock`.
    fn getMembership(self: *Network, addr: Address) !*Membership {
        if (self._memberships.get(addr)) |m| {
            return m;
        }
        try self._memberships.set(addr, Membership.init(self._allocator));
        return self._memberships.get(addr).?;
    }

    /// Check if a peer is gated (allowed) on this network.
    ///
    /// Returns true if the network is public or the peer has valid credentials.
    /// If allowed and it's time for a multicast announcement, fires the
    /// announce callback. Thread-safe (acquires lock).
    pub fn gate(self: *Network, t_ptr: ?*anyopaque, peer_addr: Address, peer_identity: *const Identity, now: i64) bool {
        self._lock.lock();
        defer self._lock.unlock();

        if (!self._config.isSet()) return false;

        const m_ptr = self._memberships.get(peer_addr);
        if (self._config.isPublic() or
            (m_ptr != null and m_ptr.?.isAllowedOnNetwork(&self._config, peer_identity)))
        {
            // Ensure membership exists.
            const m = if (m_ptr) |mp| mp else blk: {
                self._memberships.set(peer_addr, Membership.init(self._allocator)) catch return false;
                break :blk self._memberships.get(peer_addr).?;
            };

            if (m.multicastLikeGate(now)) {
                var groups_buf: [max_all_multicast_groups]MulticastGroup = undefined;
                const group_count = self.allMulticastGroups(&groups_buf);
                self.announceMulticastGroups(t_ptr, groups_buf[0..group_count]);
            }
            return true;
        }
        return false;
    }

    /// Check if a peer was recently associated with this network.
    /// Thread-safe (acquires lock).
    pub fn recentlyAssociatedWith(self: *Network, addr: Address, now: i64) bool {
        self._lock.lock();
        defer self._lock.unlock();
        if (self._memberships.get(addr)) |m| {
            return m.recentlyAssociated(now);
        }
        return false;
    }

    // ── Credential methods ───────────────────────────────

    /// Add a CertificateOfMembership credential.
    /// Thread-safe (acquires lock).
    pub fn addCredentialCom(
        self: *Network,
        com: *const CertificateOfMembership,
        callbacks: membership_mod.VerifyCallbacks,
    ) membership_mod.AddCredentialResult {
        if (com.networkId() != self._id) return .rejected;
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(com.issuedTo()) catch return .rejected;
        return m.addCom(com, callbacks);
    }

    /// Add a Capability credential.
    /// Thread-safe (acquires lock).
    pub fn addCredentialCap(
        self: *Network,
        cap: *const Capability,
        callbacks: membership_mod.VerifyCallbacks,
    ) membership_mod.AddCredentialResult {
        if (cap.networkId() != self._id) return .rejected;
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(cap.issuedTo()) catch return .rejected;
        return m.addCapability(&self._config, cap, callbacks);
    }

    /// Add a Tag credential.
    /// Thread-safe (acquires lock).
    pub fn addCredentialTag(
        self: *Network,
        tag: *const Tag,
        callbacks: membership_mod.VerifyCallbacks,
    ) membership_mod.AddCredentialResult {
        if (tag.networkId() != self._id) return .rejected;
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(tag.issuedTo()) catch return .rejected;
        return m.addTag(&self._config, tag, callbacks);
    }

    /// Add a CertificateOfOwnership credential.
    /// Thread-safe (acquires lock).
    pub fn addCredentialCoo(
        self: *Network,
        coo: *const CertificateOfOwnership,
        callbacks: membership_mod.VerifyCallbacks,
    ) membership_mod.AddCredentialResult {
        if (coo.networkId() != self._id) return .rejected;
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(coo.issuedTo()) catch return .rejected;
        return m.addCoo(&self._config, coo, callbacks);
    }

    /// Add a Revocation credential.
    ///
    /// If the revocation is new and has `fastPropagate()` set, fires the
    /// propagate_revocation callback to forward it to other members.
    /// Thread-safe (acquires lock).
    pub fn addCredentialRevocation(
        self: *Network,
        t_ptr: ?*anyopaque,
        sent_from: Address,
        rev: *const Revocation,
        callbacks: membership_mod.VerifyCallbacks,
    ) membership_mod.AddCredentialResult {
        if (rev.networkId() != self._id) return .rejected;
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(rev.target()) catch return .rejected;
        const result = m.addRevocation(rev, callbacks);

        if (result == .accepted_new and rev.fastPropagate()) {
            if (self._callbacks.propagate_revocation) |cb| {
                cb(self._callbacks.ctx, t_ptr, self._id, rev, sent_from);
            }
        }
        return result;
    }

    /// Push credentials to a peer if they haven't been pushed recently.
    ///
    /// Uses `ZT_PEER_ACTIVITY_TIMEOUT` as the max interval between pushes.
    /// Thread-safe (acquires lock).
    pub fn pushCredentialsIfNeeded(self: *Network, t_ptr: ?*anyopaque, to: Address, now: i64) void {
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(to) catch return;
        const last_pushed = m.lastPushedCredentials();
        if (last_pushed < self._last_config_update or
            (now - last_pushed) > constants.peer_activity_timeout)
        {
            if (self._callbacks.push_credentials) |cb| {
                cb(self._callbacks.ctx, t_ptr, self._id, to, now);
            }
            m.setLastPushedCredentials(now);
        }
    }

    /// Push credentials to a peer in response to their request.
    ///
    /// Rate-limited to `ZT_PEER_CREDENTIALS_REQUEST_RATE_LIMIT`.
    /// Thread-safe (acquires lock).
    pub fn peerRequestedCredentials(self: *Network, t_ptr: ?*anyopaque, to: Address, now: i64) void {
        self._lock.lock();
        defer self._lock.unlock();
        const m = self.getMembership(to) catch return;
        const last_pushed = m.lastPushedCredentials();
        if (last_pushed < self._last_config_update or
            (now - last_pushed) > constants.peer_credentials_request_rate_limit)
        {
            if (self._callbacks.push_credentials) |cb| {
                cb(self._callbacks.ctx, t_ptr, self._id, to, now);
            }
            m.setLastPushedCredentials(now);
        }
    }

    // ── Cleanup ──────────────────────────────────────────

    /// Clean expired bridged multicast groups and stale memberships.
    ///
    /// Bridged groups older than `2 * ZT_MULTICAST_LIKE_EXPIRE` are removed.
    /// Memberships for peers no longer in topology are removed; surviving
    /// memberships have their stale credentials cleaned.
    /// Thread-safe (acquires lock).
    pub fn clean(self: *Network, now: i64) void {
        self._lock.lock();
        defer self._lock.unlock();

        if (self._destroyed) return;

        // Clean bridged multicast groups.
        const expire_threshold = constants.multicast_like_expire * 2;
        var mg_it = self._multicast_groups_behind_me.iterator();
        while (mg_it.next()) |entry| {
            if ((now - entry.value_ptr.*) > expire_threshold) {
                _ = self._multicast_groups_behind_me.erase(entry.key_ptr.*);
            }
        }

        // Clean memberships.
        var m_it = self._memberships.iterator();
        while (m_it.next()) |entry| {
            const peer_exists = if (self._callbacks.peer_exists) |cb|
                cb(self._callbacks.ctx, entry.key_ptr.*)
            else
                true; // assume peer exists if no callback

            if (!peer_exists) {
                entry.value_ptr.deinit();
                _ = self._memberships.erase(entry.key_ptr.*);
            } else {
                entry.value_ptr.clean(&self._config);
            }
        }
    }

    // ── Packet filter methods ────────────────────────────

    /// Filter an outgoing packet through network rules and capabilities.
    ///
    /// Returns true if the frame should be sent, false if dropped.
    /// On redirect (zt_dest changed), the frame is forwarded to the new
    /// destination via callback and the local send is suppressed.
    ///
    /// `qos_bucket` is set by the rules engine (PRIORITY action).
    /// Thread-safe (acquires lock).
    pub fn filterOutgoingPacket(
        self: *Network,
        t_ptr: ?*anyopaque,
        no_tee: bool,
        zt_source: Address,
        zt_dest: Address,
        mac_source: MAC,
        mac_dest: MAC,
        frame_data: []const u8,
        frame_len: u32,
        ether_type: u16,
        vlan_id: u16,
        qos_bucket: *u8,
    ) bool {
        var local_capability_index: ?u32 = null;
        var accept: i32 = 0;
        var rrl: RuleResultLog = undefined;
        var crrl: RuleResultLog = undefined;
        var outputs = FilterOutputs{};

        self._lock.lock();
        defer self._lock.unlock();

        const membership: ?*const Membership = if (zt_dest.isSet())
            if (self._memberships.get(zt_dest)) |m| m else null
        else
            null;

        const result = doZtFilter(
            &rrl,
            &self._config,
            membership,
            false,
            zt_source,
            zt_dest,
            mac_source,
            mac_dest,
            frame_data,
            frame_len,
            ether_type,
            vlan_id,
            self._config.rules_arr[0..self._config.rule_count],
            self._my_address,
            self._callbacks.prng,
            self._callbacks.ctx,
            &outputs,
        );

        switch (result) {
            .no_match => {
                // Try capabilities.
                var c_idx: u32 = 0;
                while (c_idx < self._config.capability_count) : (c_idx += 1) {
                    var cap_outputs = FilterOutputs{};
                    cap_outputs.zt_dest = zt_dest;
                    const cap = &self._config.capabilities[c_idx];
                    const cap_result = doZtFilter(
                        &crrl,
                        &self._config,
                        membership,
                        false,
                        zt_source,
                        zt_dest,
                        mac_source,
                        mac_dest,
                        frame_data,
                        frame_len,
                        ether_type,
                        vlan_id,
                        cap.rules(),
                        self._my_address,
                        self._callbacks.prng,
                        self._callbacks.ctx,
                        &cap_outputs,
                    );
                    switch (cap_result) {
                        .no_match, .drop => {},
                        .redirect, .accept, .super_accept => {
                            local_capability_index = c_idx;
                            accept = 1;
                            outputs.zt_dest = cap_outputs.zt_dest;

                            if (!no_tee and cap_outputs.cc.isSet()) {
                                if (self._callbacks.send_ext_frame) |cb| {
                                    cb(
                                        self._callbacks.ctx,
                                        t_ptr,
                                        self._id,
                                        cap_outputs.cc,
                                        if (cap_outputs.cc_watch) @as(u8, 0x16) else @as(u8, 0x02),
                                        mac_dest,
                                        mac_source,
                                        ether_type,
                                        frame_data[0..@min(frame_data.len, cap_outputs.cc_length)],
                                    );
                                }
                            }
                            break;
                        },
                    }
                }
            },
            .drop => {
                self.traceFilter(t_ptr, &rrl, null, null, zt_source, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, no_tee, false, 0);
                return false;
            },
            .redirect, .accept => {
                accept = 1;
            },
            .super_accept => {
                accept = 2;
            },
        }

        if (accept != 0) {
            self._outgoing_packets_accepted += 1;
            qos_bucket.* = outputs.qos_bucket;

            if (!no_tee and outputs.cc.isSet()) {
                if (self._callbacks.send_ext_frame) |cb| {
                    cb(
                        self._callbacks.ctx,
                        t_ptr,
                        self._id,
                        outputs.cc,
                        if (outputs.cc_watch) @as(u8, 0x16) else @as(u8, 0x02),
                        mac_dest,
                        mac_source,
                        ether_type,
                        frame_data[0..@min(frame_data.len, outputs.cc_length)],
                    );
                }
            }

            if (!outputs.zt_dest.eql(zt_dest) and outputs.zt_dest.isSet()) {
                // Redirect — send to new dest, drop locally.
                if (self._callbacks.send_ext_frame) |cb| {
                    cb(
                        self._callbacks.ctx,
                        t_ptr,
                        self._id,
                        outputs.zt_dest,
                        0x04,
                        mac_dest,
                        mac_source,
                        ether_type,
                        frame_data[0..@min(frame_data.len, frame_len)],
                    );
                }
                self.traceFilterWithCap(t_ptr, &rrl, local_capability_index, &crrl, zt_source, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, no_tee, false, 0);
                return false; // DROP locally since we redirected
            } else {
                self.traceFilterWithCap(t_ptr, &rrl, local_capability_index, &crrl, zt_source, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, no_tee, false, 1);
                return true;
            }
        } else {
            self._outgoing_packets_dropped += 1;
            self.traceFilterWithCap(t_ptr, &rrl, local_capability_index, &crrl, zt_source, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, no_tee, false, 0);
            return false;
        }
    }

    /// Filter an incoming packet through network rules and capabilities.
    ///
    /// Returns: 0 = drop, 1 = accept, 2 = super-accept.
    /// Thread-safe (acquires lock).
    pub fn filterIncomingPacket(
        self: *Network,
        t_ptr: ?*anyopaque,
        source_addr: Address,
        zt_dest: Address,
        mac_source: MAC,
        mac_dest: MAC,
        frame_data: []const u8,
        frame_len: u32,
        ether_type: u16,
        vlan_id: u16,
    ) i32 {
        var rrl: RuleResultLog = undefined;
        var crrl: RuleResultLog = undefined;
        var accept: i32 = 0;
        var outputs = FilterOutputs{};
        var matched_cap: ?*const Capability = null;
        const qos_bucket: u8 = 255; // dummy for inbound

        self._lock.lock();
        defer self._lock.unlock();

        const m_ptr = self._memberships.get(source_addr);

        const result = doZtFilter(
            &rrl,
            &self._config,
            if (m_ptr) |m| m else null,
            true,
            source_addr,
            zt_dest,
            mac_source,
            mac_dest,
            frame_data,
            frame_len,
            ether_type,
            vlan_id,
            self._config.rules_arr[0..self._config.rule_count],
            self._my_address,
            self._callbacks.prng,
            self._callbacks.ctx,
            &outputs,
        );

        switch (result) {
            .no_match => {
                // Iterate peer's valid capabilities.
                if (m_ptr) |m| {
                    var cap_it = m.capabilityIterator(&self._config);
                    while (cap_it.next()) |cap| {
                        var cap_outputs = FilterOutputs{};
                        cap_outputs.zt_dest = zt_dest;
                        const cap_result = doZtFilter(
                            &crrl,
                            &self._config,
                            m,
                            true,
                            source_addr,
                            zt_dest,
                            mac_source,
                            mac_dest,
                            frame_data,
                            frame_len,
                            ether_type,
                            vlan_id,
                            cap.rules(),
                            self._my_address,
                            self._callbacks.prng,
                            self._callbacks.ctx,
                            &cap_outputs,
                        );
                        switch (cap_result) {
                            .no_match, .drop => {},
                            .redirect, .accept => {
                                accept = 1;
                                matched_cap = cap;
                                outputs.zt_dest = cap_outputs.zt_dest;
                            },
                            .super_accept => {
                                accept = 2;
                                matched_cap = cap;
                                outputs.zt_dest = cap_outputs.zt_dest;
                            },
                        }

                        if (accept != 0) {
                            if (cap_outputs.cc.isSet()) {
                                if (self._callbacks.send_ext_frame) |cb| {
                                    cb(
                                        self._callbacks.ctx,
                                        t_ptr,
                                        self._id,
                                        cap_outputs.cc,
                                        if (cap_outputs.cc_watch) @as(u8, 0x1c) else @as(u8, 0x08),
                                        mac_dest,
                                        mac_source,
                                        ether_type,
                                        frame_data[0..@min(frame_data.len, cap_outputs.cc_length)],
                                    );
                                }
                            }
                            break;
                        }
                    }
                }
            },
            .drop => {
                self.traceFilter(t_ptr, &rrl, null, null, source_addr, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, false, true, 0);
                return 0;
            },
            .redirect, .accept => {
                accept = 1;
            },
            .super_accept => {
                accept = 2;
            },
        }

        _ = qos_bucket;

        if (accept != 0) {
            self._incoming_packets_accepted += 1;
            if (outputs.cc.isSet()) {
                if (self._callbacks.send_ext_frame) |cb| {
                    cb(
                        self._callbacks.ctx,
                        t_ptr,
                        self._id,
                        outputs.cc,
                        if (outputs.cc_watch) @as(u8, 0x1c) else @as(u8, 0x08),
                        mac_dest,
                        mac_source,
                        ether_type,
                        frame_data[0..@min(frame_data.len, outputs.cc_length)],
                    );
                }
            }

            if (!outputs.zt_dest.eql(zt_dest) and outputs.zt_dest.isSet()) {
                // Redirect — send to new dest, drop locally.
                if (self._callbacks.send_ext_frame) |cb| {
                    cb(
                        self._callbacks.ctx,
                        t_ptr,
                        self._id,
                        outputs.zt_dest,
                        0x0a,
                        mac_dest,
                        mac_source,
                        ether_type,
                        frame_data[0..@min(frame_data.len, frame_len)],
                    );
                }
                self.traceFilter(t_ptr, &rrl, if (matched_cap != null) &crrl else null, matched_cap, source_addr, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, false, true, 0);
                return 0; // DROP locally since we redirected
            }
        } else {
            self._incoming_packets_dropped += 1;
        }

        self.traceFilter(t_ptr, &rrl, if (matched_cap != null) &crrl else null, matched_cap, source_addr, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, false, true, accept);
        return accept;
    }

    // ── Configuration methods ────────────────────────────

    /// Apply a NetworkConfig to this network.
    ///
    /// Returns:
    ///   0 — invalid or rejected (wrong network / wrong issued-to)
    ///   1 — valid but duplicate of current config
    ///   2 — valid and applied (new configuration)
    ///
    /// When the configuration changes, fires a UP or CONFIG_UPDATE callback
    /// depending on whether the port was previously initialized.
    /// If `save_to_disk` is true, persists the config via the state_object_put callback.
    /// Thread-safe (acquires lock internally).
    pub fn setConfiguration(self: *Network, t_ptr: ?*anyopaque, nconf: *const NetworkConfig, save_to_disk: bool) i32 {
        if (self._destroyed) return 0;

        // Validate: config must be for this network and for us.
        if (nconf.issued_to.toInt() != self._my_address.toInt()) return 0;
        if (nconf.network_id != self._id) return 0;

        // Check for duplicate.
        if (mem.eql(u8, mem.asBytes(&self._config), mem.asBytes(nconf))) return 1;

        var ec: VirtualNetworkConfig = undefined;
        var old_port_initialized: bool = undefined;

        {
            self._lock.lock();
            defer self._lock.unlock();

            self._config = nconf.*;
            self._last_config_update = if (self._callbacks.now) |now_fn| now_fn(self._callbacks.ctx) else 0;
            self._netconf_failure = .none;
            old_port_initialized = self._port_initialized;
            self._port_initialized = true;
            self.externalConfigInternal(&ec);
        }

        // Fire callback outside the lock.
        if (self._callbacks.configure_virtual_network_port) |cb| {
            const op: c_uint = if (old_port_initialized)
                c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE
            else
                c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP;
            self._port_error = cb(self._callbacks.ctx, t_ptr, self._id, &self._u_ptr, op, &ec);
        }

        // Persist to disk if requested.
        if (save_to_disk) {
            if (self._callbacks.state_object_put) |put_fn| {
                var dict = Dictionary(network_config.dict_capacity).init();
                nconf.toDictionary(&dict) catch {};
                const ids = [2]u64{ self._id, 0 };
                put_fn(
                    self._callbacks.ctx,
                    t_ptr,
                    c_api.ZT_STATE_OBJECT_NETWORK_CONFIG,
                    ids,
                    @as([*]const u8, dict.data()),
                    @intCast(dict.sizeBytes()),
                );
            }
        }

        return 2;
    }

    /// Handle an incoming network config chunk (from VERB_NETWORK_CONFIG or
    /// OK(NETWORK_CONFIG_REQUEST)).
    ///
    /// The `chunk` slice starts after the initial packet header. `ptr` is the
    /// starting offset within `chunk` where the network-config payload begins.
    /// `source` is the address of the sender.
    ///
    /// Returns the config update ID if the config was fully reassembled and
    /// applied, or 0 on error / incomplete.
    ///
    /// Thread-safe (acquires lock internally for chunk reassembly).
    pub fn handleConfigChunk(
        self: *Network,
        t_ptr: ?*anyopaque,
        packet_id: u64,
        source: Address,
        chunk: []const u8,
        start_ptr: u32,
    ) u64 {
        if (self._destroyed) return 0;

        var ptr = start_ptr;

        // Skip network ID (8 bytes) — already known.
        if (ptr + 8 > chunk.len) return 0;
        ptr += 8;

        // Read chunk length.
        if (ptr + 2 > chunk.len) return 0;
        const chunk_len: u32 = @as(u32, chunk[ptr]) << 8 | @as(u32, chunk[ptr + 1]);
        ptr += 2;

        // Validate and read chunk data.
        if (ptr + chunk_len > chunk.len) return 0;
        const chunk_data = chunk[ptr .. ptr + chunk_len];
        ptr += chunk_len;

        var nc_bytes: ?[]const u8 = null;
        var config_update_id: u64 = 0;

        {
            self._lock.lock();
            defer self._lock.unlock();

            var c: ?*IncomingConfigChunk = null;
            var chunk_id: u64 = 0;
            var total_length: u32 = undefined;
            var chunk_index: u32 = undefined;

            if (ptr < chunk.len) {
                // New signed multi-chunk format.
                if (ptr + 1 > chunk.len) return 0;
                const fast_propagate = (chunk[ptr] & 0x01) != 0;
                ptr += 1;

                if (ptr + 8 > chunk.len) return 0;
                config_update_id = readU64(chunk, ptr);
                ptr += 8;

                if (ptr + 4 > chunk.len) return 0;
                total_length = readU32(chunk, ptr);
                ptr += 4;

                if (ptr + 4 > chunk.len) return 0;
                chunk_index = readU32(chunk, ptr);
                ptr += 4;

                // Bounds checks.
                if ((chunk_index + chunk_len) > total_length) return 0;
                if (total_length >= network_config.dict_capacity) return 0;

                // Verify signature header.
                if (ptr + 3 > chunk.len) return 0;
                if (chunk[ptr] != 1) return 0;
                const sig_len = @as(u16, chunk[ptr + 1]) << 8 | @as(u16, chunk[ptr + 2]);
                if (sig_len != ecc.signature_len) return 0;
                if (ptr + 3 + ecc.signature_len > chunk.len) return 0;
                const sig = chunk[ptr + 3 .. ptr + 3 + ecc.signature_len];

                // Derive chunk ID from first 16 bytes of signature.
                for (0..16) |i| {
                    const byte_idx = i & 7;
                    const id_bytes = @as(*[8]u8, @ptrCast(&chunk_id));
                    id_bytes[byte_idx] ^= sig[i];
                }

                // Find existing or new slot for this update.
                for (&self._incoming_config_chunks) |*slot| {
                    if (slot.update_id == config_update_id) {
                        c = slot;
                        // Check for duplicate chunk.
                        for (slot.have_chunk_ids[0..slot.have_chunks]) |cid| {
                            if (cid == chunk_id) return 0;
                        }
                        break;
                    } else if (c == null or slot.ts < c.?.ts) {
                        c = slot;
                    }
                }

                // Verify signature against controller identity.
                const signed_data = chunk[start_ptr..ptr];
                if (self._callbacks.verify_controller_signature) |verify_fn| {
                    if (!verify_fn(self._callbacks.ctx, t_ptr, self._id, signed_data, sig)) {
                        return 0;
                    }
                } else {
                    // No verification callback — can't verify chunk.
                    return 0;
                }

                // Fast propagation: forward to all known members except source and controller.
                if (fast_propagate) {
                    if (self._callbacks.send_network_config) |send_fn| {
                        const propagate_data = chunk[start_ptr..];
                        var m_it = self._memberships.iterator();
                        while (m_it.next()) |entry| {
                            if (!entry.key_ptr.eql(source) and !entry.key_ptr.eql(self.controller())) {
                                send_fn(self._callbacks.ctx, t_ptr, self._id, entry.key_ptr.*, propagate_data);
                            }
                        }
                    }
                }
            } else if (source.eql(self.controller()) or !source.isSet()) {
                // Legacy single-chunk unsigned format (only from controller).
                chunk_id = packet_id;
                config_update_id = chunk_id;
                total_length = chunk_len;
                chunk_index = 0;

                if (total_length >= network_config.dict_capacity) return 0;

                // Find oldest slot.
                for (&self._incoming_config_chunks) |*slot| {
                    if (c == null or slot.ts < c.?.ts) {
                        c = slot;
                    }
                }
            } else {
                return 0;
            }

            const slot = c orelse return 0;
            slot.ts += 1;

            if (slot.update_id != config_update_id) {
                slot.update_id = config_update_id;
                slot.have_chunks = 0;
                slot.have_bytes = 0;
            }
            if (slot.have_chunks >= max_update_chunks) return 0;
            slot.have_chunk_ids[slot.have_chunks] = chunk_id;
            slot.have_chunks += 1;

            // Copy chunk data into reassembly buffer.
            const dst_end = chunk_index + chunk_len;
            if (dst_end > slot.data._d.len) return 0;
            @memcpy(slot.data._d[chunk_index..dst_end], chunk_data);
            slot.have_bytes += chunk_len;

            if (slot.have_bytes == total_length) {
                // Complete! Null-terminate.
                if (total_length < slot.data._d.len) {
                    slot.data._d[total_length] = 0;
                }
                nc_bytes = slot.data._d[0..total_length];
            }
        }

        // Parse and apply config outside the lock.
        if (nc_bytes) |config_data| {
            var nc = NetworkConfig.init();
            var dict = Dictionary(network_config.dict_capacity).init();
            // Load the raw bytes into the dictionary's internal buffer.
            @memcpy(dict._d[0..config_data.len], config_data);
            // Null-terminate so sizeBytes() picks up the correct length.
            if (config_data.len < network_config.dict_capacity) {
                dict._d[config_data.len] = 0;
            }
            if (nc.fromDictionary(&dict)) {
                const result = self.setConfiguration(t_ptr, &nc, true);
                if (result == 2) return config_update_id;
            }
        }

        return 0;
    }

    /// Request a network configuration from the controller.
    ///
    /// For special ad-hoc network IDs (0xFF prefix), generates a local config.
    /// For normal networks, sends a VERB_NETWORK_CONFIG_REQUEST to the controller.
    /// Thread-safe.
    pub fn requestConfiguration(self: *Network, t_ptr: ?*anyopaque) void {
        if (self._destroyed) return;

        // Ad-hoc network handling: network IDs starting with 0xFF.
        if ((self._id >> 56) == 0xff) {
            if ((self._id & 0xffffff) == 0) {
                // ffXXXXYYYYaaaaaa00 — ad-hoc IPv6 port-range network.
                const start_port_range: u16 = @intCast((self._id >> 40) & 0xffff);
                const end_port_range: u16 = @intCast((self._id >> 24) & 0xffff);
                if (end_port_range >= start_port_range) {
                    var nconf = NetworkConfig.init();
                    nconf.network_id = self._id;
                    nconf.timestamp = if (self._callbacks.now) |now_fn| now_fn(self._callbacks.ctx) else 0;
                    nconf.credential_time_max_delta = network_config.default_credential_time_max_max_delta;
                    nconf.revision = 1;
                    nconf.issued_to = self._my_address;
                    nconf.flags = network_config.flag_enable_ipv6_ndp_emulation;
                    nconf.mtu = constants.default_mtu;
                    nconf.multicast_limit = 0;
                    nconf.static_ip_count = 1;
                    nconf.rule_count = 14;
                    nconf.static_ips[0] = InetAddress.makeIpv66plane(self._id, self._my_address.toInt());
                    nconf.net_type = @intCast(c_api.ZT_NETWORK_TYPE_PUBLIC);

                    // Drop everything but IPv6
                    nconf.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE) | 0x80; // NOT
                    nconf.rules_arr[0].v = .{ .etherType = 0x86dd }; // IPv6
                    nconf.rules_arr[1].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_DROP);

                    // Allow ICMPv6
                    nconf.rules_arr[2].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_IP_PROTOCOL);
                    nconf.rules_arr[2].v = .{ .ipProtocol = 0x3a }; // ICMPv6
                    nconf.rules_arr[3].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

                    // Allow destination ports within range
                    nconf.rules_arr[4].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_IP_PROTOCOL);
                    nconf.rules_arr[4].v = .{ .ipProtocol = 0x11 }; // UDP
                    nconf.rules_arr[5].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_IP_PROTOCOL) | 0x40; // OR
                    nconf.rules_arr[5].v = .{ .ipProtocol = 0x06 }; // TCP
                    nconf.rules_arr[6].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_IP_DEST_PORT_RANGE);
                    nconf.rules_arr[6].v = .{ .port = [2]u16{ start_port_range, end_port_range } };
                    nconf.rules_arr[7].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

                    // Allow non-SYN TCP packets
                    nconf.rules_arr[8].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_CHARACTERISTICS) | 0x80; // NOT
                    nconf.rules_arr[8].v = .{ .characteristics = c_api.ZT_RULE_PACKET_CHARACTERISTICS_TCP_SYN };
                    nconf.rules_arr[9].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

                    // Allow SYN+ACK (replies to SYN)
                    nconf.rules_arr[10].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_CHARACTERISTICS);
                    nconf.rules_arr[10].v = .{ .characteristics = c_api.ZT_RULE_PACKET_CHARACTERISTICS_TCP_SYN };
                    nconf.rules_arr[11].t = @as(u8, c_api.ZT_NETWORK_RULE_MATCH_CHARACTERISTICS);
                    nconf.rules_arr[11].v = .{ .characteristics = c_api.ZT_RULE_PACKET_CHARACTERISTICS_TCP_ACK };
                    nconf.rules_arr[12].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

                    nconf.rules_arr[13].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_DROP);

                    // Build name: "adhoc-XXXX-YYYY"
                    const name_bytes = "adhoc-";
                    @memcpy(nconf.name[0..name_bytes.len], name_bytes);
                    hexU16(nconf.name[6..10], start_port_range);
                    nconf.name[10] = '-';
                    hexU16(nconf.name[11..15], end_port_range);
                    nconf.name[15] = 0;

                    _ = self.setConfiguration(t_ptr, &nconf, false);
                } else {
                    self.setNotFound(t_ptr);
                }
            } else if ((self._id & 0xff) == 0x01) {
                // ffAAaaaaaaaaaa01 — ad-hoc IPv4+IPv6 network.
                const my_addr_int = self._my_address.toInt();
                const network_hub = (self._id >> 8) & 0xffffffffff;
                const ipv4_net: u8 = @intCast((self._id >> 48) & 0xff);

                var ipv4: [4]u8 = undefined;
                ipv4[0] = ipv4_net;
                ipv4[1] = @intCast((my_addr_int >> 16) & 0xff);
                ipv4[2] = @intCast((my_addr_int >> 8) & 0xff);
                ipv4[3] = @intCast(my_addr_int & 0xff);

                var nconf = NetworkConfig.init();
                nconf.network_id = self._id;
                nconf.timestamp = if (self._callbacks.now) |now_fn| now_fn(self._callbacks.ctx) else 0;
                nconf.credential_time_max_delta = network_config.default_credential_time_max_max_delta;
                nconf.revision = 1;
                nconf.issued_to = self._my_address;
                nconf.flags = network_config.flag_enable_ipv6_ndp_emulation;
                nconf.mtu = constants.default_mtu;
                nconf.multicast_limit = 1024;
                nconf.specialist_count = if (network_hub == 0) 0 else 1;
                nconf.static_ip_count = 2;
                nconf.rule_count = 1;
                nconf.net_type = @intCast(c_api.ZT_NETWORK_TYPE_PUBLIC);

                if (network_hub != 0) {
                    nconf.specialists[0] = network_hub;
                }

                nconf.static_ips[0] = InetAddress.makeIpv66plane(self._id, my_addr_int);
                nconf.static_ips[1].set(&ipv4, 8);

                nconf.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

                // Build name: "adhoc-NNN.0.0.0"
                const name_prefix = "adhoc-";
                @memcpy(nconf.name[0..name_prefix.len], name_prefix);
                var nn: u32 = 6;
                nn += decimalU8(nconf.name[nn..], ipv4_net);
                nconf.name[nn] = '.';
                nn += 1;
                nconf.name[nn] = '0';
                nn += 1;
                nconf.name[nn] = '.';
                nn += 1;
                nconf.name[nn] = '0';
                nn += 1;
                nconf.name[nn] = '.';
                nn += 1;
                nconf.name[nn] = '0';
                nn += 1;
                nconf.name[nn] = 0;

                _ = self.setConfiguration(t_ptr, &nconf, false);
            }
            return;
        }

        // Normal network: send config request to controller.
        const ctrl = self.controller();

        // Fire trace callback.
        if (self._callbacks.network_config_request_sent) |cb| {
            cb(self._callbacks.ctx, t_ptr, self._id, ctrl);
        }

        // If we ARE the controller, make a local request.
        if (ctrl.eql(self._my_address)) {
            if (self._callbacks.local_controller_request) |cb| {
                var rmd = buildRequestMetadata();
                cb(self._callbacks.ctx, self._id, self._my_address, rmd.slice());
            } else {
                self.setNotFound(t_ptr);
            }
            return;
        }

        // Send to remote controller.
        if (self._callbacks.send_network_config_request) |cb| {
            var rmd = buildRequestMetadata();
            self._lock.lock();
            const has_config = self._config.isSet();
            const revision = self._config.revision;
            const timestamp = self._config.timestamp;
            self._lock.unlock();

            cb(
                self._callbacks.ctx,
                t_ptr,
                self._id,
                ctrl,
                rmd.slice(),
                if (has_config) revision else 0,
                if (has_config) @as(u64, @bitCast(timestamp)) else 0,
            );
        }
    }

    // ── Internal trace helpers ───────────────────────────

    /// Fire the network filter trace callback if remote trace target is configured.
    fn traceFilter(
        self: *Network,
        t_ptr: ?*anyopaque,
        rrl: *const RuleResultLog,
        cap_rrl: ?*const RuleResultLog,
        cap: ?*const Capability,
        zt_source: Address,
        zt_dest: Address,
        mac_source: MAC,
        mac_dest: MAC,
        frame_data: []const u8,
        ether_type: u16,
        vlan_id: u16,
        no_tee: bool,
        inbound: bool,
        accept_val: i32,
    ) void {
        if (self._config.remote_trace_target.isSet()) {
            if (self._callbacks.network_filter_trace) |cb| {
                cb(self._callbacks.ctx, t_ptr, self._id, rrl, cap_rrl, cap, zt_source, zt_dest, mac_source, mac_dest, frame_data, ether_type, vlan_id, no_tee, inbound, accept_val);
            }
        }
    }

    /// Fire trace with capability index resolution.
    fn traceFilterWithCap(
        self: *Network,
        t_ptr: ?*anyopaque,
        rrl: *const RuleResultLog,
        cap_idx: ?u32,
        cap_rrl: *const RuleResultLog,
        zt_source: Address,
        zt_dest: Address,
        mac_source: MAC,
        mac_dest: MAC,
        frame_data: []const u8,
        ether_type: u16,
        vlan_id: u16,
        no_tee: bool,
        inbound: bool,
        accept_val: i32,
    ) void {
        if (self._config.remote_trace_target.isSet()) {
            if (self._callbacks.network_filter_trace) |cb| {
                const cap: ?*const Capability = if (cap_idx) |idx|
                    &self._config.capabilities[idx]
                else
                    null;
                cb(
                    self._callbacks.ctx,
                    t_ptr,
                    self._id,
                    rrl,
                    if (cap_idx != null) cap_rrl else null,
                    cap,
                    zt_source,
                    zt_dest,
                    mac_source,
                    mac_dest,
                    frame_data,
                    ether_type,
                    vlan_id,
                    no_tee,
                    inbound,
                    accept_val,
                );
            }
        }
    }

    /// Fire the multicast group announcement callback if available.
    fn announceMulticastGroups(self: *Network, t_ptr: ?*anyopaque, groups: []const MulticastGroup) void {
        if (self._callbacks.announce_multicast_groups) |cb| {
            cb(self._callbacks.ctx, t_ptr, self._id, self._my_address, groups);
        }
    }
};

// ── Module-level helpers ─────────────────────────────────────────

/// Maximum total multicast groups across all sources (direct + bridged + broadcast).
const max_all_multicast_groups: u32 = max_multicast_subscriptions * 2 + 1;

// ── Byte-reading helpers ─────────────────────────────────────────

/// Read a big-endian u64 from a byte slice at the given offset.
fn readU64(buf: []const u8, offset: u32) u64 {
    const o = offset;
    return @as(u64, buf[o]) << 56 |
        @as(u64, buf[o + 1]) << 48 |
        @as(u64, buf[o + 2]) << 40 |
        @as(u64, buf[o + 3]) << 32 |
        @as(u64, buf[o + 4]) << 24 |
        @as(u64, buf[o + 5]) << 16 |
        @as(u64, buf[o + 6]) << 8 |
        @as(u64, buf[o + 7]);
}

/// Read a big-endian u32 from a byte slice at the given offset.
fn readU32(buf: []const u8, offset: u32) u32 {
    const o = offset;
    return @as(u32, buf[o]) << 24 |
        @as(u32, buf[o + 1]) << 16 |
        @as(u32, buf[o + 2]) << 8 |
        @as(u32, buf[o + 3]);
}

// ── String formatting helpers ────────────────────────────────────

/// Write a u16 as 4 lowercase hex characters into a 4-byte slice.
fn hexU16(dst: *[4]u8, value: u16) void {
    const hex = "0123456789abcdef";
    dst[0] = hex[(value >> 12) & 0xf];
    dst[1] = hex[(value >> 8) & 0xf];
    dst[2] = hex[(value >> 4) & 0xf];
    dst[3] = hex[value & 0xf];
}

/// Write a u8 as decimal digits (1-3 chars) into a slice.
/// Returns the number of bytes written.
fn decimalU8(dst: []u8, value: u8) u32 {
    if (value >= 100) {
        dst[0] = '0' + value / 100;
        dst[1] = '0' + (value / 10) % 10;
        dst[2] = '0' + value % 10;
        return 3;
    } else if (value >= 10) {
        dst[0] = '0' + value / 10;
        dst[1] = '0' + value % 10;
        return 2;
    } else {
        dst[0] = '0' + value;
        return 1;
    }
}

// ── Request metadata builder ─────────────────────────────────────

/// Protocol version constant (from Packet.hpp).
const proto_version: u64 = 13;

/// Network config version constant (from NetworkConfig.hpp).
const networkconfig_version: u64 = 7;

/// Rules engine revision (from ZeroTierOne.h).
const rules_engine_revision: u64 = c_api.ZT_RULES_ENGINE_REVISION;

/// Version constants (from version.h).
const version_major: u64 = 1;
const version_minor: u64 = 16;
const version_revision: u64 = 1;

/// Build a request metadata dictionary for VERB_NETWORK_CONFIG_REQUEST.
/// Contains version info, capabilities, and platform identification.
fn buildRequestMetadata() Dictionary(network_config.metadata_dict_capacity) {
    var rmd = Dictionary(network_config.metadata_dict_capacity).init();
    rmd.addU64("v", networkconfig_version) catch {};
    rmd.addU64("vend", c_api.ZT_VENDOR_ZEROTIER) catch {};
    rmd.addU64("pv", proto_version) catch {};
    rmd.addU64("majv", version_major) catch {};
    rmd.addU64("minv", version_minor) catch {};
    rmd.addU64("revv", version_revision) catch {};
    rmd.addU64("mr", c_api.ZT_MAX_NETWORK_RULES) catch {};
    rmd.addU64("mc", c_api.ZT_MAX_NETWORK_CAPABILITIES) catch {};
    rmd.addU64("mcr", c_api.ZT_MAX_CAPABILITY_RULES) catch {};
    rmd.addU64("mt", c_api.ZT_MAX_NETWORK_TAGS) catch {};
    rmd.addU64("f", 0) catch {};
    rmd.addU64("revr", rules_engine_revision) catch {};
    // OS/arch identification.
    const os_name = if (@import("builtin").os.tag == .macos) "macos" else "linux";
    const arch_name = if (@import("builtin").cpu.arch == .aarch64) "arm64" else "x86_64";
    rmd.addStr("o", os_name ++ "/" ++ arch_name) catch {};
    return rmd;
}

/// Copy a fixed-size string field from `src` to `dst`, ensuring null-termination.
fn copyStrField(dst: anytype, src: anytype) void {
    const len = @min(dst.len, src.len);
    @memcpy(dst[0..len], src[0..len]);
    if (dst.len > 0) {
        dst[dst.len - 1] = 0;
    }
}

// ── Multicast group array helpers ────────────────────────────────

/// Binary search a sorted slice of MulticastGroups.
/// Returns the index if found, or null.
fn binarySearchMulticastGroup(slice: []const MulticastGroup, target: *const MulticastGroup) ?u32 {
    if (slice.len == 0) return null;
    var lo: u32 = 0;
    var hi: u32 = @intCast(slice.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const ord = slice[mid].order(target);
        switch (ord) {
            .eq => return mid,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Find the upper-bound insertion point for a MulticastGroup in a sorted slice.
/// Returns the first index where the element would be greater than `target`.
fn upperBoundMulticastGroup(slice: []const MulticastGroup, target: *const MulticastGroup) u32 {
    var lo: u32 = 0;
    var hi: u32 = @intCast(slice.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (slice[mid].lessThan(target) or slice[mid].eql(target)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Sort a slice of MulticastGroups using insertion sort.
/// Insertion sort is appropriate here since the arrays are small (< 4096 entries).
fn sortMulticastGroups(groups: []MulticastGroup) void {
    if (groups.len <= 1) return;
    for (1..groups.len) |i_usize| {
        const i: u32 = @intCast(i_usize);
        const key = groups[i];
        var j: u32 = i;
        while (j > 0 and groups[j - 1].lessThan(&key) == false and !groups[j - 1].eql(&key)) : (j -= 1) {
            groups[j] = groups[j - 1];
        }
        groups[j] = key;
    }
}

/// Remove consecutive duplicates from a sorted MulticastGroup array.
/// Returns the new count after deduplication.
fn deduplicateMulticastGroups(buf: *[max_all_multicast_groups]MulticastGroup, count: u32) u32 {
    if (count <= 1) return count;
    var write: u32 = 1;
    for (1..count) |i| {
        if (!buf[i].eql(&buf[i - 1])) {
            buf[write] = buf[i];
            write += 1;
        }
    }
    return write;
}

// ── IPv6 payload helper ──────────────────────────────────────────

/// Result of parsing IPv6 extension headers.
pub const Ipv6PayloadInfo = struct {
    pos: u32,
    proto: u8,
};

/// Walk IPv6 extension headers and return the offset and protocol number of the
/// transport-layer payload. Returns null if the frame is too short or malformed.
///
/// Mirrors `_ipv6GetPayload` in Network.cpp.
pub fn ipv6GetPayload(frame_data: []const u8, frame_len: u32) ?Ipv6PayloadInfo {
    if (frame_len < 40) return null;
    var pos: u32 = 40;
    var proto: u8 = frame_data[6];
    while (pos <= frame_len) {
        switch (proto) {
            0, 43, 60, 135 => {
                // hop-by-hop, routing, destination, mobility options
                if ((pos + 8) > frame_len) return null;
                proto = frame_data[pos];
                pos += @as(u32, frame_data[pos + 1]) * 8 + 8;
            },
            else => return .{ .pos = pos, .proto = proto },
        }
    }
    return null; // overflow == invalid
}

// ── Local tag lookup ─────────────────────────────────────────────

/// Search the config's sorted tag array for a tag with the given ID.
/// Returns the tag's value if found, or null.
fn findLocalTag(nconf: *const NetworkConfig, tag_id: u32) ?u32 {
    for (0..nconf.tag_count) |i| {
        if (nconf.tags[i].id() == tag_id) return nconf.tags[i].value();
    }
    return null;
}

// ── Ownership verification ───────────────────────────────────────

/// Lazily compute the ownership verification bitmask for the CHARACTERISTICS
/// match rule. Uses InetAddress/MAC ownership checks against either the
/// remote membership (inbound) or local COOs (outbound).
///
/// The `mask` parameter should be initialized to 1 (sentinel meaning "not yet
/// computed"). After this call it will be 0 or a combination of the
/// `SENDER_IP_AUTHENTICATED` and `SENDER_MAC_AUTHENTICATED` characteristic flags.
fn computeOwnershipMask(
    nconf: *const NetworkConfig,
    membership: ?*const Membership,
    inbound: bool,
    frame_data: []const u8,
    frame_len: u32,
    ether_type: u16,
    mac_source: MAC,
    mask: *u64,
) void {
    if (mask.* != 1) return; // already computed
    mask.* = 0;

    var src = InetAddress.zero();
    if (ether_type == ethertype_ipv4 and frame_len >= 20) {
        src.set(frame_data[12..16], 0);
    } else if (ether_type == ethertype_ipv6 and frame_len >= 40) {
        // IPv6 NDP special handling
        if (frame_len >= (40 + 8 + 16) and frame_data[6] == 0x3a and
            (frame_data[40] == 0x87 or frame_data[40] == 0x88))
        {
            if (frame_data[40] == 0x87) {
                // Neighbor solicitations: treat as authenticated (no reliable source).
                mask.* |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_SENDER_IP_AUTHENTICATED;
            } else {
                // Neighbor advertisements: use target address.
                src.set(frame_data[48..64], 0);
            }
        } else {
            src.set(frame_data[8..24], 0);
        }
    } else if (ether_type == ethertype_arp and frame_len >= 28) {
        src.set(frame_data[14..18], 0);
    }

    if (inbound) {
        if (membership) |m| {
            if (src.family() != 0 and m.hasCertificateOfOwnershipForIp(nconf, &src)) {
                mask.* |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_SENDER_IP_AUTHENTICATED;
            }
            if (m.hasCertificateOfOwnershipForMac(nconf, mac_source)) {
                mask.* |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_SENDER_MAC_AUTHENTICATED;
            }
        }
    } else {
        for (0..nconf.certificate_of_ownership_count) |i| {
            if (src.family() != 0 and nconf.certificates_of_ownership[i].ownsIp(&src)) {
                mask.* |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_SENDER_IP_AUTHENTICATED;
            }
            if (nconf.certificates_of_ownership[i].ownsMac(mac_source)) {
                mask.* |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_SENDER_MAC_AUTHENTICATED;
            }
        }
    }
}

// ── doZtFilter ───────────────────────────────────────────────────

/// Mutable output parameters produced by the rules engine.
pub const FilterOutputs = struct {
    /// Carbon-copy (TEE) destination address. Zero if none.
    cc: Address = Address.init(0),
    /// Length of payload to carbon-copy.
    cc_length: u32 = 0,
    /// True if cc is a WATCH (as opposed to normal TEE).
    cc_watch: bool = false,
    /// QoS bucket (0-8, 4 = default / no priority).
    qos_bucket: u8 = 0,
    /// Possibly rewritten destination address (for REDIRECT).
    zt_dest: Address = Address.init(0),
};

/// Evaluate the ZeroTier packet rules engine.
///
/// This is a pure function of the rule table, frame content, and addressing
/// information. It does not send packets or modify network state — the caller
/// is responsible for acting on the result.
///
/// Mirrors the anonymous-namespace `_doZtFilter()` in Network.cpp (lines 70-645).
pub fn doZtFilter(
    rrl: *RuleResultLog,
    nconf: *const NetworkConfig,
    membership: ?*const Membership,
    inbound: bool,
    zt_source: Address,
    zt_dest_in: Address,
    mac_source: MAC,
    mac_dest: MAC,
    frame_data: []const u8,
    frame_len: u32,
    ether_type: u16,
    vlan_id: u16,
    rules: []const c_api.ZT_VirtualNetworkRule,
    my_address: Address,
    prng_fn: ?*const fn (?*anyopaque) u64,
    prng_ctx: ?*anyopaque,
    outputs: *FilterOutputs,
) DoZtFilterResult {
    // Initialize mutable dest (may be changed by REDIRECT).
    outputs.zt_dest = zt_dest_in;

    var super_accept = false;
    var this_set_matches: u8 = 1;
    var skip_drop: u8 = 0;
    var ownership_verification_mask: u64 = 1; // sentinel: not yet computed

    rrl.clear();

    for (0..rules.len) |rn| {
        const rule = rules[rn];
        const rt: u8 = rule.t & 0x3f;

        // ── ACTION check ─────────────────────────────────
        if (rt <= c_api.ZT_NETWORK_RULE_ACTION__MAX_ID) {
            if (this_set_matches != 0) {
                switch (rt) {
                    c_api.ZT_NETWORK_RULE_ACTION_PRIORITY => {
                        outputs.qos_bucket = if (rule.v.qosBucket <= 8) rule.v.qosBucket else 4;
                        return .accept;
                    },
                    c_api.ZT_NETWORK_RULE_ACTION_DROP => {
                        if (skip_drop != 0) {
                            skip_drop = 0;
                            continue;
                        }
                        return .drop;
                    },
                    c_api.ZT_NETWORK_RULE_ACTION_ACCEPT => {
                        return if (super_accept) .super_accept else .accept;
                    },
                    c_api.ZT_NETWORK_RULE_ACTION_TEE,
                    c_api.ZT_NETWORK_RULE_ACTION_WATCH,
                    c_api.ZT_NETWORK_RULE_ACTION_REDIRECT,
                    => {
                        const fwd_addr = Address.init(rule.v.fwd.address);
                        if (fwd_addr.eql(zt_source)) {
                            // no-op: source is target
                        } else if (fwd_addr.eql(my_address)) {
                            if (inbound) {
                                return .super_accept;
                            }
                            // else: no-op (outbound to self)
                        } else if (fwd_addr.eql(outputs.zt_dest)) {
                            // no-op: dest already matches
                        } else {
                            if (rt == c_api.ZT_NETWORK_RULE_ACTION_REDIRECT) {
                                outputs.zt_dest = fwd_addr;
                                return .redirect;
                            } else {
                                outputs.cc = fwd_addr;
                                const fwd_len: u32 = @intCast(rule.v.fwd.length);
                                outputs.cc_length = if (fwd_len != 0)
                                    @min(frame_len, fwd_len)
                                else
                                    frame_len;
                                outputs.cc_watch = (rt == c_api.ZT_NETWORK_RULE_ACTION_WATCH);
                            }
                        }
                        continue;
                    },
                    c_api.ZT_NETWORK_RULE_ACTION_BREAK => {
                        return .no_match;
                    },
                    else => {
                        // Unrecognized ACTIONs are no-ops.
                        continue;
                    },
                }
            } else {
                // The set didn't match. Check for inbound super-accept on TEE/REDIRECT/WATCH.
                if (inbound) {
                    switch (rt) {
                        c_api.ZT_NETWORK_RULE_ACTION_TEE,
                        c_api.ZT_NETWORK_RULE_ACTION_WATCH,
                        c_api.ZT_NETWORK_RULE_ACTION_REDIRECT,
                        => {
                            if (my_address.eql(Address.init(rule.v.fwd.address))) {
                                super_accept = true;
                            }
                        },
                        else => {},
                    }
                }
                this_set_matches = 1; // reset for next rule set
                continue;
            }
        }

        // ── Circuit breaker for AND chains ───────────────
        if ((this_set_matches == 0) and ((rule.t & 0x40) == 0)) {
            rrl.logSkipped(@intCast(rn), this_set_matches);
            continue;
        }

        // ── MATCH evaluation ─────────────────────────────
        var this_rule_matches: u8 = 0;
        const hard_yes: u8 = (rule.t >> 7) ^ 1;
        const hard_no: u8 = (rule.t >> 7) ^ 0;

        switch (rt) {
            c_api.ZT_NETWORK_RULE_MATCH_SOURCE_ZEROTIER_ADDRESS => {
                this_rule_matches = @intFromBool(rule.v.zt == zt_source.toInt());
            },
            c_api.ZT_NETWORK_RULE_MATCH_DEST_ZEROTIER_ADDRESS => {
                this_rule_matches = @intFromBool(rule.v.zt == outputs.zt_dest.toInt());
            },
            c_api.ZT_NETWORK_RULE_MATCH_VLAN_ID => {
                this_rule_matches = @intFromBool(rule.v.vlanId == vlan_id);
            },
            c_api.ZT_NETWORK_RULE_MATCH_VLAN_PCP => {
                this_rule_matches = @intFromBool(rule.v.vlanPcp == 0);
            },
            c_api.ZT_NETWORK_RULE_MATCH_VLAN_DEI => {
                this_rule_matches = @intFromBool(rule.v.vlanDei == 0);
            },
            c_api.ZT_NETWORK_RULE_MATCH_MAC_SOURCE => {
                this_rule_matches = @intFromBool(MAC.fromBytes(&rule.v.mac).eql(mac_source));
            },
            c_api.ZT_NETWORK_RULE_MATCH_MAC_DEST => {
                this_rule_matches = @intFromBool(MAC.fromBytes(&rule.v.mac).eql(mac_dest));
            },
            c_api.ZT_NETWORK_RULE_MATCH_IPV4_SOURCE => {
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    var rule_addr = InetAddress.initV4(
                        @bitCast(rule.v.ipv4.ip),
                        @as(u16, rule.v.ipv4.mask),
                    );
                    var pkt_addr = InetAddress.zero();
                    pkt_addr.set(frame_data[12..16], 0);
                    this_rule_matches = @intFromBool(rule_addr.containsAddress(&pkt_addr));
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IPV4_DEST => {
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    var rule_addr = InetAddress.initV4(
                        @bitCast(rule.v.ipv4.ip),
                        @as(u16, rule.v.ipv4.mask),
                    );
                    var pkt_addr = InetAddress.zero();
                    pkt_addr.set(frame_data[16..20], 0);
                    this_rule_matches = @intFromBool(rule_addr.containsAddress(&pkt_addr));
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IPV6_SOURCE => {
                if (ether_type == ethertype_ipv6 and frame_len >= 40) {
                    var rule_addr = InetAddress.initV6(rule.v.ipv6.ip, @as(u16, rule.v.ipv6.mask));
                    var pkt_addr = InetAddress.zero();
                    pkt_addr.set(frame_data[8..24], 0);
                    this_rule_matches = @intFromBool(rule_addr.containsAddress(&pkt_addr));
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IPV6_DEST => {
                if (ether_type == ethertype_ipv6 and frame_len >= 40) {
                    var rule_addr = InetAddress.initV6(rule.v.ipv6.ip, @as(u16, rule.v.ipv6.mask));
                    var pkt_addr = InetAddress.zero();
                    pkt_addr.set(frame_data[24..40], 0);
                    this_rule_matches = @intFromBool(rule_addr.containsAddress(&pkt_addr));
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IP_TOS => {
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    const tos_masked = frame_data[1] & rule.v.ipTos.mask;
                    this_rule_matches = @intFromBool(tos_masked >= rule.v.ipTos.value[0] and tos_masked <= rule.v.ipTos.value[1]);
                } else if (ether_type == ethertype_ipv6 and frame_len >= 40) {
                    const tos_masked = (((frame_data[0] << 4) & 0xf0) | ((frame_data[1] >> 4) & 0x0f)) & rule.v.ipTos.mask;
                    this_rule_matches = @intFromBool(tos_masked >= rule.v.ipTos.value[0] and tos_masked <= rule.v.ipTos.value[1]);
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IP_PROTOCOL => {
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    this_rule_matches = @intFromBool(rule.v.ipProtocol == frame_data[9]);
                } else if (ether_type == ethertype_ipv6) {
                    if (ipv6GetPayload(frame_data, frame_len)) |info| {
                        this_rule_matches = @intFromBool(rule.v.ipProtocol == info.proto);
                    } else {
                        this_rule_matches = hard_no;
                    }
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE => {
                this_rule_matches = @intFromBool(rule.v.etherType == ether_type);
            },
            c_api.ZT_NETWORK_RULE_MATCH_ICMP => {
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    if (frame_data[9] == 0x01) { // ICMP
                        const ihl: u32 = @as(u32, frame_data[0] & 0xf) * 4;
                        if (frame_len >= (ihl + 2)) {
                            if (rule.v.icmp.type == frame_data[ihl]) {
                                if ((rule.v.icmp.flags & 0x01) != 0) {
                                    this_rule_matches = @intFromBool(frame_data[ihl + 1] == rule.v.icmp.code);
                                } else {
                                    this_rule_matches = hard_yes;
                                }
                            } else {
                                this_rule_matches = hard_no;
                            }
                        } else {
                            this_rule_matches = hard_no;
                        }
                    } else {
                        this_rule_matches = hard_no;
                    }
                } else if (ether_type == ethertype_ipv6) {
                    if (ipv6GetPayload(frame_data, frame_len)) |info| {
                        if (info.proto == 0x3a and frame_len >= (info.pos + 2)) {
                            if (rule.v.icmp.type == frame_data[info.pos]) {
                                if ((rule.v.icmp.flags & 0x01) != 0) {
                                    this_rule_matches = @intFromBool(frame_data[info.pos + 1] == rule.v.icmp.code);
                                } else {
                                    this_rule_matches = hard_yes;
                                }
                            } else {
                                this_rule_matches = hard_no;
                            }
                        } else {
                            this_rule_matches = hard_no;
                        }
                    } else {
                        this_rule_matches = hard_no;
                    }
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_IP_SOURCE_PORT_RANGE,
            c_api.ZT_NETWORK_RULE_MATCH_IP_DEST_PORT_RANGE,
            => {
                const is_dest = (rt == c_api.ZT_NETWORK_RULE_MATCH_IP_DEST_PORT_RANGE);
                if (ether_type == ethertype_ipv4 and frame_len >= 20) {
                    const header_len: u32 = @as(u32, frame_data[0] & 0xf) * 4;
                    var p: i32 = -1;
                    switch (frame_data[9]) {
                        0x06, 0x11, 0x84, 0x88 => { // TCP, UDP, SCTP, UDPLite
                            if (frame_len > (header_len + 4)) {
                                var pos = header_len + if (is_dest) @as(u32, 2) else @as(u32, 0);
                                p = @as(i32, frame_data[pos]) << 8;
                                pos += 1;
                                p |= @as(i32, frame_data[pos]);
                            }
                        },
                        else => {},
                    }
                    this_rule_matches = if (p >= 0) @intFromBool(p >= @as(i32, rule.v.port[0]) and p <= @as(i32, rule.v.port[1])) else 0;
                } else if (ether_type == ethertype_ipv6) {
                    if (ipv6GetPayload(frame_data, frame_len)) |info| {
                        var p: i32 = -1;
                        switch (info.proto) {
                            0x06, 0x11, 0x84, 0x88 => {
                                var pos = info.pos;
                                if (frame_len > (pos + 4)) {
                                    if (is_dest) pos += 2;
                                    p = @as(i32, frame_data[pos]) << 8;
                                    pos += 1;
                                    p |= @as(i32, frame_data[pos]);
                                }
                            },
                            else => {},
                        }
                        // Note: C++ uses (p > 0) for IPv6, (p >= 0) for IPv4.
                        this_rule_matches = if (p > 0) @intFromBool(p >= @as(i32, rule.v.port[0]) and p <= @as(i32, rule.v.port[1])) else 0;
                    } else {
                        this_rule_matches = hard_no;
                    }
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_CHARACTERISTICS => {
                var cf: u64 = if (inbound) c_api.ZT_RULE_PACKET_CHARACTERISTICS_INBOUND else 0;
                if (mac_dest.isMulticast()) cf |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_MULTICAST;
                if (mac_dest.isBroadcast()) cf |= c_api.ZT_RULE_PACKET_CHARACTERISTICS_BROADCAST;

                computeOwnershipMask(nconf, membership, inbound, frame_data, frame_len, ether_type, mac_source, &ownership_verification_mask);
                cf |= ownership_verification_mask;

                // TCP flags (IPv4)
                if (ether_type == ethertype_ipv4 and frame_len >= 20 and frame_data[9] == 0x06) {
                    const header_len: u32 = @as(u32, frame_data[0] & 0xf) * 4;
                    if (frame_len > header_len + 13) {
                        cf |= @as(u64, frame_data[header_len + 13]);
                        cf |= @as(u64, frame_data[header_len + 12] & 0x0f) << 8;
                    }
                } else if (ether_type == ethertype_ipv6) {
                    if (ipv6GetPayload(frame_data, frame_len)) |info| {
                        if (info.proto == 0x06 and frame_len > (info.pos + 14)) {
                            cf |= @as(u64, frame_data[info.pos + 13]);
                            cf |= @as(u64, frame_data[info.pos + 12] & 0x0f) << 8;
                        }
                    }
                }
                this_rule_matches = @intFromBool((cf & rule.v.characteristics) != 0);
            },
            c_api.ZT_NETWORK_RULE_MATCH_FRAME_SIZE_RANGE => {
                this_rule_matches = @intFromBool(frame_len >= @as(u32, rule.v.frameSize[0]) and frame_len <= @as(u32, rule.v.frameSize[1]));
            },
            c_api.ZT_NETWORK_RULE_MATCH_RANDOM => {
                const rval: u32 = if (prng_fn) |pfn| @truncate(pfn(prng_ctx)) else 0;
                this_rule_matches = @intFromBool(rval <= rule.v.randomProbability);
            },
            c_api.ZT_NETWORK_RULE_MATCH_TAGS_DIFFERENCE,
            c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_AND,
            c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_OR,
            c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_XOR,
            c_api.ZT_NETWORK_RULE_MATCH_TAGS_EQUAL,
            => {
                const local_tag_value = findLocalTag(nconf, rule.v.tag.id);
                if (local_tag_value) |ltv| {
                    const remote_tag = if (membership) |m| m.getTag(nconf, rule.v.tag.id) else null;
                    if (remote_tag) |rtag| {
                        const rtv = rtag.value();
                        if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAGS_DIFFERENCE) {
                            const diff = if (ltv > rtv) ltv - rtv else rtv - ltv;
                            this_rule_matches = @intFromBool(diff <= rule.v.tag.value);
                        } else if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_AND) {
                            this_rule_matches = @intFromBool((ltv & rtv) == rule.v.tag.value);
                        } else if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_OR) {
                            this_rule_matches = @intFromBool((ltv | rtv) == rule.v.tag.value);
                        } else if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAGS_BITWISE_XOR) {
                            this_rule_matches = @intFromBool((ltv ^ rtv) == rule.v.tag.value);
                        } else if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAGS_EQUAL) {
                            this_rule_matches = @intFromBool(ltv == rule.v.tag.value and rtv == rule.v.tag.value);
                        } else {
                            this_rule_matches = hard_no;
                        }
                    } else {
                        // No remote tag
                        if (inbound and !super_accept) {
                            this_rule_matches = hard_no;
                        } else {
                            skip_drop = 1;
                            this_rule_matches = hard_yes;
                        }
                    }
                } else {
                    this_rule_matches = hard_no;
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_TAG_SENDER,
            c_api.ZT_NETWORK_RULE_MATCH_TAG_RECEIVER,
            => {
                if (super_accept) {
                    skip_drop = 1;
                    this_rule_matches = hard_yes;
                } else if ((rt == c_api.ZT_NETWORK_RULE_MATCH_TAG_SENDER and inbound) or
                    (rt == c_api.ZT_NETWORK_RULE_MATCH_TAG_RECEIVER and !inbound))
                {
                    const remote_tag = if (membership) |m| m.getTag(nconf, rule.v.tag.id) else null;
                    if (remote_tag) |rtag| {
                        this_rule_matches = @intFromBool(rtag.value() == rule.v.tag.value);
                    } else {
                        if (rt == c_api.ZT_NETWORK_RULE_MATCH_TAG_RECEIVER) {
                            skip_drop = 1;
                            this_rule_matches = hard_yes;
                        } else {
                            this_rule_matches = hard_no;
                        }
                    }
                } else {
                    // sender+outbound or receiver+inbound: check local tag
                    if (findLocalTag(nconf, rule.v.tag.id)) |ltv| {
                        this_rule_matches = @intFromBool(ltv == rule.v.tag.value);
                    } else {
                        this_rule_matches = hard_no;
                    }
                }
            },
            c_api.ZT_NETWORK_RULE_MATCH_INTEGER_RANGE => {
                var integer: u64 = 0;
                const bits: u32 = @as(u32, rule.v.intRange.format & 63) + 1;
                const bytes: u32 = (bits + 7) / 8;
                if ((rule.v.intRange.format & 0x80) == 0) {
                    // Big-endian
                    var idx: u32 = @as(u32, rule.v.intRange.idx) + (8 - bytes);
                    const eof: u32 = idx + bytes;
                    if (eof <= frame_len) {
                        while (idx < eof) : (idx += 1) {
                            integer <<= 8;
                            integer |= @as(u64, frame_data[idx]);
                        }
                    }
                    integer &= @as(u64, 0xffffffffffffffff) >> @intCast(64 - bits);
                } else {
                    // Little-endian
                    var idx: u32 = @as(u32, rule.v.intRange.idx);
                    const eof: u32 = idx + bytes;
                    if (eof <= frame_len) {
                        while (idx < eof) : (idx += 1) {
                            integer >>= 8;
                            integer |= @as(u64, frame_data[idx]) << 56;
                        }
                    }
                    integer >>= @intCast(64 - bits);
                }
                this_rule_matches = @intFromBool(integer >= rule.v.intRange.start and
                    integer <= (rule.v.intRange.start +% @as(u64, rule.v.intRange.end)));
            },
            else => {
                // Unsupported MATCH: result is configurable via network flag.
                this_rule_matches = @intFromBool((nconf.flags & network_config.flag_rules_result_of_unsupported_match) != 0);
            },
        }

        rrl.log(@intCast(rn), this_rule_matches, this_set_matches);

        if ((rule.t & 0x40) != 0) {
            // OR
            this_set_matches |= (this_rule_matches ^ ((rule.t >> 7) & 1));
        } else {
            // AND
            this_set_matches &= (this_rule_matches ^ ((rule.t >> 7) & 1));
        }
    }

    return .no_match;
}

// ══════════════════════════════════════════════════════════════════
//  Tests
// ══════════════════════════════════════════════════════════════════

test "MulticastGroupKey: equality and distinctness" {
    const k1 = MulticastGroupKey.fromParts(0xffffffffffff, 0);
    const k2 = MulticastGroupKey.fromParts(0xffffffffffff, 0);
    const k3 = MulticastGroupKey.fromParts(0xffffffffffff, 1);
    const k4 = MulticastGroupKey.fromParts(0x112233445566, 0);

    try testing.expect(k1.eql(k2));
    try testing.expect(!k1.eql(k3));
    try testing.expect(!k1.eql(k4));
}

test "MulticastGroupKey: hash distinctness" {
    const k1 = MulticastGroupKey.fromParts(0xffffffffffff, 0);
    const k2 = MulticastGroupKey.fromParts(0xffffffffffff, 1);
    const k3 = MulticastGroupKey.fromParts(0x112233445566, 0);

    // Different keys should (very likely) produce different hashes.
    try testing.expect(k1.hashCode() != k2.hashCode());
    try testing.expect(k1.hashCode() != k3.hashCode());
}

test "MulticastGroupKey: from MulticastGroup round-trip" {
    const mg = MulticastGroup.init(MAC.init(0xaabbccddeeff), 42);
    const key = MulticastGroupKey.fromMulticastGroup(&mg);

    try testing.expectEqual(@as(u64, 0xaabbccddeeff), key._mac_int);
    try testing.expectEqual(@as(u32, 42), key._adi);
}

test "IncomingConfigChunk: zero init" {
    const chunk = IncomingConfigChunk.init();
    try testing.expectEqual(@as(u64, 0), chunk.ts);
    try testing.expectEqual(@as(u64, 0), chunk.update_id);
    try testing.expectEqual(@as(u32, 0), chunk.have_chunks);
    try testing.expectEqual(@as(u32, 0), chunk.have_bytes);
    for (chunk.have_chunk_ids) |cid| {
        try testing.expectEqual(@as(u64, 0), cid);
    }
}

test "Network: init and basic accessors" {
    const allocator = testing.allocator;
    const nwid: u64 = 0x1234567890abcdef;
    const my_addr = Address.init(0x1122334455);

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, my_addr, null, .{});
    defer net.deinit();

    try testing.expectEqual(nwid, net.id());
    try testing.expectEqual(MAC.fromAddress(my_addr, nwid).toInt(), net.mac().toInt());
    try testing.expect(!net.hasConfig());
    try testing.expect(!net.multicastEnabled());
    try testing.expectEqual(@as(i64, 0), net.lastConfigUpdate());
    try testing.expect(!net.qosEnabled());
}

test "Network: controller and controllerFor" {
    const allocator = testing.allocator;
    const nwid: u64 = 0xaabbccddee_112233;
    const my_addr = Address.init(0x1122334455);

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, my_addr, null, .{});
    defer net.deinit();

    // Controller = top 40 bits of network ID = nwid >> 24
    const expected_ctrl = Address.init(nwid >> 24);
    try testing.expect(net.controller().eql(expected_ctrl));
    try testing.expect(Network.controllerFor(nwid).eql(expected_ctrl));
}

test "Network: BROADCAST constant" {
    try testing.expect(Network.BROADCAST.mac().isBroadcast());
    try testing.expectEqual(@as(u32, 0), Network.BROADCAST.adi());
}

test "Network: statusInternal with no config" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // No config, no failure -> REQUESTING_CONFIGURATION
    try testing.expectEqual(
        @as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_REQUESTING_CONFIGURATION),
        net.statusInternal(),
    );
}

test "Network: statusInternal with config set" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Simulate having a config by setting network_id.
    net._config.network_id = 0x1234;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_OK), net.statusInternal());
}

test "Network: statusInternal with access denied" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    net._netconf_failure = .access_denied;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_ACCESS_DENIED), net.statusInternal());
}

test "Network: statusInternal with not found" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    net._netconf_failure = .not_found;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_NOT_FOUND), net.statusInternal());
}

test "Network: statusInternal with authentication required" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    net._netconf_failure = .authentication_required;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_AUTHENTICATION_REQUIRED), net.statusInternal());
}

test "Network: statusInternal with port error overrides all" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Even with a valid config and no failure, port_error takes priority.
    net._config.network_id = 0x1234;
    net._port_error = -1;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_PORT_ERROR), net.statusInternal());
}

test "Network: statusInternal with init_failed" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    net._netconf_failure = .init_failed;
    try testing.expectEqual(@as(VirtualNetworkStatus, c_api.ZT_NETWORK_STATUS_PORT_ERROR), net.statusInternal());
}

test "Network: destroy sets flag" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    try testing.expect(!net._destroyed);
    net.destroy();
    try testing.expect(net._destroyed);
}

test "Network: setAccessDenied updates failure and fires callback" {
    const allocator = testing.allocator;
    const S = struct {
        var callback_count: u32 = 0;
        fn cb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, _: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            callback_count += 1;
            return 0;
        }
    };
    S.callback_count = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .configure_virtual_network_port = &S.cb,
    });
    defer net.deinit();

    net.setAccessDenied(null);
    try testing.expectEqual(NetconfFailure.access_denied, net._netconf_failure);
    try testing.expectEqual(@as(u32, 1), S.callback_count);
}

test "Network: setNotFound updates failure and fires callback" {
    const allocator = testing.allocator;
    const S = struct {
        var callback_count: u32 = 0;
        fn cb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, _: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            callback_count += 1;
            return 0;
        }
    };
    S.callback_count = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .configure_virtual_network_port = &S.cb,
    });
    defer net.deinit();

    net.setNotFound(null);
    try testing.expectEqual(NetconfFailure.not_found, net._netconf_failure);
    try testing.expectEqual(@as(u32, 1), S.callback_count);
}

test "Network: setAuthenticationRequired sets URL and SSO fields" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const url = "https://auth.example.com/login";
    net.setAuthenticationRequired(null, url);

    try testing.expectEqual(NetconfFailure.authentication_required, net._netconf_failure);
    try testing.expect(net._config.sso_enabled);
    try testing.expectEqual(@as(u64, 0), net._config.sso_version);

    // Verify URL was copied.
    try testing.expect(mem.startsWith(u8, &net._authentication_url, url));
    try testing.expectEqual(@as(u8, 0), net._authentication_url[url.len]);
}

test "Network: findBridgeTo returns zero when empty" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const result = net.findBridgeTo(MAC.init(0x112233445566));
    try testing.expect(!result.isSet());
}

test "Network: findBridgeTo returns correct address" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Manually add a bridge route.
    const mac_val = MAC.init(0xaabbccddeeff);
    const bridge_addr = Address.init(0x9988776655);
    try net._remote_bridge_routes.set(mac_val, bridge_addr);

    const result = net.findBridgeTo(mac_val);
    try testing.expect(result.eql(bridge_addr));
}

test "Network: externalConfigInternal populates basic fields" {
    const allocator = testing.allocator;
    const nwid: u64 = 0x1234567890abcdef;
    const my_addr = Address.init(0x1122334455);

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, my_addr, null, .{});
    defer net.deinit();

    var ec: VirtualNetworkConfig = undefined;
    net.externalConfigInternal(&ec);

    try testing.expectEqual(nwid, ec.nwid);
    try testing.expectEqual(net._mac.toInt(), ec.mac);
    try testing.expectEqual(
        @as(@TypeOf(ec.status), c_api.ZT_NETWORK_STATUS_REQUESTING_CONFIGURATION),
        ec.status,
    );
    // Default type should be PRIVATE.
    try testing.expectEqual(
        @as(@TypeOf(ec.type), @intCast(c_api.ZT_NETWORK_TYPE_PRIVATE)),
        ec.type,
    );
    // Default MTU when no config.
    try testing.expectEqual(network_config.default_mtu, ec.mtu);
    try testing.expectEqual(@as(c_int, 0), ec.dhcp);
    try testing.expectEqual(@as(c_int, 0), ec.bridge);
    try testing.expectEqual(@as(c_int, 0), ec.portError);
}

test "Network: externalConfigInternal with config set" {
    const allocator = testing.allocator;
    const nwid: u64 = 0x1234567890abcdef;
    const my_addr = Address.init(0x1122334455);

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, my_addr, null, .{});
    defer net.deinit();

    // Set a minimal config.
    net._config.network_id = nwid;
    net._config.mtu = 1500;
    net._config.revision = 42;
    net._config.flags = network_config.flag_enable_broadcast;

    var ec: VirtualNetworkConfig = undefined;
    net.externalConfigInternal(&ec);

    try testing.expectEqual(@as(@TypeOf(ec.status), c_api.ZT_NETWORK_STATUS_OK), ec.status);
    try testing.expectEqual(@as(c_uint, 1500), ec.mtu);
    try testing.expectEqual(@as(c_ulong, 42), ec.netconfRevision);
    try testing.expectEqual(@as(c_int, 1), ec.broadcastEnabled);
}

test "Network: deinit fires DOWN callback when not destroyed" {
    const allocator = testing.allocator;
    const S = struct {
        var last_op: c_uint = 0;
        fn cb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, op: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            last_op = op;
            return 0;
        }
    };
    S.last_op = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .configure_virtual_network_port = &S.cb,
    });

    net.deinit();
    try testing.expectEqual(@as(c_uint, c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_DOWN), S.last_op);
}

test "Network: deinit skips DOWN callback when destroyed" {
    const allocator = testing.allocator;
    const S = struct {
        var callback_count: u32 = 0;
        fn cb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, _: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            callback_count += 1;
            return 0;
        }
    };
    S.callback_count = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .configure_virtual_network_port = &S.cb,
    });

    net._destroyed = true;
    net.deinit();
    try testing.expectEqual(@as(u32, 0), S.callback_count);
}

test "Network: multicast group count starts at zero" {
    const allocator = testing.allocator;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    try testing.expectEqual(@as(u32, 0), net._my_multicast_group_count);
}

// ══════════════════════════════════════════════════════════════════
//  Chunk 2 tests — ipv6GetPayload, findLocalTag, doZtFilter
// ══════════════════════════════════════════════════════════════════

// ── Test helpers ─────────────────────────────────────────────────

/// Create a zeroed rule with the given type byte.
fn makeRule(t: u8) c_api.ZT_VirtualNetworkRule {
    var rule: c_api.ZT_VirtualNetworkRule = @bitCast([_]u8{0} ** @sizeOf(c_api.ZT_VirtualNetworkRule));
    rule.t = t;
    return rule;
}

/// Minimal NetworkConfig suitable for filter tests.
fn makeTestNconf() NetworkConfig {
    var nconf = NetworkConfig.init();
    nconf.network_id = 0xdeadbeef12345678;
    nconf.rule_count = 0;
    return nconf;
}

/// Run doZtFilter with sensible defaults, returning the result and outputs.
fn runFilter(
    rules: []const c_api.ZT_VirtualNetworkRule,
    nconf: *const NetworkConfig,
    frame_data: []const u8,
    frame_len: u32,
    ether_type: u16,
    inbound: bool,
) struct { result: DoZtFilterResult, outputs: FilterOutputs } {
    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};
    const zt_src = Address.init(0xaa11223344);
    const zt_dst = Address.init(0xbb55667788);
    const mac_src = MAC.init(0x112233445566);
    const mac_dst = MAC.init(0xaabbccddeeff);
    const my_addr = Address.init(0xcc99887766);

    const result = doZtFilter(
        &rrl,
        nconf,
        null, // no membership
        inbound,
        zt_src,
        zt_dst,
        mac_src,
        mac_dst,
        frame_data,
        frame_len,
        ether_type,
        0, // vlan_id
        rules,
        my_addr,
        null, // no prng
        null,
        &outputs,
    );
    return .{ .result = result, .outputs = outputs };
}

// ── ipv6GetPayload tests ─────────────────────────────────────────

test "ipv6GetPayload: too short returns null" {
    const short = [_]u8{0} ** 39;
    try testing.expect(ipv6GetPayload(&short, 39) == null);
}

test "ipv6GetPayload: minimal IPv6 (no extension headers)" {
    // Minimal 40-byte IPv6 header. next-header = 6 (TCP) at offset 6.
    var hdr = [_]u8{0} ** 60;
    hdr[6] = 0x06; // next header = TCP
    const result = ipv6GetPayload(&hdr, 60);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 40), result.?.pos);
    try testing.expectEqual(@as(u8, 0x06), result.?.proto);
}

test "ipv6GetPayload: with hop-by-hop extension header" {
    // IPv6 header with hop-by-hop extension (type 0).
    // next-header at byte 6 = 0 (hop-by-hop)
    // Extension: next-header at byte 40 = 17 (UDP), length at byte 41 = 0 (meaning 8 bytes total)
    var hdr = [_]u8{0} ** 60;
    hdr[6] = 0x00; // next header = hop-by-hop
    hdr[40] = 0x11; // extension next-header = UDP
    hdr[41] = 0x00; // extension length = 0 -> 8 bytes total
    const result = ipv6GetPayload(&hdr, 60);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 48), result.?.pos); // 40 + 8
    try testing.expectEqual(@as(u8, 0x11), result.?.proto);
}

test "ipv6GetPayload: extension header truncated returns null" {
    // Extension header present but frame too short for it.
    var hdr = [_]u8{0} ** 44;
    hdr[6] = 0x00; // hop-by-hop
    // Extension at byte 40 needs at least 8 bytes, but we only have 4 after 40.
    const result = ipv6GetPayload(&hdr, 44);
    // pos 40 + 8 > 44, but we check (pos + 8) > frame_len → (48) > 44 → true → null
    try testing.expect(result == null);
}

// ── findLocalTag tests ───────────────────────────────────────────

test "findLocalTag: finds existing tag" {
    var nconf = makeTestNconf();
    // Add a tag with id=10, value=42. We need to set the tag fields directly.
    var tag_bytes = [_]u8{0} ** @sizeOf(Tag);
    const tag_ptr: *Tag = @ptrCast(@alignCast(&tag_bytes));
    tag_ptr.* = Tag.init();
    // Tag stores id/value in internal fields. We need to use the create method.
    // Tag.create(nwid, ts, issued_to, tag_id, tag_value) -> Tag
    nconf.tags[0] = Tag.create(0x1234, 1000, Address.init(1), 10, 42);
    nconf.tag_count = 1;

    const result = findLocalTag(&nconf, 10);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 42), result.?);
}

test "findLocalTag: returns null for missing tag" {
    var nconf = makeTestNconf();
    nconf.tags[0] = Tag.create(0x1234, 1000, Address.init(1), 10, 42);
    nconf.tag_count = 1;

    const result = findLocalTag(&nconf, 99);
    try testing.expect(result == null);
}

test "findLocalTag: empty config returns null" {
    var nconf = makeTestNconf();
    nconf.tag_count = 0;

    const result = findLocalTag(&nconf, 10);
    try testing.expect(result == null);
}

// ── doZtFilter tests ─────────────────────────────────────────────

test "doZtFilter: empty rules returns no_match" {
    const nconf = makeTestNconf();
    const rules = [_]c_api.ZT_VirtualNetworkRule{};
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r.result);
}

test "doZtFilter: single ACCEPT rule" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r.result);
}

test "doZtFilter: single DROP rule" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_DROP);
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.drop, r.result);
}

test "doZtFilter: single BREAK rule" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_BREAK);
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r.result);
}

test "doZtFilter: PRIORITY action sets qos_bucket and returns accept" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_PRIORITY);
    rules[0].v.qosBucket = 3;
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r.result);
    try testing.expectEqual(@as(u8, 3), r.outputs.qos_bucket);
}

test "doZtFilter: PRIORITY with out-of-range bucket defaults to 4" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_PRIORITY);
    rules[0].v.qosBucket = 20; // > 8
    const frame = [_]u8{0} ** 64;
    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r.result);
    try testing.expectEqual(@as(u8, 4), r.outputs.qos_bucket);
}

test "doZtFilter: ETHERTYPE match followed by ACCEPT" {
    const nconf = makeTestNconf();
    // Rule 0: MATCH_ETHERTYPE = 0x0800
    // Rule 1: ACTION_ACCEPT
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[0].v.etherType = 0x0800;
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 64;

    // Matching ethertype -> accept
    const r1 = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r1.result);

    // Non-matching ethertype -> the set doesn't match, continues, no more rules -> no_match
    const r2 = runFilter(&rules, &nconf, &frame, 64, 0x86dd, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r2.result);
}

test "doZtFilter: NOT bit inverts match" {
    const nconf = makeTestNconf();
    // Rule 0: NOT MATCH_ETHERTYPE = 0x0800 (NOT bit set: t = 0x80 | 37)
    // Rule 1: ACTION_ACCEPT
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(0x80 | c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[0].v.etherType = 0x0800;
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 64;

    // Ethertype IS 0x0800 but NOT inverts -> set doesn't match -> no_match
    const r1 = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r1.result);

    // Ethertype is NOT 0x0800, NOT inverts -> set matches -> accept
    const r2 = runFilter(&rules, &nconf, &frame, 64, 0x86dd, false);
    try testing.expectEqual(DoZtFilterResult.accept, r2.result);
}

test "doZtFilter: OR bit combines matches" {
    const nconf = makeTestNconf();
    // Rule 0: MATCH_ETHERTYPE = 0x0800
    // Rule 1: OR MATCH_ETHERTYPE = 0x86dd (OR bit set: t = 0x40 | 37)
    // Rule 2: ACTION_ACCEPT
    var rules: [3]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[0].v.etherType = 0x0800;
    rules[1] = makeRule(0x40 | c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[1].v.etherType = 0x86dd;
    rules[2] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 64;

    // IPv4 matches first -> OR'd -> accept
    const r1 = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r1.result);

    // IPv6 matches second -> OR'd -> accept
    const r2 = runFilter(&rules, &nconf, &frame, 64, 0x86dd, false);
    try testing.expectEqual(DoZtFilterResult.accept, r2.result);

    // ARP matches neither -> no_match
    const r3 = runFilter(&rules, &nconf, &frame, 64, 0x0806, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r3.result);
}

test "doZtFilter: FRAME_SIZE_RANGE match" {
    const nconf = makeTestNconf();
    // Rule 0: MATCH_FRAME_SIZE_RANGE [60, 100]
    // Rule 1: ACTION_ACCEPT
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_FRAME_SIZE_RANGE);
    rules[0].v.frameSize = .{ 60, 100 };
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 128;

    // frame_len = 80, in range [60,100] -> accept
    const r1 = runFilter(&rules, &nconf, frame[0..80], 80, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r1.result);

    // frame_len = 50, below range -> no_match
    const r2 = runFilter(&rules, &nconf, frame[0..50], 50, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r2.result);

    // frame_len = 120, above range -> no_match
    const r3 = runFilter(&rules, &nconf, frame[0..120], 120, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r3.result);
}

test "doZtFilter: REDIRECT changes zt_dest" {
    const nconf = makeTestNconf();
    // Single REDIRECT rule -> should change zt_dest and return .redirect
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_REDIRECT);
    rules[0].v.fwd.address = 0xddeeff1122;
    rules[0].v.fwd.length = 0;

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};
    const zt_src = Address.init(0xaa11223344);
    const zt_dst = Address.init(0xbb55667788);
    const my_addr = Address.init(0xcc99887766);

    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        zt_src,
        zt_dst,
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        my_addr,
        null,
        null,
        &outputs,
    );
    try testing.expectEqual(DoZtFilterResult.redirect, result);
    try testing.expect(outputs.zt_dest.eql(Address.init(0xddeeff1122)));
}

test "doZtFilter: TEE sets cc and cc_length" {
    const nconf = makeTestNconf();
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_TEE);
    rules[0].v.fwd.address = 0xddeeff1122;
    rules[0].v.fwd.length = 32;

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};
    const zt_src = Address.init(0xaa11223344);
    const zt_dst = Address.init(0xbb55667788);
    const my_addr = Address.init(0xcc99887766);

    // TEE is not an action that returns immediately — it sets cc and continues.
    // With no further rules, it falls through to no_match.
    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        zt_src,
        zt_dst,
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        my_addr,
        null,
        null,
        &outputs,
    );
    try testing.expectEqual(DoZtFilterResult.no_match, result);
    try testing.expect(outputs.cc.eql(Address.init(0xddeeff1122)));
    try testing.expectEqual(@as(u32, 32), outputs.cc_length);
    try testing.expect(!outputs.cc_watch);
}

test "doZtFilter: WATCH sets cc_watch flag" {
    const nconf = makeTestNconf();
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_WATCH);
    rules[0].v.fwd.address = 0xddeeff1122;
    rules[0].v.fwd.length = 0; // 0 means full frame
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};
    const zt_src = Address.init(0xaa11223344);
    const zt_dst = Address.init(0xbb55667788);
    const my_addr = Address.init(0xcc99887766);

    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        zt_src,
        zt_dst,
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        my_addr,
        null,
        null,
        &outputs,
    );
    try testing.expectEqual(DoZtFilterResult.accept, result);
    try testing.expect(outputs.cc.eql(Address.init(0xddeeff1122)));
    try testing.expectEqual(@as(u32, 64), outputs.cc_length); // fwd.length == 0 means full frame
    try testing.expect(outputs.cc_watch);
}

test "doZtFilter: MATCH_RANDOM with prng" {
    const nconf = makeTestNconf();
    // MATCH_RANDOM with probability = 0 -> never matches -> DROP doesn't fire -> no_match
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_RANDOM);
    rules[0].v.randomProbability = 0;
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    const S = struct {
        fn alwaysMax(_: ?*anyopaque) u64 {
            return 0xFFFFFFFF_FFFFFFFF; // truncates to u32 max
        }
    };
    const frame = [_]u8{0} ** 64;

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};
    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        Address.init(0xaa11223344),
        Address.init(0xbb55667788),
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &frame,
        64,
        0x0800,
        0,
        &rules,
        Address.init(0xcc99887766),
        &S.alwaysMax,
        null,
        &outputs,
    );
    // PRNG returns 0xFFFFFFFF but probability is 0, so rval (0xFFFFFFFF) > 0 -> no match
    try testing.expectEqual(DoZtFilterResult.no_match, result);
}

test "doZtFilter: non-matching set resets for next set" {
    const nconf = makeTestNconf();
    // Set 1: MATCH_ETHERTYPE(0x86dd) + DROP -> doesn't match IPv4
    // Set 2 (implicit after action resets): ACCEPT
    var rules: [3]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[0].v.etherType = 0x86dd; // IPv6
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_DROP); // won't fire for IPv4
    rules[2] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT); // next set: unconditional
    const frame = [_]u8{0} ** 64;

    const r = runFilter(&rules, &nconf, &frame, 64, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r.result);
}

test "doZtFilter: AND chain - both must match" {
    const nconf = makeTestNconf();
    // Rule 0: MATCH_ETHERTYPE = 0x0800 (AND)
    // Rule 1: MATCH_FRAME_SIZE_RANGE [50, 100] (AND)
    // Rule 2: ACTION_ACCEPT
    var rules: [3]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_ETHERTYPE);
    rules[0].v.etherType = 0x0800;
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_MATCH_FRAME_SIZE_RANGE);
    rules[1].v.frameSize = .{ 50, 100 };
    rules[2] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);
    const frame = [_]u8{0} ** 128;

    // Both match: ethertype 0x0800 AND frame_len 80 in [50,100]
    const r1 = runFilter(&rules, &nconf, frame[0..80], 80, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.accept, r1.result);

    // Ethertype matches but frame too big -> AND fails
    const r2 = runFilter(&rules, &nconf, frame[0..120], 120, 0x0800, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r2.result);

    // Frame size matches but wrong ethertype -> AND fails
    const r3 = runFilter(&rules, &nconf, frame[0..80], 80, 0x86dd, false);
    try testing.expectEqual(DoZtFilterResult.no_match, r3.result);
}

test "doZtFilter: TEE to self on inbound returns super_accept" {
    const nconf = makeTestNconf();
    // TEE target = my_address, inbound -> super_accept
    const my_addr = Address.init(0xcc99887766);
    var rules: [1]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_TEE);
    rules[0].v.fwd.address = my_addr.toInt();

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};

    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        true, // inbound
        Address.init(0xaa11223344),
        Address.init(0xbb55667788),
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        my_addr,
        null,
        null,
        &outputs,
    );
    try testing.expectEqual(DoZtFilterResult.super_accept, result);
}

test "doZtFilter: TEE to source is no-op" {
    const nconf = makeTestNconf();
    // TEE target = zt_source -> no-op, falls through
    const zt_src = Address.init(0xaa11223344);
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_TEE);
    rules[0].v.fwd.address = zt_src.toInt();
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};

    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        zt_src,
        Address.init(0xbb55667788),
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        Address.init(0xcc99887766),
        null,
        null,
        &outputs,
    );
    // TEE to source is no-op, continues to next rule which is ACCEPT
    try testing.expectEqual(DoZtFilterResult.accept, result);
    // cc should NOT be set since TEE was a no-op
    try testing.expect(!outputs.cc.isSet());
}

test "doZtFilter: REDIRECT to dest is no-op" {
    const nconf = makeTestNconf();
    // REDIRECT target = zt_dest -> no-op, falls through
    const zt_dst = Address.init(0xbb55667788);
    var rules: [2]c_api.ZT_VirtualNetworkRule = undefined;
    rules[0] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_REDIRECT);
    rules[0].v.fwd.address = zt_dst.toInt();
    rules[1] = makeRule(c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    var rrl: RuleResultLog = undefined;
    rrl.clear();
    var outputs = FilterOutputs{};

    const result = doZtFilter(
        &rrl,
        &nconf,
        null,
        false,
        Address.init(0xaa11223344),
        zt_dst,
        MAC.init(0x112233445566),
        MAC.init(0xaabbccddeeff),
        &([_]u8{0} ** 64),
        64,
        0x0800,
        0,
        &rules,
        Address.init(0xcc99887766),
        null,
        null,
        &outputs,
    );
    // REDIRECT to same dest is no-op, continue to ACCEPT
    try testing.expectEqual(DoZtFilterResult.accept, result);
    // zt_dest should remain unchanged
    try testing.expect(outputs.zt_dest.eql(zt_dst));
}

// ══════════════════════════════════════════════════════════════════
//  Chunk 3 tests — multicast, bridge, credential, membership
// ══════════════════════════════════════════════════════════════════

// ── Multicast group helper tests ─────────────────────────────────

test "binarySearchMulticastGroup: finds element in sorted array" {
    const groups = [_]MulticastGroup{
        MulticastGroup.init(MAC.init(0x111111111111), 0),
        MulticastGroup.init(MAC.init(0x222222222222), 0),
        MulticastGroup.init(MAC.init(0x333333333333), 0),
    };
    const target = MulticastGroup.init(MAC.init(0x222222222222), 0);
    try testing.expectEqual(@as(?u32, 1), binarySearchMulticastGroup(&groups, &target));
}

test "binarySearchMulticastGroup: returns null for missing element" {
    const groups = [_]MulticastGroup{
        MulticastGroup.init(MAC.init(0x111111111111), 0),
        MulticastGroup.init(MAC.init(0x333333333333), 0),
    };
    const target = MulticastGroup.init(MAC.init(0x222222222222), 0);
    try testing.expect(binarySearchMulticastGroup(&groups, &target) == null);
}

test "binarySearchMulticastGroup: empty slice returns null" {
    const groups = [_]MulticastGroup{};
    const target = MulticastGroup.init(MAC.init(0x111111111111), 0);
    try testing.expect(binarySearchMulticastGroup(&groups, &target) == null);
}

test "upperBoundMulticastGroup: insertion point in middle" {
    const groups = [_]MulticastGroup{
        MulticastGroup.init(MAC.init(0x111111111111), 0),
        MulticastGroup.init(MAC.init(0x333333333333), 0),
    };
    const target = MulticastGroup.init(MAC.init(0x222222222222), 0);
    const pos = upperBoundMulticastGroup(&groups, &target);
    try testing.expectEqual(@as(u32, 1), pos);
}

test "sortMulticastGroups: sorts unsorted array" {
    var groups = [_]MulticastGroup{
        MulticastGroup.init(MAC.init(0x333333333333), 0),
        MulticastGroup.init(MAC.init(0x111111111111), 0),
        MulticastGroup.init(MAC.init(0x222222222222), 0),
    };
    sortMulticastGroups(&groups);
    try testing.expect(groups[0].mac().eql(MAC.init(0x111111111111)));
    try testing.expect(groups[1].mac().eql(MAC.init(0x222222222222)));
    try testing.expect(groups[2].mac().eql(MAC.init(0x333333333333)));
}

test "deduplicateMulticastGroups: removes duplicates" {
    var buf: [max_all_multicast_groups]MulticastGroup = undefined;
    buf[0] = MulticastGroup.init(MAC.init(0x111111111111), 0);
    buf[1] = MulticastGroup.init(MAC.init(0x111111111111), 0); // dup
    buf[2] = MulticastGroup.init(MAC.init(0x222222222222), 0);
    buf[3] = MulticastGroup.init(MAC.init(0x222222222222), 0); // dup
    buf[4] = MulticastGroup.init(MAC.init(0x333333333333), 0);
    const result = deduplicateMulticastGroups(&buf, 5);
    try testing.expectEqual(@as(u32, 3), result);
    try testing.expect(buf[0].mac().eql(MAC.init(0x111111111111)));
    try testing.expect(buf[1].mac().eql(MAC.init(0x222222222222)));
    try testing.expect(buf[2].mac().eql(MAC.init(0x333333333333)));
}

// ── Multicast subscription tests ─────────────────────────────────

test "Network: multicastSubscribe inserts in sorted order" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x333333333333), 0);
    const mg2 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    const mg3 = MulticastGroup.init(MAC.init(0x222222222222), 0);

    net.multicastSubscribe(null, mg1);
    net.multicastSubscribe(null, mg2);
    net.multicastSubscribe(null, mg3);

    try testing.expectEqual(@as(u32, 3), net._my_multicast_group_count);
    // Should be sorted.
    try testing.expect(net._my_multicast_groups[0].mac().eql(MAC.init(0x111111111111)));
    try testing.expect(net._my_multicast_groups[1].mac().eql(MAC.init(0x222222222222)));
    try testing.expect(net._my_multicast_groups[2].mac().eql(MAC.init(0x333333333333)));
}

test "Network: multicastSubscribe deduplicates" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    net.multicastSubscribe(null, mg1);
    net.multicastSubscribe(null, mg1); // duplicate — should be ignored

    try testing.expectEqual(@as(u32, 1), net._my_multicast_group_count);
}

test "Network: multicastUnsubscribe removes group" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    const mg2 = MulticastGroup.init(MAC.init(0x222222222222), 0);
    const mg3 = MulticastGroup.init(MAC.init(0x333333333333), 0);

    net.multicastSubscribe(null, mg1);
    net.multicastSubscribe(null, mg2);
    net.multicastSubscribe(null, mg3);
    try testing.expectEqual(@as(u32, 3), net._my_multicast_group_count);

    net.multicastUnsubscribe(&mg2);
    try testing.expectEqual(@as(u32, 2), net._my_multicast_group_count);
    try testing.expect(net._my_multicast_groups[0].mac().eql(MAC.init(0x111111111111)));
    try testing.expect(net._my_multicast_groups[1].mac().eql(MAC.init(0x333333333333)));
}

test "Network: multicastUnsubscribe nonexistent is no-op" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    const mg2 = MulticastGroup.init(MAC.init(0x222222222222), 0);
    net.multicastSubscribe(null, mg1);

    net.multicastUnsubscribe(&mg2); // not subscribed
    try testing.expectEqual(@as(u32, 1), net._my_multicast_group_count);
}

test "Network: subscribedToMulticastGroup finds direct subscription" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    const mg2 = MulticastGroup.init(MAC.init(0x222222222222), 0);
    net.multicastSubscribe(null, mg1);

    try testing.expect(net.subscribedToMulticastGroup(&mg1, false));
    try testing.expect(!net.subscribedToMulticastGroup(&mg2, false));
}

test "Network: subscribedToMulticastGroup finds bridged group" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    try net.learnBridgedMulticastGroup(null, &mg1, 1000);

    // Not found without bridged groups.
    try testing.expect(!net.subscribedToMulticastGroup(&mg1, false));
    // Found with bridged groups.
    try testing.expect(net.subscribedToMulticastGroup(&mg1, true));
}

// ── Bridge route tests ───────────────────────────────────────────

test "Network: learnBridgeRoute adds and overwrites" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mac1 = MAC.init(0x112233445566);
    const addr1 = Address.init(0xaa11223344);
    const addr2 = Address.init(0xbb55667788);

    try net.learnBridgeRoute(mac1, addr1);
    try testing.expect(net.findBridgeTo(mac1).eql(addr1));

    // Overwrite with new address.
    try net.learnBridgeRoute(mac1, addr2);
    try testing.expect(net.findBridgeTo(mac1).eql(addr2));
}

// ── allMulticastGroups tests ─────────────────────────────────────

test "Network: allMulticastGroups merges and deduplicates" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Direct subscription.
    const mg1 = MulticastGroup.init(MAC.init(0x111111111111), 0);
    net.multicastSubscribe(null, mg1);

    // Bridged group (different).
    const mg2 = MulticastGroup.init(MAC.init(0x222222222222), 0);
    try net.learnBridgedMulticastGroup(null, &mg2, 1000);

    // Enable broadcast.
    net._config.network_id = 0x1234;
    net._config.flags = network_config.flag_enable_broadcast;

    var buf: [max_all_multicast_groups]MulticastGroup = undefined;
    const count = net.allMulticastGroups(&buf);

    // Should have: mg1, mg2, broadcast = 3.
    try testing.expectEqual(@as(u32, 3), count);
}

test "Network: allMulticastGroups deduplicates overlapping groups" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Same group subscribed directly AND learned from bridge.
    const mg = MulticastGroup.init(MAC.init(0x111111111111), 0);
    net.multicastSubscribe(null, mg);
    try net.learnBridgedMulticastGroup(null, &mg, 1000);

    var buf: [max_all_multicast_groups]MulticastGroup = undefined;
    const count = net.allMulticastGroups(&buf);

    // Should deduplicate: only 1 entry.
    try testing.expectEqual(@as(u32, 1), count);
}

// ── Membership / gate tests ──────────────────────────────────────

test "Network: gate returns false with no config" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    var id = Identity.init();
    try testing.expect(!net.gate(null, Address.init(0xaa11223344), &id, 1000));
}

test "Network: gate returns true for public network" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    // Set config as public (net_type = PUBLIC, network_id set).
    net._config.network_id = 0x1234;
    net._config.net_type = @intCast(constants.c_api.ZT_NETWORK_TYPE_PUBLIC);

    var id = Identity.init();
    try testing.expect(net.gate(null, Address.init(0xaa11223344), &id, 1000));
}

test "Network: recentlyAssociatedWith returns false for unknown peer" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    try testing.expect(!net.recentlyAssociatedWith(Address.init(0xaa11223344), 1000));
}

// ── Credential method tests ──────────────────────────────────────

test "Network: addCredentialCom rejects wrong network ID" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    var com = CertificateOfMembership.init();
    // COM with wrong network ID (0xFFFF != 0x1234).
    // Set qualifier_count and network_id qualifier manually.
    com._qualifier_count = 2;
    com._qualifiers[1] = .{
        .qualifier_id = com_mod.ReservedId.network_id,
        .value = 0xFFFF,
        .max_delta = 0,
    };

    const result = net.addCredentialCom(&com, .{});
    try testing.expectEqual(membership_mod.AddCredentialResult.rejected, result);
}

test "Network: addCredentialTag rejects wrong network ID" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const tag = Tag.create(0xFFFF, 1000, Address.init(2), 10, 42);
    const result = net.addCredentialTag(&tag, .{});
    try testing.expectEqual(membership_mod.AddCredentialResult.rejected, result);
}

test "Network: pushCredentialsIfNeeded rate limits" {
    const allocator = testing.allocator;
    const S = struct {
        var push_count: u32 = 0;
        fn pushCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: i64) void {
            push_count += 1;
        }
    };
    S.push_count = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .push_credentials = &S.pushCb,
    });
    defer net.deinit();

    const peer = Address.init(0xaa11223344);

    // First push should always fire (lastPushed = 0 < lastConfigUpdate = 0 is false,
    // but now - 0 > peer_activity_timeout (500000) requires now > 500000).
    net.pushCredentialsIfNeeded(null, peer, 600000);
    try testing.expectEqual(@as(u32, 1), S.push_count);

    // Second push too soon — should NOT fire.
    net.pushCredentialsIfNeeded(null, peer, 600001);
    try testing.expectEqual(@as(u32, 1), S.push_count);

    // After timeout period — should fire.
    net.pushCredentialsIfNeeded(null, peer, 600000 + constants.peer_activity_timeout + 1);
    try testing.expectEqual(@as(u32, 2), S.push_count);
}

test "Network: peerRequestedCredentials uses request rate limit" {
    const allocator = testing.allocator;
    const S = struct {
        var push_count: u32 = 0;
        fn pushCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: i64) void {
            push_count += 1;
        }
    };
    S.push_count = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .push_credentials = &S.pushCb,
    });
    defer net.deinit();

    const peer = Address.init(0xaa11223344);

    // First request fires.
    net.peerRequestedCredentials(null, peer, 2000);
    try testing.expectEqual(@as(u32, 1), S.push_count);

    // Within rate limit (1000ms) — should NOT fire.
    net.peerRequestedCredentials(null, peer, 2500);
    try testing.expectEqual(@as(u32, 1), S.push_count);

    // After rate limit — should fire.
    net.peerRequestedCredentials(null, peer, 2000 + constants.peer_credentials_request_rate_limit + 1);
    try testing.expectEqual(@as(u32, 2), S.push_count);
}

// ── Clean tests ──────────────────────────────────────────────────

test "Network: clean removes expired bridged multicast groups" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg = MulticastGroup.init(MAC.init(0x111111111111), 0);
    try net.learnBridgedMulticastGroup(null, &mg, 1000);

    // Clean at time before expiry — should still be there.
    const expire_threshold = constants.multicast_like_expire * 2;
    net.clean(1000 + expire_threshold - 1);
    try testing.expect(net.subscribedToMulticastGroup(&mg, true));

    // Clean at time after expiry — should be gone.
    net.clean(1000 + expire_threshold + 1);
    try testing.expect(!net.subscribedToMulticastGroup(&mg, true));
}

test "Network: clean on destroyed network is no-op" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{});
    defer net.deinit();

    const mg = MulticastGroup.init(MAC.init(0x111111111111), 0);
    try net.learnBridgedMulticastGroup(null, &mg, 1000);

    net._destroyed = true;
    net.clean(1000 + constants.multicast_like_expire * 2 + 1);
    // Should NOT have cleaned because _destroyed is true.
    try testing.expect(net.subscribedToMulticastGroup(&mg, true));
}

test "Network: clean removes memberships for unknown peers" {
    const allocator = testing.allocator;
    const S = struct {
        fn peerNotExists(_: ?*anyopaque, _: Address) bool {
            return false; // peer doesn't exist
        }
    };

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .peer_exists = &S.peerNotExists,
    });
    defer net.deinit();

    // Manually add a membership.
    try net._memberships.set(Address.init(0xaa11223344), Membership.init(allocator));
    try testing.expectEqual(@as(usize, 1), net._memberships.count());

    net.clean(1000);
    try testing.expectEqual(@as(usize, 0), net._memberships.count());
}

test "Network: clean keeps memberships for known peers" {
    const allocator = testing.allocator;
    const S = struct {
        fn peerExists(_: ?*anyopaque, _: Address) bool {
            return true; // peer exists
        }
    };

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0x1234, Address.init(1), null, .{
        .peer_exists = &S.peerExists,
    });
    defer net.deinit();

    net._config.network_id = 0x1234; // set config so clean has something to pass

    try net._memberships.set(Address.init(0xaa11223344), Membership.init(allocator));
    try testing.expectEqual(@as(usize, 1), net._memberships.count());

    net.clean(1000);
    // Membership should be retained.
    try testing.expectEqual(@as(usize, 1), net._memberships.count());
}

// ── Chunk 4 Tests: Helper functions ──────────────────────────────

test "readU64: reads big-endian u64" {
    const buf = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), readU64(&buf, 0));
}

test "readU64: reads from offset" {
    const buf = [_]u8{ 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try testing.expectEqual(@as(u64, 0x0000000000000001), readU64(&buf, 2));
}

test "readU32: reads big-endian u32" {
    const buf = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expectEqual(@as(u32, 0xDEADBEEF), readU32(&buf, 0));
}

test "readU32: reads from offset" {
    const buf = [_]u8{ 0x00, 0x00, 0x01, 0x02, 0x03, 0x04 };
    try testing.expectEqual(@as(u32, 0x01020304), readU32(&buf, 2));
}

test "hexU16: formats zero" {
    var dst: [4]u8 = undefined;
    hexU16(&dst, 0x0000);
    try testing.expectEqualStrings("0000", &dst);
}

test "hexU16: formats max value" {
    var dst: [4]u8 = undefined;
    hexU16(&dst, 0xFFFF);
    try testing.expectEqualStrings("ffff", &dst);
}

test "hexU16: formats mid value" {
    var dst: [4]u8 = undefined;
    hexU16(&dst, 0x1A2B);
    try testing.expectEqualStrings("1a2b", &dst);
}

test "decimalU8: single digit" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 5);
    try testing.expectEqual(@as(u32, 1), len);
    try testing.expectEqualStrings("5", dst[0..len]);
}

test "decimalU8: two digits" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 42);
    try testing.expectEqual(@as(u32, 2), len);
    try testing.expectEqualStrings("42", dst[0..len]);
}

test "decimalU8: three digits" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 255);
    try testing.expectEqual(@as(u32, 3), len);
    try testing.expectEqualStrings("255", dst[0..len]);
}

test "decimalU8: zero" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 0);
    try testing.expectEqual(@as(u32, 1), len);
    try testing.expectEqualStrings("0", dst[0..len]);
}

test "decimalU8: boundary 10" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 10);
    try testing.expectEqual(@as(u32, 2), len);
    try testing.expectEqualStrings("10", dst[0..len]);
}

test "decimalU8: boundary 100" {
    var dst: [3]u8 = undefined;
    const len = decimalU8(&dst, 100);
    try testing.expectEqual(@as(u32, 3), len);
    try testing.expectEqualStrings("100", dst[0..len]);
}

test "buildRequestMetadata: contains required fields" {
    const rmd = buildRequestMetadata();
    // Must be non-empty.
    try testing.expect(rmd.sizeBytes() > 0);
    // Must contain version key.
    try testing.expect(rmd.contains("v"));
    // Must contain protocol version.
    try testing.expect(rmd.contains("pv"));
    // Must contain rules engine revision.
    try testing.expect(rmd.contains("revr"));
    // Must contain OS/arch.
    try testing.expect(rmd.contains("o"));
    // Must contain capabilities limits.
    try testing.expect(rmd.contains("mr"));
    try testing.expect(rmd.contains("mc"));
    try testing.expect(rmd.contains("mt"));
}

test "buildRequestMetadata: version values are correct" {
    const rmd = buildRequestMetadata();
    try testing.expectEqual(@as(u64, 7), rmd.getUI("v", 0));
    try testing.expectEqual(@as(u64, 13), rmd.getUI("pv", 0));
    try testing.expectEqual(@as(u64, 1), rmd.getUI("majv", 0));
    try testing.expectEqual(@as(u64, 16), rmd.getUI("minv", 0));
    try testing.expectEqual(@as(u64, 1), rmd.getUI("revv", 0));
}

// ── Chunk 4 Tests: setConfiguration ──────────────────────────────

test "Network: setConfiguration rejects wrong issued_to" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    var nconf = NetworkConfig.init();
    nconf.network_id = 0xABCD;
    nconf.issued_to = Address.init(0x2222222222); // different!
    const result = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 0), result);
}

test "Network: setConfiguration rejects wrong network_id" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    var nconf = NetworkConfig.init();
    nconf.network_id = 0x9999; // wrong network
    nconf.issued_to = Address.init(0x1111111111);
    const result = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 0), result);
}

test "Network: setConfiguration accepts valid config and returns 2" {
    const allocator = testing.allocator;
    const S = struct {
        var last_op: c_uint = 0;
        fn configCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, op: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            last_op = op;
            return 0;
        }
    };
    S.last_op = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{
        .configure_virtual_network_port = &S.configCb,
    });
    defer net.deinit();

    var nconf = NetworkConfig.init();
    nconf.network_id = 0xABCD;
    nconf.issued_to = Address.init(0x1111111111);
    nconf.mtu = 2800;
    const result = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 2), result);
    // Should fire UP since port was not initialized.
    try testing.expectEqual(@as(c_uint, c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP), S.last_op);
    try testing.expect(net._port_initialized);
}

test "Network: setConfiguration returns 1 for duplicate config" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    var nconf = NetworkConfig.init();
    nconf.network_id = 0xABCD;
    nconf.issued_to = Address.init(0x1111111111);
    nconf.mtu = 2800;
    // Apply first time.
    const r1 = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 2), r1);
    // Apply same config again.
    const r2 = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 1), r2);
}

test "Network: setConfiguration fires CONFIG_UPDATE on second config" {
    const allocator = testing.allocator;
    const S = struct {
        var last_op: c_uint = 0;
        fn configCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, op: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            last_op = op;
            return 0;
        }
    };
    S.last_op = 0;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{
        .configure_virtual_network_port = &S.configCb,
    });
    defer net.deinit();

    var nconf1 = NetworkConfig.init();
    nconf1.network_id = 0xABCD;
    nconf1.issued_to = Address.init(0x1111111111);
    nconf1.mtu = 2800;
    _ = net.setConfiguration(null, &nconf1, false);
    try testing.expectEqual(@as(c_uint, c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_UP), S.last_op);

    // Second config with different MTU.
    var nconf2 = NetworkConfig.init();
    nconf2.network_id = 0xABCD;
    nconf2.issued_to = Address.init(0x1111111111);
    nconf2.mtu = 1500;
    _ = net.setConfiguration(null, &nconf2, false);
    try testing.expectEqual(@as(c_uint, c_api.ZT_VIRTUAL_NETWORK_CONFIG_OPERATION_CONFIG_UPDATE), S.last_op);
}

test "Network: setConfiguration rejects when destroyed" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    net._destroyed = true;

    var nconf = NetworkConfig.init();
    nconf.network_id = 0xABCD;
    nconf.issued_to = Address.init(0x1111111111);
    const result = net.setConfiguration(null, &nconf, false);
    try testing.expectEqual(@as(i32, 0), result);
}

// ── Chunk 4 Tests: filterOutgoingPacket ──────────────────────────

test "Network: filterOutgoingPacket drops with no rules" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    // No rules configured → doZtFilter returns no_match → no capability match → drop.
    var qos: u8 = 0;
    const frame = [_]u8{0} ** 64;
    const accepted = net.filterOutgoingPacket(
        null,
        false,
        Address.init(0x1111111111),
        Address.init(0x2222222222),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
        &qos,
    );
    try testing.expect(!accepted);
    try testing.expectEqual(@as(u64, 1), net._outgoing_packets_dropped);
}

test "Network: filterOutgoingPacket accepts with ACCEPT rule" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    // Set up a single ACCEPT rule.
    net._config.rule_count = 1;
    net._config.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    var qos: u8 = 0;
    const frame = [_]u8{0} ** 64;
    const accepted = net.filterOutgoingPacket(
        null,
        false,
        Address.init(0x1111111111),
        Address.init(0x2222222222),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
        &qos,
    );
    try testing.expect(accepted);
    try testing.expectEqual(@as(u64, 1), net._outgoing_packets_accepted);
}

test "Network: filterOutgoingPacket increments drop counter on DROP rule" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    net._config.rule_count = 1;
    net._config.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_DROP);

    var qos: u8 = 0;
    const frame = [_]u8{0} ** 64;
    const accepted = net.filterOutgoingPacket(
        null,
        false,
        Address.init(0x1111111111),
        Address.init(0x2222222222),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
        &qos,
    );
    try testing.expect(!accepted);
    // DROP rule returns early before counter increment — only no_match→no-cap path increments.
    // The C++ code also doesn't increment on explicit DROP — it returns immediately.
    try testing.expectEqual(@as(u64, 0), net._outgoing_packets_dropped);
}

// ── Chunk 4 Tests: filterIncomingPacket ──────────────────────────

test "Network: filterIncomingPacket drops with no rules" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    const frame = [_]u8{0} ** 64;
    const result = net.filterIncomingPacket(
        null,
        Address.init(0x2222222222),
        Address.init(0x1111111111),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
    );
    try testing.expectEqual(@as(i32, 0), result);
    try testing.expectEqual(@as(u64, 1), net._incoming_packets_dropped);
}

test "Network: filterIncomingPacket accepts with ACCEPT rule" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    net._config.rule_count = 1;
    net._config.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_ACCEPT);

    const frame = [_]u8{0} ** 64;
    const result = net.filterIncomingPacket(
        null,
        Address.init(0x2222222222),
        Address.init(0x1111111111),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
    );
    try testing.expectEqual(@as(i32, 1), result);
    try testing.expectEqual(@as(u64, 1), net._incoming_packets_accepted);
}

test "Network: filterIncomingPacket DROP rule increments drop counter" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    net._config.rule_count = 1;
    net._config.rules_arr[0].t = @as(u8, c_api.ZT_NETWORK_RULE_ACTION_DROP);

    const frame = [_]u8{0} ** 64;
    const result = net.filterIncomingPacket(
        null,
        Address.init(0x2222222222),
        Address.init(0x1111111111),
        MAC.init(0x112233445566),
        MAC.init(0xAABBCCDDEEFF),
        &frame,
        64,
        0x0800,
        0,
    );
    try testing.expectEqual(@as(i32, 0), result);
    // C++ does NOT increment the counter on explicit DROP — only on fallthrough no-match.
    try testing.expectEqual(@as(u64, 0), net._incoming_packets_dropped);
}

// ── Chunk 4 Tests: handleConfigChunk ─────────────────────────────

test "Network: handleConfigChunk returns 0 when destroyed" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    net._destroyed = true;
    const result = net.handleConfigChunk(null, 0, Address.init(0), &[_]u8{}, 0);
    try testing.expectEqual(@as(u64, 0), result);
}

test "Network: handleConfigChunk returns 0 for truncated chunk" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    // Only 4 bytes — not enough for network ID (8 bytes).
    const buf = [_]u8{ 0, 0, 0, 0 };
    const result = net.handleConfigChunk(null, 0, Address.init(0), &buf, 0);
    try testing.expectEqual(@as(u64, 0), result);
}

test "Network: handleConfigChunk returns 0 for zero-length chunk data" {
    const allocator = testing.allocator;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{});
    defer net.deinit();

    // 8 bytes network ID + 2 bytes chunk length (= 0) = 10 bytes.
    // Legacy single-chunk format: no more bytes after chunk → enter legacy branch.
    // But source must be the controller or unset.
    var buf: [10]u8 = undefined;
    @memset(&buf, 0);
    // chunk_len = 0 → total_length = 0 → empty dict → fromDictionary likely fails.
    const ctrl = net.controller();
    const result = net.handleConfigChunk(null, 42, ctrl, &buf, 0);
    // chunk_len=0 so total_length=0, haveBytes==0==totalLength → tries to parse empty dict.
    // Empty dict → fromDictionary returns false → returns 0.
    try testing.expectEqual(@as(u64, 0), result);
}

// ── Chunk 4 Tests: requestConfiguration ──────────────────────────

test "Network: requestConfiguration does nothing when destroyed" {
    const allocator = testing.allocator;
    const S = struct {
        var called: bool = false;
        fn sendReq(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: Address, _: []const u8, _: u64, _: u64) void {
            called = true;
        }
    };
    S.called = false;

    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, 0xABCD, Address.init(0x1111111111), null, .{
        .send_network_config_request = &S.sendReq,
    });
    defer net.deinit();

    net._destroyed = true;
    net.requestConfiguration(null);
    try testing.expect(!S.called);
}

test "Network: requestConfiguration sends to controller for normal network" {
    const allocator = testing.allocator;
    const S = struct {
        var called_with_ctrl: u64 = 0;
        var called_with_nwid: u64 = 0;
        fn sendReq(_: ?*anyopaque, _: ?*anyopaque, nwid: u64, ctrl: Address, _: []const u8, _: u64, _: u64) void {
            called_with_ctrl = ctrl.toInt();
            called_with_nwid = nwid;
        }
    };
    S.called_with_ctrl = 0;
    S.called_with_nwid = 0;

    // Network ID → controller = upper 40 bits = nwid >> 24
    const nwid: u64 = 0x1234567890ABCDEF;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, Address.init(0x1111111111), null, .{
        .send_network_config_request = &S.sendReq,
    });
    defer net.deinit();

    net.requestConfiguration(null);
    try testing.expectEqual(nwid, S.called_with_nwid);
    // Controller is upper 40 bits of network ID (nwid >> 24).
    try testing.expectEqual(nwid >> 24, S.called_with_ctrl);
}

test "Network: requestConfiguration generates IPv6 ad-hoc config" {
    const allocator = testing.allocator;
    const S = struct {
        var config_applied: bool = false;
        fn configCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, _: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            config_applied = true;
            return 0;
        }
    };
    S.config_applied = false;

    // ffXXXXYYYYaaaaaa00 format: 0xff prefix, port range 1000-2000, some addr, trailing 00.
    // start_port_range = 0x03E8 (1000), end_port_range = 0x07D0 (2000)
    const nwid: u64 = 0xff03E807D0000000;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, Address.init(0x1111111111), null, .{
        .configure_virtual_network_port = &S.configCb,
    });
    defer net.deinit();

    net.requestConfiguration(null);
    // Ad-hoc config should have been generated and applied.
    try testing.expect(S.config_applied);
    try testing.expect(net._port_initialized);
    try testing.expectEqual(nwid, net._config.network_id);
    try testing.expectEqual(@as(u32, 14), net._config.rule_count);
    try testing.expectEqual(@as(u32, 1), net._config.static_ip_count);
    // Name should start with "adhoc-"
    try testing.expectEqualStrings("adhoc-", net._config.name[0..6]);
}

test "Network: requestConfiguration generates IPv4+IPv6 ad-hoc config" {
    const allocator = testing.allocator;
    const S = struct {
        var config_applied: bool = false;
        fn configCb(_: ?*anyopaque, _: ?*anyopaque, _: u64, _: *?*anyopaque, _: c_uint, _: ?*const VirtualNetworkConfig) c_int {
            config_applied = true;
            return 0;
        }
    };
    S.config_applied = false;

    // ffAAaaaaaaaaaa01 format: 0xff prefix, ipv4_net=10 (0x0A), some hub addr, trailing 01.
    // ipv4_net = (nwid >> 48) & 0xff = 0x0A = 10
    const nwid: u64 = 0xff0A000000000001;
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, Address.init(0x1111111111), null, .{
        .configure_virtual_network_port = &S.configCb,
    });
    defer net.deinit();

    net.requestConfiguration(null);
    try testing.expect(S.config_applied);
    try testing.expect(net._port_initialized);
    try testing.expectEqual(nwid, net._config.network_id);
    try testing.expectEqual(@as(u32, 1), net._config.rule_count);
    try testing.expectEqual(@as(u32, 2), net._config.static_ip_count);
    // Name should start with "adhoc-"
    try testing.expectEqualStrings("adhoc-", net._config.name[0..6]);
}

test "Network: requestConfiguration calls local_controller_request when we are controller" {
    const allocator = testing.allocator;
    const S = struct {
        var local_request_called: bool = false;
        var local_request_nwid: u64 = 0;
        fn localCtrlReq(_: ?*anyopaque, nwid: u64, _: Address, _: []const u8) void {
            local_request_called = true;
            local_request_nwid = nwid;
        }
    };
    S.local_request_called = false;
    S.local_request_nwid = 0;

    // Controller = upper 40 bits of nwid (nwid >> 24). Set nwid so controller == my_address.
    const my_addr: u64 = 0x1111111111;
    const nwid: u64 = my_addr << 24; // upper 40 bits == my_address
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, Address.init(my_addr), null, .{
        .local_controller_request = &S.localCtrlReq,
    });
    defer net.deinit();

    net.requestConfiguration(null);
    try testing.expect(S.local_request_called);
    try testing.expectEqual(nwid, S.local_request_nwid);
}

test "Network: requestConfiguration sets NOT_FOUND when local controller absent" {
    const allocator = testing.allocator;

    const my_addr: u64 = 0x1111111111;
    const nwid: u64 = my_addr << 24; // upper 40 bits == my_address
    var net = try allocator.create(Network);
    defer allocator.destroy(net);
    net.* = Network.init(allocator, nwid, Address.init(my_addr), null, .{
        // No local_controller_request callback.
    });
    defer net.deinit();

    net.requestConfiguration(null);
    try testing.expectEqual(NetconfFailure.not_found, net._netconf_failure);
}
