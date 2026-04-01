/// Network configuration received from network controller nodes.
///
/// Converted from `node/NetworkConfig.hpp` and `node/NetworkConfig.cpp`.
/// This is a large value type (~466 KB) with fixed-capacity arrays for
/// specialists, routes, static IPs, rules, capabilities, tags, COOs,
/// DNS, and SSO fields. It supports serialization to/from a Dictionary
/// for wire transport.
///
/// Legacy `ZT_SUPPORT_OLD_STYLE_NETCONF` format (version < 6) is NOT
/// supported in this Zig conversion.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const Capability = @import("capability.zig").Capability;
const CertificateOfMembership = @import("certificate_of_membership.zig").CertificateOfMembership;
const CertificateOfOwnership = @import("certificate_of_ownership.zig").CertificateOfOwnership;
const Dictionary = @import("dictionary.zig").Dictionary;
const InetAddress = @import("inet_address.zig").InetAddress;
const Tag = @import("tag.zig").Tag;
const constants = @import("constants.zig");
const dns_mod = @import("dns.zig");
const cap_mod = @import("capability.zig");

const c_api = constants.c_api;

// ── C API types ───────────────────────────────────────────────────

const VirtualNetworkRule = c_api.ZT_VirtualNetworkRule;
const VirtualNetworkRoute = c_api.ZT_VirtualNetworkRoute;
const VirtualNetworkDNS = c_api.ZT_VirtualNetworkDNS;

/// C enum type — translated to c_uint by @cImport.
const VirtualNetworkType = c_api.enum_ZT_VirtualNetworkType;

/// Network type constants (c_int in C, cast to c_uint for VirtualNetworkType).
const NETWORK_TYPE_PRIVATE: VirtualNetworkType = @intCast(c_api.ZT_NETWORK_TYPE_PRIVATE);
const NETWORK_TYPE_PUBLIC: VirtualNetworkType = @intCast(c_api.ZT_NETWORK_TYPE_PUBLIC);

// ── C API constants ───────────────────────────────────────────────

pub const max_network_specialists: u32 = c_api.ZT_MAX_NETWORK_SPECIALISTS;
pub const max_network_routes: u32 = c_api.ZT_MAX_NETWORK_ROUTES;
pub const max_zt_assigned_addresses: u32 = c_api.ZT_MAX_ZT_ASSIGNED_ADDRESSES;
pub const max_network_rules: u32 = c_api.ZT_MAX_NETWORK_RULES;
pub const max_network_capabilities: u32 = c_api.ZT_MAX_NETWORK_CAPABILITIES;
pub const max_network_tags: u32 = c_api.ZT_MAX_NETWORK_TAGS;
pub const max_certificates_of_ownership: u32 = c_api.ZT_MAX_CERTIFICATES_OF_OWNERSHIP;
pub const max_network_short_name_length: u32 = c_api.ZT_MAX_NETWORK_SHORT_NAME_LENGTH;
pub const max_mtu: u32 = c_api.ZT_MAX_MTU;

// Default MTU (from Constants.hpp, not in ZeroTierOne.h).
pub const default_mtu: u32 = 2800;

// ── Credential time defaults (milliseconds) ──────────────────────

/// Default max delta for COMs/tags/capabilities (30 minutes).
pub const default_credential_time_dfl_max_delta: i64 = 1000 * 60 * 30;

/// Maximum allowed max delta (2 hours).
pub const default_credential_time_max_max_delta: i64 = 1000 * 60 * 60 * 2;

/// Minimum allowed max delta (5 minutes).
pub const default_credential_time_min_max_delta: i64 = 1000 * 60 * 5;

// ── Network flags ─────────────────────────────────────────────────

pub const flag_enable_broadcast: u64 = 0x0000000000000002;
pub const flag_enable_ipv6_ndp_emulation: u64 = 0x0000000000000004;
pub const flag_rules_result_of_unsupported_match: u64 = 0x0000000000000008;
pub const flag_disable_compression: u64 = 0x0000000000000010;

// ── Specialist type flags ─────────────────────────────────────────

pub const specialist_type_active_bridge: u64 = 0x0000020000000000;
pub const specialist_type_multicast_replicator: u64 = 0x0000080000000000;
pub const specialist_type_network_relay: u64 = 0x0000100000000000;

// ── Config version ────────────────────────────────────────────────

pub const config_version: u64 = 7;

// ── Trace level (minimal, for remoteTraceLevel field) ─────────────

pub const TraceLevel = enum(u64) {
    normal = 0,
    verbose = 10,
    rules = 15,
    debug = 20,
    insane = 30,
    _,
};

// ── Dictionary capacity ───────────────────────────────────────────

/// Dictionary capacity for a max-size network config.
/// Matches ZT_NETWORKCONFIG_DICT_CAPACITY in the C++ code.
pub const dict_capacity: u32 = 4096 +
    @sizeOf(c_api.ZT_VirtualNetworkConfig) +
    (@sizeOf(VirtualNetworkRule) * max_network_rules) +
    (@sizeOf(Capability) * max_network_capabilities) +
    (@sizeOf(Tag) * max_network_tags) +
    (@sizeOf(CertificateOfOwnership) * max_certificates_of_ownership);

/// Dictionary capacity for network config metadata.
pub const metadata_dict_capacity: u32 = 1024;

// ── Dictionary keys ───────────────────────────────────────────────

const dk = struct {
    const version = "v";
    const network_id = "nwid";
    const timestamp = "ts";
    const revision = "r";
    const issued_to = "id";
    const remote_trace_target = "tt";
    const remote_trace_level = "tl";
    const flags = "f";
    const multicast_limit = "ml";
    const net_type = "t";
    const name = "n";
    const mtu = "mtu";
    const credential_time_max_delta = "ctmd";
    const com = "C";
    const specialists = "S";
    const routes = "RT";
    const static_ips = "I";
    const rules = "R";
    const capabilities = "CAP";
    const tags = "TAG";
    const certificates_of_ownership = "COO";
    const dns_key = "DNS";
    const sso_enabled = "ssoe";
    const sso_version = "ssov";
    const authentication_url = "aurl";
    const authentication_expiry_time = "aexpt";
    const issuer_url = "iurl";
    const central_endpoint_url = "ssoce";
    const nonce = "sson";
    const state = "ssos";
    const client_id = "ssocid";
    const sso_provider = "ssop";
};

// ── Request metadata keys ─────────────────────────────────────────

pub const request_metadata = struct {
    pub const version = "v";
    pub const os_arch = "o";
    pub const protocol_version = "pv";
    pub const node_vendor = "vend";
    pub const node_major_version = "majv";
    pub const node_minor_version = "minv";
    pub const node_revision = "revv";
    pub const rules_engine_rev = "revr";
    pub const max_network_rules_key = "mr";
    pub const max_network_capabilities_key = "mc";
    pub const max_capability_rules = "mcr";
    pub const max_network_tags_key = "mt";
    pub const auth = "a";
    pub const flags_key = "f";
};

// ── Helper: sockaddr_storage ──────────────────────────────────────

/// C API sockaddr_storage type (from @cImport, layout-identical to std.c.sockaddr.storage).
const C_SockaddrStorage = c_api.struct_sockaddr_storage;

const SS_SIZE = @sizeOf(C_SockaddrStorage);

// ── NetworkConfig ─────────────────────────────────────────────────

/// Network configuration received from network controller nodes.
///
/// This is a value type with fixed-capacity arrays. It is designed to be
/// memcpy-able and safe to modify without locks (in a crash-safety sense).
pub const NetworkConfig = struct {
    /// Network ID that this configuration applies to.
    network_id: u64,

    /// Controller-side time of config generation/issue.
    timestamp: i64,

    /// Max difference between timestamp and credential timestamps.
    credential_time_max_delta: i64,

    /// Controller-side revision counter.
    revision: u64,

    /// Address of device to which this config is issued.
    issued_to: Address,

    /// Remote trace target address (zero if none).
    remote_trace_target: Address,

    /// Flags (64-bit).
    flags: u64,

    /// Remote trace level.
    remote_trace_level: TraceLevel,

    /// Network MTU.
    mtu: u32,

    /// Maximum number of recipients per multicast.
    multicast_limit: u32,

    /// Number of specialists.
    specialist_count: u32,

    /// Number of routes.
    route_count: u32,

    /// Number of ZT-managed static IP assignments.
    static_ip_count: u32,

    /// Number of rule table entries.
    rule_count: u32,

    /// Number of capabilities.
    capability_count: u32,

    /// Number of tags.
    tag_count: u32,

    /// Number of certificates of ownership.
    certificate_of_ownership_count: u32,

    /// Specialist devices (lower 40 bits = address, upper 24 bits = flags).
    specialists: [max_network_specialists]u64,

    /// Statically defined "pushed" routes.
    routes: [max_network_routes]VirtualNetworkRoute,

    /// Static IP assignments.
    static_ips: [max_zt_assigned_addresses]InetAddress,

    /// Base network rules.
    rules_arr: [max_network_rules]VirtualNetworkRule,

    /// Capabilities for this node, in ascending order of capability ID.
    capabilities: [max_network_capabilities]Capability,

    /// Tags for this node, in ascending order of tag ID.
    tags: [max_network_tags]Tag,

    /// Certificates of ownership for this network member.
    certificates_of_ownership: [max_certificates_of_ownership]CertificateOfOwnership,

    /// Network type (public or private).
    net_type: VirtualNetworkType,

    /// Network short name or empty string.
    name: [max_network_short_name_length + 1]u8,

    /// Certificate of membership (for private networks).
    com: CertificateOfMembership,

    /// Number of ZT-pushed DNS configurations.
    dns_count: u32,

    /// ZT pushed DNS configuration.
    dns_conf: VirtualNetworkDNS,

    /// SSO enabled flag.
    sso_enabled: bool,

    /// SSO version.
    sso_version: u64,

    /// Authentication URL.
    authentication_url: [2048]u8,

    /// Time current authentication expires (0 = disabled, SSO v0 only).
    authentication_expiry_time: u64,

    /// OIDC issuer URL.
    issuer_url: [2048]u8,

    /// Central base URL.
    central_auth_url: [2048]u8,

    /// SSO nonce.
    sso_nonce: [128]u8,

    /// SSO state.
    sso_state: [256]u8,

    /// OIDC client ID.
    sso_client_id: [256]u8,

    /// SSO provider name.
    sso_provider: [64]u8,

    // ── Constructor ───────────────────────────────────────

    /// Create a zero-initialized NetworkConfig (matches C++ constructor).
    pub fn init() NetworkConfig {
        var nc: NetworkConfig = undefined;

        nc.network_id = 0;
        nc.timestamp = 0;
        nc.credential_time_max_delta = 0;
        nc.revision = 0;
        nc.issued_to = Address.init(0);
        nc.remote_trace_target = Address.init(0);
        nc.flags = 0;
        nc.remote_trace_level = .normal;
        nc.mtu = 0;
        nc.multicast_limit = 0;
        nc.specialist_count = 0;
        nc.route_count = 0;
        nc.static_ip_count = 0;
        nc.rule_count = 0;
        nc.capability_count = 0;
        nc.tag_count = 0;
        nc.certificate_of_ownership_count = 0;
        nc.net_type = NETWORK_TYPE_PRIVATE;

        @memset(&nc.specialists, 0);
        @memset(mem.asBytes(&nc.routes), 0);
        nc.static_ips = [_]InetAddress{InetAddress.zero()} ** max_zt_assigned_addresses;
        @memset(mem.asBytes(&nc.rules_arr), 0);
        nc.capabilities = [_]Capability{Capability.init()} ** max_network_capabilities;
        nc.tags = [_]Tag{Tag.init()} ** max_network_tags;
        nc.certificates_of_ownership = [_]CertificateOfOwnership{CertificateOfOwnership.init()} ** max_certificates_of_ownership;
        nc.name = [_]u8{0} ** (max_network_short_name_length + 1);
        nc.com = CertificateOfMembership.init();
        nc.dns_count = 0;
        @memset(mem.asBytes(&nc.dns_conf), 0);
        nc.sso_enabled = false;
        nc.sso_version = 0;
        @memset(&nc.authentication_url, 0);
        nc.authentication_expiry_time = 0;
        @memset(&nc.issuer_url, 0);
        @memset(&nc.central_auth_url, 0);
        @memset(&nc.sso_nonce, 0);
        @memset(&nc.sso_state, 0);
        @memset(&nc.sso_client_id, 0);

        // Default SSO provider = "default"
        @memset(&nc.sso_provider, 0);
        const default_provider = "default";
        @memcpy(nc.sso_provider[0..default_provider.len], default_provider);

        return nc;
    }

    // ── Accessors ─────────────────────────────────────────

    /// True if broadcast (ff:ff:ff:ff:ff:ff) should work on this network.
    pub fn enableBroadcast(self: *const NetworkConfig) bool {
        return (self.flags & flag_enable_broadcast) != 0;
    }

    /// True if IPv6 NDP emulation should be enabled.
    pub fn ndpEmulation(self: *const NetworkConfig) bool {
        return (self.flags & flag_enable_ipv6_ndp_emulation) != 0;
    }

    /// True if network type is public (no access control).
    pub fn isPublic(self: *const NetworkConfig) bool {
        return self.net_type == NETWORK_TYPE_PUBLIC;
    }

    /// True if network type is private (certificate access control).
    pub fn isPrivate(self: *const NetworkConfig) bool {
        return self.net_type == NETWORK_TYPE_PRIVATE;
    }

    /// True if this config has a valid network ID.
    pub fn isSet(self: *const NetworkConfig) bool {
        return self.network_id != 0;
    }

    // ── Specialist queries ────────────────────────────────

    /// Check if an address is an active bridge on this network.
    pub fn isActiveBridge(self: *const NetworkConfig, addr: Address) bool {
        const aint = addr.toInt();
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & specialist_type_active_bridge) != 0 and
                (self.specialists[i] & 0xffffffffff) == aint)
            {
                return true;
            }
        }
        return false;
    }

    /// Check if an address is a multicast replicator.
    pub fn isMulticastReplicator(self: *const NetworkConfig, addr: Address) bool {
        const aint = addr.toInt();
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & specialist_type_multicast_replicator) != 0 and
                (self.specialists[i] & 0xffffffffff) == aint)
            {
                return true;
            }
        }
        return false;
    }

    /// Check if a peer is permitted to bridge.
    pub fn permitsBridging(self: *const NetworkConfig, from_peer: Address) bool {
        return self.isActiveBridge(from_peer);
    }

    /// Count active bridges, writing their addresses into `out`.
    /// Returns the number written.
    pub fn activeBridges(self: *const NetworkConfig, out: []Address) u32 {
        var count: u32 = 0;
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & specialist_type_active_bridge) != 0) {
                if (count < out.len) {
                    out[count] = Address.init(self.specialists[i]);
                }
                count += 1;
            }
        }
        return count;
    }

    /// Count multicast replicators, writing their addresses into `out`.
    /// Returns the number written.
    pub fn multicastReplicators(self: *const NetworkConfig, out: []Address) u32 {
        var count: u32 = 0;
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & specialist_type_multicast_replicator) != 0) {
                if (count < out.len) {
                    out[count] = Address.init(self.specialists[i]);
                }
                count += 1;
            }
        }
        return count;
    }

    /// Count always-contact addresses (relays + multicast replicators).
    pub fn alwaysContactAddresses(self: *const NetworkConfig, out: []Address) u32 {
        const mask = specialist_type_network_relay | specialist_type_multicast_replicator;
        var count: u32 = 0;
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & mask) != 0) {
                if (count < out.len) {
                    out[count] = Address.init(self.specialists[i]);
                }
                count += 1;
            }
        }
        return count;
    }

    /// Add a specialist or OR flags if already present.
    /// Returns true if successfully added/masked, false if array is full.
    pub fn addSpecialist(self: *NetworkConfig, addr: Address, f: u64) bool {
        const aint = addr.toInt();
        for (0..self.specialist_count) |i| {
            if ((self.specialists[i] & 0xffffffffff) == aint) {
                self.specialists[i] |= f;
                return true;
            }
        }
        if (self.specialist_count < max_network_specialists) {
            self.specialists[self.specialist_count] = f | aint;
            self.specialist_count += 1;
            return true;
        }
        return false;
    }

    // ── Credential lookups ────────────────────────────────

    /// Find a capability by ID, or return null.
    pub fn capability(self: *const NetworkConfig, cap_id: u32) ?*const Capability {
        for (0..self.capability_count) |i| {
            if (self.capabilities[i].capId() == cap_id) {
                return &self.capabilities[i];
            }
        }
        return null;
    }

    /// Find a tag by ID, or return null.
    pub fn tag(self: *const NetworkConfig, tag_id: u32) ?*const Tag {
        for (0..self.tag_count) |i| {
            if (self.tags[i].id() == tag_id) {
                return &self.tags[i];
            }
        }
        return null;
    }

    // ── Dictionary serialization ──────────────────────────

    /// Serialize this network config to a Dictionary for wire transport.
    ///
    /// Returns error on dictionary overflow.
    pub fn toDictionary(self: *const NetworkConfig, dict: *Dictionary(dict_capacity)) !void {
        var tmp = Buffer(dict_capacity){};

        dict.clear();

        // Human-readable fields first
        try dict.addU64(dk.version, config_version);
        try dict.addU64(dk.network_id, self.network_id);
        try dict.addI64(dk.timestamp, self.timestamp);
        try dict.addI64(dk.credential_time_max_delta, self.credential_time_max_delta);
        try dict.addU64(dk.revision, self.revision);
        try dict.addAddress(dk.issued_to, self.issued_to);
        try dict.addAddress(dk.remote_trace_target, self.remote_trace_target);
        try dict.addU64(dk.remote_trace_level, @intFromEnum(self.remote_trace_level));
        try dict.addU64(dk.flags, self.flags);
        try dict.addU64(dk.multicast_limit, @as(u64, self.multicast_limit));
        try dict.addU64(dk.net_type, @as(u64, self.net_type));

        // Name as a null-terminated string
        const name_slice = mem.sliceTo(&self.name, 0);
        try dict.add(dk.name, name_slice);

        try dict.addU64(dk.mtu, @as(u64, self.mtu));

        // Binary blobs

        // COM
        if (self.com.isSet()) {
            tmp = Buffer(dict_capacity){};
            self.com.serialize(dict_capacity, &tmp) catch return error.Overflow;
            try dict.add(dk.com, tmp.data()[0..tmp.size()]);
        }

        // Capabilities
        if (self.capability_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.capability_count) |i| {
                self.capabilities[i].serialize(dict_capacity, &tmp) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.capabilities, tmp.data()[0..tmp.size()]);
            }
        }

        // Tags
        if (self.tag_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.tag_count) |i| {
                self.tags[i].serialize(dict_capacity, &tmp) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.tags, tmp.data()[0..tmp.size()]);
            }
        }

        // Certificates of ownership
        if (self.certificate_of_ownership_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.certificate_of_ownership_count) |i| {
                self.certificates_of_ownership[i].serialize(dict_capacity, &tmp) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.certificates_of_ownership, tmp.data()[0..tmp.size()]);
            }
        }

        // Specialists (binary array of uint64_t)
        if (self.specialist_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.specialist_count) |i| {
                tmp.appendInt(u64, self.specialists[i]) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.specialists, tmp.data()[0..tmp.size()]);
            }
        }

        // Routes
        if (self.route_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.route_count) |i| {
                // Serialize target and via as InetAddress
                var target_ia = inetAddressFromSockaddrStorage(&self.routes[i].target);
                var via_ia = inetAddressFromSockaddrStorage(&self.routes[i].via);
                target_ia.serialize(dict_capacity, &tmp) catch return error.Overflow;
                via_ia.serialize(dict_capacity, &tmp) catch return error.Overflow;
                tmp.appendInt(u16, self.routes[i].flags) catch return error.Overflow;
                tmp.appendInt(u16, self.routes[i].metric) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.routes, tmp.data()[0..tmp.size()]);
            }
        }

        // Static IPs
        if (self.static_ip_count > 0) {
            tmp = Buffer(dict_capacity){};
            for (0..self.static_ip_count) |i| {
                self.static_ips[i].serialize(dict_capacity, &tmp) catch return error.Overflow;
            }
            if (tmp.size() > 0) {
                try dict.add(dk.static_ips, tmp.data()[0..tmp.size()]);
            }
        }

        // Rules
        if (self.rule_count > 0) {
            tmp = Buffer(dict_capacity){};
            cap_mod.serializeRules(dict_capacity, &tmp, self.rules_arr[0..self.rule_count]) catch return error.Overflow;
            if (tmp.size() > 0) {
                try dict.add(dk.rules, tmp.data()[0..tmp.size()]);
            }
        }

        // DNS
        {
            tmp = Buffer(dict_capacity){};
            dns_mod.serializeDNS(dict_capacity, &tmp, &self.dns_conf) catch return error.Overflow;
            if (tmp.size() > 0) {
                try dict.add(dk.dns_key, tmp.data()[0..tmp.size()]);
            }
        }

        // SSO fields
        if (self.sso_version == 0) {
            try dict.addU64(dk.sso_version, self.sso_version);
            try dict.addBool(dk.sso_enabled, self.sso_enabled);
            if (self.sso_enabled) {
                if (self.authentication_url[0] != 0) {
                    const url_slice = mem.sliceTo(&self.authentication_url, 0);
                    try dict.add(dk.authentication_url, url_slice);
                }
                try dict.addU64(dk.authentication_expiry_time, self.authentication_expiry_time);
            }
        } else if (self.sso_version == 1) {
            try dict.addU64(dk.sso_version, self.sso_version);
            try dict.addBool(dk.sso_enabled, self.sso_enabled);
            try dict.add(dk.issuer_url, mem.sliceTo(&self.issuer_url, 0));
            try dict.add(dk.central_endpoint_url, mem.sliceTo(&self.central_auth_url, 0));
            try dict.add(dk.nonce, mem.sliceTo(&self.sso_nonce, 0));
            try dict.add(dk.state, mem.sliceTo(&self.sso_state, 0));
            try dict.add(dk.client_id, mem.sliceTo(&self.sso_client_id, 0));
            try dict.add(dk.sso_provider, mem.sliceTo(&self.sso_provider, 0));
        }
    }

    /// Deserialize this network config from a Dictionary.
    ///
    /// Returns true if the dictionary was valid and config was loaded.
    pub fn fromDictionary(self: *NetworkConfig, dict: *const Dictionary(dict_capacity)) bool {
        var tmp_buf: [dict_capacity]u8 = undefined;

        // Reset to defaults
        self.* = NetworkConfig.init();

        // Fields that are always present
        self.network_id = dict.getUI(dk.network_id, 0);
        if (self.network_id == 0) return false;

        self.timestamp = dict.getI(dk.timestamp, 0);
        self.credential_time_max_delta = dict.getI(dk.credential_time_max_delta, 0);
        self.revision = dict.getUI(dk.revision, 0);
        self.issued_to = Address.init(dict.getUI(dk.issued_to, 0));
        if (!self.issued_to.isSet()) return false;

        self.remote_trace_target = Address.init(dict.getUI(dk.remote_trace_target, 0));
        self.remote_trace_level = @enumFromInt(dict.getUI(dk.remote_trace_level, 0));
        self.multicast_limit = @intCast(@min(dict.getUI(dk.multicast_limit, 0), std.math.maxInt(u32)));

        // Name
        if (dict.get(dk.name, &self.name)) |_| {
            self.name[max_network_short_name_length] = 0;
        }

        // MTU
        const mtu_val = dict.getUI(dk.mtu, default_mtu);
        if (mtu_val < 1280) {
            self.mtu = 1280;
        } else if (mtu_val > max_mtu) {
            self.mtu = max_mtu;
        } else {
            self.mtu = @intCast(mtu_val);
        }

        // Check version
        if (dict.getUI(dk.version, 0) < 6) {
            // Legacy format not supported
            return false;
        }

        // New-style fields
        self.flags = dict.getUI(dk.flags, 0);
        self.net_type = @intCast(@min(dict.getUI(dk.net_type, @as(u64, NETWORK_TYPE_PRIVATE)), std.math.maxInt(VirtualNetworkType)));

        // COM
        if (dict.get(dk.com, &tmp_buf)) |com_data| {
            if (com_data.len > 0) {
                var com_buf = Buffer(dict_capacity){};
                com_buf.appendBytes(com_data) catch return false;
                const result = CertificateOfMembership.deserialize(dict_capacity, &com_buf, 0) catch return false;
                self.com = result.com;
            }
        }

        // Capabilities
        if (dict.get(dk.capabilities, &tmp_buf)) |cap_data| {
            if (cap_data.len > 0) {
                var cap_buf = Buffer(dict_capacity){};
                cap_buf.appendBytes(cap_data) catch return false;
                var p: u32 = 0;
                while (p < cap_buf.size() and self.capability_count < max_network_capabilities) {
                    const result = Capability.deserialize(dict_capacity, &cap_buf, p) catch break;
                    if (result.bytes_read == 0) break; // §4.7: prevent infinite loop on zero-length record
                    self.capabilities[self.capability_count] = result.capability;
                    self.capability_count += 1;
                    p += result.bytes_read;
                }
                // Sort by capability ID
                sortCapabilities(self.capabilities[0..self.capability_count]);
            }
        }

        // Tags
        if (dict.get(dk.tags, &tmp_buf)) |tag_data| {
            if (tag_data.len > 0) {
                var tag_buf = Buffer(dict_capacity){};
                tag_buf.appendBytes(tag_data) catch return false;
                var p: u32 = 0;
                while (p < tag_buf.size() and self.tag_count < max_network_tags) {
                    const result = Tag.deserialize(dict_capacity, &tag_buf, p) catch break;
                    if (result.bytes_read == 0) break; // §4.7: prevent infinite loop on zero-length record
                    self.tags[self.tag_count] = result.tag;
                    self.tag_count += 1;
                    p += result.bytes_read;
                }
                // Sort by tag ID
                sortTags(self.tags[0..self.tag_count]);
            }
        }

        // Certificates of Ownership
        if (dict.get(dk.certificates_of_ownership, &tmp_buf)) |coo_data| {
            if (coo_data.len > 0) {
                var coo_buf = Buffer(dict_capacity){};
                coo_buf.appendBytes(coo_data) catch return false;
                var p: u32 = 0;
                while (p < coo_buf.size()) {
                    const result = CertificateOfOwnership.deserialize(dict_capacity, &coo_buf, p) catch break;
                    if (result.bytes_read == 0) break; // §4.7: prevent infinite loop on zero-length record
                    if (self.certificate_of_ownership_count < max_certificates_of_ownership) {
                        self.certificates_of_ownership[self.certificate_of_ownership_count] = result.coo;
                        self.certificate_of_ownership_count += 1;
                    }
                    p += result.bytes_read;
                }
            }
        }

        // Specialists (binary array of uint64_t)
        if (dict.get(dk.specialists, &tmp_buf)) |spec_data| {
            if (spec_data.len > 0) {
                var spec_buf = Buffer(dict_capacity){};
                spec_buf.appendBytes(spec_data) catch return false;
                var p: u32 = 0;
                while (p + 8 <= spec_buf.size() and self.specialist_count < max_network_specialists) {
                    self.specialists[self.specialist_count] = spec_buf.at(u64, p) catch break;
                    self.specialist_count += 1;
                    p += 8;
                }
            }
        }

        // Routes
        if (dict.get(dk.routes, &tmp_buf)) |route_data| {
            if (route_data.len > 0) {
                var route_buf = Buffer(dict_capacity){};
                route_buf.appendBytes(route_data) catch return false;
                var p: u32 = 0;
                while (p < route_buf.size() and self.route_count < max_network_routes) {
                    var target_ia = InetAddress.zero();
                    const target_consumed = target_ia.deserialize(dict_capacity, &route_buf, p) catch break;
                    p += target_consumed;

                    var via_ia = InetAddress.zero();
                    const via_consumed = via_ia.deserialize(dict_capacity, &route_buf, p) catch break;
                    p += via_consumed;

                    const route_flags = route_buf.at(u16, p) catch break;
                    p += 2;
                    const route_metric = route_buf.at(u16, p) catch break;
                    p += 2;

                    sockaddrStorageFromInetAddress(&self.routes[self.route_count].target, &target_ia);
                    sockaddrStorageFromInetAddress(&self.routes[self.route_count].via, &via_ia);
                    self.routes[self.route_count].flags = route_flags;
                    self.routes[self.route_count].metric = route_metric;
                    self.route_count += 1;
                }
            }
        }

        // Static IPs
        if (dict.get(dk.static_ips, &tmp_buf)) |ip_data| {
            if (ip_data.len > 0) {
                var ip_buf = Buffer(dict_capacity){};
                ip_buf.appendBytes(ip_data) catch return false;
                var p: u32 = 0;
                while (p < ip_buf.size() and self.static_ip_count < max_zt_assigned_addresses) {
                    const consumed = self.static_ips[self.static_ip_count].deserialize(dict_capacity, &ip_buf, p) catch break;
                    self.static_ip_count += 1;
                    p += consumed;
                }
            }
        }

        // Rules
        if (dict.get(dk.rules, &tmp_buf)) |rule_data| {
            if (rule_data.len > 0) {
                var rule_buf = Buffer(dict_capacity){};
                rule_buf.appendBytes(rule_data) catch return false;
                self.rule_count = 0;
                var rc: u32 = 0;
                _ = cap_mod.deserializeRules(dict_capacity, &rule_buf, 0, &self.rules_arr, &rc, max_network_rules) catch return false;
                self.rule_count = rc;
            }
        }

        // DNS
        if (dict.get(dk.dns_key, &tmp_buf)) |dns_data| {
            if (dns_data.len > 0) {
                var dns_buf = Buffer(dict_capacity){};
                dns_buf.appendBytes(dns_data) catch return false;
                _ = dns_mod.deserializeDNS(dict_capacity, &dns_buf, 0, &self.dns_conf) catch {
                    // DNS config malformed — continue with default (zeros)
                };
            }
        }

        // SSO
        self.sso_version = dict.getUI(dk.sso_version, 0);
        self.sso_enabled = dict.getBool(dk.sso_enabled, false);

        if (self.sso_version == 0) {
            if (self.sso_enabled) {
                if (dict.get(dk.authentication_url, &self.authentication_url)) |_| {
                    self.authentication_url[2047] = 0;
                } else {
                    self.authentication_url[0] = 0;
                }
                self.authentication_expiry_time = dict.getUI(dk.authentication_expiry_time, 0);
            } else {
                self.authentication_url[0] = 0;
                self.authentication_expiry_time = 0;
            }
        } else if (self.sso_version == 1) {
            if (self.sso_enabled) {
                if (dict.get(dk.authentication_url, &self.authentication_url)) |_| {
                    self.authentication_url[2047] = 0;
                }
                if (dict.get(dk.issuer_url, &self.issuer_url)) |_| {
                    self.issuer_url[2047] = 0;
                }
                if (dict.get(dk.central_endpoint_url, &self.central_auth_url)) |_| {
                    self.central_auth_url[2047] = 0;
                }
                if (dict.get(dk.nonce, &self.sso_nonce)) |_| {
                    self.sso_nonce[127] = 0;
                }
                if (dict.get(dk.state, &self.sso_state)) |_| {
                    self.sso_state[255] = 0;
                }
                if (dict.get(dk.client_id, &self.sso_client_id)) |_| {
                    self.sso_client_id[255] = 0;
                }
                if (dict.get(dk.sso_provider, &self.sso_provider)) |val| {
                    _ = val;
                    self.sso_provider[63] = 0;
                } else {
                    const default_provider = "default";
                    @memset(&self.sso_provider, 0);
                    @memcpy(self.sso_provider[0..default_provider.len], default_provider);
                }
            } else {
                self.authentication_url[0] = 0;
                self.authentication_expiry_time = 0;
                self.central_auth_url[0] = 0;
                self.sso_nonce[0] = 0;
                self.sso_state[0] = 0;
                self.sso_client_id[0] = 0;
                self.issuer_url[0] = 0;
                self.sso_provider[0] = 0;
            }
        }

        return true;
    }
};

// ── Helper functions ──────────────────────────────────────────────

/// Convert a C API sockaddr_storage to an InetAddress (byte-level copy).
fn inetAddressFromSockaddrStorage(ss: *const C_SockaddrStorage) InetAddress {
    var ia = InetAddress.zero();
    const src: *const [SS_SIZE]u8 = @ptrCast(ss);
    const dst: *[SS_SIZE]u8 = @ptrCast(&ia.storage);
    @memcpy(dst, src);
    return ia;
}

/// Copy an InetAddress into a C API sockaddr_storage (byte-level copy).
fn sockaddrStorageFromInetAddress(ss: *C_SockaddrStorage, ia: *const InetAddress) void {
    const src: *const [SS_SIZE]u8 = @ptrCast(&ia.storage);
    const dst: *[SS_SIZE]u8 = @ptrCast(ss);
    @memcpy(dst, src);
}

/// Sort a slice of Capabilities in ascending order by ID.
fn sortCapabilities(caps: []Capability) void {
    mem.sort(Capability, caps, {}, Capability.lessThan);
}

/// Sort a slice of Tags in ascending order by ID.
fn sortTags(tag_slice: []Tag) void {
    mem.sort(Tag, tag_slice, {}, Tag.lessThan);
}

// ── Tests ─────────────────────────────────────────────────────────

test "NetworkConfig: init creates zero state" {
    const nc = NetworkConfig.init();
    try testing.expectEqual(@as(u64, 0), nc.network_id);
    try testing.expectEqual(@as(i64, 0), nc.timestamp);
    try testing.expectEqual(@as(i64, 0), nc.credential_time_max_delta);
    try testing.expectEqual(@as(u64, 0), nc.revision);
    try testing.expect(!nc.issued_to.isSet());
    try testing.expect(!nc.remote_trace_target.isSet());
    try testing.expectEqual(@as(u64, 0), nc.flags);
    try testing.expectEqual(TraceLevel.normal, nc.remote_trace_level);
    try testing.expectEqual(@as(u32, 0), nc.mtu);
    try testing.expectEqual(@as(u32, 0), nc.multicast_limit);
    try testing.expectEqual(@as(u32, 0), nc.specialist_count);
    try testing.expectEqual(@as(u32, 0), nc.route_count);
    try testing.expectEqual(@as(u32, 0), nc.static_ip_count);
    try testing.expectEqual(@as(u32, 0), nc.rule_count);
    try testing.expectEqual(@as(u32, 0), nc.capability_count);
    try testing.expectEqual(@as(u32, 0), nc.tag_count);
    try testing.expectEqual(@as(u32, 0), nc.certificate_of_ownership_count);
    try testing.expect(!nc.isSet());
    try testing.expect(nc.isPrivate());
    try testing.expect(!nc.isPublic());
    try testing.expect(!nc.sso_enabled);
    try testing.expectEqual(@as(u64, 0), nc.sso_version);

    // Default SSO provider
    const provider = mem.sliceTo(&nc.sso_provider, 0);
    try testing.expectEqualStrings("default", provider);
}

test "NetworkConfig: flag accessors" {
    var nc = NetworkConfig.init();
    try testing.expect(!nc.enableBroadcast());
    try testing.expect(!nc.ndpEmulation());

    nc.flags = flag_enable_broadcast;
    try testing.expect(nc.enableBroadcast());
    try testing.expect(!nc.ndpEmulation());

    nc.flags = flag_enable_ipv6_ndp_emulation;
    try testing.expect(!nc.enableBroadcast());
    try testing.expect(nc.ndpEmulation());

    nc.flags = flag_enable_broadcast | flag_enable_ipv6_ndp_emulation;
    try testing.expect(nc.enableBroadcast());
    try testing.expect(nc.ndpEmulation());
}

test "NetworkConfig: addSpecialist and queries" {
    var nc = NetworkConfig.init();

    const addr1 = Address.init(0x1234567890);
    const addr2 = Address.init(0xaabbccddee);

    try testing.expect(nc.addSpecialist(addr1, specialist_type_active_bridge));
    try testing.expectEqual(@as(u32, 1), nc.specialist_count);
    try testing.expect(nc.isActiveBridge(addr1));
    try testing.expect(!nc.isActiveBridge(addr2));

    // Add same address with different flag — should OR
    try testing.expect(nc.addSpecialist(addr1, specialist_type_multicast_replicator));
    try testing.expectEqual(@as(u32, 1), nc.specialist_count);
    try testing.expect(nc.isActiveBridge(addr1));
    try testing.expect(nc.isMulticastReplicator(addr1));

    // Add different address
    try testing.expect(nc.addSpecialist(addr2, specialist_type_network_relay));
    try testing.expectEqual(@as(u32, 2), nc.specialist_count);

    // alwaysContactAddresses should include relay + replicator
    var out: [4]Address = undefined;
    const count = nc.alwaysContactAddresses(&out);
    try testing.expectEqual(@as(u32, 2), count);
}

test "NetworkConfig: toDictionary/fromDictionary round-trip minimal" {
    var nc = NetworkConfig.init();
    nc.network_id = 0x1234567890abcdef;
    nc.timestamp = 1000;
    nc.revision = 42;
    nc.issued_to = Address.init(0xaabbccddee);
    nc.mtu = 2800;
    nc.flags = flag_enable_broadcast;
    nc.net_type = NETWORK_TYPE_PRIVATE;

    const name_str = "test-network";
    @memcpy(nc.name[0..name_str.len], name_str);

    var dict = Dictionary(dict_capacity).init();
    nc.toDictionary(&dict) catch {
        try testing.expect(false);
        return;
    };

    var nc2 = NetworkConfig.init();
    try testing.expect(nc2.fromDictionary(&dict));

    try testing.expectEqual(nc.network_id, nc2.network_id);
    try testing.expectEqual(nc.timestamp, nc2.timestamp);
    try testing.expectEqual(nc.revision, nc2.revision);
    try testing.expectEqual(nc.issued_to.toInt(), nc2.issued_to.toInt());
    try testing.expectEqual(nc.mtu, nc2.mtu);
    try testing.expectEqual(nc.flags, nc2.flags);
    try testing.expectEqual(nc.net_type, nc2.net_type);

    const n1 = mem.sliceTo(&nc.name, 0);
    const n2 = mem.sliceTo(&nc2.name, 0);
    try testing.expectEqualStrings(n1, n2);
}

test "NetworkConfig: fromDictionary rejects missing network_id" {
    const dict = Dictionary(dict_capacity).init();
    var nc = NetworkConfig.init();
    try testing.expect(!nc.fromDictionary(&dict));
}

test "NetworkConfig: fromDictionary rejects missing issued_to" {
    var dict = Dictionary(dict_capacity).init();
    dict.addU64(dk.network_id, 1) catch return;
    dict.addU64(dk.version, 7) catch return;

    var nc = NetworkConfig.init();
    try testing.expect(!nc.fromDictionary(&dict));
}

test "NetworkConfig: MTU clamping" {
    var dict = Dictionary(dict_capacity).init();
    dict.addU64(dk.network_id, 1) catch return;
    dict.addU64(dk.version, 7) catch return;
    dict.addAddress(dk.issued_to, Address.init(0x1234567890)) catch return;
    dict.addU64(dk.mtu, 500) catch return; // too low

    var nc = NetworkConfig.init();
    try testing.expect(nc.fromDictionary(&dict));
    try testing.expectEqual(@as(u32, 1280), nc.mtu);
}

test "NetworkConfig: constants match C++ defines" {
    try testing.expectEqual(@as(u32, 256), max_network_specialists);
    try testing.expectEqual(@as(u32, 128), max_network_routes);
    try testing.expectEqual(@as(u32, 32), max_zt_assigned_addresses);
    try testing.expectEqual(@as(u32, 1024), max_network_rules);
    try testing.expectEqual(@as(u32, 128), max_network_capabilities);
    try testing.expectEqual(@as(u32, 128), max_network_tags);
    try testing.expectEqual(@as(u32, 4), max_certificates_of_ownership);
    try testing.expectEqual(@as(u32, 127), max_network_short_name_length);
    try testing.expectEqual(@as(u64, 0x0000000000000002), flag_enable_broadcast);
    try testing.expectEqual(@as(u64, 0x0000020000000000), specialist_type_active_bridge);
    try testing.expectEqual(@as(u64, 7), config_version);
    try testing.expectEqual(@as(i64, 1000 * 60 * 30), default_credential_time_dfl_max_delta);
}

test "NetworkConfig: credential lookups" {
    var nc = NetworkConfig.init();

    // No capabilities or tags initially
    try testing.expect(nc.capability(0) == null);
    try testing.expect(nc.tag(0) == null);
}

test "NetworkConfig: toDictionary/fromDictionary with static IPs" {
    var nc = NetworkConfig.init();
    nc.network_id = 0x1;
    nc.issued_to = Address.init(0x1234567890);
    nc.mtu = 2800;

    // Add a static IP
    nc.static_ips[0] = InetAddress.initV4(.{ 10, 0, 0, 1 }, 24);
    nc.static_ip_count = 1;

    var dict = Dictionary(dict_capacity).init();
    nc.toDictionary(&dict) catch return;

    var nc2 = NetworkConfig.init();
    try testing.expect(nc2.fromDictionary(&dict));
    try testing.expectEqual(@as(u32, 1), nc2.static_ip_count);
    try testing.expect(nc2.static_ips[0].ipsEqual(&nc.static_ips[0]));
}

test "NetworkConfig: toDictionary/fromDictionary with specialists" {
    var nc = NetworkConfig.init();
    nc.network_id = 0x1;
    nc.issued_to = Address.init(0x1234567890);
    nc.mtu = 2800;

    const addr = Address.init(0xaabbccddee);
    _ = nc.addSpecialist(addr, specialist_type_active_bridge);

    var dict = Dictionary(dict_capacity).init();
    nc.toDictionary(&dict) catch return;

    var nc2 = NetworkConfig.init();
    try testing.expect(nc2.fromDictionary(&dict));
    try testing.expectEqual(@as(u32, 1), nc2.specialist_count);
    try testing.expect(nc2.isActiveBridge(addr));
}

test "NetworkConfig: SSO v0 round-trip" {
    var nc = NetworkConfig.init();
    nc.network_id = 0x1;
    nc.issued_to = Address.init(0x1234567890);
    nc.mtu = 2800;
    nc.sso_version = 0;
    nc.sso_enabled = true;

    const url = "https://auth.example.com/login";
    @memcpy(nc.authentication_url[0..url.len], url);
    nc.authentication_expiry_time = 999;

    var dict = Dictionary(dict_capacity).init();
    nc.toDictionary(&dict) catch return;

    var nc2 = NetworkConfig.init();
    try testing.expect(nc2.fromDictionary(&dict));
    try testing.expect(nc2.sso_enabled);
    try testing.expectEqual(@as(u64, 0), nc2.sso_version);
    try testing.expectEqual(@as(u64, 999), nc2.authentication_expiry_time);

    const restored_url = mem.sliceTo(&nc2.authentication_url, 0);
    try testing.expectEqualStrings(url, restored_url);
}

test "NetworkConfig: SSO v1 round-trip" {
    var nc = NetworkConfig.init();
    nc.network_id = 0x1;
    nc.issued_to = Address.init(0x1234567890);
    nc.mtu = 2800;
    nc.sso_version = 1;
    nc.sso_enabled = true;

    const issuer = "https://issuer.example.com";
    @memcpy(nc.issuer_url[0..issuer.len], issuer);

    const central = "https://central.example.com";
    @memcpy(nc.central_auth_url[0..central.len], central);

    const nonce_str = "abc123";
    @memcpy(nc.sso_nonce[0..nonce_str.len], nonce_str);

    const state_str = "state456";
    @memcpy(nc.sso_state[0..state_str.len], state_str);

    const client = "client-id-789";
    @memcpy(nc.sso_client_id[0..client.len], client);

    const provider = "auth0";
    @memset(&nc.sso_provider, 0);
    @memcpy(nc.sso_provider[0..provider.len], provider);

    var dict = Dictionary(dict_capacity).init();
    nc.toDictionary(&dict) catch return;

    var nc2 = NetworkConfig.init();
    try testing.expect(nc2.fromDictionary(&dict));
    try testing.expect(nc2.sso_enabled);
    try testing.expectEqual(@as(u64, 1), nc2.sso_version);

    try testing.expectEqualStrings(issuer, mem.sliceTo(&nc2.issuer_url, 0));
    try testing.expectEqualStrings(central, mem.sliceTo(&nc2.central_auth_url, 0));
    try testing.expectEqualStrings(nonce_str, mem.sliceTo(&nc2.sso_nonce, 0));
    try testing.expectEqualStrings(state_str, mem.sliceTo(&nc2.sso_state, 0));
    try testing.expectEqualStrings(client, mem.sliceTo(&nc2.sso_client_id, 0));
    try testing.expectEqualStrings(provider, mem.sliceTo(&nc2.sso_provider, 0));
}
