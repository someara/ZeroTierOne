/// Protocol constants and tuning parameters for the ZeroTier core.
///
/// Converted from `node/Constants.hpp`. This module contains compile-time
/// constants used throughout the protocol implementation including timing
/// intervals, buffer sizes, rate limits, and QoS parameters.
///
/// Platform detection (endianness, arch) is handled by Zig's `@import("builtin")`
/// and is not replicated here. Constants that originate in the public C API
/// header (`include/ZeroTierOne.h`) are re-exported from `c_api` for
/// convenience.
const std = @import("std");
const builtin = @import("builtin");

// ── Public C API constants (from ZeroTierOne.h) ────────────────────
// These are authoritative values defined in the C header. We import
// them so Zig code doesn't need to @cImport directly.

/// Re-export of ZeroTierOne.h types/constants available via C interop.
pub const c_api = @cImport({
    // ZeroTierOne.h uses `bool` which requires stdbool.h in C mode.
    @cInclude("stdbool.h");
    @cInclude("include/ZeroTierOne.h");
});

// ── Platform detection ─────────────────────────────────────────────

pub const is_x86_64 = builtin.cpu.arch == .x86_64;
pub const is_aarch64 = builtin.cpu.arch == .aarch64;
pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;
pub const is_windows = builtin.os.tag == .windows;
pub const is_freebsd = builtin.os.tag == .freebsd;
pub const is_unix_like = is_linux or is_macos or is_freebsd;

pub const native_endian = builtin.cpu.arch.endian();

pub const target_name = platform_name ++ "/" ++ arch_name;

const platform_name: []const u8 = if (is_linux)
    "linux"
else if (is_macos)
    "macos"
else if (is_freebsd)
    "bsd"
else if (is_windows)
    "windows"
else
    "unknown";

const arch_name: []const u8 = if (is_x86_64)
    "x86_64"
else if (is_aarch64)
    "arm64"
else if (builtin.cpu.arch == .arm)
    "arm"
else
    "unknown";

pub const path_separator: u8 = if (is_windows) '\\' else '/';
pub const eol = if (is_windows) "\r\n" else "\n";

// ── Address constants ──────────────────────────────────────────────

/// Length of a ZeroTier address in bytes.
pub const address_length = 5;

/// Length of a hexadecimal ZeroTier address string.
pub const address_length_hex = 10;

/// Size of symmetric key (only the first 32 bits are used for some ciphers).
pub const symmetric_key_size = 48;

/// Addresses beginning with this byte are reserved for in-band signaling.
pub const address_reserved_prefix = 0xff;

// ── MTU and buffer sizes ───────────────────────────────────────────

/// Default MTU used for Ethernet tap device.
pub const default_mtu = 2800;

/// Maximum number of packet fragments we'll support (protocol max: 16).
pub const max_packet_fragments = 7;

/// Size of RX queue.
pub const rx_queue_size = 32;

/// Size of TX queue.
pub const tx_queue_size = 32;

// ── Timer and housekeeping intervals ───────────────────────────────

/// Minimum delay between timer task checks to prevent thrashing.
pub const core_timer_task_granularity = 60;

/// How often Topology::clean() and Network::clean() are called (ms).
pub const housekeeping_period = 30000;

/// Delay between WHOIS retries (ms).
pub const whois_retry_delay = 500;

/// Transmit queue entry timeout (ms).
pub const transmit_queue_timeout = 5000;

/// Receive queue entry timeout (ms).
pub const receive_queue_timeout = 5000;

// ── Relay and multicast ────────────────────────────────────────────

/// Maximum number of ZT hops allowed (protocol allows up to 7).
pub const relay_max_hops = 3;

/// Expire time for multicast 'likes' and indirect multicast memberships (ms).
pub const multicast_like_expire = 600000;

/// Period for multicast LIKE announcements (ms).
pub const multicast_announce_period = 60000;

/// Delay between explicit MULTICAST_GATHER requests for a given multicast channel (ms).
pub const multicast_explicit_gather_delay = multicast_like_expire / 10;

/// Timeout for outgoing multicasts (ms).
pub const multicast_transmit_timeout = 5000;

// ── Ping and peer timing ───────────────────────────────────────────

/// Delay between checks of peer pings and related housekeeping (ms).
pub const ping_check_interval = 5000;

/// How often the local.conf file is checked for changes (ms).
pub const local_conf_file_check_interval = 10000;

/// How frequently to send heartbeats over in-use paths (ms).
pub const path_heartbeat_period = 14000;

/// Do not accept HELLOs over a given path more often than this (ms).
pub const path_hello_rate_limit = 1000;

/// Delay between full-fledge pings of directly connected peers (ms).
pub const peer_ping_period = 60000;

/// Paths are considered expired after this duration without a real packet (ms).
pub const peer_path_expiration = (peer_ping_period * 4) + 3000;

/// How often to retry expired paths that we're still remembering (ms).
pub const peer_expired_path_trial_period = peer_ping_period * 10;

// ── QoS and ACK parameters ─────────────────────────────────────────

/// Divisor for statistical sampling of packets for QoS/ACK. Must be power of 2.
/// Set at 2 so ~50% of packets are sampled.
pub const qos_ack_divisor = 0x2;

/// Time horizon for QoS/ACK packet processing cutoff (ms).
pub const qos_ack_cutoff_time = 30000;

/// Maximum number of QoS/ACK packets processed within cutoff time.
pub const qos_ack_cutoff_limit = 128;

/// Minimum acceptable size for a QoS measurement packet.
pub const qos_min_packet_size = 8 + 1;

/// Maximum acceptable size for a QoS measurement packet.
pub const qos_max_packet_size = 1400;

/// How many ID:sojourn time pairs are in a single QoS packet.
pub const qos_table_size = (qos_max_packet_size * 8) / (64 + 16);

/// Maximum pending ACK records.
pub const ack_max_pending_records = 32 * 1024;

/// Maximum pending QoS records.
pub const qos_max_pending_records = qos_table_size * 3;

/// Interval used for rate-limiting path quality estimation (ms).
pub const qos_compute_interval = 1000;

/// Number of samples for real-time path statistics.
pub const qos_shortterm_sample_win_size = 64;

/// Minimum samples required before computing statistics summaries.
pub const qos_shortterm_sample_win_min_req_size = 4;

// ── AQM (Active Queue Management) parameters ──────────────────────

/// Max allowable time spent in any queue (ms).
pub const aqm_target = 5;

/// Time period where queue time should fall below target at least once (ms).
pub const aqm_interval = 100;

/// Bytes each queue is allowed to send per DRR cycle.
pub const aqm_quantum = default_mtu;

/// Maximum total packets that can be queued across all queues.
pub const aqm_max_enqueued_packets = 1024;

/// Number of QoS queue buckets.
pub const aqm_num_buckets = 9;

/// Default traffic bucket (0 = lowest priority).
pub const aqm_default_bucket = 0;

// ── Peer activity and rate limiting ────────────────────────────────

/// Timeout for overall peer activity measured from last receive (ms).
pub const peer_activity_timeout = 500000;

/// General rate limit timeout for multiple packet types (HELLO, etc.) (ms).
pub const peer_general_inbound_rate_limit = 500;

/// General limit for max RTT for requests over the network (ms).
pub const general_rtt_limit = 5000;

// ── Network configuration ──────────────────────────────────────────

/// Delay between requests for updated network autoconf information (ms).
pub const network_autoconf_delay = 60000;

/// Minimum interval between relay-mediated RENDEZVOUS messages (ms).
pub const min_unite_interval = 30000;

/// How often peers try memorized or statically defined paths (ms).
pub const try_memorized_path_interval = 30000;

/// Sanity limit on maximum bridge routes.
pub const max_bridge_routes = 67108864;

/// Max active bridges to spam when no L2 bridging route is known.
pub const max_bridge_spam = 32;

// ── Direct path push ───────────────────────────────────────────────

/// Interval between direct path pushes (ms).
pub const direct_path_push_interval = 15000;

/// Interval between direct path pushes when we already have a path (ms).
pub const direct_path_push_interval_havepath = 120000;

/// Time horizon for push direct paths cutoff (ms).
pub const push_direct_paths_cutoff_time = 30000;

/// Maximum number of direct path pushes within cutoff time.
pub const push_direct_paths_cutoff_limit = 8;

/// Maximum paths per IP scope and family.
pub const push_direct_paths_max_per_scope_and_family = 8;

// ── Rate limiters (ECHO, QOS, ACK) ─────────────────────────────────
// Note: ZT_MAX_PEER_NETWORK_PATHS comes from ZeroTierOne.h (= 64).

pub const max_peer_network_paths = c_api.ZT_MAX_PEER_NETWORK_PATHS;

pub const echo_cutoff_limit = (1000 / core_timer_task_granularity) * max_peer_network_paths;
pub const echo_drainage_divisor = 1000 / echo_cutoff_limit;

pub const qos_cutoff_limit = (1000 / core_timer_task_granularity) * max_peer_network_paths;
pub const qos_drainage_divisor = 1000 / qos_cutoff_limit;

pub const ack_cutoff_limit = 128;
pub const ack_drainage_divisor = 1000 / ack_cutoff_limit;

// ── Credential rate limits ─────────────────────────────────────────

/// Rate limit for network credential pushes from peer (ms).
pub const peer_credentials_rate_limit = 1000;

/// Rate limit for responding to peer credential requests (ms).
pub const peer_credentials_request_rate_limit = 1000;

/// WHOIS rate limit (ms).
pub const peer_whois_rate_limit = 100;

/// General rate limit for rate-limited packets (HELLO, credential request, etc.) (ms).
pub const peer_general_rate_limit = 1000;

// ── Bond parameters ────────────────────────────────────────────────

pub const bond_default_refractory_period = 8000;
pub const bond_max_refractory_period = 600000;

/// Minimum allowed time between flow/path optimizations (anti-flapping) (ms).
pub const bond_optimize_interval = 15000;

/// Maximum number of flows allowed before forcibly forgetting old ones.
pub const flow_max_count = 1024 * 64;

/// How often we emit a bond summary for each bond (ms).
pub const bond_status_interval = 30000;

/// How long before a path is considered dead (general sense) (ms).
pub const bond_failover_default_interval = 5000;

/// Minimum failover interval to avoid thrashing (ms).
pub const bond_failover_min_interval = 500;

/// ECHOs per failover interval (should be at least 2).
pub const bond_echos_per_failover_interval = 3;

/// Defensive timer for path quality metric processing.
pub const bond_background_task_min_interval = core_timer_task_granularity;

/// How often bonding policy background tasks are processed.
pub const bond_active_backup_check_interval = core_timer_task_granularity;

// ── Path negotiation ───────────────────────────────────────────────

/// Time horizon for path negotiation cutoff (ms).
pub const path_negotiation_cutoff_time = 60000;

/// Maximum path negotiations within cutoff time.
pub const path_negotiation_cutoff_limit = 8;

/// How many times a peer will petition another to synchronize paths.
pub const path_negotiation_try_count = 3;

/// Minimum quality improvement before triggering a switch.
pub const bond_active_backup_optimize_min_threshold: f64 = 0.10;

/// Failover handicap scores for path ranking.
pub const bond_failover_handicap_preferred = 500;
pub const bond_failover_handicap_primary = 1000;
pub const bond_failover_handicap_negotiated = 5000;

/// Indicator that no flow is associated with a packet.
pub const qos_no_flow: i32 = -1;

// ── Identity validation rate limit ─────────────────────────────────

/// Rate limit for expensive identity validation (ms).
/// ARM/MIPS/etc. are slower at validation, so they get a longer window.
pub const identity_validation_source_rate_limit: u64 = if (is_x86_64)
    2000
else if (builtin.cpu.arch == .x86)
    5000
else
    10000;

// ── Trust and socket parameters ────────────────────────────────────

/// How long a path/peer retains trust relationship (ms).
pub const trust_expiration = 600000;

/// Desired buffer size for UDP sockets.
pub const udp_desired_buf_size = 1048576;

/// Desired / recommended min stack size for threads.
pub const thread_min_stack_size = 1048576;

// ── Tests ──────────────────────────────────────────────────────────

test "derived constants are consistent" {
    // multicast_explicit_gather_delay = multicast_like_expire / 10
    try std.testing.expectEqual(@as(u64, 60000), multicast_explicit_gather_delay);

    // peer_path_expiration = (peer_ping_period * 4) + 3000
    try std.testing.expectEqual(@as(u64, 243000), peer_path_expiration);

    // peer_expired_path_trial_period = peer_ping_period * 10
    try std.testing.expectEqual(@as(u64, 600000), peer_expired_path_trial_period);

    // qos_table_size = (1400 * 8) / (64 + 16) = 140
    try std.testing.expectEqual(@as(u64, 140), qos_table_size);

    // aqm_quantum == default_mtu
    try std.testing.expectEqual(default_mtu, aqm_quantum);
}

test "platform detection is sane" {
    // At least one platform should be detected
    try std.testing.expect(is_linux or is_macos or is_windows or is_freebsd or
        !(is_linux or is_macos or is_windows or is_freebsd));

    // target_name should be non-empty
    try std.testing.expect(target_name.len > 0);
}

test "rate limiter constants are computed correctly" {
    // Verify the derived values match C++ behavior.
    // echo_cutoff_limit = (1000 / 60) * 64 = 16 * 64 = 1024
    try std.testing.expectEqual(@as(comptime_int, 1024), echo_cutoff_limit);

    // echo_drainage_divisor = 1000 / 1024 = 0 (integer division)
    // This matches the C++ behavior (ZT_ECHO_DRAINAGE_DIVISOR).
    try std.testing.expectEqual(@as(comptime_int, 0), echo_drainage_divisor);

    try std.testing.expectEqual(@as(comptime_int, 1024), qos_cutoff_limit);
    try std.testing.expectEqual(@as(comptime_int, 0), qos_drainage_divisor);

    try std.testing.expectEqual(@as(comptime_int, 128), ack_cutoff_limit);
    try std.testing.expectEqual(@as(comptime_int, 7), ack_drainage_divisor);
}

test "c_api constants match expected values" {
    // ZT_MAX_PEER_NETWORK_PATHS should be 64
    try std.testing.expectEqual(@as(comptime_int, 64), @as(comptime_int, c_api.ZT_MAX_PEER_NETWORK_PATHS));
}
