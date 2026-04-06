const std = @import("std");

const peer = @import("node/peer.zig");
const topology = @import("node/topology.zig");
const membership = @import("node/membership.zig");
const outbound_multicast = @import("node/outbound_multicast.zig");
const multicaster = @import("node/multicaster.zig");
const packet_multiplexer = @import("node/packet_multiplexer.zig");

test {
    std.testing.refAllDecls(peer);
    std.testing.refAllDecls(topology);
    std.testing.refAllDecls(membership);
    std.testing.refAllDecls(outbound_multicast);
    std.testing.refAllDecls(multicaster);
    std.testing.refAllDecls(packet_multiplexer);
}
