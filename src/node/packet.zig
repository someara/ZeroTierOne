/// ZeroTier wire protocol packet encoding and decoding.
///
/// Converted from `node/Packet.hpp` and `node/Packet.cpp`.
///
/// Packet format:
///   [0..8]   64-bit packet ID / crypto IV / counter
///   [8..13]  destination ZT address (5 bytes)
///   [13..18] source ZT address (5 bytes)
///   [18]     flags/cipher/hops (FFCCCHHH)
///   [19..27] 64-bit MAC (or trusted path ID)
///   [27]     encrypted verb flags (3 bits) + verb (5 bits)
///   [28..]   verb-specific payload
///
/// Fragment format:
///   [0..8]   packet ID of parent packet
///   [8..13]  destination ZT address
///   [13]     0xff fragment indicator
///   [14]     totalFragments(4 bits) | fragmentNo(4 bits)
///   [15]     hop count (lower 3 bits)
///   [16..]   fragment payload
const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const testing = std.testing;

const constants = @import("constants.zig");
const Address = @import("address.zig").Address;
const aes_mod = @import("aes.zig");
const Aes = aes_mod.Aes;
const salsa20_mod = @import("salsa20.zig");
const Salsa20 = salsa20_mod.Salsa20;
const poly1305_mod = @import("poly1305.zig");
const ecc = @import("ecc.zig");
const lz4 = @import("lz4.zig");
const Buffer = @import("buffer.zig").Buffer;

// ── Protocol version ──────────────────────────────────────────────

pub const protocol_version: u8 = 13;
pub const protocol_version_min: u8 = 4;

// ── Cipher suites ─────────────────────────────────────────────────

pub const CipherSuite = enum(u3) {
    /// Poly1305 MAC only, no payload encryption (used for HELLO).
    c25519_poly1305_none = 0,
    /// Poly1305 MAC + Salsa20/12 payload encryption.
    c25519_poly1305_salsa2012 = 1,
    /// No crypto at all — trusted local path (MAC = trusted path ID).
    no_crypto_trusted_path = 2,
    /// AES-GMAC-SIV authenticated encryption.
    aes_gmac_siv = 3,
};

// ── KBKDF labels for AES-GMAC-SIV ────────────────────────────────

pub const kbkdf_label_aes_gmac_siv_k0: u8 = '0';
pub const kbkdf_label_aes_gmac_siv_k1: u8 = '1';

// ── Flags ─────────────────────────────────────────────────────────

/// Packet has an ephemeral key appended and a second AES-CTR encryption pass.
pub const flag_extended_armor: u8 = 0x80;
/// Packet is fragmented — more fragments follow.
pub const flag_fragmented: u8 = 0x40;
/// Verb flag: payload is LZ4-compressed.
pub const verb_flag_compressed: u8 = 0x80;

// ── Header layout constants ───────────────────────────────────────

pub const idx_iv: u32 = 0;
pub const idx_dest: u32 = 8;
pub const idx_source: u32 = 13;
pub const idx_flags: u32 = 18;
pub const idx_mac: u32 = 19;
pub const idx_verb: u32 = 27;
pub const idx_payload: u32 = 28;

/// Extended armor encryption starts right after flags, before MAC.
pub const idx_extended_armor_start: u32 = idx_mac;

// ── Packet sizes ──────────────────────────────────────────────────

pub const max_packet_length: u32 = constants.max_packet_fragments *
    constants.c_api.ZT_DEFAULT_PHYSMTU;
pub const min_packet_length: u32 = idx_payload;

// ── Fragment header layout ────────────────────────────────────────

pub const frag_idx_packet_id: u32 = 0;
pub const frag_idx_dest: u32 = 8;
pub const frag_idx_fragment_indicator: u32 = 13;
pub const frag_idx_fragment_no: u32 = 14;
pub const frag_idx_hops: u32 = 15;
pub const frag_idx_payload: u32 = 16;

pub const fragment_indicator: u8 = constants.address_reserved_prefix; // 0xff
pub const min_fragment_length: u32 = frag_idx_payload;

// ── Protocol limits ───────────────────────────────────────────────

pub const max_hops: u3 = 7;
pub const salsa20_rounds: u5 = 12;

// ── Push direct paths flags ───────────────────────────────────────

pub const push_direct_paths_flag_forget_path: u8 = 0x01;
pub const push_direct_paths_flag_cluster_redirect: u8 = 0x02;

// ── Verb ──────────────────────────────────────────────────────────

pub const Verb = enum(u5) {
    nop = 0x00,
    hello = 0x01,
    @"error" = 0x02,
    ok = 0x03,
    whois = 0x04,
    rendezvous = 0x05,
    frame = 0x06,
    ext_frame = 0x07,
    echo = 0x08,
    multicast_like = 0x09,
    network_credentials = 0x0a,
    network_config_request = 0x0b,
    network_config = 0x0c,
    multicast_gather = 0x0d,
    multicast_frame = 0x0e,
    push_direct_paths = 0x10,
    ack = 0x12,
    qos_measurement = 0x13,
    user_message = 0x14,
    remote_trace = 0x15,
    path_negotiation_request = 0x16,
    _,
};

// ── ErrorCode ─────────────────────────────────────────────────────

pub const ErrorCode = enum(u8) {
    none = 0x00,
    invalid_request = 0x01,
    bad_protocol_version = 0x02,
    obj_not_found = 0x03,
    identity_collision = 0x04,
    unsupported_operation = 0x05,
    need_membership_certificate = 0x06,
    network_access_denied = 0x07,
    unwanted_multicast = 0x08,
    network_authentication_required = 0x09,
    _,
};

// ── Verb-specific field indices ───────────────────────────────────
// These are defined relative to idx_payload (28).

pub const hello = struct {
    pub const idx_protocol_version: u32 = idx_payload;
    pub const idx_major_version: u32 = idx_protocol_version + 1;
    pub const idx_minor_version: u32 = idx_major_version + 1;
    pub const idx_revision: u32 = idx_minor_version + 1;
    pub const idx_timestamp: u32 = idx_revision + 2;
    pub const idx_identity: u32 = idx_timestamp + 8;
};

pub const error_idx = struct {
    pub const idx_in_re_verb: u32 = idx_payload;
    pub const idx_in_re_packet_id: u32 = idx_in_re_verb + 1;
    pub const idx_error_code: u32 = idx_in_re_packet_id + 8;
    pub const idx_error_payload: u32 = idx_error_code + 1;
};

pub const ok_idx = struct {
    pub const idx_in_re_verb: u32 = idx_payload;
    pub const idx_in_re_packet_id: u32 = idx_in_re_verb + 1;
    pub const idx_ok_payload: u32 = idx_in_re_packet_id + 8;
};

pub const whois_idx = struct {
    pub const idx_zt_address: u32 = idx_payload;
};

pub const rendezvous_idx = struct {
    pub const idx_flags: u32 = idx_payload;
    pub const idx_zt_address: u32 = @This().idx_flags + 1;
    pub const idx_port: u32 = idx_zt_address + 5;
    pub const idx_addrlen: u32 = idx_port + 2;
    pub const idx_address: u32 = idx_addrlen + 1;
};

pub const frame_idx = struct {
    pub const idx_network_id: u32 = idx_payload;
    pub const idx_ethertype: u32 = idx_network_id + 8;
    pub const idx_frame_payload: u32 = idx_ethertype + 2;
};

pub const ext_frame_idx = struct {
    pub const idx_network_id: u32 = idx_payload;
    pub const len_network_id: u32 = 8;
    pub const idx_flags: u32 = idx_network_id + len_network_id;
    pub const len_flags: u32 = 1;
    pub const idx_com: u32 = @This().idx_flags + len_flags;
    pub const idx_to: u32 = @This().idx_flags + len_flags;
    pub const len_to: u32 = 6;
    pub const idx_from: u32 = idx_to + len_to;
    pub const len_from: u32 = 6;
    pub const idx_ethertype: u32 = idx_from + len_from;
    pub const len_ethertype: u32 = 2;
    pub const idx_frame_payload: u32 = idx_ethertype + len_ethertype;
};

pub const network_config_request_idx = struct {
    pub const idx_network_id: u32 = idx_payload;
    pub const idx_dict_len: u32 = idx_network_id + 8;
    pub const idx_dict: u32 = idx_dict_len + 2;
};

pub const multicast_gather_idx = struct {
    pub const idx_network_id: u32 = idx_payload;
    pub const idx_flags: u32 = idx_network_id + 8;
    pub const idx_mac: u32 = @This().idx_flags + 1;
    pub const idx_adi: u32 = @This().idx_mac + 6;
    pub const idx_gather_limit: u32 = idx_adi + 4;
    pub const idx_com: u32 = idx_gather_limit + 4;
};

pub const multicast_frame_idx = struct {
    pub const idx_network_id: u32 = idx_payload;
    pub const idx_flags: u32 = idx_network_id + 8;
    pub const idx_com: u32 = @This().idx_flags + 1;
    pub const idx_gather_limit: u32 = @This().idx_flags + 1;
    pub const idx_source_mac: u32 = @This().idx_flags + 1;
    pub const idx_dest_mac: u32 = @This().idx_flags + 1;
    pub const idx_dest_adi: u32 = idx_dest_mac + 6;
    pub const idx_ethertype: u32 = idx_dest_adi + 4;
    pub const idx_frame: u32 = idx_ethertype + 2;
};

/// OK sub-indices for HELLO OK responses.
pub const hello_ok_idx = struct {
    pub const idx_timestamp: u32 = ok_idx.idx_ok_payload;
    pub const idx_protocol_version: u32 = idx_timestamp + 8;
    pub const idx_major_version: u32 = idx_protocol_version + 1;
    pub const idx_minor_version: u32 = idx_major_version + 1;
    pub const idx_revision: u32 = idx_minor_version + 1;
};

/// OK sub-indices for WHOIS OK responses.
pub const whois_ok_idx = struct {
    pub const idx_identity: u32 = ok_idx.idx_ok_payload;
};

/// OK sub-indices for NETWORK_CONFIG_REQUEST OK responses.
pub const network_config_request_ok_idx = struct {
    pub const idx_network_id: u32 = ok_idx.idx_ok_payload;
    pub const idx_dict_len: u32 = idx_network_id + 8;
    pub const idx_dict: u32 = idx_dict_len + 2;
};

/// OK sub-indices for MULTICAST_GATHER OK responses.
pub const multicast_gather_ok_idx = struct {
    pub const idx_network_id: u32 = ok_idx.idx_ok_payload;
    pub const idx_mac: u32 = idx_network_id + 8;
    pub const idx_adi: u32 = @This().idx_mac + 6;
    pub const idx_gather_results: u32 = idx_adi + 4;
};

/// OK sub-indices for MULTICAST_FRAME OK responses.
pub const multicast_frame_ok_idx = struct {
    pub const idx_network_id: u32 = ok_idx.idx_ok_payload;
    pub const idx_mac: u32 = idx_network_id + 8;
    pub const idx_adi: u32 = @This().idx_mac + 6;
    pub const idx_flags: u32 = idx_adi + 4;
    pub const idx_com_and_gather_results: u32 = @This().idx_flags + 1;
};

// ── Fragment ──────────────────────────────────────────────────────

/// A packet fragment. Fragments are sent when a packet exceeds the
/// physical MTU. The first fragment is sent with the normal Packet
/// header (with the fragmented flag set); subsequent fragments use
/// this 16-byte header.
pub const Fragment = struct {
    buf: Buffer(max_packet_length),

    pub fn initEmpty() Fragment {
        return .{ .buf = .{} };
    }

    /// Initialize a fragment from a parent packet.
    ///
    /// Copies the packet ID and destination from `pkt`, then appends
    /// the fragment header and `frag_len` bytes of payload starting
    /// at `frag_start` in the parent packet.
    pub fn initFromPacket(
        pkt: *const Packet,
        frag_start: u32,
        frag_len: u32,
        frag_no: u4,
        frag_total: u4,
    ) Buffer(max_packet_length).Error!Fragment {
        var frag = Fragment{ .buf = .{} };

        // Set size to header + payload.
        try frag.buf.setSize(min_fragment_length + frag_len);

        // Copy packet ID (8 bytes) + destination (5 bytes) = 13 bytes.
        const pkt_header = try pkt.buf.field(idx_iv, 13);
        const frag_header = try frag.buf.fieldMut(frag_idx_packet_id, 13);
        @memcpy(frag_header, pkt_header);

        // Fragment indicator, number, and hops.
        try frag.buf.setByte(frag_idx_fragment_indicator, fragment_indicator);
        try frag.buf.setByte(frag_idx_fragment_no, (@as(u8, frag_total) << 4) | @as(u8, frag_no));
        try frag.buf.setByte(frag_idx_hops, 0);

        // Copy fragment payload from parent packet.
        const src_data = try pkt.buf.field(frag_start, frag_len);
        const dst_data = try frag.buf.fieldMut(frag_idx_payload, frag_len);
        @memcpy(dst_data, src_data);

        return frag;
    }

    pub fn destination(self: *const Fragment) Address {
        const bytes = self.buf.field(frag_idx_dest, 5) catch return Address.zero();
        return Address.fromSlice(bytes);
    }

    pub fn lengthValid(self: *const Fragment) bool {
        return self.buf.size() >= min_fragment_length;
    }

    pub fn packetId(self: *const Fragment) u64 {
        return self.buf.at(u64, frag_idx_packet_id) catch 0;
    }

    pub fn totalFragments(self: *const Fragment) u4 {
        const b = self.buf.getByte(frag_idx_fragment_no) catch return 0;
        return @truncate(b >> 4);
    }

    pub fn fragmentNumber(self: *const Fragment) u4 {
        const b = self.buf.getByte(frag_idx_fragment_no) catch return 0;
        return @truncate(b & 0x0f);
    }

    pub fn hops(self: *const Fragment) u3 {
        const b = self.buf.getByte(frag_idx_hops) catch return 0;
        return @truncate(b & 0x07);
    }

    pub fn incrementHops(self: *Fragment) void {
        const b = self.buf.getByte(frag_idx_hops) catch return;
        self.buf.setByte(frag_idx_hops, (b & 0xf8) | ((b +% 1) & 0x07)) catch {};
    }

    pub fn payloadLength(self: *const Fragment) u32 {
        const sz = self.buf.size();
        return if (sz > frag_idx_payload) sz - frag_idx_payload else 0;
    }

    pub fn payload(self: *const Fragment) ?[]const u8 {
        const sz = self.buf.size();
        if (sz <= frag_idx_payload) return null;
        return self.buf.field(frag_idx_payload, sz - frag_idx_payload) catch null;
    }
};

// ── Packet ────────────────────────────────────────────────────────

/// A ZeroTier protocol packet, wrapping a Buffer of max_packet_length.
///
/// Provides header accessors, armor/dearmor (encrypt/decrypt + MAC),
/// cryptField (partial Salsa20 encryption for HELLO), and LZ4
/// compress/uncompress.
pub const Packet = struct {
    buf: Buffer(max_packet_length),

    const zero_key: [32]u8 = [_]u8{0} ** 32;

    // ── Constructors ──────────────────────────────────────────────

    /// Create an empty packet (zero-length buffer).
    pub fn initEmpty() Packet {
        return .{ .buf = .{} };
    }

    /// Create a new packet with a random IV and the given addresses/verb.
    pub fn initNew(dest: Address, src_addr: Address, verb_val: Verb) Packet {
        var pkt = Packet{ .buf = .{} };
        pkt.buf.setSize(min_packet_length) catch unreachable;

        // Random IV (8 bytes).
        var iv_slice = pkt.buf.fieldMut(idx_iv, 8) catch unreachable;
        crypto.random.bytes(iv_slice[0..8]);

        // Destination + source + flags.
        dest.toBytes(sliceToArray5(pkt.buf.fieldMut(idx_dest, 5) catch unreachable));
        src_addr.toBytes(sliceToArray5(pkt.buf.fieldMut(idx_source, 5) catch unreachable));
        pkt.buf.setByte(idx_flags, 0) catch unreachable;
        pkt.buf.setByte(idx_verb, @intFromEnum(verb_val)) catch unreachable;

        return pkt;
    }

    /// Initialize from raw data.
    pub fn initFromData(raw: []const u8) Buffer(max_packet_length).Error!Packet {
        var pkt = Packet{ .buf = .{} };
        try pkt.buf.copyFrom(raw);
        return pkt;
    }

    /// Reset this packet for reuse with a new IV, addresses, and verb.
    pub fn reset(self: *Packet, dest: Address, src_addr: Address, verb_val: Verb) void {
        self.buf.setSize(min_packet_length) catch return;
        var iv_slice = self.buf.fieldMut(idx_iv, 8) catch return;
        crypto.random.bytes(iv_slice[0..8]);
        dest.toBytes(sliceToArray5(self.buf.fieldMut(idx_dest, 5) catch return));
        src_addr.toBytes(sliceToArray5(self.buf.fieldMut(idx_source, 5) catch return));
        self.buf.setByte(idx_flags, 0) catch {};
        self.buf.setByte(idx_verb, @intFromEnum(verb_val)) catch {};
    }

    /// Generate a new random IV / packet ID.
    pub fn newInitializationVector(self: *Packet) void {
        var iv_slice = self.buf.fieldMut(idx_iv, 8) catch return;
        crypto.random.bytes(iv_slice[0..8]);
    }

    // ── Header accessors ──────────────────────────────────────────

    pub fn setDestination(self: *Packet, dest: Address) void {
        dest.toBytes(sliceToArray5(self.buf.fieldMut(idx_dest, 5) catch return));
    }

    pub fn setSource(self: *Packet, src_addr: Address) void {
        src_addr.toBytes(sliceToArray5(self.buf.fieldMut(idx_source, 5) catch return));
    }

    pub fn destination(self: *const Packet) Address {
        const bytes = self.buf.field(idx_dest, 5) catch return Address.zero();
        return Address.fromSlice(bytes);
    }

    pub fn source(self: *const Packet) Address {
        const bytes = self.buf.field(idx_source, 5) catch return Address.zero();
        return Address.fromSlice(bytes);
    }

    pub fn lengthValid(self: *const Packet) bool {
        return self.buf.size() >= min_packet_length;
    }

    pub fn fragmented(self: *const Packet) bool {
        const b = self.buf.getByte(idx_flags) catch return false;
        return (b & flag_fragmented) != 0;
    }

    pub fn setFragmented(self: *Packet, f: bool) void {
        const b = self.buf.getByte(idx_flags) catch return;
        if (f) {
            self.buf.setByte(idx_flags, b | flag_fragmented) catch {};
        } else {
            self.buf.setByte(idx_flags, b & ~flag_fragmented) catch {};
        }
    }

    pub fn extendedArmor(self: *const Packet) bool {
        const b = self.buf.getByte(idx_flags) catch return false;
        return (b & flag_extended_armor) != 0;
    }

    pub fn setExtendedArmor(self: *Packet, f: bool) void {
        const b = self.buf.getByte(idx_flags) catch return;
        if (f) {
            self.buf.setByte(idx_flags, b | flag_extended_armor) catch {};
        } else {
            self.buf.setByte(idx_flags, b & ~flag_extended_armor) catch {};
        }
    }

    pub fn compressed(self: *const Packet) bool {
        const b = self.buf.getByte(idx_verb) catch return false;
        return (b & verb_flag_compressed) != 0;
    }

    pub fn hops(self: *const Packet) u3 {
        const b = self.buf.getByte(idx_flags) catch return 0;
        return @truncate(b & 0x07);
    }

    pub fn incrementHops(self: *Packet) void {
        const b = self.buf.getByte(idx_flags) catch return;
        self.buf.setByte(idx_flags, (b & 0xf8) | ((b +% 1) & 0x07)) catch {};
    }

    pub fn cipher(self: *const Packet) CipherSuite {
        const b = self.buf.getByte(idx_flags) catch return .c25519_poly1305_none;
        const raw: u3 = @truncate((b >> 3) & 0x07);
        return @enumFromInt(raw);
    }

    pub fn isEncrypted(self: *const Packet) bool {
        const cs = self.cipher();
        return cs == .c25519_poly1305_salsa2012 or cs == .aes_gmac_siv;
    }

    pub fn setCipher(self: *Packet, cs: CipherSuite) void {
        const b = self.buf.getByte(idx_flags) catch return;
        self.buf.setByte(idx_flags, (b & 0xc7) | (@as(u8, @intFromEnum(cs)) << 3)) catch {};
    }

    pub fn trustedPathId(self: *const Packet) u64 {
        return self.buf.at(u64, idx_mac) catch 0;
    }

    pub fn setTrusted(self: *Packet, tpid: u64) void {
        self.setCipher(.no_crypto_trusted_path);
        self.buf.setAt(u64, idx_mac, tpid) catch {};
    }

    pub fn packetId(self: *const Packet) u64 {
        return self.buf.at(u64, idx_iv) catch 0;
    }

    pub fn setVerb(self: *Packet, v: Verb) void {
        self.buf.setByte(idx_verb, @intFromEnum(v)) catch {};
    }

    pub fn verb(self: *const Packet) Verb {
        const b = self.buf.getByte(idx_verb) catch return .nop;
        return @enumFromInt(@as(u5, @truncate(b & 0x1f)));
    }

    pub fn payloadLength(self: *const Packet) u32 {
        const sz = self.buf.size();
        return if (sz < min_packet_length) 0 else sz - min_packet_length;
    }

    pub fn payloadSlice(self: *const Packet) ?[]const u8 {
        const sz = self.buf.size();
        if (sz <= idx_payload) return null;
        return self.buf.field(idx_payload, sz - idx_payload) catch null;
    }

    // ── Key mangling ──────────────────────────────────────────────

    /// Derive a per-packet Salsa20 key by XOR-ing header fields into
    /// the shared secret. This gives an effective IV wider than 64 bits.
    fn salsa20MangleKey(self: *const Packet, in_key: *const [32]u8) [32]u8 {
        const d = self.buf.data();
        if (d.len < min_packet_length) return in_key.*;

        var out: [32]u8 = undefined;

        // XOR bytes 0..17 (IV + dest + source) into key.
        for (0..18) |i| {
            out[i] = in_key[i] ^ d[i];
        }

        // Flags with hops masked off (bits FFCCC000).
        out[18] = in_key[18] ^ (d[idx_flags] & 0xf8);

        // Packet size as little-endian u16.
        const sz = self.buf.size();
        out[19] = in_key[19] ^ @as(u8, @truncate(sz & 0xff));
        out[20] = in_key[20] ^ @as(u8, @truncate((sz >> 8) & 0xff));

        // Bytes 21..31 unchanged.
        @memcpy(out[21..32], in_key[21..32]);

        return out;
    }

    // ── Armor (encrypt + MAC) ─────────────────────────────────────

    /// Armor a packet for transport.
    ///
    /// - `key`: 32-byte shared secret (Salsa20/Poly1305 path)
    /// - `encrypt_payload`: if true, encrypt the payload (cipher suite 1 or 3)
    /// - `extended_armor_flag`: if true, add ephemeral ECC + AES-CTR second pass
    /// - `aes_keys`: if non-null, use AES-GMAC-SIV (cipher suite 3) when encrypting
    /// - `recipient_pub`: recipient's public key for extended armor ECDH
    pub fn armor(
        self: *Packet,
        key: *const [32]u8,
        encrypt_payload: bool,
        extended_armor_flag: bool,
        aes_keys: ?*const [2]Aes,
        recipient_pub: ?*const ecc.Public,
    ) void {
        self.setExtendedArmor(extended_armor_flag);

        if (aes_keys) |keys| {
            if (encrypt_payload) {
                self.armorAes(keys);
            } else {
                self.armorSalsa(key, encrypt_payload);
            }
        } else {
            self.armorSalsa(key, encrypt_payload);
        }

        if (extended_armor_flag) {
            self.applyExtendedArmor(recipient_pub);
        }
    }

    fn armorAes(self: *Packet, aes_keys: *const [2]Aes) void {
        self.setCipher(.aes_gmac_siv);

        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < min_packet_length) return;

        const payload_start = idx_verb;
        const payload_len = self.buf.size() - payload_start;
        const payload_slice = pkt_data[payload_start..][0..payload_len];

        var enc = aes_mod.GmacSivEncryptor.init(&aes_keys[0], &aes_keys[1]);
        const iv = mem.readInt(u64, pkt_data[idx_iv..][0..8], .little);
        enc.initEnc(iv, payload_slice.ptr);
        enc.aad(pkt_data[idx_dest..][0..11]);
        enc.update1(payload_slice);
        enc.finish1();
        enc.update2(payload_slice);
        const tag: *const [16]u8 = enc.finish2();

        // Tag bytes [0..8] → IV field, bytes [8..16] → MAC field.
        @memcpy(pkt_data[idx_iv..][0..8], tag[0..8]);
        @memcpy(pkt_data[idx_mac..][0..8], tag[8..16]);
    }

    fn armorSalsa(self: *Packet, key: *const [32]u8, encrypt_payload: bool) void {
        if (encrypt_payload) {
            self.setCipher(.c25519_poly1305_salsa2012);
        } else {
            self.setCipher(.c25519_poly1305_none);
        }

        const mangled_key = self.salsa20MangleKey(key);
        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < min_packet_length) return;

        const payload_start = idx_verb;
        const total_payload_len = self.buf.size() - payload_start;

        // Generate 32-byte Poly1305 key from first Salsa20/12 block.
        var s20 = Salsa20.init(
            &mangled_key,
            pkt_data[idx_iv..][0..8],
        );
        var mac_key: [32]u8 = undefined;
        s20.crypt12(&mac_key, &zero_key);

        // Encrypt payload if requested (continuing from block 1).
        if (encrypt_payload) {
            // Skip the rest of block 0 (32 bytes already used for mac key).
            var skip_buf: [32]u8 = undefined;
            s20.crypt12(&skip_buf, &([_]u8{0} ** 32));

            const payload = pkt_data[payload_start..][0..total_payload_len];
            s20.crypt12(payload, payload);
        }

        // Compute Poly1305 MAC over (possibly encrypted) payload.
        var mac_buf: [16]u8 = undefined;
        poly1305_mod.compute(&mac_buf, pkt_data[payload_start..][0..total_payload_len], &mac_key);

        // Store first 8 bytes of MAC.
        @memcpy(pkt_data[idx_mac..][0..8], mac_buf[0..8]);
    }

    /// Apply extended armor: ephemeral ECC keypair + AES-CTR encryption
    /// of everything from MAC field onwards.
    fn applyExtendedArmor(self: *Packet, recipient_pub: ?*const ecc.Public) void {
        const pub_key = recipient_pub orelse return;

        // Generate ephemeral keypair and derive shared secret.
        const ephemeral_kp = ecc.generate() catch return;
        var ephemeral_symmetric: [32]u8 = undefined;
        defer crypto.secureZero(u8, &ephemeral_symmetric);

        // ecc.agree uses [0..32] (X25519 portion) of both keys.
        ecc.agree(&ephemeral_kp.private_key, pub_key, &ephemeral_symmetric) catch return;

        // AES-CTR encrypt from MAC field to end of packet.
        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < idx_extended_armor_start) return;

        var aes_cipher = Aes.init(&ephemeral_symmetric);
        defer aes_cipher.deinit();
        var ctr = aes_mod.Ctr.initCtx(&aes_cipher);

        // IV for AES-CTR is derived from packet header bytes.
        var ctr_iv: [16]u8 = [_]u8{0} ** 16;
        const header_len = @min(pkt_data.len, 16);
        @memcpy(ctr_iv[0..header_len], pkt_data[0..header_len]);
        ctr.initWithIv(&ctr_iv, pkt_data[idx_extended_armor_start..].ptr);

        const encrypt_len = self.buf.size() - idx_extended_armor_start;
        ctr.crypt(pkt_data[idx_extended_armor_start..][0..encrypt_len]);
        ctr.finish();

        // Append ephemeral public key (X25519 portion, 32 bytes).
        // If this fails, the packet is incomplete and dearmor will fail
        // on the receiver — this is a fatal send error for this packet.
        self.buf.appendBytes(ephemeral_kp.public_key[0..ecc.ephemeral_public_key_len]) catch return;
    }

    // ── Dearmor (verify MAC + decrypt) ────────────────────────────

    /// Verify MAC and decrypt a packet.
    ///
    /// Returns true if the MAC is valid (and the packet is now decrypted).
    /// Returns false if the packet is invalid, MAC fails, or cipher suite
    /// is trusted path (those are handled elsewhere).
    ///
    /// - `key`: 32-byte shared secret
    /// - `aes_keys`: if non-null, these are the two keys for AES-GMAC-SIV
    /// - `identity_private`: receiver's private key for extended armor
    pub fn dearmor(
        self: *Packet,
        key: *const [32]u8,
        aes_keys: ?*const [2]Aes,
        identity_private: ?*const ecc.Private,
    ) bool {
        // Handle extended armor first (strip ephemeral key, AES-CTR decrypt).
        if (self.extendedArmor() and
            self.cipher() == .c25519_poly1305_none)
        {
            if (!self.removeExtendedArmor(identity_private)) return false;
        }

        const cs = self.cipher();

        if (cs == .aes_gmac_siv) {
            return self.dearmorAes(aes_keys);
        } else if (cs == .c25519_poly1305_none or cs == .c25519_poly1305_salsa2012) {
            return self.dearmorSalsa(key, cs);
        }

        return false;
    }

    fn removeExtendedArmor(self: *Packet, identity_private: ?*const ecc.Private) bool {
        const priv_key = identity_private orelse return false;
        const min_extended_size = idx_verb + 1 + ecc.ephemeral_public_key_len;
        if (self.buf.size() < min_extended_size) return false;

        const pkt_data = self.buf.dataMut();
        const pkt_size = self.buf.size();

        // Extract ephemeral public key from end of packet.
        const eph_start = pkt_size - ecc.ephemeral_public_key_len;
        var eph_pub: ecc.Public = [_]u8{0} ** 64;
        @memcpy(eph_pub[0..32], pkt_data[eph_start..][0..32]);

        // Derive shared secret.
        var ephemeral_symmetric: [32]u8 = undefined;
        defer crypto.secureZero(u8, &ephemeral_symmetric);
        ecc.agree(priv_key, &eph_pub, &ephemeral_symmetric) catch return false;

        // AES-CTR decrypt from MAC field to before ephemeral key.
        var aes_cipher = Aes.init(&ephemeral_symmetric);
        defer aes_cipher.deinit();
        var ctr = aes_mod.Ctr.initCtx(&aes_cipher);

        var ctr_iv: [16]u8 = [_]u8{0} ** 16;
        const header_len = @min(pkt_data.len, 16);
        @memcpy(ctr_iv[0..header_len], pkt_data[0..header_len]);
        ctr.initWithIv(&ctr_iv, pkt_data[idx_extended_armor_start..].ptr);

        const decrypt_len = eph_start - idx_extended_armor_start;
        ctr.crypt(pkt_data[idx_extended_armor_start..][0..decrypt_len]);
        ctr.finish();

        // Remove ephemeral key from packet.
        self.buf.setSize(eph_start) catch return false;
        return true;
    }

    fn dearmorAes(self: *Packet, aes_keys: ?*const [2]Aes) bool {
        const keys = aes_keys orelse return false;

        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < min_packet_length) return false;

        const payload_start = idx_verb;
        const payload_len = self.buf.size() - payload_start;

        // Reconstruct the 16-byte tag from IV and MAC fields.
        var tag: [16]u8 = undefined;
        @memcpy(tag[0..8], pkt_data[idx_iv..][0..8]);
        @memcpy(tag[8..16], pkt_data[idx_mac..][0..8]);

        var dec = aes_mod.GmacSivDecryptor.init(&keys[0], &keys[1]);
        dec.initDec(&tag, pkt_data[payload_start..].ptr);

        // AAD is dest(5) + source(5) + flags(1) with hops masked.
        // Temporarily mask hops for AAD computation.
        const old_flags = pkt_data[idx_flags];
        pkt_data[idx_flags] &= 0xf8;
        dec.aad(pkt_data[idx_dest..][0..11]);
        pkt_data[idx_flags] = old_flags;

        dec.update(pkt_data[payload_start..][0..payload_len]);
        return dec.finish();
    }

    fn dearmorSalsa(self: *Packet, key: *const [32]u8, cs: CipherSuite) bool {
        const mangled_key = self.salsa20MangleKey(key);
        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < min_packet_length) return false;

        const payload_start = idx_verb;
        const payload_len = self.buf.size() - payload_start;

        // Generate Poly1305 MAC key.
        var s20 = Salsa20.init(&mangled_key, pkt_data[idx_iv..][0..8]);
        var mac_key: [32]u8 = undefined;
        s20.crypt12(&mac_key, &zero_key);

        // Verify MAC against (still-encrypted) payload.
        var computed_mac: [16]u8 = undefined;
        poly1305_mod.compute(&computed_mac, pkt_data[payload_start..][0..payload_len], &mac_key);

        // Compare first 8 bytes of MAC (constant-time).
        const stored_mac = pkt_data[idx_mac..][0..8];
        if (!constantTimeEql8(stored_mac, computed_mac[0..8])) {
            return false;
        }

        // Decrypt if cipher suite 1.
        if (cs == .c25519_poly1305_salsa2012) {
            // Skip remainder of first Salsa20 block (32 bytes used for MAC key).
            var skip_buf: [32]u8 = undefined;
            s20.crypt12(&skip_buf, &([_]u8{0} ** 32));

            const payload = pkt_data[payload_start..][0..payload_len];
            s20.crypt12(payload, payload);
        }

        return true;
    }

    // ── cryptField ────────────────────────────────────────────────

    /// Encrypt/decrypt a sub-region of the packet with Salsa20/12.
    ///
    /// Used to mask portions of HELLO. Must NOT be called more than once
    /// per packet (same keystream would be reused).
    pub fn cryptField(self: *Packet, key: *const [32]u8, start: u32, len: u32) void {
        const pkt_data = self.buf.dataMut();
        if (pkt_data.len < start + len) return;
        if (pkt_data.len < 8) return;

        // IV is the packet's first 8 bytes with the lowest 3 bits masked off.
        var iv: [8]u8 = undefined;
        @memcpy(&iv, pkt_data[0..8]);
        iv[7] &= 0xf8;

        var s20 = Salsa20.init(key, &iv);
        const region = pkt_data[start..][0..len];
        s20.crypt12(region, region);
    }

    // ── Compression ───────────────────────────────────────────────

    /// Compress the payload with LZ4 if it reduces size.
    ///
    /// Sets the compressed verb flag if compression succeeds.
    /// Returns true if compression was applied.
    pub fn compress(self: *Packet) bool {
        if (self.compressed()) return false;
        if (self.buf.size() <= idx_payload + 64) return false;

        const pkt_data = self.buf.dataMut();
        const payload_len = self.buf.size() - idx_payload;

        var comp_buf: [max_packet_length * 2]u8 = undefined;
        const comp_len = lz4.compressBlock(
            pkt_data[idx_payload..][0..payload_len],
            &comp_buf,
        ) orelse {
            // Compression failed or didn't reduce size.
            const verb_byte = pkt_data[idx_verb];
            pkt_data[idx_verb] = verb_byte & ~verb_flag_compressed;
            return false;
        };

        if (comp_len >= payload_len) {
            // No size reduction.
            const verb_byte = pkt_data[idx_verb];
            pkt_data[idx_verb] = verb_byte & ~verb_flag_compressed;
            return false;
        }

        // Set compressed flag and copy compressed data.
        pkt_data[idx_verb] |= verb_flag_compressed;
        self.buf.setSize(@intCast(comp_len + idx_payload)) catch return false;
        @memcpy(pkt_data[idx_payload..][0..comp_len], comp_buf[0..comp_len]);
        return true;
    }

    /// Decompress the payload if the compressed flag is set.
    ///
    /// Returns true if data is now decompressed and valid.
    /// Returns false on decompression error.
    pub fn uncompress(self: *Packet) bool {
        if (!self.compressed()) return true;
        if (self.buf.size() < min_packet_length) return true;

        if (self.buf.size() <= idx_payload) {
            // Nothing to decompress, just clear the flag.
            const pkt_data = self.buf.dataMut();
            pkt_data[idx_verb] &= ~verb_flag_compressed;
            return true;
        }

        const pkt_data = self.buf.dataMut();
        const comp_len = self.buf.size() - idx_payload;

        var decomp_buf: [max_packet_length]u8 = undefined;
        const ucl = lz4.decompressSafe(
            pkt_data[idx_payload..][0..comp_len],
            &decomp_buf,
        ) orelse return false;

        const ucl32: u32 = std.math.cast(u32, ucl) orelse return false;
        if (ucl32 > max_packet_length - idx_payload) return false;

        self.buf.setSize(ucl32 + idx_payload) catch return false;

        // Re-fetch dataMut after setSize (pointer is the same, but semantics).
        const updated_data = self.buf.dataMut();
        @memcpy(updated_data[idx_payload..][0..ucl32], decomp_buf[0..ucl32]);
        updated_data[idx_verb] &= ~verb_flag_compressed;
        return true;
    }
};

// ── Helpers ───────────────────────────────────────────────────────

fn sliceToArray5(s: []u8) *[5]u8 {
    return s[0..5];
}

/// Constant-time comparison of two 8-byte slices.
fn constantTimeEql8(a: *const [8]u8, b: *const [8]u8) bool {
    var diff: u8 = 0;
    for (0..8) |i| {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}

// ── Tests ─────────────────────────────────────────────────────────

test "Packet: protocol constants" {
    try testing.expectEqual(@as(u32, 10024), max_packet_length);
    try testing.expectEqual(@as(u32, 28), min_packet_length);
    try testing.expectEqual(@as(u32, 16), min_fragment_length);
}

test "Packet: verb enum values" {
    try testing.expectEqual(@as(u5, 0x00), @intFromEnum(Verb.nop));
    try testing.expectEqual(@as(u5, 0x01), @intFromEnum(Verb.hello));
    try testing.expectEqual(@as(u5, 0x02), @intFromEnum(Verb.@"error"));
    try testing.expectEqual(@as(u5, 0x03), @intFromEnum(Verb.ok));
    try testing.expectEqual(@as(u5, 0x04), @intFromEnum(Verb.whois));
    try testing.expectEqual(@as(u5, 0x06), @intFromEnum(Verb.frame));
    try testing.expectEqual(@as(u5, 0x07), @intFromEnum(Verb.ext_frame));
    try testing.expectEqual(@as(u5, 0x08), @intFromEnum(Verb.echo));
    try testing.expectEqual(@as(u5, 0x10), @intFromEnum(Verb.push_direct_paths));
    try testing.expectEqual(@as(u5, 0x16), @intFromEnum(Verb.path_negotiation_request));
}

test "Packet: error code enum values" {
    try testing.expectEqual(@as(u8, 0x00), @intFromEnum(ErrorCode.none));
    try testing.expectEqual(@as(u8, 0x09), @intFromEnum(ErrorCode.network_authentication_required));
}

test "Packet: header field indices" {
    try testing.expectEqual(@as(u32, 0), idx_iv);
    try testing.expectEqual(@as(u32, 8), idx_dest);
    try testing.expectEqual(@as(u32, 13), idx_source);
    try testing.expectEqual(@as(u32, 18), idx_flags);
    try testing.expectEqual(@as(u32, 19), idx_mac);
    try testing.expectEqual(@as(u32, 27), idx_verb);
    try testing.expectEqual(@as(u32, 28), idx_payload);
}

test "Packet: verb-specific field indices match C++" {
    // HELLO
    try testing.expectEqual(@as(u32, 28), hello.idx_protocol_version);
    try testing.expectEqual(@as(u32, 29), hello.idx_major_version);
    try testing.expectEqual(@as(u32, 30), hello.idx_minor_version);
    try testing.expectEqual(@as(u32, 31), hello.idx_revision);
    try testing.expectEqual(@as(u32, 33), hello.idx_timestamp);
    try testing.expectEqual(@as(u32, 41), hello.idx_identity);

    // ERROR
    try testing.expectEqual(@as(u32, 28), error_idx.idx_in_re_verb);
    try testing.expectEqual(@as(u32, 29), error_idx.idx_in_re_packet_id);
    try testing.expectEqual(@as(u32, 37), error_idx.idx_error_code);
    try testing.expectEqual(@as(u32, 38), error_idx.idx_error_payload);

    // OK
    try testing.expectEqual(@as(u32, 28), ok_idx.idx_in_re_verb);
    try testing.expectEqual(@as(u32, 29), ok_idx.idx_in_re_packet_id);
    try testing.expectEqual(@as(u32, 37), ok_idx.idx_ok_payload);
}

test "Packet: fragment field indices" {
    try testing.expectEqual(@as(u32, 0), frag_idx_packet_id);
    try testing.expectEqual(@as(u32, 8), frag_idx_dest);
    try testing.expectEqual(@as(u32, 13), frag_idx_fragment_indicator);
    try testing.expectEqual(@as(u32, 14), frag_idx_fragment_no);
    try testing.expectEqual(@as(u32, 15), frag_idx_hops);
    try testing.expectEqual(@as(u32, 16), frag_idx_payload);
}

test "Packet: initNew and header accessors" {
    const dest = Address.init(0xdeadbeef01);
    const src = Address.init(0x1234567890);

    var pkt = Packet.initNew(dest, src, .hello);
    try testing.expect(pkt.lengthValid());
    try testing.expect(pkt.destination().eql(dest));
    try testing.expect(pkt.source().eql(src));
    try testing.expectEqual(Verb.hello, pkt.verb());
    try testing.expectEqual(@as(u3, 0), pkt.hops());
    try testing.expect(!pkt.fragmented());
    try testing.expect(!pkt.extendedArmor());
    try testing.expect(!pkt.compressed());
}

test "Packet: set/get cipher suite" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);

    pkt.setCipher(.aes_gmac_siv);
    try testing.expectEqual(CipherSuite.aes_gmac_siv, pkt.cipher());

    pkt.setCipher(.c25519_poly1305_salsa2012);
    try testing.expectEqual(CipherSuite.c25519_poly1305_salsa2012, pkt.cipher());

    pkt.setCipher(.no_crypto_trusted_path);
    try testing.expectEqual(CipherSuite.no_crypto_trusted_path, pkt.cipher());
}

test "Packet: increment hops" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);
    try testing.expectEqual(@as(u3, 0), pkt.hops());

    pkt.incrementHops();
    try testing.expectEqual(@as(u3, 1), pkt.hops());

    pkt.incrementHops();
    try testing.expectEqual(@as(u3, 2), pkt.hops());

    // Incrementing should not clobber other flag bits.
    pkt.setFragmented(true);
    pkt.incrementHops();
    try testing.expectEqual(@as(u3, 3), pkt.hops());
    try testing.expect(pkt.fragmented());
}

test "Packet: set/get fragmented and extended armor flags" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);

    pkt.setFragmented(true);
    try testing.expect(pkt.fragmented());
    try testing.expect(!pkt.extendedArmor());

    pkt.setExtendedArmor(true);
    try testing.expect(pkt.fragmented());
    try testing.expect(pkt.extendedArmor());

    pkt.setFragmented(false);
    try testing.expect(!pkt.fragmented());
    try testing.expect(pkt.extendedArmor());
}

test "Packet: trusted path" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);
    const tpid: u64 = 0x1122334455667788;
    pkt.setTrusted(tpid);
    try testing.expectEqual(CipherSuite.no_crypto_trusted_path, pkt.cipher());
    try testing.expectEqual(tpid, pkt.trustedPathId());
}

test "Packet: salsa20MangleKey" {
    // Build a packet with known header bytes.
    var pkt = Packet{ .buf = .{} };
    pkt.buf.setSize(min_packet_length) catch unreachable;
    const d = pkt.buf.dataMut();

    // Set known header: IV (8) + dest (5) + source (5) = 18 bytes.
    for (0..18) |i| {
        d[i] = @truncate(i + 1);
    }
    // Flags byte (idx_flags = 18): FFCCCHHH. Set to 0xA8 (flags=10, cipher=5, hops=0).
    d[idx_flags] = 0xA8;
    // Verb byte.
    d[idx_verb] = 0x01;

    const key: [32]u8 = [_]u8{0xff} ** 32;
    const mangled = pkt.salsa20MangleKey(&key);

    // Bytes 0..17: key XOR header.
    for (0..18) |i| {
        try testing.expectEqual(0xff ^ @as(u8, @truncate(i + 1)), mangled[i]);
    }
    // Byte 18: key[18] XOR (flags & 0xf8) = 0xff XOR 0xA8 = 0x57.
    try testing.expectEqual(@as(u8, 0xff ^ 0xa8), mangled[18]);
    // Byte 19: key[19] XOR (size & 0xff) = 0xff XOR 28 = 0xe3.
    try testing.expectEqual(@as(u8, 0xff ^ 28), mangled[19]);
    // Byte 20: key[20] XOR ((size >> 8) & 0xff) = 0xff XOR 0 = 0xff.
    try testing.expectEqual(@as(u8, 0xff), mangled[20]);
    // Bytes 21..31: unchanged.
    for (21..32) |i| {
        try testing.expectEqual(@as(u8, 0xff), mangled[i]);
    }
}

test "Packet: armor/dearmor Salsa20+Poly1305 (no encryption)" {
    const key: [32]u8 = [_]u8{0x42} ** 32;

    var pkt = Packet.initNew(Address.init(0x1234567890), Address.init(0x0987654321), .hello);
    // Append some payload.
    try pkt.buf.appendBytes("Hello, ZeroTier!");

    // Save original payload for comparison.
    const orig_verb = pkt.buf.getByte(idx_verb) catch unreachable;
    var orig_payload: [16]u8 = undefined;
    @memcpy(&orig_payload, (pkt.buf.field(idx_payload, 16) catch unreachable)[0..16]);

    pkt.armor(&key, false, false, null, null);
    try testing.expectEqual(CipherSuite.c25519_poly1305_none, pkt.cipher());

    // Payload should still be readable (not encrypted).
    const post_verb = pkt.buf.getByte(idx_verb) catch unreachable;
    try testing.expectEqual(orig_verb, post_verb);

    // Dearmor should succeed.
    try testing.expect(pkt.dearmor(&key, null, null));

    // Payload unchanged after dearmor.
    const final_payload = pkt.buf.field(idx_payload, 16) catch unreachable;
    try testing.expectEqualSlices(u8, &orig_payload, final_payload[0..16]);
}

test "Packet: armor/dearmor Salsa20+Poly1305 (with encryption)" {
    const key: [32]u8 = [_]u8{0x37} ** 32;

    var pkt = Packet.initNew(Address.init(0xaabbccddee), Address.init(0x1122334455), .frame);
    try pkt.buf.appendBytes("Secret payload data!!");

    var orig_payload: [21]u8 = undefined;
    @memcpy(&orig_payload, (pkt.buf.field(idx_payload, 21) catch unreachable)[0..21]);

    pkt.armor(&key, true, false, null, null);
    try testing.expectEqual(CipherSuite.c25519_poly1305_salsa2012, pkt.cipher());

    // Payload should now be different (encrypted).
    const enc_payload = pkt.buf.field(idx_payload, 21) catch unreachable;
    try testing.expect(!mem.eql(u8, &orig_payload, enc_payload[0..21]));

    // Dearmor should succeed and recover original payload.
    try testing.expect(pkt.dearmor(&key, null, null));
    const dec_payload = pkt.buf.field(idx_payload, 21) catch unreachable;
    try testing.expectEqualSlices(u8, &orig_payload, dec_payload[0..21]);
}

test "Packet: dearmor rejects wrong key" {
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const wrong_key: [32]u8 = [_]u8{0x99} ** 32;

    var pkt = Packet.initNew(Address.init(1), Address.init(2), .hello);
    try pkt.buf.appendBytes("test payload");

    pkt.armor(&key, false, false, null, null);
    try testing.expect(!pkt.dearmor(&wrong_key, null, null));
}

test "Packet: armor/dearmor with AES-GMAC-SIV" {
    const key0_bytes: [32]u8 = [_]u8{0x10} ** 32;
    const key1_bytes: [32]u8 = [_]u8{0x20} ** 32;
    const aes_keys = [2]Aes{ Aes.init(&key0_bytes), Aes.init(&key1_bytes) };

    var pkt = Packet.initNew(Address.init(0xaabbccddee), Address.init(0x1122334455), .frame);
    try pkt.buf.appendBytes("AES-encrypted payload");

    var orig_payload: [21]u8 = undefined;
    @memcpy(&orig_payload, (pkt.buf.field(idx_payload, 21) catch unreachable)[0..21]);

    pkt.armor(&([_]u8{0} ** 32), true, false, &aes_keys, null);
    try testing.expectEqual(CipherSuite.aes_gmac_siv, pkt.cipher());

    // Dearmor with AES should succeed.
    try testing.expect(pkt.dearmor(&([_]u8{0} ** 32), &aes_keys, null));

    const dec_payload = pkt.buf.field(idx_payload, 21) catch unreachable;
    try testing.expectEqualSlices(u8, &orig_payload, dec_payload[0..21]);
}

test "Packet: cryptField round-trip" {
    const key: [32]u8 = [_]u8{0xab} ** 32;

    var pkt = Packet.initNew(Address.init(1), Address.init(2), .hello);
    try pkt.buf.appendBytes("plaintext region here");

    var orig: [10]u8 = undefined;
    @memcpy(&orig, (pkt.buf.field(idx_payload, 10) catch unreachable)[0..10]);

    // Encrypt a 10-byte region starting at idx_payload.
    pkt.cryptField(&key, idx_payload, 10);

    // Should be different now.
    const enc = pkt.buf.field(idx_payload, 10) catch unreachable;
    try testing.expect(!mem.eql(u8, &orig, enc[0..10]));

    // Decrypt (cryptField is symmetric).
    pkt.cryptField(&key, idx_payload, 10);
    const dec = pkt.buf.field(idx_payload, 10) catch unreachable;
    try testing.expectEqualSlices(u8, &orig, dec[0..10]);
}

test "Packet: compress/uncompress round-trip" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .frame);

    // Append highly compressible payload (> 64 bytes required).
    var payload: [200]u8 = [_]u8{0x41} ** 200;
    // Add some variation.
    for (0..200) |i| {
        payload[i] = @truncate(i % 3);
    }
    try pkt.buf.appendBytes(&payload);

    const orig_size = pkt.buf.size();

    // Compress.
    const did_compress = pkt.compress();
    // The payload may or may not compress — depends on compressibility.
    if (did_compress) {
        try testing.expect(pkt.compressed());
        try testing.expect(pkt.buf.size() < orig_size);

        // Uncompress.
        try testing.expect(pkt.uncompress());
        try testing.expect(!pkt.compressed());
        try testing.expectEqual(orig_size, pkt.buf.size());

        // Verify payload matches.
        const final_payload = pkt.buf.field(idx_payload, 200) catch unreachable;
        try testing.expectEqualSlices(u8, &payload, final_payload[0..200]);
    }
}

test "Packet: uncompress with no compression is no-op" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);
    try testing.expect(!pkt.compressed());
    try testing.expect(pkt.uncompress());
}

test "Fragment: initFromPacket and accessors" {
    var pkt = Packet.initNew(Address.init(0xdeadbeef01), Address.init(0x1234567890), .frame);
    try pkt.buf.appendBytes("some payload data here");

    const frag = Fragment.initFromPacket(&pkt, idx_payload, 10, 1, 3) catch unreachable;

    try testing.expect(frag.lengthValid());
    try testing.expect(frag.destination().eql(Address.init(0xdeadbeef01)));
    try testing.expectEqual(frag.packetId(), pkt.packetId());
    try testing.expectEqual(@as(u4, 3), frag.totalFragments());
    try testing.expectEqual(@as(u4, 1), frag.fragmentNumber());
    try testing.expectEqual(@as(u3, 0), frag.hops());
    try testing.expectEqual(@as(u32, 10), frag.payloadLength());
}

test "Fragment: increment hops wraps at 7" {
    var frag = Fragment.initEmpty();
    frag.buf.setSize(min_fragment_length) catch unreachable;
    frag.buf.setByte(frag_idx_hops, 0) catch unreachable;

    for (0..7) |_| {
        frag.incrementHops();
    }
    try testing.expectEqual(@as(u3, 7), frag.hops());

    frag.incrementHops();
    try testing.expectEqual(@as(u3, 0), frag.hops());
}

test "Packet: reset reuses buffer" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .hello);
    try pkt.buf.appendBytes("some data");

    const old_size = pkt.buf.size();
    try testing.expect(old_size > min_packet_length);

    pkt.reset(Address.init(3), Address.init(4), .frame);
    try testing.expectEqual(min_packet_length, pkt.buf.size());
    try testing.expect(pkt.destination().eql(Address.init(3)));
    try testing.expect(pkt.source().eql(Address.init(4)));
    try testing.expectEqual(Verb.frame, pkt.verb());
}

test "Packet: cipher suite preserves flags and hops" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);

    // Set flags and hops.
    pkt.setFragmented(true);
    pkt.setExtendedArmor(true);
    pkt.incrementHops();
    pkt.incrementHops();

    // Set cipher.
    pkt.setCipher(.aes_gmac_siv);

    // Verify everything is preserved.
    try testing.expect(pkt.fragmented());
    try testing.expect(pkt.extendedArmor());
    try testing.expectEqual(@as(u3, 2), pkt.hops());
    try testing.expectEqual(CipherSuite.aes_gmac_siv, pkt.cipher());
}

test "Packet: isEncrypted" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);

    pkt.setCipher(.c25519_poly1305_none);
    try testing.expect(!pkt.isEncrypted());

    pkt.setCipher(.c25519_poly1305_salsa2012);
    try testing.expect(pkt.isEncrypted());

    pkt.setCipher(.no_crypto_trusted_path);
    try testing.expect(!pkt.isEncrypted());

    pkt.setCipher(.aes_gmac_siv);
    try testing.expect(pkt.isEncrypted());
}

test "Packet: armor Salsa MAC-only then dearmor AES rejects" {
    const key: [32]u8 = [_]u8{0x55} ** 32;
    const aes_k0: [32]u8 = [_]u8{0x10} ** 32;
    const aes_k1: [32]u8 = [_]u8{0x20} ** 32;
    const aes_keys = [2]Aes{ Aes.init(&aes_k0), Aes.init(&aes_k1) };

    var pkt = Packet.initNew(Address.init(1), Address.init(2), .hello);
    try pkt.buf.appendBytes("payload");

    // Armor with Salsa.
    pkt.armor(&key, false, false, null, null);

    // Manually set cipher to AES to simulate mismatch.
    pkt.setCipher(.aes_gmac_siv);

    // Dearmor with AES keys should fail (tag won't match).
    try testing.expect(!pkt.dearmor(&key, &aes_keys, null));
}

test "Packet: compress small payload does not compress" {
    var pkt = Packet.initNew(Address.init(1), Address.init(2), .nop);
    try pkt.buf.appendBytes("tiny");

    // Payload < 64 bytes, should not compress.
    try testing.expect(!pkt.compress());
    try testing.expect(!pkt.compressed());
}

test "Packet: multiple armor/dearmor cycles" {
    const key: [32]u8 = [_]u8{0x77} ** 32;

    var pkt = Packet.initNew(Address.init(0xaabbccddee), Address.init(0x1122334455), .echo);
    try pkt.buf.appendBytes("persistent payload data");

    var orig_payload: [23]u8 = undefined;
    @memcpy(&orig_payload, (pkt.buf.field(idx_payload, 23) catch unreachable)[0..23]);

    // Cycle 1: encrypt.
    pkt.armor(&key, true, false, null, null);
    try testing.expect(pkt.dearmor(&key, null, null));
    var dec1 = pkt.buf.field(idx_payload, 23) catch unreachable;
    try testing.expectEqualSlices(u8, &orig_payload, dec1[0..23]);

    // Cycle 2: new IV, encrypt again.
    pkt.newInitializationVector();
    pkt.armor(&key, true, false, null, null);
    try testing.expect(pkt.dearmor(&key, null, null));
    dec1 = pkt.buf.field(idx_payload, 23) catch unreachable;
    try testing.expectEqualSlices(u8, &orig_payload, dec1[0..23]);
}
