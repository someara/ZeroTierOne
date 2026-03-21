/// A container for certificates of membership and other network credentials.
///
/// Converted from `node/Membership.hpp` and `node/Membership.cpp`.
///
/// This is a relational join between Peer and Network. It stores the remote
/// member's COM, tags, capabilities, and certificates of ownership, along
/// with a revocation table. It is NOT thread-safe — callers must lock
/// externally.
///
/// Design notes for Phase 5:
///   - `pushCredentials` is modeled as a callback since it depends on
///     Packet/Switch/Metrics (Phase 6). The caller provides a function
///     pointer that handles serialization and sending.
///   - `addCredential` verification is also callback-based: the caller
///     provides a `VerifyFn` that resolves signer identity (via Topology)
///     and returns the verify result. This avoids coupling to
///     RuntimeEnvironment until Phase 6.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Capability = @import("capability.zig").Capability;
const CertificateOfMembership = @import("certificate_of_membership.zig").CertificateOfMembership;
const CertificateOfOwnership = @import("certificate_of_ownership.zig").CertificateOfOwnership;
const constants = @import("constants.zig");
const Credential = @import("credential.zig");
const Hashtable = @import("hashtable.zig").Hashtable;
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const MAC = @import("mac.zig").MAC;
const NetworkConfig = @import("network_config.zig").NetworkConfig;
const Revocation = @import("revocation.zig").Revocation;
const Tag = @import("tag.zig").Tag;

/// Sentinel value indicating an unused credential slot.
pub const cred_id_unused: u64 = 0xffffffffffffffff;

/// Result of attempting to add a credential.
pub const AddCredentialResult = enum {
    /// Credential was rejected (invalid, revoked, or old).
    rejected,
    /// Credential was accepted and is new/updated.
    accepted_new,
    /// Credential was accepted but identical to one already stored.
    accepted_redundant,
    /// Credential verification needs the signer identity (WHOIS pending).
    deferred_for_whois,
};

/// Result from a credential verification callback.
///
/// Maps to the C++ `verify()` return: 0 = valid, 1 = deferred, else = invalid.
pub const VerifyResult = enum {
    ok,
    deferred,
    invalid,
};

/// Callback for credential rejection tracing.
pub const TraceRejectFn = *const fn (ctx: ?*anyopaque, credential_type: Credential.Type, credential_id: u32, reason: []const u8) void;

/// Callback for verifying a COM. The callback should look up the signer
/// identity via Topology and call `verifySignature`.
pub const VerifyComFn = *const fn (ctx: ?*anyopaque, com: *const CertificateOfMembership) VerifyResult;

/// Callback for verifying a Tag.
pub const VerifyTagFn = *const fn (ctx: ?*anyopaque, tag: *const Tag) VerifyResult;

/// Callback for verifying a Capability.
pub const VerifyCapFn = *const fn (ctx: ?*anyopaque, cap: *const Capability) VerifyResult;

/// Callback for verifying a CertificateOfOwnership.
pub const VerifyCooFn = *const fn (ctx: ?*anyopaque, coo: *const CertificateOfOwnership) VerifyResult;

/// Callback for verifying a Revocation.
pub const VerifyRevFn = *const fn (ctx: ?*anyopaque, rev: *const Revocation) VerifyResult;

/// Verification callbacks bundle.
pub const VerifyCallbacks = struct {
    verify_com: ?VerifyComFn = null,
    verify_tag: ?VerifyTagFn = null,
    verify_cap: ?VerifyCapFn = null,
    verify_coo: ?VerifyCooFn = null,
    verify_rev: ?VerifyRevFn = null,
    trace_reject: ?TraceRejectFn = null,
    ctx: ?*anyopaque = null,
};

/// Membership — credential store joining a Peer and a Network.
pub const Membership = struct {
    /// Last time we pushed MULTICAST_LIKE(s).
    _last_updated_multicast: i64,

    /// Revocation threshold for COM, or 0 if none.
    _com_revocation_threshold: i64,

    /// Time we last pushed credentials to this peer.
    _last_pushed_credentials: i64,

    /// Remote member's latest network COM.
    _com: CertificateOfMembership,

    /// Revocations indexed by credentialKey(type, id).
    _revocations: Hashtable(u64, i64),

    /// Remote tags indexed by tag ID.
    _remote_tags: Hashtable(u32, Tag),

    /// Remote capabilities indexed by capability ID.
    _remote_caps: Hashtable(u32, Capability),

    /// Remote certificates of ownership indexed by COO ID.
    _remote_coos: Hashtable(u32, CertificateOfOwnership),

    /// Allocator used for hashtable storage.
    _allocator: std.mem.Allocator,

    // ── Constructor / Destructor ──────────────────────────

    pub fn init(allocator: std.mem.Allocator) Membership {
        return .{
            ._last_updated_multicast = 0,
            ._com_revocation_threshold = 0,
            ._last_pushed_credentials = 0,
            ._com = CertificateOfMembership.init(),
            ._revocations = Hashtable(u64, i64).init(allocator),
            ._remote_tags = Hashtable(u32, Tag).init(allocator),
            ._remote_caps = Hashtable(u32, Capability).init(allocator),
            ._remote_coos = Hashtable(u32, CertificateOfOwnership).init(allocator),
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: *Membership) void {
        self._revocations.deinit();
        self._remote_tags.deinit();
        self._remote_caps.deinit();
        self._remote_coos.deinit();
    }

    // ── Accessors ─────────────────────────────────────────

    /// Return the last time credentials were pushed to this peer.
    pub fn lastPushedCredentials(self: *const Membership) i64 {
        return self._last_pushed_credentials;
    }

    /// Return the timestamp of the current COM.
    pub fn comTimestamp(self: *const Membership) i64 {
        return self._com.timestamp();
    }

    /// Return the COM revocation threshold.
    pub fn comRevocationThreshold(self: *const Membership) i64 {
        return self._com_revocation_threshold;
    }

    /// Get the current COM.
    pub fn com(self: *const Membership) *const CertificateOfMembership {
        return &self._com;
    }

    /// Record that credentials were pushed at `now`.
    pub fn setLastPushedCredentials(self: *Membership, now: i64) void {
        self._last_pushed_credentials = now;
    }

    // ── Multicast gate ────────────────────────────────────

    /// Check whether we should push MULTICAST_LIKEs to this peer.
    ///
    /// Returns true (and updates the timestamp) if enough time has
    /// passed since the last multicast announcement.
    pub fn multicastLikeGate(self: *Membership, now: i64) bool {
        if ((now - self._last_updated_multicast) >= constants.multicast_announce_period) {
            self._last_updated_multicast = now;
            return true;
        }
        return false;
    }

    // ── Access control ────────────────────────────────────

    /// Check whether the peer is allowed on this network at all.
    ///
    /// A peer is allowed if the network is public, or if:
    ///   - The COM timestamp exceeds the revocation threshold, AND
    ///   - Our COM agrees with the remote COM (given the remote identity).
    pub fn isAllowedOnNetwork(
        self: *const Membership,
        nconf: *const NetworkConfig,
        other_identity: *const Identity,
    ) bool {
        if (nconf.isPublic()) return true;
        return (self._com.timestamp() > self._com_revocation_threshold) and
            nconf.com.agreesWith(&self._com, other_identity);
    }

    /// Check whether the peer was recently associated (COM is set and
    /// not older than the peer activity timeout).
    pub fn recentlyAssociated(self: *const Membership, now: i64) bool {
        return self._com.isSet() and
            ((now - self._com.timestamp()) < constants.peer_activity_timeout);
    }

    // ── Certificate of Ownership queries ──────────────────

    /// Check whether the peer owns a given IP address.
    pub fn hasCertificateOfOwnershipForIp(
        self: *const Membership,
        nconf: *const NetworkConfig,
        ip: *const InetAddress,
    ) bool {
        var it = self._remote_coos.iterator();
        while (it.next()) |entry| {
            if (isCredentialTimestampValid(self, nconf, CertificateOfOwnership.credential_type, entry.value_ptr.timestamp(), entry.value_ptr.id()) and
                entry.value_ptr.ownsIp(ip))
            {
                return true;
            }
        }
        return isV6NDPEmulatedIp(nconf, ip);
    }

    /// Check whether the peer owns a given MAC address.
    pub fn hasCertificateOfOwnershipForMac(
        self: *const Membership,
        nconf: *const NetworkConfig,
        mac_val: MAC,
    ) bool {
        var it = self._remote_coos.iterator();
        while (it.next()) |entry| {
            if (isCredentialTimestampValid(self, nconf, CertificateOfOwnership.credential_type, entry.value_ptr.timestamp(), entry.value_ptr.id()) and
                entry.value_ptr.ownsMac(mac_val))
            {
                return true;
            }
        }
        // _isV6NDPEmulated(nconf, MAC) always returns false in C++
        return false;
    }

    // ── Tag lookup ────────────────────────────────────────

    /// Get a remote member's tag by ID, or null if not found or expired.
    pub fn getTag(
        self: *const Membership,
        nconf: *const NetworkConfig,
        tag_id: u32,
    ) ?*const Tag {
        const t = self._remote_tags.get(tag_id) orelse return null;
        if (isCredentialTimestampValid(self, nconf, Tag.credential_type, t.timestamp(), t.id())) {
            return t;
        }
        return null;
    }

    // ── Add credentials ───────────────────────────────────

    /// Add a Certificate of Membership.
    pub fn addCom(
        self: *Membership,
        new_com: *const CertificateOfMembership,
        callbacks: VerifyCallbacks,
    ) AddCredentialResult {
        const newts = new_com.timestamp();
        if (newts <= self._com_revocation_threshold) {
            traceReject(callbacks, Credential.Type.com, 0, "revoked");
            return .rejected;
        }

        const oldts = self._com.timestamp();
        if (newts < oldts) {
            traceReject(callbacks, Credential.Type.com, 0, "old");
            return .rejected;
        }
        if (self._com.eql(new_com)) {
            return .accepted_redundant;
        }

        const verify_fn = callbacks.verify_com orelse {
            // No verification callback — accept on trust (testing mode).
            self._com = new_com.*;
            return .accepted_new;
        };

        return switch (verify_fn(callbacks.ctx, new_com)) {
            .ok => {
                self._com = new_com.*;
                return .accepted_new;
            },
            .deferred => .deferred_for_whois,
            .invalid => {
                traceReject(callbacks, Credential.Type.com, 0, "invalid");
                return .rejected;
            },
        };
    }

    /// Add a Tag credential.
    pub fn addTag(
        self: *Membership,
        nconf: *const NetworkConfig,
        tag: *const Tag,
        callbacks: VerifyCallbacks,
    ) AddCredentialResult {
        return addCredImpl(
            Tag,
            &self._remote_tags,
            &self._revocations,
            nconf,
            tag,
            tag.id(),
            tag.timestamp(),
            Tag.credential_type,
            callbacks,
            callbacks.verify_tag,
        );
    }

    /// Add a Capability credential.
    pub fn addCapability(
        self: *Membership,
        nconf: *const NetworkConfig,
        cap: *const Capability,
        callbacks: VerifyCallbacks,
    ) AddCredentialResult {
        return addCredImpl(
            Capability,
            &self._remote_caps,
            &self._revocations,
            nconf,
            cap,
            cap.capId(),
            cap.timestamp(),
            Capability.credential_type,
            callbacks,
            callbacks.verify_cap,
        );
    }

    /// Add a CertificateOfOwnership credential.
    pub fn addCoo(
        self: *Membership,
        nconf: *const NetworkConfig,
        coo: *const CertificateOfOwnership,
        callbacks: VerifyCallbacks,
    ) AddCredentialResult {
        return addCredImpl(
            CertificateOfOwnership,
            &self._remote_coos,
            &self._revocations,
            nconf,
            coo,
            coo.id(),
            coo.timestamp(),
            CertificateOfOwnership.credential_type,
            callbacks,
            callbacks.verify_coo,
        );
    }

    /// Add a Revocation.
    pub fn addRevocation(
        self: *Membership,
        rev: *const Revocation,
        callbacks: VerifyCallbacks,
    ) AddCredentialResult {
        const verify_fn = callbacks.verify_rev orelse {
            // No verification — accept on trust (testing mode).
            return self.applyRevocation(rev);
        };

        return switch (verify_fn(callbacks.ctx, rev)) {
            .ok => self.applyRevocation(rev),
            .deferred => .deferred_for_whois,
            .invalid => {
                traceReject(callbacks, Credential.Type.revocation, rev.id(), "invalid");
                return .rejected;
            },
        };
    }

    // ── Clean stale entries ───────────────────────────────

    /// Remove all credentials whose timestamps are no longer valid.
    pub fn clean(self: *Membership, nconf: *const NetworkConfig) void {
        cleanCredTable(Tag, &self._remote_tags, self, nconf);
        cleanCredTable(Capability, &self._remote_caps, self, nconf);
        cleanCredTable(CertificateOfOwnership, &self._remote_coos, self, nconf);
    }

    // ── Capability iteration ──────────────────────────────

    /// Iterator over valid remote capabilities.
    pub const CapabilityIterator = struct {
        _it: Hashtable(u32, Capability).Iterator,
        _membership: *const Membership,
        _nconf: *const NetworkConfig,

        pub fn init(m: *const Membership, nconf: *const NetworkConfig) CapabilityIterator {
            return .{
                ._it = m._remote_caps.iterator(),
                ._membership = m,
                ._nconf = nconf,
            };
        }

        /// Return the next valid capability, or null when exhausted.
        pub fn next(self: *CapabilityIterator) ?*Capability {
            while (self._it.next()) |entry| {
                if (isCredentialTimestampValid(
                    self._membership,
                    self._nconf,
                    Capability.credential_type,
                    entry.value_ptr.timestamp(),
                    entry.value_ptr.capId(),
                )) {
                    return entry.value_ptr;
                }
            }
            return null;
        }
    };

    /// Return an iterator over valid remote capabilities.
    pub fn capabilityIterator(self: *const Membership, nconf: *const NetworkConfig) CapabilityIterator {
        return CapabilityIterator.init(self, nconf);
    }

    // ── Static helpers ────────────────────────────────────

    /// Generate a key for indexing credentials by type and ID.
    ///
    /// This matches the C++ `Membership::credentialKey()`.
    pub fn credentialKey(cred_type: Credential.Type, cred_id: u32) u64 {
        return (@as(u64, cred_type.toInt()) << 32) | @as(u64, cred_id);
    }

    // ── Private helpers ───────────────────────────────────

    /// Check whether a credential's timestamp is within the allowed
    /// delta of the network config timestamp and not revoked.
    fn isCredentialTimestampValid(
        self: *const Membership,
        nconf: *const NetworkConfig,
        cred_type: Credential.Type,
        ts: i64,
        cred_id: u32,
    ) bool {
        const config_ts = nconf.timestamp;
        const diff = if (ts >= config_ts) ts - config_ts else config_ts - ts;
        if (diff > nconf.credential_time_max_delta) return false;

        const key = credentialKey(cred_type, cred_id);
        const threshold = self._revocations.getCopy(key);
        if (threshold) |t| {
            return ts > t;
        }
        return true;
    }

    /// Apply a verified revocation.
    fn applyRevocation(self: *Membership, rev: *const Revocation) AddCredentialResult {
        const ct = rev.credentialType();
        switch (ct) {
            .com => {
                if (rev.threshold() > self._com_revocation_threshold) {
                    self._com_revocation_threshold = rev.threshold();
                    return .accepted_new;
                }
                return .accepted_redundant;
            },
            .capability, .tag, .coo => {
                const key = credentialKey(ct, rev.credentialId());
                const rt = self._revocations.getOrPut(key, 0) catch return .rejected;
                if (rt.* < rev.threshold()) {
                    rt.* = rev.threshold();
                    self._com_revocation_threshold = rev.threshold();
                    return .accepted_new;
                }
                return .accepted_redundant;
            },
            else => return .rejected,
        }
    }

    /// Trace a credential rejection if a callback is set.
    fn traceReject(
        callbacks: VerifyCallbacks,
        cred_type: Credential.Type,
        cred_id: u32,
        reason: []const u8,
    ) void {
        if (callbacks.trace_reject) |f| {
            f(callbacks.ctx, cred_type, cred_id, reason);
        }
    }

    /// Generic credential add implementation.
    ///
    /// Mirrors the C++ `_addCredImpl` template.
    fn addCredImpl(
        comptime C: type,
        remote_creds: *Hashtable(u32, C),
        revocations: *const Hashtable(u64, i64),
        _: *const NetworkConfig,
        cred: *const C,
        cred_id: u32,
        cred_ts: i64,
        cred_type: Credential.Type,
        callbacks: VerifyCallbacks,
        verify_fn_opt: ?*const fn (?*anyopaque, *const C) VerifyResult,
    ) AddCredentialResult {
        // Check if we already have this credential
        if (remote_creds.get(cred_id)) |existing| {
            if (existing.timestamp() > cred_ts) {
                traceReject(callbacks, cred_type, cred_id, "old");
                return .rejected;
            }
            // Check byte-level equality for redundancy
            if (mem.eql(u8, mem.asBytes(existing), mem.asBytes(cred))) {
                return .accepted_redundant;
            }
        }

        // Check revocations
        const key = credentialKey(cred_type, cred_id);
        if (revocations.getCopy(key)) |threshold| {
            if (threshold >= cred_ts) {
                traceReject(callbacks, cred_type, cred_id, "revoked");
                return .rejected;
            }
        }

        // Verify
        const verify_fn = verify_fn_opt orelse {
            // No verification callback — accept on trust (testing mode).
            remote_creds.set(cred_id, cred.*) catch return .rejected;
            return .accepted_new;
        };

        return switch (verify_fn(callbacks.ctx, cred)) {
            .ok => {
                remote_creds.set(cred_id, cred.*) catch return .rejected;
                return .accepted_new;
            },
            .deferred => .deferred_for_whois,
            .invalid => {
                traceReject(callbacks, cred_type, cred_id, "invalid");
                return .rejected;
            },
        };
    }

    /// Remove stale entries from a credential hashtable.
    fn cleanCredTable(
        comptime C: type,
        table: *Hashtable(u32, C),
        self: *const Membership,
        nconf: *const NetworkConfig,
    ) void {
        // Collect keys to remove first, then erase (avoid mutation during iteration).
        var to_remove: [128]u32 = undefined;
        var remove_count: usize = 0;

        var it = table.iterator();
        while (it.next()) |entry| {
            if (!isCredentialTimestampValid(self, nconf, C.credential_type, entry.value_ptr.timestamp(), getCredId(C, entry.value_ptr))) {
                if (remove_count < to_remove.len) {
                    to_remove[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }

        for (to_remove[0..remove_count]) |key| {
            _ = table.erase(key);
        }
    }

    /// Get the ID of a credential, handling the Capability special case.
    fn getCredId(comptime C: type, cred: *const C) u32 {
        if (C == Capability) {
            return cred.capId();
        } else {
            return cred.id();
        }
    }
};

// ── NDP Emulation helpers (private) ───────────────────────────────

/// Check if an IPv6 address is emulated via NDP for 6plane/rfc4193.
///
/// This matches C++ `_isV6NDPEmulated(nconf, InetAddress)`.
fn isV6NDPEmulatedIp(nconf: *const NetworkConfig, ip: *const InetAddress) bool {
    if (!ip.isV6() or !nconf.ndpEmulation()) return false;

    const ip_bytes = ip.rawIpData() orelse return false;
    if (ip_bytes.len < 16) return false;

    // Check 6plane (/40 prefix match)
    const sixpl = InetAddress.makeIpv66plane(nconf.network_id, nconf.issued_to.toInt());
    for (nconf.static_ips[0..nconf.static_ip_count]) |*sip| {
        if (sip.ipsEqual(&sixpl)) {
            const sixpl_bytes = sixpl.rawIpData() orelse break;
            if (sixpl_bytes.len >= 5) {
                var prefix_matches = true;
                for (0..5) |j| {
                    if (ip_bytes[j] != sixpl_bytes[j]) {
                        prefix_matches = false;
                        break;
                    }
                }
                if (prefix_matches) return true;
            }
            break;
        }
    }

    // Check rfc4193 (/88 prefix match)
    const rfc4193 = InetAddress.makeIpv6rfc4193(nconf.network_id, nconf.issued_to.toInt());
    for (nconf.static_ips[0..nconf.static_ip_count]) |*sip| {
        if (sip.ipsEqual(&rfc4193)) {
            const rfc_bytes = rfc4193.rawIpData() orelse break;
            if (rfc_bytes.len >= 11) {
                var prefix_matches = true;
                for (0..11) |j| {
                    if (ip_bytes[j] != rfc_bytes[j]) {
                        prefix_matches = false;
                        break;
                    }
                }
                if (prefix_matches) return true;
            }
            break;
        }
    }

    return false;
}

// ── Tests ─────────────────────────────────────────────────────────

test "init and deinit" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    try testing.expectEqual(@as(i64, 0), m.lastPushedCredentials());
    try testing.expectEqual(@as(i64, 0), m.comTimestamp());
    try testing.expectEqual(@as(i64, 0), m.comRevocationThreshold());
}

test "credentialKey produces unique keys per type+id" {
    const k1 = Membership.credentialKey(Credential.Type.tag, 42);
    const k2 = Membership.credentialKey(Credential.Type.capability, 42);
    const k3 = Membership.credentialKey(Credential.Type.tag, 43);

    try testing.expect(k1 != k2);
    try testing.expect(k1 != k3);
    try testing.expect(k2 != k3);

    // Verify structure: type in upper 32, id in lower 32
    try testing.expectEqual(@as(u64, @as(u64, 3) << 32) | 42, k1);
    try testing.expectEqual(@as(u64, @as(u64, 2) << 32) | 42, k2);
}

test "multicastLikeGate rate-limits" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    // First call always succeeds (0 - 0 >= period)
    try testing.expect(m.multicastLikeGate(100_000));

    // Immediately after, should be gated
    try testing.expect(!m.multicastLikeGate(100_001));

    // After the announce period, should succeed again
    try testing.expect(m.multicastLikeGate(100_000 + constants.multicast_announce_period));
}

test "recentlyAssociated requires set COM and recent timestamp" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    // No COM set — not recently associated
    try testing.expect(!m.recentlyAssociated(1_000_000));
}

test "addCom without verify callback — default COM is redundant or rejected" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const com1 = CertificateOfMembership.init();
    const no_verify = VerifyCallbacks{};

    // Default COM has timestamp 0. With revocation threshold 0,
    // the check `newts <= _comRevocationThreshold` is `0 <= 0` = true,
    // so the COM is rejected as "revoked". This matches C++ behavior
    // where a 0-timestamp COM against a 0 threshold is blocked.
    const result = m.addCom(&com1, no_verify);
    try testing.expectEqual(AddCredentialResult.rejected, result);
}

test "addTag without verify callback stores tag" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();
    const no_verify = VerifyCallbacks{};

    // Create a tag with a known ID
    const tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 99);

    const result = m.addTag(&nconf, &tag, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_new, result);

    // Adding the same tag again should be redundant
    const result2 = m.addTag(&nconf, &tag, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_redundant, result2);
}

test "addTag rejects older tag" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();
    const no_verify = VerifyCallbacks{};

    const newer_tag = Tag.create(0x1234567890, 200_000, Address.init(0x1234567890), 42, 100);
    _ = m.addTag(&nconf, &newer_tag, no_verify);

    const older_tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 50);
    const result = m.addTag(&nconf, &older_tag, no_verify);
    try testing.expectEqual(AddCredentialResult.rejected, result);
}

test "addRevocation for COM updates threshold" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const no_verify = VerifyCallbacks{};

    // Create a revocation targeting COM type
    const com_rev = Revocation.create(
        0, // revocation_id
        0x1234567890, // network ID
        0, // credential ID (unused for COM)
        500_000, // threshold
        0, // flags
        Address.init(0xABCDEF0123), // target
        Credential.Type.com,
    );

    const result = m.addRevocation(&com_rev, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_new, result);
    try testing.expectEqual(@as(i64, 500_000), m.comRevocationThreshold());

    // Same threshold again should be redundant
    const result2 = m.addRevocation(&com_rev, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_redundant, result2);
}

test "addRevocation for tag type updates revocations table" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const no_verify = VerifyCallbacks{};

    const tag_rev = Revocation.create(
        1, // revocation_id
        0x1234567890, // network ID
        42, // credential ID = tag id 42
        300_000, // threshold
        0, // flags
        Address.init(0xABCDEF0123), // target
        Credential.Type.tag,
    );

    const result = m.addRevocation(&tag_rev, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_new, result);

    // The revocation should now block tags with id=42 and timestamp <= 300_000
    const key = Membership.credentialKey(Credential.Type.tag, 42);
    const threshold = m._revocations.getCopy(key);
    try testing.expect(threshold != null);
    try testing.expectEqual(@as(i64, 300_000), threshold.?);
}

test "clean removes expired credentials" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    nconf.timestamp = 1_000_000;
    nconf.credential_time_max_delta = 100_000;

    const no_verify = VerifyCallbacks{};

    // Add a tag within the time window
    const good_tag = Tag.create(0x1234567890, 950_000, Address.init(0x1234567890), 1, 10);
    _ = m.addTag(&nconf, &good_tag, no_verify);

    // Add a tag outside the time window
    const old_tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 2, 20);
    _ = m.addTag(&nconf, &old_tag, no_verify);

    try testing.expectEqual(@as(usize, 2), m._remote_tags.count());

    m.clean(&nconf);

    // Only the good tag should remain
    try testing.expectEqual(@as(usize, 1), m._remote_tags.count());
    try testing.expect(m._remote_tags.get(1) != null);
    try testing.expect(m._remote_tags.get(2) == null);
}

test "capabilityIterator filters by timestamp validity" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    nconf.timestamp = 1_000_000;
    nconf.credential_time_max_delta = 100_000;

    const no_verify = VerifyCallbacks{};

    // Add a valid capability
    const good_cap = Capability.create(1, 1_000_000, 950_000, 1, &.{});
    _ = m.addCapability(&nconf, &good_cap, no_verify);

    // Add an expired capability
    const old_cap = Capability.create(2, 1_000_000, 100_000, 1, &.{});
    _ = m.addCapability(&nconf, &old_cap, no_verify);

    var it = m.capabilityIterator(&nconf);
    var count: u32 = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(u32, 1), count);
}

test "getTag returns null for expired tag" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    nconf.timestamp = 1_000_000;
    nconf.credential_time_max_delta = 50_000;

    const no_verify = VerifyCallbacks{};

    // Add a tag that's outside the time delta
    const old_tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 99);
    _ = m.addTag(&nconf, &old_tag, no_verify);

    // Should return null because timestamp is too old
    try testing.expect(m.getTag(&nconf, 42) == null);
}

test "getTag returns tag within valid time window" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    nconf.timestamp = 1_000_000;
    nconf.credential_time_max_delta = 100_000;

    const no_verify = VerifyCallbacks{};

    const tag = Tag.create(0x1234567890, 950_000, Address.init(0x1234567890), 42, 99);
    _ = m.addTag(&nconf, &tag, no_verify);

    const result = m.getTag(&nconf, 42);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 99), result.?.value());
}

test "verify callback integration — deferred" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();

    const DeferAll = struct {
        fn verifyTag(_: ?*anyopaque, _: *const Tag) VerifyResult {
            return .deferred;
        }
    };

    const callbacks = VerifyCallbacks{
        .verify_tag = DeferAll.verifyTag,
    };

    const tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 99);
    const result = m.addTag(&nconf, &tag, callbacks);
    try testing.expectEqual(AddCredentialResult.deferred_for_whois, result);

    // Tag should NOT have been stored
    try testing.expectEqual(@as(usize, 0), m._remote_tags.count());
}

test "verify callback integration — invalid" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();

    const RejectAll = struct {
        fn verifyTag(_: ?*anyopaque, _: *const Tag) VerifyResult {
            return .invalid;
        }
    };

    const callbacks = VerifyCallbacks{
        .verify_tag = RejectAll.verifyTag,
    };

    const tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 99);
    const result = m.addTag(&nconf, &tag, callbacks);
    try testing.expectEqual(AddCredentialResult.rejected, result);

    // Tag should NOT have been stored
    try testing.expectEqual(@as(usize, 0), m._remote_tags.count());
}

test "verify callback integration — ok" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();

    const AcceptAll = struct {
        fn verifyTag(_: ?*anyopaque, _: *const Tag) VerifyResult {
            return .ok;
        }
    };

    const callbacks = VerifyCallbacks{
        .verify_tag = AcceptAll.verifyTag,
    };

    const tag = Tag.create(0x1234567890, 100_000, Address.init(0x1234567890), 42, 99);
    const result = m.addTag(&nconf, &tag, callbacks);
    try testing.expectEqual(AddCredentialResult.accepted_new, result);

    // Tag should have been stored
    try testing.expectEqual(@as(usize, 1), m._remote_tags.count());
}

test "addRevocation blocks subsequent credential adds" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    nconf.timestamp = 1_000_000;
    nconf.credential_time_max_delta = 500_000;

    const no_verify = VerifyCallbacks{};

    // Revoke tag ID 42 with threshold 800_000
    const rev = Revocation.create(
        2, // revocation_id
        0x1234567890, // network ID
        42, // credential ID = tag id 42
        800_000, // threshold
        0, // flags
        Address.init(0xABCDEF0123), // target
        Credential.Type.tag,
    );
    _ = m.addRevocation(&rev, no_verify);

    // Try to add a tag with timestamp 700_000 (below revocation threshold)
    const tag = Tag.create(0x1234567890, 700_000, Address.init(0x1234567890), 42, 99);
    const result = m.addTag(&nconf, &tag, no_verify);
    try testing.expectEqual(AddCredentialResult.rejected, result);

    // A tag with timestamp 900_000 (above threshold) should succeed
    const newer_tag = Tag.create(0x1234567890, 900_000, Address.init(0x1234567890), 42, 100);
    const result2 = m.addTag(&nconf, &newer_tag, no_verify);
    try testing.expectEqual(AddCredentialResult.accepted_new, result2);
}

test "setLastPushedCredentials updates timestamp" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    m.setLastPushedCredentials(12345);
    try testing.expectEqual(@as(i64, 12345), m.lastPushedCredentials());
}

test "isAllowedOnNetwork for public network" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    var nconf = NetworkConfig.init();
    // Set network type to public (ZT_NETWORK_TYPE_PUBLIC = 1)
    nconf.net_type = 1;

    const id = Identity.init();
    try testing.expect(m.isAllowedOnNetwork(&nconf, &id));
}

test "hasCertificateOfOwnershipForMac with empty store" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const nconf = NetworkConfig.init();
    const mac_val = MAC.init(0x001122334455);
    try testing.expect(!m.hasCertificateOfOwnershipForMac(&nconf, mac_val));
}

test "addCom rejects when below revocation threshold" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const no_verify = VerifyCallbacks{};

    // Set a high revocation threshold
    m._com_revocation_threshold = 999_999;

    // A COM with timestamp 0 (default) should be rejected
    var com1 = CertificateOfMembership.init();
    const result = m.addCom(&com1, no_verify);
    try testing.expectEqual(AddCredentialResult.rejected, result);
}

test "trace callback receives rejection info" {
    var m = Membership.init(testing.allocator);
    defer m.deinit();

    const Context = struct {
        var called: bool = false;
        var last_reason: []const u8 = "";

        fn onReject(_: ?*anyopaque, _: Credential.Type, _: u32, reason: []const u8) void {
            called = true;
            last_reason = reason;
        }
    };

    Context.called = false;

    // Set high revocation threshold to force rejection
    m._com_revocation_threshold = 999_999;

    const callbacks = VerifyCallbacks{
        .trace_reject = Context.onReject,
    };

    var com1 = CertificateOfMembership.init();
    _ = m.addCom(&com1, callbacks);

    try testing.expect(Context.called);
    try testing.expectEqualStrings("revoked", Context.last_reason);
}
