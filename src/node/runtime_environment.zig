/// Global state holder for an instance of a ZeroTier node.
///
/// Converted from `node/RuntimeEnvironment.hpp`. This is a simple aggregate
/// struct that holds pointers to all major subsystem objects. During transition,
/// subsystem types that haven't been converted yet are represented as opaque
/// types. The pointers are filled in during Node initialization and are constant
/// after startup unless noted otherwise.
///
/// No heap allocation is performed by this struct itself; it merely holds
/// references owned elsewhere.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const Identity = @import("identity.zig").Identity;

// ── Opaque subsystem types ────────────────────────────────────────
//
// These will be replaced with concrete Zig types as conversion progresses
// through Phases 4–6. For now they allow typed pointers that prevent
// accidental misuse.

pub const Node = opaque {};
pub const Switch = opaque {};
pub const Topology = opaque {};
pub const Multicaster = opaque {};
pub const SelfAwareness = opaque {};
pub const Trace = opaque {};
pub const Bond = opaque {};
pub const PacketMultiplexer = opaque {};
pub const NetworkController = opaque {};

// ── Constants ─────────────────────────────────────────────────────

/// Buffer length for identity string representations.
/// Matches `ZT_IDENTITY_STRING_BUFFER_LENGTH` (384) in Identity.hpp.
pub const identity_string_buffer_length: u32 = @import("identity.zig").string_buffer_length;

// ── RuntimeEnvironment ────────────────────────────────────────────

/// Holds global state for an instance of ZeroTier::Node.
///
/// All pointer fields are optional — they are null until the owning Node
/// initializes them. After startup, the subsystem pointers are constant
/// and non-null.
pub const RuntimeEnvironment = struct {
    /// Node instance that owns this RuntimeEnvironment.
    node: ?*Node,

    /// External network controller implementation (set externally).
    local_network_controller: ?*NetworkController,

    /// Memory occupied by Trace, Switch, etc. (raw allocation handle).
    rtmem: ?*anyopaque,

    // -- Subsystem pointers (construction order matters in C++; here
    //    they are all optional and filled in during init) --

    /// Trace / remote tracing handler.
    t: ?*Trace,

    /// Packet switch / forwarding engine.
    sw: ?*Switch,

    /// Multicast propagation engine.
    mc: ?*Multicaster,

    /// Peer and root topology manager.
    topology: ?*Topology,

    /// Self-awareness (external address detection).
    sa: ?*SelfAwareness,

    /// Bonding / link aggregation controller.
    bc: ?*Bond,

    /// Packet multiplexer for concurrent processing.
    pm: ?*PacketMultiplexer,

    // -- Identity and string representations --

    /// This node's identity (address + key pairs).
    identity: Identity,

    /// Public identity as a null-terminated ASCII string.
    public_identity_str: [identity_string_buffer_length]u8,

    /// Secret identity as a null-terminated ASCII string.
    /// Securely zeroed on deinit.
    secret_identity_str: [identity_string_buffer_length]u8,

    // ── Constructor ───────────────────────────────────────

    /// Create a new RuntimeEnvironment with the given owning Node.
    ///
    /// All subsystem pointers are null. Identity strings are empty.
    pub fn init(owning_node: ?*Node) RuntimeEnvironment {
        var re: RuntimeEnvironment = .{
            .node = owning_node,
            .local_network_controller = null,
            .rtmem = null,
            .t = null,
            .sw = null,
            .mc = null,
            .topology = null,
            .sa = null,
            .bc = null,
            .pm = null,
            .identity = Identity.init(),
            .public_identity_str = [_]u8{0} ** identity_string_buffer_length,
            .secret_identity_str = [_]u8{0} ** identity_string_buffer_length,
        };
        _ = &re;
        return re;
    }

    /// Clean up sensitive data.
    ///
    /// Securely zeros the secret identity string to prevent it from
    /// lingering in memory. Mirrors the C++ destructor behavior.
    pub fn deinit(self: *RuntimeEnvironment) void {
        std.crypto.secureZero(u8, &self.secret_identity_str);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "RuntimeEnvironment: init creates null state" {
    var re = RuntimeEnvironment.init(null);
    defer re.deinit();

    try testing.expect(re.node == null);
    try testing.expect(re.local_network_controller == null);
    try testing.expect(re.rtmem == null);
    try testing.expect(re.t == null);
    try testing.expect(re.sw == null);
    try testing.expect(re.mc == null);
    try testing.expect(re.topology == null);
    try testing.expect(re.sa == null);
    try testing.expect(re.bc == null);
    try testing.expect(re.pm == null);
    try testing.expect(!re.identity.isSet());
    try testing.expectEqual(@as(u8, 0), re.public_identity_str[0]);
    try testing.expectEqual(@as(u8, 0), re.secret_identity_str[0]);
}

test "RuntimeEnvironment: deinit zeros secret identity" {
    var re = RuntimeEnvironment.init(null);

    // Write some recognizable data into the secret identity string
    const test_secret = "this-is-a-secret-identity-string";
    @memcpy(re.secret_identity_str[0..test_secret.len], test_secret);

    // Verify it's there
    try testing.expect(re.secret_identity_str[0] != 0);

    // deinit should zero it
    re.deinit();

    // Verify all bytes are zero
    for (re.secret_identity_str) |b| {
        try testing.expectEqual(@as(u8, 0), b);
    }
}

test "RuntimeEnvironment: identity string buffer length matches" {
    try testing.expectEqual(@as(u32, 384), identity_string_buffer_length);
}
