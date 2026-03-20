/// A set of grouped and signed network flow rules (capability).
///
/// Converted from `node/Capability.hpp` and `node/Capability.cpp`. Capabilities
/// associate a set of ZT_VirtualNetworkRule entries with a chain of custody.
/// Each entry in the custody chain is signed by the previous holder, enabling
/// transferable (or non-transferable, chain length 1) capability delegation.
///
/// The `serializeRules` / `deserializeRules` functions are public and also
/// used by `NetworkConfig` (Phase 3d).
///
/// No heap allocation. This is a value type.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Address = @import("address.zig").Address;
const Buffer = @import("buffer.zig").Buffer;
const constants = @import("constants.zig");
const Credential = @import("credential.zig");
const ecc = @import("ecc.zig");
const Identity = @import("identity.zig").Identity;

// ── C API types ────────────────────────────────────────────────────

const c = constants.c_api;

/// The C API rule type. Imported from ZeroTierOne.h.
pub const Rule = c.ZT_VirtualNetworkRule;

// ── Constants ──────────────────────────────────────────────────────

/// Maximum rules per capability (from ZeroTierOne.h).
pub const max_rules: u32 = c.ZT_MAX_CAPABILITY_RULES;

/// Maximum custody chain length (from ZeroTierOne.h).
pub const max_custody_chain_length: u32 = c.ZT_MAX_CAPABILITY_CUSTODY_CHAIN_LENGTH;

/// Maximum serialized size (generous upper bound).
/// Rules: max 64 × (1 type + 1 len + 19 data) = 1344
/// Chain: max 7 × (5 to + 5 from + 1 sigType + 2 sigLen + 96 sig) = 763
/// Header: 8 + 8 + 4 + 2 + 1 + 2 + 5(term) + 2 = 32
/// Total: ~2200, round up generously.
pub const max_serialized_size: u32 = 4096;

/// Sentinel value used as a delimiter for the signing payload.
const for_sign_sentinel: u64 = 0x7f7f7f7f7f7f7f7f;

/// Address length in bytes (ZT_ADDRESS_LENGTH).
const address_len: u32 = 5;

// ── Rule type enum values from ZeroTierOne.h ──────────────────────
// We use raw u8 constants rather than the C enum to avoid issues with
// Zig's @cImport of C enums (the C enum has a "default" entry and
// non-exhaustive values). These must match ZeroTierOne.h exactly.

const RULE_ACTION_DROP: u8 = 0;
const RULE_ACTION_ACCEPT: u8 = 1;
const RULE_ACTION_TEE: u8 = 2;
const RULE_ACTION_WATCH: u8 = 3;
const RULE_ACTION_REDIRECT: u8 = 4;
const RULE_ACTION_BREAK: u8 = 5;
const RULE_ACTION_PRIORITY: u8 = 6;

const RULE_MATCH_SOURCE_ZT_ADDRESS: u8 = 24;
const RULE_MATCH_DEST_ZT_ADDRESS: u8 = 25;
const RULE_MATCH_VLAN_ID: u8 = 26;
const RULE_MATCH_VLAN_PCP: u8 = 27;
const RULE_MATCH_VLAN_DEI: u8 = 28;
const RULE_MATCH_MAC_SOURCE: u8 = 29;
const RULE_MATCH_MAC_DEST: u8 = 30;
const RULE_MATCH_IPV4_SOURCE: u8 = 31;
const RULE_MATCH_IPV4_DEST: u8 = 32;
const RULE_MATCH_IPV6_SOURCE: u8 = 33;
const RULE_MATCH_IPV6_DEST: u8 = 34;
const RULE_MATCH_IP_TOS: u8 = 35;
const RULE_MATCH_IP_PROTOCOL: u8 = 36;
const RULE_MATCH_ETHERTYPE: u8 = 37;
const RULE_MATCH_ICMP: u8 = 38;
const RULE_MATCH_IP_SOURCE_PORT_RANGE: u8 = 39;
const RULE_MATCH_IP_DEST_PORT_RANGE: u8 = 40;
const RULE_MATCH_CHARACTERISTICS: u8 = 41;
const RULE_MATCH_FRAME_SIZE_RANGE: u8 = 42;
const RULE_MATCH_RANDOM: u8 = 43;
const RULE_MATCH_TAGS_DIFFERENCE: u8 = 44;
const RULE_MATCH_TAGS_BITWISE_AND: u8 = 45;
const RULE_MATCH_TAGS_BITWISE_OR: u8 = 46;
const RULE_MATCH_TAGS_BITWISE_XOR: u8 = 47;
const RULE_MATCH_TAGS_EQUAL: u8 = 48;
const RULE_MATCH_TAG_SENDER: u8 = 49;
const RULE_MATCH_TAG_RECEIVER: u8 = 50;
const RULE_MATCH_INTEGER_RANGE: u8 = 51;

// ── Custody Chain Entry ────────────────────────────────────────────

pub const CustodyChainEntry = struct {
    to: Address,
    from: Address,
    signature: ecc.Signature,

    pub fn init() CustodyChainEntry {
        return .{
            .to = Address.zero(),
            .from = Address.zero(),
            .signature = [_]u8{0} ** ecc.signature_len,
        };
    }
};

// ── Capability ─────────────────────────────────────────────────────

pub const Capability = struct {
    _network_id: u64,
    _ts: i64,
    _id: u32,
    _max_custody_chain_length: u32,
    _rule_count: u32,
    _rules: [max_rules]Rule,
    _custody: [max_custody_chain_length]CustodyChainEntry,

    /// Credential type identifier for wire protocol.
    pub const credential_type = Credential.Type.capability;

    // ── Constructors ──────────────────────────────────────

    /// Create a zero/empty capability.
    pub fn init() Capability {
        var rule_arr: [max_rules]Rule = undefined;
        @memset(mem.asBytes(&rule_arr), 0);
        var custody_arr: [max_custody_chain_length]CustodyChainEntry = undefined;
        for (&custody_arr) |*entry| {
            entry.* = CustodyChainEntry.init();
        }
        return .{
            ._network_id = 0,
            ._ts = 0,
            ._id = 0,
            ._max_custody_chain_length = 0,
            ._rule_count = 0,
            ._rules = rule_arr,
            ._custody = custody_arr,
        };
    }

    /// Create a capability with the given fields.
    ///
    /// `mccl` is the maximum custody chain length (1 = non-transferable).
    /// `cap_rules` is a slice of rules to include (clamped to max_rules).
    pub fn create(
        cap_id: u32,
        nwid: u64,
        ts: i64,
        mccl: u32,
        cap_rules: []const Rule,
    ) Capability {
        var self = Capability.init();
        self._network_id = nwid;
        self._ts = ts;
        self._id = cap_id;

        // Clamp mccl: min 1, max ZT_MAX_CAPABILITY_CUSTODY_CHAIN_LENGTH
        self._max_custody_chain_length = if (mccl < 1)
            1
        else if (mccl > max_custody_chain_length)
            max_custody_chain_length
        else
            mccl;

        const count = if (cap_rules.len > max_rules)
            max_rules
        else
            @as(u32, @intCast(cap_rules.len));
        self._rule_count = count;

        if (count > 0) {
            for (0..count) |i| {
                self._rules[i] = cap_rules[i];
            }
        }

        return self;
    }

    // ── Accessors ─────────────────────────────────────────

    pub fn capId(self: *const Capability) u32 {
        return self._id;
    }

    pub fn networkId(self: *const Capability) u64 {
        return self._network_id;
    }

    pub fn timestamp(self: *const Capability) i64 {
        return self._ts;
    }

    pub fn ruleCount(self: *const Capability) u32 {
        return self._rule_count;
    }

    pub fn rules(self: *const Capability) []const Rule {
        return self._rules[0..self._rule_count];
    }

    /// Return the last 'to' address in the custody chain.
    pub fn issuedTo(self: *const Capability) Address {
        var result = Address.zero();
        for (&self._custody) |*entry| {
            if (!entry.to.isSet()) break;
            result = entry.to;
        }
        return result;
    }

    // ── Signing ───────────────────────────────────────────

    /// Sign this capability and append to its chain of custody.
    ///
    /// The `from_identity` is the signer (must have private key).
    /// The `to_addr` is the recipient of this custody transfer.
    ///
    /// Returns false if the identity has no private key or the chain
    /// is already full.
    pub fn sign(
        self: *Capability,
        from_identity: *const Identity,
        to_addr: Address,
    ) bool {
        if (!from_identity.hasPrivate()) return false;

        // Find the first empty slot in the custody chain
        for (0..@min(self._max_custody_chain_length, max_custody_chain_length)) |i| {
            if (!self._custody[i].to.isSet()) {
                // Serialize for signing (before modifying the chain)
                var tmp: Buffer(max_serialized_size) = .{};
                self.serializeForSign(&tmp) catch return false;

                self._custody[i].to = to_addr;
                self._custody[i].from = from_identity.address();
                self._custody[i].signature = from_identity.sign(
                    tmp.data(),
                ) orelse return false;
                return true;
            }
        }
        return false; // chain is full
    }

    /// Verify the last signature in the custody chain.
    ///
    /// NOTE: Full chain verification requires RuntimeEnvironment/Topology
    /// (Phase 4-6 dependencies). This method verifies only the specified
    /// chain entry's signature against the provided signer identity.
    /// The caller is responsible for identity lookup and chain validation.
    pub fn verifySignature(
        self: *const Capability,
        chain_index: u32,
        signer_identity: *const Identity,
    ) bool {
        if (chain_index >= max_custody_chain_length) return false;
        if (!self._custody[chain_index].to.isSet()) return false;

        var tmp: Buffer(max_serialized_size) = .{};
        self.serializeForSign(&tmp) catch return false;
        return signer_identity.verify(
            tmp.data(),
            &self._custody[chain_index].signature,
        );
    }

    // ── Serialization ─────────────────────────────────────

    /// Serialize for signing (with sentinel delimiters, rules but no chain).
    fn serializeForSign(self: *const Capability, buf: *Buffer(max_serialized_size)) !void {
        try buf.appendInt(u64, for_sign_sentinel);
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u64, @bitCast(self._ts));
        try buf.appendInt(u32, self._id);
        try buf.appendInt(u16, @intCast(self._rule_count));
        try serializeRules(max_serialized_size, buf, self._rules[0..self._rule_count]);
        try buf.appendByte(@intCast(self._max_custody_chain_length), 1);
        try buf.appendInt(u16, 0); // additional fields length
        try buf.appendInt(u64, for_sign_sentinel);
    }

    /// Serialize to wire format.
    ///
    /// Wire format:
    ///   networkId(8) + ts(8) + id(4) +
    ///   ruleCount(2) + [rules...] +
    ///   maxCustodyChainLength(1) +
    ///   [custody chain entries terminated by zero 'to' address] +
    ///   additionalFieldsLen(2)
    pub fn serialize(
        self: *const Capability,
        comptime C: u32,
        buf: *Buffer(C),
    ) !void {
        try buf.appendInt(u64, self._network_id);
        try buf.appendInt(u64, @bitCast(self._ts));
        try buf.appendInt(u32, self._id);

        try buf.appendInt(u16, @intCast(self._rule_count));
        try serializeRules(C, buf, self._rules[0..self._rule_count]);
        try buf.appendByte(@intCast(self._max_custody_chain_length), 1);

        // Custody chain
        for (0..max_custody_chain_length) |i| {
            if (i < self._max_custody_chain_length and
                self._custody[i].to.isSet())
            {
                try self._custody[i].to.appendTo(C, buf);
                try self._custody[i].from.appendTo(C, buf);
                try buf.appendByte(1, 1); // 1 == Ed25519
                try buf.appendInt(u16, ecc.signature_len);
                try buf.appendBytes(&self._custody[i].signature);
            } else {
                // Zero 'to' terminates the chain
                try buf.appendByte(0, address_len);
                break;
            }
        }

        try buf.appendInt(u16, 0); // additional fields length
    }

    /// Deserialize from wire format.
    ///
    /// Returns the capability and the number of bytes consumed.
    pub fn deserialize(
        comptime C: u32,
        buf: *const Buffer(C),
        start: u32,
    ) !DeserializeResult {
        var self = Capability.init();
        var p = start;

        self._network_id = try buf.at(u64, p);
        p += 8;
        self._ts = @bitCast(try buf.at(u64, p));
        p += 8;
        self._id = try buf.at(u32, p);
        p += 4;

        const rc = try buf.at(u16, p);
        p += 2;
        if (rc > max_rules) return error.OutOfBounds;

        self._rule_count = 0;
        p = try deserializeRules(C, buf, p, &self._rules, &self._rule_count, rc);

        self._max_custody_chain_length = try buf.getByte(p);
        p += 1;
        if (self._max_custody_chain_length < 1 or
            self._max_custody_chain_length > max_custody_chain_length)
        {
            return error.OutOfBounds;
        }

        // Custody chain — terminated by zero 'to' address
        var chain_idx: u32 = 0;
        while (true) {
            const to_bytes = try buf.field(p, address_len);
            const to_addr = Address.fromSlice(to_bytes);
            p += address_len;

            if (!to_addr.isSet()) break;

            if (chain_idx >= self._max_custody_chain_length or
                chain_idx >= max_custody_chain_length)
            {
                return error.OutOfBounds;
            }

            self._custody[chain_idx].to = to_addr;
            const from_bytes = try buf.field(p, address_len);
            self._custody[chain_idx].from = Address.fromSlice(from_bytes);
            p += address_len;

            const sig_type = try buf.getByte(p);
            p += 1;
            if (sig_type == 1) {
                const sig_len = try buf.at(u16, p);
                if (sig_len != ecc.signature_len) {
                    return error.OutOfBounds;
                }
                p += 2;
                const sig_bytes = try buf.field(p, ecc.signature_len);
                @memcpy(&self._custody[chain_idx].signature, sig_bytes);
                p += ecc.signature_len;
            } else {
                // Unknown signature type — skip
                const skip_len = try buf.at(u16, p);
                p += 2 + skip_len;
            }

            chain_idx += 1;
        }

        // Skip additional fields
        const additional_len = try buf.at(u16, p);
        p += 2 + additional_len;

        if (p > buf._l) return error.OutOfBounds;

        return .{ .capability = self, .bytes_read = p - start };
    }

    // ── Comparison ────────────────────────────────────────

    /// Natural sort order by ID (for sorted arrays).
    pub fn lessThan(_: void, a: Capability, b: Capability) bool {
        return a._id < b._id;
    }

    pub fn order(self: *const Capability, other: *const Capability) std.math.Order {
        return std.math.order(self._id, other._id);
    }
};

/// Result of deserializing a Capability.
pub const DeserializeResult = struct {
    capability: Capability,
    bytes_read: u32,
};

// ── Rules Serialization (shared with NetworkConfig) ────────────────

/// Serialize an array of network flow rules to a buffer.
///
/// Each rule is encoded as: type(1) + fieldLen(1) + [field data].
/// This matches the C++ `Capability::serializeRules` template method.
pub fn serializeRules(
    comptime C: u32,
    buf: *Buffer(C),
    rule_slice: []const Rule,
) !void {
    for (rule_slice) |rule| {
        try buf.appendByte(rule.t, 1);

        const rule_type: u8 = rule.t & 0x3f;
        switch (rule_type) {
            RULE_ACTION_TEE,
            RULE_ACTION_WATCH,
            RULE_ACTION_REDIRECT,
            => {
                try buf.appendByte(14, 1); // field length
                try buf.appendInt(u64, rule.v.fwd.address);
                try buf.appendInt(u32, rule.v.fwd.flags);
                try buf.appendInt(u16, rule.v.fwd.length);
            },
            RULE_MATCH_SOURCE_ZT_ADDRESS,
            RULE_MATCH_DEST_ZT_ADDRESS,
            => {
                try buf.appendByte(5, 1); // field length
                const addr = Address.init(rule.v.zt);
                try addr.appendTo(C, buf);
            },
            RULE_MATCH_VLAN_ID => {
                try buf.appendByte(2, 1);
                try buf.appendInt(u16, rule.v.vlanId);
            },
            RULE_MATCH_VLAN_PCP => {
                try buf.appendByte(1, 1);
                try buf.appendByte(rule.v.vlanPcp, 1);
            },
            RULE_MATCH_VLAN_DEI => {
                try buf.appendByte(1, 1);
                try buf.appendByte(rule.v.vlanDei, 1);
            },
            RULE_MATCH_MAC_SOURCE,
            RULE_MATCH_MAC_DEST,
            => {
                try buf.appendByte(6, 1);
                try buf.appendBytes(&rule.v.mac);
            },
            RULE_MATCH_IPV4_SOURCE,
            RULE_MATCH_IPV4_DEST,
            => {
                try buf.appendByte(5, 1);
                // ipv4.ip is a u32 — write its raw bytes
                try buf.appendBytes(mem.asBytes(&rule.v.ipv4.ip));
                try buf.appendByte(rule.v.ipv4.mask, 1);
            },
            RULE_MATCH_IPV6_SOURCE,
            RULE_MATCH_IPV6_DEST,
            => {
                try buf.appendByte(17, 1);
                try buf.appendBytes(&rule.v.ipv6.ip);
                try buf.appendByte(rule.v.ipv6.mask, 1);
            },
            RULE_MATCH_IP_TOS => {
                try buf.appendByte(3, 1);
                try buf.appendByte(rule.v.ipTos.mask, 1);
                try buf.appendByte(rule.v.ipTos.value[0], 1);
                try buf.appendByte(rule.v.ipTos.value[1], 1);
            },
            RULE_MATCH_IP_PROTOCOL => {
                try buf.appendByte(1, 1);
                try buf.appendByte(rule.v.ipProtocol, 1);
            },
            RULE_MATCH_ETHERTYPE => {
                try buf.appendByte(2, 1);
                try buf.appendInt(u16, rule.v.etherType);
            },
            RULE_MATCH_ICMP => {
                try buf.appendByte(3, 1);
                try buf.appendByte(rule.v.icmp.type, 1);
                try buf.appendByte(rule.v.icmp.code, 1);
                try buf.appendByte(rule.v.icmp.flags, 1);
            },
            RULE_MATCH_IP_SOURCE_PORT_RANGE,
            RULE_MATCH_IP_DEST_PORT_RANGE,
            => {
                try buf.appendByte(4, 1);
                try buf.appendInt(u16, rule.v.port[0]);
                try buf.appendInt(u16, rule.v.port[1]);
            },
            RULE_MATCH_CHARACTERISTICS => {
                try buf.appendByte(8, 1);
                try buf.appendInt(u64, rule.v.characteristics);
            },
            RULE_MATCH_FRAME_SIZE_RANGE => {
                try buf.appendByte(4, 1);
                try buf.appendInt(u16, rule.v.frameSize[0]);
                try buf.appendInt(u16, rule.v.frameSize[1]);
            },
            RULE_MATCH_RANDOM => {
                try buf.appendByte(4, 1);
                try buf.appendInt(u32, rule.v.randomProbability);
            },
            RULE_MATCH_TAGS_DIFFERENCE,
            RULE_MATCH_TAGS_BITWISE_AND,
            RULE_MATCH_TAGS_BITWISE_OR,
            RULE_MATCH_TAGS_BITWISE_XOR,
            RULE_MATCH_TAGS_EQUAL,
            RULE_MATCH_TAG_SENDER,
            RULE_MATCH_TAG_RECEIVER,
            => {
                try buf.appendByte(8, 1);
                try buf.appendInt(u32, rule.v.tag.id);
                try buf.appendInt(u32, rule.v.tag.value);
            },
            RULE_MATCH_INTEGER_RANGE => {
                try buf.appendByte(19, 1);
                try buf.appendInt(u64, rule.v.intRange.start);
                // C++ encodes start + end (more future-proof)
                try buf.appendInt(
                    u64,
                    rule.v.intRange.start +% @as(u64, rule.v.intRange.end),
                );
                try buf.appendInt(u16, rule.v.intRange.idx);
                try buf.appendByte(rule.v.intRange.format, 1);
            },
            else => {
                try buf.appendByte(0, 1); // unknown rule type — 0 length
            },
        }
    }
}

/// Deserialize an array of network flow rules from a buffer.
///
/// Updates `p` (current position) and `out_rule_count` as rules are read.
/// Reads up to `max_rule_count` rules. Returns the new buffer position.
///
/// This matches the C++ `Capability::deserializeRules` template method.
pub fn deserializeRules(
    comptime C: u32,
    buf: *const Buffer(C),
    start_pos: u32,
    out_rules: *[max_rules]Rule,
    out_rule_count: *u32,
    max_rule_count: u32,
) !u32 {
    var p = start_pos;
    while (out_rule_count.* < max_rule_count and p < buf._l) {
        const idx = out_rule_count.*;
        out_rules[idx].t = try buf.getByte(p);
        p += 1;
        const field_len: u32 = try buf.getByte(p);
        p += 1;

        const rule_type: u8 = out_rules[idx].t & 0x3f;
        // Zero the union first to avoid leaking uninitialised data.
        @memset(mem.asBytes(&out_rules[idx].v), 0);

        switch (rule_type) {
            RULE_ACTION_TEE,
            RULE_ACTION_WATCH,
            RULE_ACTION_REDIRECT,
            => {
                out_rules[idx].v.fwd.address = try buf.at(u64, p);
                out_rules[idx].v.fwd.flags = try buf.at(u32, p + 8);
                out_rules[idx].v.fwd.length = try buf.at(u16, p + 12);
            },
            RULE_MATCH_SOURCE_ZT_ADDRESS,
            RULE_MATCH_DEST_ZT_ADDRESS,
            => {
                const addr_bytes = try buf.field(p, address_len);
                const addr = Address.fromSlice(addr_bytes);
                out_rules[idx].v.zt = addr.toInt();
            },
            RULE_MATCH_VLAN_ID => {
                out_rules[idx].v.vlanId = try buf.at(u16, p);
            },
            RULE_MATCH_VLAN_PCP => {
                out_rules[idx].v.vlanPcp = try buf.getByte(p);
            },
            RULE_MATCH_VLAN_DEI => {
                out_rules[idx].v.vlanDei = try buf.getByte(p);
            },
            RULE_MATCH_MAC_SOURCE,
            RULE_MATCH_MAC_DEST,
            => {
                const mac_bytes = try buf.field(p, 6);
                @memcpy(&out_rules[idx].v.mac, mac_bytes);
            },
            RULE_MATCH_IPV4_SOURCE,
            RULE_MATCH_IPV4_DEST,
            => {
                const ip_bytes = try buf.field(p, 4);
                @memcpy(mem.asBytes(&out_rules[idx].v.ipv4.ip), ip_bytes);
                out_rules[idx].v.ipv4.mask = try buf.getByte(p + 4);
            },
            RULE_MATCH_IPV6_SOURCE,
            RULE_MATCH_IPV6_DEST,
            => {
                const ip_bytes = try buf.field(p, 16);
                @memcpy(&out_rules[idx].v.ipv6.ip, ip_bytes);
                out_rules[idx].v.ipv6.mask = try buf.getByte(p + 16);
            },
            RULE_MATCH_IP_TOS => {
                out_rules[idx].v.ipTos.mask = try buf.getByte(p);
                out_rules[idx].v.ipTos.value[0] = try buf.getByte(p + 1);
                out_rules[idx].v.ipTos.value[1] = try buf.getByte(p + 2);
            },
            RULE_MATCH_IP_PROTOCOL => {
                out_rules[idx].v.ipProtocol = try buf.getByte(p);
            },
            RULE_MATCH_ETHERTYPE => {
                out_rules[idx].v.etherType = try buf.at(u16, p);
            },
            RULE_MATCH_ICMP => {
                out_rules[idx].v.icmp.type = try buf.getByte(p);
                out_rules[idx].v.icmp.code = try buf.getByte(p + 1);
                out_rules[idx].v.icmp.flags = try buf.getByte(p + 2);
            },
            RULE_MATCH_IP_SOURCE_PORT_RANGE,
            RULE_MATCH_IP_DEST_PORT_RANGE,
            => {
                out_rules[idx].v.port[0] = try buf.at(u16, p);
                out_rules[idx].v.port[1] = try buf.at(u16, p + 2);
            },
            RULE_MATCH_CHARACTERISTICS => {
                out_rules[idx].v.characteristics = try buf.at(u64, p);
            },
            RULE_MATCH_FRAME_SIZE_RANGE => {
                out_rules[idx].v.frameSize[0] = try buf.at(u16, p);
                out_rules[idx].v.frameSize[1] = try buf.at(u16, p + 2);
            },
            RULE_MATCH_RANDOM => {
                out_rules[idx].v.randomProbability = try buf.at(u32, p);
            },
            RULE_MATCH_TAGS_DIFFERENCE,
            RULE_MATCH_TAGS_BITWISE_AND,
            RULE_MATCH_TAGS_BITWISE_OR,
            RULE_MATCH_TAGS_BITWISE_XOR,
            RULE_MATCH_TAGS_EQUAL,
            RULE_MATCH_TAG_SENDER,
            RULE_MATCH_TAG_RECEIVER,
            => {
                out_rules[idx].v.tag.id = try buf.at(u32, p);
                out_rules[idx].v.tag.value = try buf.at(u32, p + 4);
            },
            RULE_MATCH_INTEGER_RANGE => {
                out_rules[idx].v.intRange.start = try buf.at(u64, p);
                const end_abs = try buf.at(u64, p + 8);
                out_rules[idx].v.intRange.end = @truncate(
                    end_abs -% out_rules[idx].v.intRange.start,
                );
                out_rules[idx].v.intRange.idx = try buf.at(u16, p + 16);
                out_rules[idx].v.intRange.format = try buf.getByte(p + 18);
            },
            else => {},
        }

        p += field_len;
        out_rule_count.* += 1;
    }
    return p;
}

// ── Tests ──────────────────────────────────────────────────────────

fn makeDropRule() Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_ACTION_DROP;
    return rule;
}

fn makeAcceptRule() Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_ACTION_ACCEPT;
    return rule;
}

fn makeMatchEthertype(etype: u16) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_ETHERTYPE;
    rule.v.etherType = etype;
    return rule;
}

fn makeTeeRule(addr: u64, flags: u32, length: u16) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_ACTION_TEE;
    rule.v.fwd.address = addr;
    rule.v.fwd.flags = flags;
    rule.v.fwd.length = length;
    return rule;
}

fn makeMatchZtAddress(src: bool, addr: u64) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = if (src) RULE_MATCH_SOURCE_ZT_ADDRESS else RULE_MATCH_DEST_ZT_ADDRESS;
    rule.v.zt = addr;
    return rule;
}

fn makeMatchIpv4(src: bool, ip: u32, mask: u8) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = if (src) RULE_MATCH_IPV4_SOURCE else RULE_MATCH_IPV4_DEST;
    rule.v.ipv4.ip = ip;
    rule.v.ipv4.mask = mask;
    return rule;
}

fn makeMatchPortRange(src: bool, lo: u16, hi: u16) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = if (src) RULE_MATCH_IP_SOURCE_PORT_RANGE else RULE_MATCH_IP_DEST_PORT_RANGE;
    rule.v.port[0] = lo;
    rule.v.port[1] = hi;
    return rule;
}

fn makeMatchMac(src: bool, mac_bytes: [6]u8) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = if (src) RULE_MATCH_MAC_SOURCE else RULE_MATCH_MAC_DEST;
    rule.v.mac = mac_bytes;
    return rule;
}

fn makeMatchTagsEqual(tag_id: u32, tag_value: u32) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_TAGS_EQUAL;
    rule.v.tag.id = tag_id;
    rule.v.tag.value = tag_value;
    return rule;
}

fn makeMatchCharacteristics(chars: u64) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_CHARACTERISTICS;
    rule.v.characteristics = chars;
    return rule;
}

fn makeMatchRandom(prob: u32) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_RANDOM;
    rule.v.randomProbability = prob;
    return rule;
}

fn makeMatchIpv6(src: bool, ip: [16]u8, mask: u8) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = if (src) RULE_MATCH_IPV6_SOURCE else RULE_MATCH_IPV6_DEST;
    rule.v.ipv6.ip = ip;
    rule.v.ipv6.mask = mask;
    return rule;
}

fn makeMatchIcmp(icmp_type: u8, icmp_code: u8, flags: u8) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_ICMP;
    rule.v.icmp.type = icmp_type;
    rule.v.icmp.code = icmp_code;
    rule.v.icmp.flags = flags;
    return rule;
}

fn makeMatchIntRange(start_val: u64, end_val: u32, idx: u16, fmt: u8) Rule {
    var rule: Rule = undefined;
    @memset(mem.asBytes(&rule), 0);
    rule.t = RULE_MATCH_INTEGER_RANGE;
    rule.v.intRange.start = start_val;
    rule.v.intRange.end = end_val;
    rule.v.intRange.idx = idx;
    rule.v.intRange.format = fmt;
    return rule;
}

test "Capability: init produces empty capability" {
    const cap = Capability.init();
    try testing.expectEqual(@as(u32, 0), cap.capId());
    try testing.expectEqual(@as(u64, 0), cap.networkId());
    try testing.expectEqual(@as(i64, 0), cap.timestamp());
    try testing.expectEqual(@as(u32, 0), cap.ruleCount());
    try testing.expect(!cap.issuedTo().isSet());
}

test "Capability: create with rules" {
    const rules_arr = [_]Rule{
        makeMatchEthertype(0x0800),
        makeAcceptRule(),
    };

    const cap = Capability.create(42, 0xdeadbeef00000000, 1000, 1, &rules_arr);
    try testing.expectEqual(@as(u32, 42), cap.capId());
    try testing.expectEqual(@as(u64, 0xdeadbeef00000000), cap.networkId());
    try testing.expectEqual(@as(i64, 1000), cap.timestamp());
    try testing.expectEqual(@as(u32, 2), cap.ruleCount());
}

test "Capability: rules serialize and deserialize round-trip" {
    const rules_arr = [_]Rule{
        makeMatchEthertype(0x0800),
        makeMatchPortRange(false, 80, 443),
        makeTeeRule(0x1234567890, 0x01, 100),
        makeMatchZtAddress(true, 0xaabbccddee),
        makeMatchMac(true, .{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }),
        makeMatchIpv4(true, 0xC0A80164, 24),
        makeMatchIpv6(false, .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 64),
        makeMatchCharacteristics(0x8000000000000000),
        makeMatchRandom(0x80000000),
        makeMatchTagsEqual(10, 200),
        makeMatchIcmp(8, 0, 0x01),
        makeMatchIntRange(100, 50, 4, 0x3f),
        makeDropRule(),
        makeAcceptRule(),
    };

    var buf: Buffer(4096) = .{};
    try serializeRules(4096, &buf, &rules_arr);
    try testing.expect(buf._l > 0);

    var out_rules: [max_rules]Rule = undefined;
    @memset(mem.asBytes(&out_rules), 0);
    var out_count: u32 = 0;
    _ = try deserializeRules(4096, &buf, 0, &out_rules, &out_count, @intCast(rules_arr.len));
    try testing.expectEqual(@as(u32, rules_arr.len), out_count);

    // Verify specific field values survived the round-trip
    try testing.expectEqual(@as(u16, 0x0800), out_rules[0].v.etherType);
    try testing.expectEqual(@as(u16, 80), out_rules[1].v.port[0]);
    try testing.expectEqual(@as(u16, 443), out_rules[1].v.port[1]);
    try testing.expectEqual(@as(u64, 0x1234567890), out_rules[2].v.fwd.address);
    try testing.expectEqual(@as(u32, 0x01), out_rules[2].v.fwd.flags);
    try testing.expectEqual(@as(u16, 100), out_rules[2].v.fwd.length);
    try testing.expectEqual(@as(u64, 0xaabbccddee), out_rules[3].v.zt);
    try testing.expect(mem.eql(
        u8,
        &out_rules[4].v.mac,
        &[_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff },
    ));
    try testing.expectEqual(@as(u32, 0xC0A80164), out_rules[5].v.ipv4.ip);
    try testing.expectEqual(@as(u8, 24), out_rules[5].v.ipv4.mask);
    try testing.expectEqual(@as(u8, 64), out_rules[6].v.ipv6.mask);
    try testing.expectEqual(@as(u64, 0x8000000000000000), out_rules[7].v.characteristics);
    try testing.expectEqual(@as(u32, 0x80000000), out_rules[8].v.randomProbability);
    try testing.expectEqual(@as(u32, 10), out_rules[9].v.tag.id);
    try testing.expectEqual(@as(u32, 200), out_rules[9].v.tag.value);
    try testing.expectEqual(@as(u8, 8), out_rules[10].v.icmp.type);
    try testing.expectEqual(@as(u8, 0x01), out_rules[10].v.icmp.flags);
    try testing.expectEqual(@as(u64, 100), out_rules[11].v.intRange.start);
    try testing.expectEqual(@as(u32, 50), out_rules[11].v.intRange.end);
    try testing.expectEqual(@as(u16, 4), out_rules[11].v.intRange.idx);
    try testing.expectEqual(@as(u8, 0x3f), out_rules[11].v.intRange.format);
}

test "Capability: full serialize and deserialize round-trip" {
    const rules_arr = [_]Rule{
        makeMatchEthertype(0x0800),
        makeAcceptRule(),
    };

    var cap = Capability.create(7, 0x1122334455667788, -500, 2, &rules_arr);

    // Simulate controller signing
    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const recipient = Address.init(0xaabbccddee);
    try testing.expect(cap.sign(&id1, recipient));

    var buf: Buffer(max_serialized_size) = .{};
    try cap.serialize(max_serialized_size, &buf);
    try testing.expect(buf._l > 0);

    const result = try Capability.deserialize(max_serialized_size, &buf, 0);
    try testing.expectEqual(@as(u32, 7), result.capability.capId());
    try testing.expectEqual(@as(u64, 0x1122334455667788), result.capability.networkId());
    try testing.expectEqual(@as(i64, -500), result.capability.timestamp());
    try testing.expectEqual(@as(u32, 2), result.capability.ruleCount());
    try testing.expect(result.capability.issuedTo().eql(recipient));
    try testing.expectEqual(buf._l, result.bytes_read);
}

test "Capability: sign and verify" {
    const rules_arr = [_]Rule{
        makeMatchEthertype(0x0800),
        makeAcceptRule(),
    };

    var cap = Capability.create(1, 0x1000000000000000, 12345, 1, &rules_arr);

    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const recipient = Address.init(0x1111111111);
    try testing.expect(cap.sign(&id1, recipient));

    try testing.expect(cap.issuedTo().eql(recipient));
    try testing.expect(cap._custody[0].from.eql(id1.address()));

    // Verify signature
    try testing.expect(cap.verifySignature(0, &id1));

    // Tamper with ID — should fail
    var cap2 = cap;
    cap2._id = 999;
    try testing.expect(!cap2.verifySignature(0, &id1));
}

test "Capability: chain full returns false" {
    const rules_arr = [_]Rule{makeAcceptRule()};
    var cap = Capability.create(1, 0, 0, 1, &rules_arr); // max chain = 1

    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const addr1 = Address.init(1);
    try testing.expect(cap.sign(&id1, addr1)); // first sign succeeds
    try testing.expect(!cap.sign(&id1, addr1)); // second sign fails (chain full)
}

test "Capability: lessThan ordering" {
    const rules_arr = [_]Rule{makeAcceptRule()};
    const c1 = Capability.create(10, 0, 0, 1, &rules_arr);
    const c2 = Capability.create(20, 0, 0, 1, &rules_arr);
    const c3 = Capability.create(5, 0, 0, 1, &rules_arr);

    try testing.expect(Capability.lessThan({}, c1, c2));
    try testing.expect(!Capability.lessThan({}, c2, c1));
    try testing.expect(Capability.lessThan({}, c3, c1));
}

test "Capability: empty rules serialize/deserialize" {
    var cap = Capability.create(1, 0x1234, 100, 1, &[_]Rule{});
    try testing.expectEqual(@as(u32, 0), cap.ruleCount());

    const id1 = Identity.generate(testing.allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    try testing.expect(cap.sign(&id1, Address.init(1)));

    var buf: Buffer(max_serialized_size) = .{};
    try cap.serialize(max_serialized_size, &buf);

    const result = try Capability.deserialize(max_serialized_size, &buf, 0);
    try testing.expectEqual(@as(u32, 0), result.capability.ruleCount());
    try testing.expectEqual(@as(u32, 1), result.capability.capId());
}

test "Capability: deserialize rejects excessive rule count" {
    var buf: Buffer(128) = .{};
    try buf.appendInt(u64, 0); // networkId
    try buf.appendInt(u64, 0); // ts
    try buf.appendInt(u32, 0); // id
    try buf.appendInt(u16, max_rules + 1); // ruleCount > max

    const result = Capability.deserialize(128, &buf, 0);
    try testing.expectError(error.OutOfBounds, result);
}

test "Capability: deserialize rejects bad chain length" {
    var buf: Buffer(128) = .{};
    try buf.appendInt(u64, 0); // networkId
    try buf.appendInt(u64, 0); // ts
    try buf.appendInt(u32, 0); // id
    try buf.appendInt(u16, 0); // ruleCount = 0
    try buf.appendByte(0, 1); // maxCustodyChainLength = 0 (invalid, must be >= 1)

    const result = Capability.deserialize(128, &buf, 0);
    try testing.expectError(error.OutOfBounds, result);
}

test "Capability: VLAN and IP TOS rules round-trip" {
    var r_vlan_id: Rule = undefined;
    @memset(mem.asBytes(&r_vlan_id), 0);
    r_vlan_id.t = RULE_MATCH_VLAN_ID;
    r_vlan_id.v.vlanId = 42;

    var r_vlan_pcp: Rule = undefined;
    @memset(mem.asBytes(&r_vlan_pcp), 0);
    r_vlan_pcp.t = RULE_MATCH_VLAN_PCP;
    r_vlan_pcp.v.vlanPcp = 5;

    var r_vlan_dei: Rule = undefined;
    @memset(mem.asBytes(&r_vlan_dei), 0);
    r_vlan_dei.t = RULE_MATCH_VLAN_DEI;
    r_vlan_dei.v.vlanDei = 1;

    var r_ip_tos: Rule = undefined;
    @memset(mem.asBytes(&r_ip_tos), 0);
    r_ip_tos.t = RULE_MATCH_IP_TOS;
    r_ip_tos.v.ipTos.mask = 0xfc;
    r_ip_tos.v.ipTos.value[0] = 0x20;
    r_ip_tos.v.ipTos.value[1] = 0x40;

    var r_ip_proto: Rule = undefined;
    @memset(mem.asBytes(&r_ip_proto), 0);
    r_ip_proto.t = RULE_MATCH_IP_PROTOCOL;
    r_ip_proto.v.ipProtocol = 6; // TCP

    var r_frame_size: Rule = undefined;
    @memset(mem.asBytes(&r_frame_size), 0);
    r_frame_size.t = RULE_MATCH_FRAME_SIZE_RANGE;
    r_frame_size.v.frameSize[0] = 64;
    r_frame_size.v.frameSize[1] = 1500;

    const rules_arr = [_]Rule{
        r_vlan_id,
        r_vlan_pcp,
        r_vlan_dei,
        r_ip_tos,
        r_ip_proto,
        r_frame_size,
        makeAcceptRule(),
    };

    var buf: Buffer(4096) = .{};
    try serializeRules(4096, &buf, &rules_arr);

    var out_rules: [max_rules]Rule = undefined;
    @memset(mem.asBytes(&out_rules), 0);
    var out_count: u32 = 0;
    _ = try deserializeRules(4096, &buf, 0, &out_rules, &out_count, @intCast(rules_arr.len));

    try testing.expectEqual(@as(u32, 7), out_count);
    try testing.expectEqual(@as(u16, 42), out_rules[0].v.vlanId);
    try testing.expectEqual(@as(u8, 5), out_rules[1].v.vlanPcp);
    try testing.expectEqual(@as(u8, 1), out_rules[2].v.vlanDei);
    try testing.expectEqual(@as(u8, 0xfc), out_rules[3].v.ipTos.mask);
    try testing.expectEqual(@as(u8, 0x20), out_rules[3].v.ipTos.value[0]);
    try testing.expectEqual(@as(u8, 0x40), out_rules[3].v.ipTos.value[1]);
    try testing.expectEqual(@as(u8, 6), out_rules[4].v.ipProtocol);
    try testing.expectEqual(@as(u16, 64), out_rules[5].v.frameSize[0]);
    try testing.expectEqual(@as(u16, 1500), out_rules[5].v.frameSize[1]);
}
