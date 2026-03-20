/// Interface for network controller implementations.
///
/// Converted from `node/NetworkController.hpp`. This is a pure virtual
/// interface in C++ — in Zig it becomes a struct of function pointers
/// (vtable pattern). Network controllers handle network configuration
/// requests and send configuration pushes, revocations, and errors.
///
/// No heap allocation is performed by this module.
const std = @import("std");
const testing = std.testing;

const Address = @import("address.zig").Address;
const Identity = @import("identity.zig").Identity;
const InetAddress = @import("inet_address.zig").InetAddress;
const Revocation = @import("revocation.zig").Revocation;
// NetworkConfig forward reference — uses an opaque type during transition.
// Will be replaced with the concrete type once network_config.zig is available.
const NetworkConfig = @import("network_config.zig").NetworkConfig;
const Dictionary = @import("dictionary.zig").Dictionary;

// ── Constants ─────────────────────────────────────────────────────

/// Dictionary capacity needed for network config metadata.
/// Matches `ZT_NETWORKCONFIG_METADATA_DICT_CAPACITY` (1024).
pub const metadata_dict_capacity: u32 = 1024;

// ── Error codes ───────────────────────────────────────────────────

/// Error codes returned by network controller operations.
pub const ErrorCode = enum(u8) {
    /// No error.
    none = 0,
    /// Requested object was not found.
    object_not_found = 1,
    /// Access denied.
    access_denied = 2,
    /// Internal server error.
    internal_server_error = 3,
    /// Authentication is required (SSO flow).
    authentication_required = 4,
};

// ── Sender interface ──────────────────────────────────────────────

/// Interface for sending configuration replies and pushes.
///
/// Implementations are provided by the node's Switch subsystem.
pub const Sender = struct {
    /// Opaque context pointer (BORROWED — owned by the caller).
    context: *anyopaque,

    /// Send a configuration to a remote peer.
    ///
    /// - `nwid`: Network ID.
    /// - `request_packet_id`: Packet ID of the request, or 0 for a push.
    /// - `destination`: Destination peer address.
    /// - `nc`: Network configuration to send.
    /// - `send_legacy`: If true, send old-format network config.
    send_config_fn: *const fn (
        context: *anyopaque,
        nwid: u64,
        request_packet_id: u64,
        destination: Address,
        nc: *const NetworkConfig,
        send_legacy: bool,
    ) void,

    /// Send a revocation to a node.
    ///
    /// - `destination`: Destination node address.
    /// - `rev`: Revocation to send.
    send_revocation_fn: *const fn (
        context: *anyopaque,
        destination: Address,
        rev: *const Revocation,
    ) void,

    /// Send a network configuration request error.
    ///
    /// - `nwid`: Network ID.
    /// - `request_packet_id`: Request packet ID or 0.
    /// - `destination`: Destination peer address.
    /// - `error_code`: Error code.
    /// - `error_data`: Optional error data bytes (may be empty).
    send_error_fn: *const fn (
        context: *anyopaque,
        nwid: u64,
        request_packet_id: u64,
        destination: Address,
        error_code: ErrorCode,
        error_data: []const u8,
    ) void,

    // ── Convenience wrappers ──────────────────────────────

    pub fn sendConfig(
        self: *const Sender,
        nwid: u64,
        request_packet_id: u64,
        destination: Address,
        nc: *const NetworkConfig,
        send_legacy: bool,
    ) void {
        self.send_config_fn(
            self.context,
            nwid,
            request_packet_id,
            destination,
            nc,
            send_legacy,
        );
    }

    pub fn sendRevocation(
        self: *const Sender,
        destination: Address,
        rev: *const Revocation,
    ) void {
        self.send_revocation_fn(self.context, destination, rev);
    }

    pub fn sendError(
        self: *const Sender,
        nwid: u64,
        request_packet_id: u64,
        destination: Address,
        error_code: ErrorCode,
        error_data: []const u8,
    ) void {
        self.send_error_fn(
            self.context,
            nwid,
            request_packet_id,
            destination,
            error_code,
            error_data,
        );
    }
};

// ── NetworkController interface ───────────────────────────────────

/// Virtual interface for network controller implementations.
///
/// In C++ this was a pure virtual class. In Zig it is a struct of
/// function pointers with an opaque context pointer.
pub const Controller = struct {
    /// Opaque implementation context (BORROWED — owned by the caller).
    context: *anyopaque,

    /// Initialize the controller with a signing identity and sender.
    ///
    /// Called when the controller is added to a Node.
    init_fn: *const fn (
        context: *anyopaque,
        signing_id: *const Identity,
        sender_ctx: *Sender,
    ) void,

    /// Handle a network configuration request.
    ///
    /// - `nwid`: 64-bit network ID.
    /// - `from_addr`: Originating wire address (or zero if not direct).
    /// - `request_packet_id`: Packet ID of request, or 0 if not remote.
    /// - `requester_identity`: ZeroTier identity of the requesting peer.
    /// - `meta_data`: Metadata bundled with the request.
    request_fn: *const fn (
        context: *anyopaque,
        nwid: u64,
        from_addr: *const InetAddress,
        request_packet_id: u64,
        requester_identity: *const Identity,
        meta_data: *const Dictionary(metadata_dict_capacity),
    ) void,

    // ── Convenience wrappers ──────────────────────────────

    pub fn initController(
        self: *const Controller,
        signing_id: *const Identity,
        sender_ctx: *Sender,
    ) void {
        self.init_fn(self.context, signing_id, sender_ctx);
    }

    pub fn request(
        self: *const Controller,
        nwid: u64,
        from_addr: *const InetAddress,
        request_packet_id: u64,
        requester_identity: *const Identity,
        meta_data: *const Dictionary(metadata_dict_capacity),
    ) void {
        self.request_fn(
            self.context,
            nwid,
            from_addr,
            request_packet_id,
            requester_identity,
            meta_data,
        );
    }
};

// ── Tests ─────────────────────────────────────────────────────────

test "NetworkController: ErrorCode values match C++" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ErrorCode.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ErrorCode.object_not_found));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ErrorCode.access_denied));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ErrorCode.internal_server_error));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ErrorCode.authentication_required));
}

test "NetworkController: metadata_dict_capacity matches C++" {
    try testing.expectEqual(@as(u32, 1024), metadata_dict_capacity);
}

test "NetworkController: Sender struct layout" {
    // Verify the Sender struct has the expected fields.
    const info = @typeInfo(Sender);
    try testing.expect(info == .@"struct");
    try testing.expectEqual(@as(usize, 4), info.@"struct".fields.len);
}

test "NetworkController: Controller struct layout" {
    const info = @typeInfo(Controller);
    try testing.expect(info == .@"struct");
    try testing.expectEqual(@as(usize, 3), info.@"struct".fields.len);
}
