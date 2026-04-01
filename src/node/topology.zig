/// Network topology database.
///
/// Converted from `node/Topology.hpp` and `node/Topology.cpp`. Manages the
/// set of known peers, canonical network paths, planet/moon worlds, upstream
/// (root) addresses, and per-path physical configuration.
///
/// Cross-module calls to Node (for state object I/O and current time) are
/// modeled as configurable callbacks. These will be wired to the real Node
/// during Phase 6.
///
/// Peers and paths are stored in bounded fixed-size arrays rather than
/// heap-allocated hash tables. This limits the maximum number of concurrent
/// peers and paths but avoids heap allocation in the struct itself.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const constants = @import("constants.zig");
const Identity = @import("identity.zig").Identity;
const inet_address = @import("inet_address.zig");
const InetAddress = inet_address.InetAddress;
const IpScope = inet_address.IpScope;
const Mutex = @import("mutex.zig");
const path_mod = @import("path.zig");
const Path = path_mod.Path;
const Peer = @import("peer.zig").Peer;
const world_mod = @import("world.zig");
const World = world_mod.World;
const Root = world_mod.Root;

// ── Capacity Constants ──────────────────────────────────────────

/// Maximum number of peers in the topology.
pub const max_peers: u32 = 1024;

/// Maximum number of canonical paths.
pub const max_paths: u32 = 4096;

/// Maximum number of moons.
pub const max_moons: u32 = 16;

/// Maximum number of moon seeds (id, address pairs).
pub const max_moon_seeds: u32 = 32;

/// Maximum number of upstream (root/relay) addresses.
pub const max_upstream_addresses: u32 = 64;

/// Maximum number of configurable physical paths.
pub const max_configurable_paths: u32 = 32;

/// Default physical MTU.
pub const default_physmtu: u32 = 1432;

/// Minimum physical MTU.
pub const min_physmtu: u32 = 510;

/// Maximum physical MTU.
pub const max_physmtu: u32 = 10000;

// ── Peer Role ────────────────────────────────────────────────────

/// Role of a peer in the network hierarchy.
pub const PeerRole = enum(u8) {
    /// Leaf node (ordinary peer).
    leaf = 0,
    /// Moon root server.
    moon = 1,
    /// Planet root server.
    planet = 2,
};

// ── Physical Path Configuration ──────────────────────────────────

/// Configuration for a physical network path.
pub const PhysicalPathConfig = struct {
    /// If non-zero, this path is trusted (disables encryption).
    trusted_path_id: u64,
    /// MTU for this physical path.
    mtu: u32,

    pub fn init() PhysicalPathConfig {
        return .{
            .trusted_path_id = 0,
            .mtu = default_physmtu,
        };
    }
};

/// A configured physical path: a network prefix + its configuration.
pub const PhysicalPathEntry = struct {
    network: InetAddress,
    config: PhysicalPathConfig,

    pub fn init() PhysicalPathEntry {
        return .{
            .network = InetAddress.zero(),
            .config = PhysicalPathConfig.init(),
        };
    }
};

// ── Moon Seed ────────────────────────────────────────────────────

/// A moon seed: a moon world ID paired with a seed address.
pub const MoonSeed = struct {
    id: u64,
    seed: Address,

    pub fn init() MoonSeed {
        return .{ .id = 0, .seed = Address.zero() };
    }

    pub fn eql(self: MoonSeed, other: MoonSeed) bool {
        return self.id == other.id and self.seed.eql(other.seed);
    }
};

// ── Peer Entry ───────────────────────────────────────────────────

/// A slot in the peer table.
const PeerEntry = struct {
    addr: Address,
    peer: Peer,
    in_use: bool,

    fn init() PeerEntry {
        return .{
            .addr = Address.zero(),
            .peer = undefined,
            .in_use = false,
        };
    }
};

// ── Path Entry ───────────────────────────────────────────────────

/// A slot in the canonical path table.
const PathEntry = struct {
    key: path_mod.HashKey,
    path: Path,
    in_use: bool,

    fn init() PathEntry {
        return .{
            .key = path_mod.HashKey.zero(),
            .path = Path.init(),
            .in_use = false,
        };
    }
};

// ── Callback Types ───────────────────────────────────────────────

/// Callback for getting the current time in milliseconds.
pub const NowCallback = *const fn (ctx: ?*anyopaque) i64;

/// Callback for reading a state object.
/// Returns the number of bytes read, or -1 on failure.
pub const StateObjectGetCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    obj_type: u32,
    id: [2]u64,
    data: [*]u8,
    max_len: u32,
) i32;

/// Callback for writing a state object.
pub const StateObjectPutCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    obj_type: u32,
    id: [2]u64,
    data: [*]const u8,
    len: u32,
) void;

/// Callback for deleting a state object.
pub const StateObjectDeleteCallback = *const fn (
    ctx: ?*anyopaque,
    t_ptr: ?*anyopaque,
    obj_type: u32,
    id: [2]u64,
) void;

// ── State Object Type Constants (from ZeroTierOne.h) ─────────────

/// ZT_STATE_OBJECT_PLANET
const state_object_planet: u32 = 4;
/// ZT_STATE_OBJECT_MOON
const state_object_moon: u32 = 5;
/// ZT_STATE_OBJECT_PEER
const state_object_peer: u32 = 6;

// ── Topology ─────────────────────────────────────────────────────

pub const Topology = struct {
    // -- Our identity (needed for self-check in various lookups) --
    _my_identity: Identity,

    // -- Peers --
    _peers: [max_peers]PeerEntry,
    _peer_count: u32,
    _peers_m: Mutex,

    // -- Canonical paths --
    _paths: [max_paths]PathEntry,
    _path_count: u32,
    _paths_m: Mutex,

    // -- Worlds --
    _planet: World,
    _moons: [max_moons]World,
    _moon_count: u32,
    _moon_seeds: [max_moon_seeds]MoonSeed,
    _moon_seed_count: u32,
    _upstream_addresses: [max_upstream_addresses]Address,
    _upstream_count: u32,
    _am_upstream: bool,
    _upstreams_m: Mutex,

    // -- Physical path configuration --
    _physical_path_config: [max_configurable_paths]PhysicalPathEntry,
    _num_configured_physical_paths: u32,

    // -- Callbacks --
    _now_fn: ?NowCallback,
    _state_get_fn: ?StateObjectGetCallback,
    _state_put_fn: ?StateObjectPutCallback,
    _state_delete_fn: ?StateObjectDeleteCallback,
    _cb_ctx: ?*anyopaque,

    // ── Construction ──────────────────────────────────────────

    /// Create a new Topology database.
    /// Initializes the topology in-place to avoid stack overflow from large arrays.
    pub fn create(self: *Topology, my_identity: *const Identity) void {
        self._my_identity = my_identity.*;

        self._peers = [_]PeerEntry{PeerEntry.init()} ** max_peers;
        self._peer_count = 0;
        self._peers_m = .{};

        self._paths = [_]PathEntry{PathEntry.init()} ** max_paths;
        self._path_count = 0;
        self._paths_m = .{};

        self._planet = World.init();
        self._moons = [_]World{World.init()} ** max_moons;
        self._moon_count = 0;
        self._moon_seeds = [_]MoonSeed{MoonSeed.init()} ** max_moon_seeds;
        self._moon_seed_count = 0;
        self._upstream_addresses = [_]Address{Address.zero()} ** max_upstream_addresses;
        self._upstream_count = 0;
        self._am_upstream = false;
        self._upstreams_m = .{};

        self._physical_path_config = [_]PhysicalPathEntry{PhysicalPathEntry.init()} ** max_configurable_paths;
        self._num_configured_physical_paths = 0;

        self._now_fn = null;
        self._state_get_fn = null;
        self._state_put_fn = null;
        self._state_delete_fn = null;
        self._cb_ctx = null;
    }

    /// Set callbacks for Node integration.
    pub fn setCallbacks(
        self: *Topology,
        ctx: ?*anyopaque,
        now_fn: ?NowCallback,
        state_get_fn: ?StateObjectGetCallback,
        state_put_fn: ?StateObjectPutCallback,
        state_delete_fn: ?StateObjectDeleteCallback,
    ) void {
        self._cb_ctx = ctx;
        self._now_fn = now_fn;
        self._state_get_fn = state_get_fn;
        self._state_put_fn = state_put_fn;
        self._state_delete_fn = state_delete_fn;
    }

    /// Clean up — wipe key material from all peers.
    pub fn deinit(self: *Topology) void {
        for (&self._peers) |*entry| {
            if (entry.in_use) {
                entry.peer.deinit();
                entry.in_use = false;
            }
        }
        self._peer_count = 0;
    }

    // ── Peer Management ──────────────────────────────────────

    /// Add a peer. If a peer with the same address already exists,
    /// the existing peer is kept (not replaced). Returns a pointer
    /// to the peer in the table (existing or newly added), or null
    /// if the table is full.
    pub fn addPeer(self: *Topology, peer: *const Peer) ?*Peer {
        self._peers_m.lock();
        defer self._peers_m.unlock();

        const addr = peer._id.address();

        // Check if already present
        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(addr)) {
                return &entry.peer;
            }
        }

        // Find an empty slot
        for (&self._peers) |*entry| {
            if (!entry.in_use) {
                entry.addr = addr;
                entry.peer = peer.*;
                entry.in_use = true;
                self._peer_count += 1;
                return &entry.peer;
            }
        }

        return null; // Table full
    }

    /// Get a peer by address. Returns null if not found.
    pub fn getPeer(self: *Topology, zta: Address) ?*Peer {
        // Don't return ourselves
        if (zta.eql(self._my_identity.address())) {
            return null;
        }

        self._peers_m.lock();
        defer self._peers_m.unlock();

        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(zta)) {
                return &entry.peer;
            }
        }

        return null;
    }

    /// Get a peer without preventing cache eviction (no side effects).
    pub fn getPeerNoCache(self: *Topology, zta: Address) ?*Peer {
        self._peers_m.lock();
        defer self._peers_m.unlock();

        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(zta)) {
                return &entry.peer;
            }
        }

        return null;
    }

    /// Get the identity of a peer by address. Returns null if not found.
    /// If the address matches our own identity, returns our identity.
    pub fn getIdentity(self: *Topology, zta: Address) ?*const Identity {
        if (zta.eql(self._my_identity.address())) {
            return &self._my_identity;
        }

        self._peers_m.lock();
        defer self._peers_m.unlock();

        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(zta)) {
                return entry.peer.identity();
            }
        }

        return null;
    }

    /// Remove a peer by address. Returns true if found and removed.
    pub fn removePeer(self: *Topology, zta: Address) bool {
        self._peers_m.lock();
        defer self._peers_m.unlock();

        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(zta)) {
                entry.peer.deinit();
                entry.in_use = false;
                self._peer_count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Count of peers currently in the table.
    pub fn peerCount(self: *Topology) u32 {
        self._peers_m.lock();
        defer self._peers_m.unlock();
        return self._peer_count;
    }

    /// Count of active peers (those with a direct path).
    pub fn countActive(self: *Topology, now: i64) u32 {
        self._peers_m.lock();
        defer self._peers_m.unlock();

        var cnt: u32 = 0;
        for (&self._peers) |*entry| {
            if (entry.in_use) {
                if (entry.peer.getAppropriatePath(now, false) != null) {
                    cnt += 1;
                }
            }
        }
        return cnt;
    }

    /// Get all peer addresses. Writes into the provided buffer and returns
    /// the number of addresses written.
    pub fn allPeerAddresses(self: *Topology, out: []Address) u32 {
        self._peers_m.lock();
        defer self._peers_m.unlock();

        var count: u32 = 0;
        for (&self._peers) |*entry| {
            if (entry.in_use and count < out.len) {
                out[count] = entry.addr;
                count += 1;
            }
        }
        return count;
    }

    // ── Path Management ──────────────────────────────────────

    /// Get or create a canonical path for the given local socket and
    /// remote address. Returns a pointer to the path in the table,
    /// or null if the table is full.
    pub fn getPath(self: *Topology, local_socket: i64, remote_addr: *const InetAddress) ?*Path {
        const key = path_mod.HashKey.init(local_socket, remote_addr);

        self._paths_m.lock();
        defer self._paths_m.unlock();

        // Look for existing
        for (&self._paths) |*entry| {
            if (entry.in_use and entry.key.eql(key)) {
                return &entry.path;
            }
        }

        // Create new
        for (&self._paths) |*entry| {
            if (!entry.in_use) {
                entry.key = key;
                entry.path = Path.initWithAddress(local_socket, remote_addr.*);
                entry.in_use = true;
                self._path_count += 1;
                return &entry.path;
            }
        }

        return null; // Table full
    }

    /// Count of canonical paths.
    pub fn pathCount(self: *Topology) u32 {
        self._paths_m.lock();
        defer self._paths_m.unlock();
        return self._path_count;
    }

    // ── Upstream / Root Management ───────────────────────────

    /// Get the best upstream (root) peer for relaying.
    ///
    /// Returns the upstream peer with the best relay quality score,
    /// or null if no upstream peers are known.
    ///
    /// Lock order: _upstreams_m before _peers_m (must be consistent
    /// with getRootsToContact, sendWhoisRequest, _memoizeUpstreams).
    pub fn getUpstreamPeer(self: *Topology, now: i64) ?*Peer {
        _ = now;
        // Lock order: _upstreams_m first, then _peers_m
        self._upstreams_m.lock();
        defer self._upstreams_m.unlock();
        self._peers_m.lock();
        defer self._peers_m.unlock();

        var best: ?*Peer = null;
        var best_q: u32 = std.math.maxInt(u32);

        const current_now = if (self._now_fn) |now_fn| now_fn(self._cb_ctx) else @as(i64, 0);

        for (0..self._upstream_count) |i| {
            const addr = self._upstream_addresses[i];
            for (&self._peers) |*entry| {
                if (entry.in_use and entry.addr.eql(addr)) {
                    const q = entry.peer.relayQuality(current_now);
                    if (q <= best_q) {
                        best_q = q;
                        best = &entry.peer;
                    }
                    break;
                }
            }
        }

        return best;
    }

    /// Check if an identity is an upstream (root) peer.
    pub fn isUpstream(self: *const Topology, id: *const Identity) bool {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        const addr = id.address();
        for (0..self._upstream_count) |i| {
            if (self._upstream_addresses[i].eql(addr)) {
                return true;
            }
        }
        return false;
    }

    /// Check if we should accept a world update from the given address.
    pub fn shouldAcceptWorldUpdateFrom(self: *const Topology, addr: Address) bool {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        // Check upstream addresses
        for (0..self._upstream_count) |i| {
            if (self._upstream_addresses[i].eql(addr)) {
                return true;
            }
        }

        // Check moon seeds
        for (0..self._moon_seed_count) |i| {
            if (self._moon_seeds[i].seed.eql(addr)) {
                return true;
            }
        }

        return false;
    }

    /// Get the role of a peer by address.
    pub fn role(self: *const Topology, ztaddr: Address) PeerRole {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        // Check if it's an upstream
        var is_upstream = false;
        for (0..self._upstream_count) |i| {
            if (self._upstream_addresses[i].eql(ztaddr)) {
                is_upstream = true;
                break;
            }
        }

        if (!is_upstream) {
            return .leaf;
        }

        // Check if it's a planet root
        const roots = self._planet.roots();
        for (roots) |r| {
            if (r.identity.address().eql(ztaddr)) {
                return .planet;
            }
        }

        // It's an upstream but not a planet root — must be a moon root
        return .moon;
    }

    /// Check if an endpoint is prohibited for a given ZeroTier address.
    ///
    /// For root servers, only addresses defined in the world definition
    /// are permitted. This provides additional security against spoofing.
    pub fn isProhibitedEndpoint(self: *const Topology, ztaddr: Address, ipaddr: *const InetAddress) bool {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        // Only apply to upstream addresses
        var is_upstream = false;
        for (0..self._upstream_count) |i| {
            if (self._upstream_addresses[i].eql(ztaddr)) {
                is_upstream = true;
                break;
            }
        }
        if (!is_upstream) {
            return false;
        }

        // Check planet roots
        const planet_roots = self._planet.roots();
        for (planet_roots) |r| {
            if (r.identity.address().eql(ztaddr)) {
                if (r.endpoint_count == 0) {
                    return false; // No stable endpoints specified, allow dynamic
                }
                for (0..r.endpoint_count) |j| {
                    if (ipaddr.ipsEqual(&r.stable_endpoints[j])) {
                        return false;
                    }
                }
            }
        }

        // Check moon roots
        for (0..self._moon_count) |mi| {
            const moon_roots = self._moons[mi].roots();
            for (moon_roots) |r| {
                if (r.identity.address().eql(ztaddr)) {
                    if (r.endpoint_count == 0) {
                        return false; // No stable endpoints, allow dynamic
                    }
                    for (0..r.endpoint_count) |j| {
                        if (ipaddr.ipsEqual(&r.stable_endpoints[j])) {
                            return false;
                        }
                    }
                }
            }
        }

        return true; // Root address with no matching stable endpoint — prohibited
    }

    /// Get root contact information: addresses + their stable endpoints.
    /// Writes results into the provided buffers. Returns the number of
    /// root entries written.
    pub const RootContact = struct {
        addr: Address,
        peer: ?*Peer,
        endpoints: [world_mod.max_stable_endpoints_per_root]InetAddress,
        endpoint_count: u32,
    };

    /// Lock order: _upstreams_m before _peers_m.
    pub fn getRootsToContact(self: *Topology, out: []RootContact) u32 {
        self._upstreams_m.lock();
        defer self._upstreams_m.unlock();
        self._peers_m.lock();
        defer self._peers_m.unlock();

        var count: u32 = 0;

        // Planet roots
        const planet_roots = self._planet.roots();
        for (planet_roots) |r| {
            if (!r.identity.eql(&self._my_identity) and count < out.len) {
                out[count].addr = r.identity.address();
                out[count].peer = self._findPeerLocked(r.identity.address());
                out[count].endpoint_count = r.endpoint_count;
                for (0..r.endpoint_count) |j| {
                    out[count].endpoints[j] = r.stable_endpoints[j];
                }
                count += 1;
            }
        }

        // Moon roots
        for (0..self._moon_count) |mi| {
            const moon_roots = self._moons[mi].roots();
            for (moon_roots) |r| {
                if (!r.identity.eql(&self._my_identity) and count < out.len) {
                    // Check for duplicate address
                    var dup = false;
                    for (0..count) |k| {
                        if (out[k].addr.eql(r.identity.address())) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        out[count].addr = r.identity.address();
                        out[count].peer = self._findPeerLocked(r.identity.address());
                        out[count].endpoint_count = r.endpoint_count;
                        for (0..r.endpoint_count) |j| {
                            out[count].endpoints[j] = r.stable_endpoints[j];
                        }
                        count += 1;
                    }
                }
            }
        }

        // Moon seeds (address only, no endpoints)
        for (0..self._moon_seed_count) |i| {
            if (count < out.len) {
                var dup = false;
                for (0..count) |k| {
                    if (out[k].addr.eql(self._moon_seeds[i].seed)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    out[count].addr = self._moon_seeds[i].seed;
                    out[count].peer = null;
                    out[count].endpoint_count = 0;
                    count += 1;
                }
            }
        }

        return count;
    }

    /// Get all upstream addresses.
    pub fn upstreamAddresses(self: *const Topology, out: []Address) u32 {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        var count: u32 = 0;
        for (0..self._upstream_count) |i| {
            if (count < out.len) {
                out[count] = self._upstream_addresses[i];
                count += 1;
            }
        }
        return count;
    }

    /// Get current moons.
    pub fn moons(self: *const Topology, out: []World) u32 {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        var count: u32 = 0;
        for (0..self._moon_count) |i| {
            if (count < out.len) {
                out[count] = self._moons[i];
                count += 1;
            }
        }
        return count;
    }

    /// Get moon IDs we are waiting for from seeds.
    pub fn moonsWanted(self: *const Topology, out: []u64) u32 {
        const self_mut: *Topology = @constCast(self);
        self_mut._upstreams_m.lock();
        defer self_mut._upstreams_m.unlock();

        var count: u32 = 0;
        for (0..self._moon_seed_count) |i| {
            const mid = self._moon_seeds[i].id;
            // Deduplicate
            var dup = false;
            for (0..count) |k| {
                if (out[k] == mid) {
                    dup = true;
                    break;
                }
            }
            if (!dup and count < out.len) {
                out[count] = mid;
                count += 1;
            }
        }
        return count;
    }

    /// Get the current planet.
    pub fn planet(self: *const Topology) *const World {
        return &self._planet;
    }

    /// Planet's world ID (safe to read without lock).
    pub fn planetWorldId(self: *const Topology) u64 {
        return self._planet.id();
    }

    /// Planet's world timestamp (safe to read without lock).
    pub fn planetWorldTimestamp(self: *const Topology) u64 {
        return self._planet.timestamp();
    }

    /// Whether we are a root server in a planet or moon.
    pub fn amUpstream(self: *const Topology) bool {
        return self._am_upstream;
    }

    // ── World Management ─────────────────────────────────────

    /// Validate and add/update a world (planet or moon).
    ///
    /// Returns true if the world was valid and newer than the current
    /// one (or totally new for moons).
    pub fn addWorld(self: *Topology, new_world: *const World, always_accept_new: bool) bool {
        const world_type = new_world.worldType();
        if (world_type != .planet and world_type != .moon) {
            return false;
        }

        self._peers_m.lock();
        defer self._peers_m.unlock();
        self._upstreams_m.lock();
        defer self._upstreams_m.unlock();

        if (world_type == .planet) {
            if (self._planet.shouldBeReplacedBy(new_world)) {
                self._planet = new_world.*;
            } else {
                return false;
            }
        } else {
            // Moon
            var existing_idx: ?usize = null;
            for (0..self._moon_count) |i| {
                if (self._moons[i].id() == new_world.id()) {
                    existing_idx = i;
                    break;
                }
            }

            if (existing_idx) |idx| {
                if (self._moons[idx].shouldBeReplacedBy(new_world)) {
                    self._moons[idx] = new_world.*;
                } else {
                    return false;
                }
            } else {
                // New moon
                if (always_accept_new) {
                    if (self._moon_count < max_moons) {
                        self._moons[self._moon_count] = new_world.*;
                        self._moon_count += 1;
                    } else {
                        return false; // No room
                    }
                } else {
                    // Check if we have a seed for this moon
                    var found_seed = false;
                    for (0..self._moon_seed_count) |si| {
                        if (self._moon_seeds[si].id == new_world.id()) {
                            const roots = new_world.roots();
                            for (roots) |r| {
                                if (r.identity.address().eql(self._moon_seeds[si].seed)) {
                                    // Remove the seed
                                    self._removeMoonSeedAt(si);
                                    // Add the moon
                                    if (self._moon_count < max_moons) {
                                        self._moons[self._moon_count] = new_world.*;
                                        self._moon_count += 1;
                                        found_seed = true;
                                    }
                                    break;
                                }
                            }
                            if (found_seed) break;
                        }
                    }
                    if (!found_seed) {
                        return false;
                    }
                }
            }
        }

        self._memoizeUpstreams();

        return true;
    }

    /// Add a moon by ID and seed address. If the moon is already
    /// cached (via state callbacks), it will be loaded. Otherwise
    /// the seed is recorded for later contact.
    pub fn addMoon(self: *Topology, id: u64, seed: Address) void {
        // In the full integration, this would try to load from
        // stateObjectGet first. For now, just record the seed.
        if (seed.toInt() != 0) {
            self._upstreams_m.lock();
            defer self._upstreams_m.unlock();

            const ms = MoonSeed{ .id = id, .seed = seed };
            // Check for duplicates
            for (0..self._moon_seed_count) |i| {
                if (self._moon_seeds[i].eql(ms)) {
                    return;
                }
            }
            if (self._moon_seed_count < max_moon_seeds) {
                self._moon_seeds[self._moon_seed_count] = ms;
                self._moon_seed_count += 1;
            }
        }
    }

    /// Remove a moon by world ID.
    pub fn removeMoon(self: *Topology, id: u64) void {
        self._peers_m.lock();
        defer self._peers_m.unlock();
        self._upstreams_m.lock();
        defer self._upstreams_m.unlock();

        // Remove from moons
        var i: u32 = 0;
        while (i < self._moon_count) {
            if (self._moons[i].id() == id) {
                // Shift remaining moons down
                var j: u32 = i;
                while (j + 1 < self._moon_count) : (j += 1) {
                    self._moons[j] = self._moons[j + 1];
                }
                self._moon_count -= 1;
            } else {
                i += 1;
            }
        }

        // Remove matching moon seeds
        i = 0;
        while (i < self._moon_seed_count) {
            if (self._moon_seeds[i].id == id) {
                var j: u32 = i;
                while (j + 1 < self._moon_seed_count) : (j += 1) {
                    self._moon_seeds[j] = self._moon_seeds[j + 1];
                }
                self._moon_seed_count -= 1;
            } else {
                i += 1;
            }
        }

        self._memoizeUpstreams();
    }

    // ── Periodic Tasks ───────────────────────────────────────

    /// Clean expired peers and unused paths.
    pub fn doPeriodicTasks(self: *Topology, now: i64) void {
        // Clean peers: remove non-alive, non-upstream peers
        {
            self._peers_m.lock();
            defer self._peers_m.unlock();
            self._upstreams_m.lock();
            defer self._upstreams_m.unlock();

            for (&self._peers) |*entry| {
                if (entry.in_use and !entry.peer.isAlive(now)) {
                    // Don't remove upstream peers
                    var is_up = false;
                    for (0..self._upstream_count) |i| {
                        if (self._upstream_addresses[i].eql(entry.addr)) {
                            is_up = true;
                            break;
                        }
                    }
                    if (!is_up) {
                        entry.peer.deinit();
                        entry.in_use = false;
                        self._peer_count -= 1;
                    }
                }
            }
        }

        // Clean paths: remove paths with no external references.
        // Since we don't have SharedPtr reference counting in the Zig
        // conversion, we skip this for now. In the full integration,
        // paths that are no longer referenced by any peer would be
        // collected here.
    }

    // ── Physical Path Configuration ──────────────────────────

    /// Get outbound path info (MTU and trusted path ID) for a physical address.
    pub fn getOutboundPathInfo(self: *const Topology, physical_address: *const InetAddress) struct { mtu: u32, trusted_path_id: u64 } {
        for (0..self._num_configured_physical_paths) |i| {
            if (self._physical_path_config[i].network.containsAddress(physical_address)) {
                return .{
                    .mtu = self._physical_path_config[i].config.mtu,
                    .trusted_path_id = self._physical_path_config[i].config.trusted_path_id,
                };
            }
        }
        return .{ .mtu = default_physmtu, .trusted_path_id = 0 };
    }

    /// Get the MTU for an outbound physical path.
    pub fn getOutboundPathMtu(self: *const Topology, physical_address: *const InetAddress) u32 {
        for (0..self._num_configured_physical_paths) |i| {
            if (self._physical_path_config[i].network.containsAddress(physical_address)) {
                return self._physical_path_config[i].config.mtu;
            }
        }
        return default_physmtu;
    }

    /// Get the trusted path ID for a physical address, or 0 if none.
    pub fn getOutboundPathTrust(self: *const Topology, physical_address: *const InetAddress) u64 {
        for (0..self._num_configured_physical_paths) |i| {
            if (self._physical_path_config[i].network.containsAddress(physical_address)) {
                return self._physical_path_config[i].config.trusted_path_id;
            }
        }
        return 0;
    }

    /// Check whether an inbound trusted-path-marked packet is valid.
    pub fn shouldInboundPathBeTrusted(self: *const Topology, physical_address: *const InetAddress, trusted_path_id: u64) bool {
        for (0..self._num_configured_physical_paths) |i| {
            if (self._physical_path_config[i].config.trusted_path_id == trusted_path_id and
                self._physical_path_config[i].network.containsAddress(physical_address))
            {
                return true;
            }
        }
        return false;
    }

    /// Set or clear physical path configuration.
    ///
    /// If `path_network` is null, all configurations are cleared.
    /// If `path_config` is null, the entry for `path_network` is removed.
    /// Otherwise the entry is added or updated.
    pub fn setPhysicalPathConfiguration(
        self: *Topology,
        path_network: ?*const InetAddress,
        config: ?*const PhysicalPathConfig,
    ) void {
        if (path_network == null) {
            self._num_configured_physical_paths = 0;
            return;
        }

        const net = path_network.?;

        if (config) |cfg| {
            // Add or update
            var pc = cfg.*;

            // Clamp MTU
            if (pc.mtu == 0) {
                pc.mtu = default_physmtu;
            } else if (pc.mtu < min_physmtu) {
                pc.mtu = min_physmtu;
            } else if (pc.mtu > max_physmtu) {
                pc.mtu = max_physmtu;
            }

            // Check for existing entry
            for (0..self._num_configured_physical_paths) |i| {
                if (self._physical_path_config[i].network.eql(net)) {
                    self._physical_path_config[i].config = pc;
                    return;
                }
            }

            // Add new entry
            if (self._num_configured_physical_paths < max_configurable_paths) {
                self._physical_path_config[self._num_configured_physical_paths] = .{
                    .network = net.*,
                    .config = pc,
                };
                self._num_configured_physical_paths += 1;
            }
        } else {
            // Remove entry
            var i: u32 = 0;
            while (i < self._num_configured_physical_paths) {
                if (self._physical_path_config[i].network.eql(net)) {
                    var j: u32 = i;
                    while (j + 1 < self._num_configured_physical_paths) : (j += 1) {
                        self._physical_path_config[j] = self._physical_path_config[j + 1];
                    }
                    self._num_configured_physical_paths -= 1;
                } else {
                    i += 1;
                }
            }
        }
    }

    // ── Private Helpers ──────────────────────────────────────

    /// Find a peer by address. Assumes _peers_m is already locked.
    fn _findPeerLocked(self: *Topology, addr: Address) ?*Peer {
        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(addr)) {
                return &entry.peer;
            }
        }
        return null;
    }

    /// Memoize upstream addresses from planet + moons.
    /// Assumes _upstreams_m and _peers_m are already locked.
    fn _memoizeUpstreams(self: *Topology) void {
        self._upstream_count = 0;
        self._am_upstream = false;

        // Planet roots
        const planet_roots = self._planet.roots();
        for (planet_roots) |r| {
            if (r.identity.eql(&self._my_identity)) {
                self._am_upstream = true;
            } else if (!self._isUpstreamAddress(r.identity.address())) {
                if (self._upstream_count < max_upstream_addresses) {
                    self._upstream_addresses[self._upstream_count] = r.identity.address();
                    self._upstream_count += 1;
                }
                // Ensure peer exists for this root with its stable endpoints
                self._ensurePeerForRootWithEndpoints(&r.identity, &r.stable_endpoints, r.endpoint_count);
            }
        }

        // Moon roots
        for (0..self._moon_count) |mi| {
            const moon_roots = self._moons[mi].roots();
            for (moon_roots) |r| {
                if (r.identity.eql(&self._my_identity)) {
                    self._am_upstream = true;
                } else if (!self._isUpstreamAddress(r.identity.address())) {
                    if (self._upstream_count < max_upstream_addresses) {
                        self._upstream_addresses[self._upstream_count] = r.identity.address();
                        self._upstream_count += 1;
                    }
                    self._ensurePeerForRootWithEndpoints(&r.identity, &r.stable_endpoints, r.endpoint_count);
                }
            }
        }

        // Sort upstream addresses
        std.mem.sort(Address, self._upstream_addresses[0..self._upstream_count], {}, Address.lessThan);
    }

    /// Check if an address is already in the upstream list.
    fn _isUpstreamAddress(self: *const Topology, addr: Address) bool {
        for (0..self._upstream_count) |i| {
            if (self._upstream_addresses[i].eql(addr)) {
                return true;
            }
        }
        return false;
    }

    /// Ensure a peer entry exists for a root, including its stable endpoints as paths.
    /// Assumes _peers_m is locked.
    fn _ensurePeerForRoot(self: *Topology, root_identity: *const Identity) void {
        self._ensurePeerForRootWithEndpoints(root_identity, null, 0);
    }

    fn _ensurePeerForRootWithEndpoints(
        self: *Topology,
        root_identity: *const Identity,
        endpoints: ?[]const InetAddress,
        endpoint_count: u32,
    ) void {
        const addr = root_identity.address();

        // Check if peer already exists
        var existing_peer: ?*Peer = null;
        for (&self._peers) |*entry| {
            if (entry.in_use and entry.addr.eql(addr)) {
                existing_peer = &entry.peer;
                break;
            }
        }

        // Create new peer if needed
        if (existing_peer == null) {
            if (Peer.create(&self._my_identity, root_identity)) |peer| {
                for (&self._peers) |*entry| {
                    if (!entry.in_use) {
                        entry.addr = addr;
                        entry.peer = peer;
                        entry.in_use = true;
                        self._peer_count += 1;
                        existing_peer = &entry.peer;
                        break;
                    }
                }
            }
        }

        // Add stable endpoints as paths (must use topology's path table for stable pointers)
        if (existing_peer) |peer| {
            if (endpoints) |eps| {
                const now = std.time.milliTimestamp();
                var i: u32 = 0;
                while (i < endpoint_count and i < eps.len) : (i += 1) {
                    if (eps[i].port() != 0) {
                        // Use topology's path table for stable pointer
                        const stable_path = self.getPath(-1, &eps[i]);
                        if (stable_path) |p| {
                            p._last_in = now;
                            _ = peer.addPath(p, now);
                        }
                    }
                }
            }
        }
    }

    /// Remove a moon seed at the given index.
    fn _removeMoonSeedAt(self: *Topology, idx: usize) void {
        var j: u32 = @intCast(idx);
        while (j + 1 < self._moon_seed_count) : (j += 1) {
            self._moon_seeds[j] = self._moon_seeds[j + 1];
        }
        self._moon_seed_count -= 1;
    }
};

// ── Tests ─────────────────────────────────────────────────────────

// Helper: heap-allocate a Topology so the ~5 MB struct doesn't blow the stack.
fn createTestTopology(my_id: *const Identity) !*Topology {
    const topo = try testing.allocator.create(Topology);
    topo.create(my_id);
    return topo;
}

fn destroyTestTopology(topo: *Topology) void {
    topo.deinit();
    testing.allocator.destroy(topo);
}

test "Topology: create and basic state" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    try testing.expectEqual(@as(u32, 0), topo.peerCount());
    try testing.expectEqual(@as(u32, 0), topo.pathCount());
    try testing.expect(!topo.amUpstream());
    try testing.expectEqual(@as(u64, 0), topo.planetWorldId());
}

test "Topology: addPeer and getPeer" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();

    const added = topo.addPeer(&peer);
    try testing.expect(added != null);
    try testing.expectEqual(@as(u32, 1), topo.peerCount());

    // Should be findable by address
    const found = topo.getPeer(peer_id.address());
    try testing.expect(found != null);
    try testing.expect(found.?.identity().address().eql(peer_id.address()));
}

test "Topology: addPeer does not replace existing" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer1 = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer1.deinit();
    var peer2 = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer2.deinit();

    const added1 = topo.addPeer(&peer1);
    try testing.expect(added1 != null);

    const added2 = topo.addPeer(&peer2);
    try testing.expect(added2 != null);

    // Should still be one peer
    try testing.expectEqual(@as(u32, 1), topo.peerCount());
}

test "Topology: getPeer returns null for self" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    try testing.expect(topo.getPeer(my_id.address()) == null);
}

test "Topology: removePeer" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();

    _ = topo.addPeer(&peer);
    try testing.expectEqual(@as(u32, 1), topo.peerCount());

    try testing.expect(topo.removePeer(peer_id.address()));
    try testing.expectEqual(@as(u32, 0), topo.peerCount());
    try testing.expect(topo.getPeer(peer_id.address()) == null);

    // Removing non-existent should return false
    try testing.expect(!topo.removePeer(peer_id.address()));
}

test "Topology: getIdentity returns own identity" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const found = topo.getIdentity(my_id.address());
    try testing.expect(found != null);
    try testing.expect(found.?.address().eql(my_id.address()));
}

test "Topology: getIdentity returns peer identity" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();
    _ = topo.addPeer(&peer);

    const found = topo.getIdentity(peer_id.address());
    try testing.expect(found != null);
    try testing.expect(found.?.address().eql(peer_id.address()));
}

test "Topology: getPath creates canonical paths" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const addr1 = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    const addr2 = InetAddress.initV4(.{ 5, 6, 7, 8 }, 9993);

    const p1 = topo.getPath(1, &addr1);
    try testing.expect(p1 != null);
    try testing.expectEqual(@as(u32, 1), topo.pathCount());

    const p2 = topo.getPath(2, &addr2);
    try testing.expect(p2 != null);
    try testing.expectEqual(@as(u32, 2), topo.pathCount());

    // Same key should return same path
    const p1_again = topo.getPath(1, &addr1);
    try testing.expect(p1_again != null);
    try testing.expect(p1.? == p1_again.?);
    try testing.expectEqual(@as(u32, 2), topo.pathCount());
}

test "Topology: physical path configuration" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    // Initially, default MTU for any address
    const addr = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);
    try testing.expectEqual(default_physmtu, topo.getOutboundPathMtu(&addr));
    try testing.expectEqual(@as(u64, 0), topo.getOutboundPathTrust(&addr));

    // Configure a trusted path for 10.0.0.0/8
    var network = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    var cfg = PhysicalPathConfig{
        .trusted_path_id = 42,
        .mtu = 2000,
    };
    topo.setPhysicalPathConfiguration(&network, &cfg);

    try testing.expectEqual(@as(u32, 2000), topo.getOutboundPathMtu(&addr));
    try testing.expectEqual(@as(u64, 42), topo.getOutboundPathTrust(&addr));

    // Address outside the network should get defaults
    const addr2 = InetAddress.initV4(.{ 192, 168, 1, 1 }, 9993);
    try testing.expectEqual(default_physmtu, topo.getOutboundPathMtu(&addr2));

    // Trusted path check
    try testing.expect(topo.shouldInboundPathBeTrusted(&addr, 42));
    try testing.expect(!topo.shouldInboundPathBeTrusted(&addr, 99));
    try testing.expect(!topo.shouldInboundPathBeTrusted(&addr2, 42));
}

test "Topology: setPhysicalPathConfiguration clear all" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var network = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    var cfg = PhysicalPathConfig{
        .trusted_path_id = 42,
        .mtu = 2000,
    };
    topo.setPhysicalPathConfiguration(&network, &cfg);
    try testing.expectEqual(@as(u32, 1), topo._num_configured_physical_paths);

    // Clear all
    topo.setPhysicalPathConfiguration(null, null);
    try testing.expectEqual(@as(u32, 0), topo._num_configured_physical_paths);
}

test "Topology: setPhysicalPathConfiguration remove entry" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var network = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    var cfg = PhysicalPathConfig{
        .trusted_path_id = 42,
        .mtu = 2000,
    };
    topo.setPhysicalPathConfiguration(&network, &cfg);
    try testing.expectEqual(@as(u32, 1), topo._num_configured_physical_paths);

    // Remove that specific entry
    topo.setPhysicalPathConfiguration(&network, null);
    try testing.expectEqual(@as(u32, 0), topo._num_configured_physical_paths);
}

test "Topology: setPhysicalPathConfiguration MTU clamping" {
    var my_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var network = InetAddress.initV4(.{ 10, 0, 0, 0 }, 8);
    const addr = InetAddress.initV4(.{ 10, 0, 0, 1 }, 9993);

    // MTU 0 should default
    var cfg = PhysicalPathConfig{ .trusted_path_id = 0, .mtu = 0 };
    topo.setPhysicalPathConfiguration(&network, &cfg);
    try testing.expectEqual(default_physmtu, topo.getOutboundPathMtu(&addr));

    // MTU below minimum should be clamped
    cfg.mtu = 100;
    topo.setPhysicalPathConfiguration(&network, &cfg);
    try testing.expectEqual(min_physmtu, topo.getOutboundPathMtu(&addr));

    // MTU above maximum should be clamped
    cfg.mtu = 999999;
    topo.setPhysicalPathConfiguration(&network, &cfg);
    try testing.expectEqual(max_physmtu, topo.getOutboundPathMtu(&addr));
}

test "Topology: addMoon records seed" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const seed_addr = Address.init(0x1234567890);
    topo.addMoon(12345, seed_addr);

    try testing.expectEqual(@as(u32, 1), topo._moon_seed_count);
    try testing.expectEqual(@as(u64, 12345), topo._moon_seeds[0].id);
    try testing.expect(topo._moon_seeds[0].seed.eql(seed_addr));

    // Duplicate should not add again
    topo.addMoon(12345, seed_addr);
    try testing.expectEqual(@as(u32, 1), topo._moon_seed_count);
}

test "Topology: addMoon with zero seed ignored" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    topo.addMoon(12345, Address.zero());
    try testing.expectEqual(@as(u32, 0), topo._moon_seed_count);
}

test "Topology: removeMoon removes seeds" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const seed_addr = Address.init(0x1234567890);
    topo.addMoon(12345, seed_addr);
    try testing.expectEqual(@as(u32, 1), topo._moon_seed_count);

    topo.removeMoon(12345);
    try testing.expectEqual(@as(u32, 0), topo._moon_seed_count);
}

test "Topology: moonsWanted deduplicates" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const seed1 = Address.init(0x1234567890);
    const seed2 = Address.init(0x9876543210);
    topo.addMoon(12345, seed1);
    topo.addMoon(12345, seed2); // same moon ID, different seed

    var wanted: [8]u64 = undefined;
    const count = topo.moonsWanted(&wanted);
    try testing.expectEqual(@as(u32, 1), count); // Only one unique moon ID
    try testing.expectEqual(@as(u64, 12345), wanted[0]);
}

test "Topology: role returns leaf for unknown" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const unknown = Address.init(0x1234567890);
    try testing.expectEqual(PeerRole.leaf, topo.role(unknown));
}

test "Topology: shouldAcceptWorldUpdateFrom checks seeds" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const seed_addr = Address.init(0x1234567890);
    topo.addMoon(12345, seed_addr);

    try testing.expect(topo.shouldAcceptWorldUpdateFrom(seed_addr));

    const other = Address.init(0x9876543210);
    try testing.expect(!topo.shouldAcceptWorldUpdateFrom(other));
}

test "Topology: allPeerAddresses" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id1 = try Identity.generate(testing.allocator);
    var peer_id2 = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var p1 = Peer.create(&my_id, &peer_id1) orelse return error.SkipZigTest;
    defer p1.deinit();
    var p2 = Peer.create(&my_id, &peer_id2) orelse return error.SkipZigTest;
    defer p2.deinit();

    _ = topo.addPeer(&p1);
    _ = topo.addPeer(&p2);

    var addrs: [8]Address = undefined;
    const count = topo.allPeerAddresses(&addrs);
    try testing.expectEqual(@as(u32, 2), count);
}

test "Topology: getPeerNoCache" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();
    _ = topo.addPeer(&peer);

    const found = topo.getPeerNoCache(peer_id.address());
    try testing.expect(found != null);

    // Non-existent
    const bogus = Address.init(0xFFFFFFFFFF);
    try testing.expect(topo.getPeerNoCache(bogus) == null);
}

test "Topology: doPeriodicTasks removes dead peers" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();

    // Set last_receive to make it look alive
    peer._last_receive = 1_000_000;
    _ = topo.addPeer(&peer);
    try testing.expectEqual(@as(u32, 1), topo.peerCount());

    // At time 1_000_000 + a little, peer is still alive
    topo.doPeriodicTasks(1_000_100);
    try testing.expectEqual(@as(u32, 1), topo.peerCount());

    // At time far in the future, peer should be removed (not upstream)
    topo.doPeriodicTasks(2_000_000);
    try testing.expectEqual(@as(u32, 0), topo.peerCount());
}

test "Topology: isProhibitedEndpoint returns false for non-upstream" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const addr = Address.init(0x1234567890);
    const ip = InetAddress.initV4(.{ 1, 2, 3, 4 }, 9993);
    try testing.expect(!topo.isProhibitedEndpoint(addr, &ip));
}

test "Topology: countActive with no paths" {
    var my_id = try Identity.generate(testing.allocator);
    var peer_id = try Identity.generate(testing.allocator);

    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var peer = Peer.create(&my_id, &peer_id) orelse return error.SkipZigTest;
    defer peer.deinit();
    _ = topo.addPeer(&peer);

    // No paths set, so count active should be 0
    try testing.expectEqual(@as(u32, 0), topo.countActive(1_000_000));
}

test "Topology: planet accessor" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    const p = topo.planet();
    try testing.expect(!p.isSet());
}

test "Topology: upstreamAddresses with no upstreams" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var addrs: [8]Address = undefined;
    const count = topo.upstreamAddresses(&addrs);
    try testing.expectEqual(@as(u32, 0), count);
}

test "Topology: moons with no moons" {
    var my_id = try Identity.generate(testing.allocator);
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var m: [4]World = undefined;
    const count = topo.moons(&m);
    try testing.expectEqual(@as(u32, 0), count);
}

test "Topology: getRootsToContact returns empty when no planet" {
    var my_id = try Identity.generate(testing.allocator);
    defer my_id.deinit();
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    var contacts: [8]Topology.RootContact = undefined;
    const count = topo.getRootsToContact(&contacts);
    try testing.expectEqual(@as(u32, 0), count);
}

test "Topology: _findPeerLocked returns null for unknown address" {
    var my_id = try Identity.generate(testing.allocator);
    defer my_id.deinit();
    const topo = try createTestTopology(&my_id);
    defer destroyTestTopology(topo);

    // Must hold lock to call _findPeerLocked
    topo._peers_m.lock();
    defer topo._peers_m.unlock();

    const result = topo._findPeerLocked(Address.init(0xDEADBEEF0));
    try testing.expect(result == null);
}
