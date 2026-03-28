const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------
    // NOTE: C++ build is handled by Makefile, not build.zig
    // ---------------------------------------------------------------
    // The C++/Rust ZeroTier daemon is built using `make` (unchanged from
    // upstream). This build.zig file handles ONLY pure Zig code.
    //
    // C++ builds:
    //   - make              # Build zerotier-one daemon
    //   - make selftest     # Build C++ crypto benchmarks
    //
    // Zig builds (this file):
    //   - zig build test        # Run 673 Zig module tests
    //   - zig build selftest    # Run Zig crypto benchmarks
    //   - zig build zig-demo    # Run Zig demonstration
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // Zig module tests  (`zig build test`)
    // ---------------------------------------------------------------
    // Each converted Zig module has inline tests. We create a test step
    // for each module and wire them all into `zig build test`.

    const zig_test_modules = [_][]const u8{
        "src/node/atomic_counter.zig",
        "src/node/credential.zig",
        "src/node/mutex.zig",
        "src/node/shared_ptr.zig",
        "src/node/ring_buffer.zig",
        "src/node/buffer.zig",
        "src/node/hashtable.zig",
        "src/node/metrics.zig",
        "src/node/constants.zig",
        "src/node/utils.zig",
        "src/node/sha512.zig",
        "src/node/poly1305.zig",
        "src/node/salsa20.zig",
        "src/node/ecc.zig",
        "src/node/aes.zig",
        // Phase 3a: Network address types
        "src/node/address.zig",
        "src/node/mac.zig",
        "src/node/inet_address.zig",
        "src/node/multicast_group.zig",
        "src/node/dns.zig",
        "src/node/dictionary.zig",
        // Phase 3b: Identity + Packet
        "src/node/identity.zig",
        "src/node/lz4.zig",
        "src/node/packet.zig",
        // Phase 3c: Credentials
        "src/node/tag.zig",
        "src/node/revocation.zig",
        "src/node/certificate_of_membership.zig",
        "src/node/certificate_of_ownership.zig",
        "src/node/capability.zig",
        // Phase 3d: Configuration
        "src/node/world.zig",
        "src/node/runtime_environment.zig",
        "src/node/network_config.zig",
        "src/node/network_controller.zig",
        // Phase 4: Peer Management
        "src/node/path.zig",
        "src/node/trace.zig",
        "src/node/self_awareness.zig",
        "src/node/peer.zig",
        "src/node/topology.zig",
        // Phase 5: Network & Multicast
        "src/node/membership.zig",
        "src/node/outbound_multicast.zig",
        "src/node/multicaster.zig",
        "src/node/network.zig",
        // Phase 6: Packet Processing & Node
        "src/node/packet_multiplexer.zig",
        "src/node/incoming_packet.zig",
    };

    const test_step = b.step("test", "Run Zig module tests");

    for (zig_test_modules) |test_file| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });

        // All test modules get the project root include path so that
        // transitive @cImport of "include/ZeroTierOne.h" (via
        // constants.zig) resolves correctly.
        test_mod.addIncludePath(b.path("."));

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ---------------------------------------------------------------
    // Zig demonstration executable (`zig build zig-demo`)
    // ---------------------------------------------------------------
    // Demonstrates the converted Zig modules working together on Mac/Linux.
    // Shows Node initialization, identity generation, packet operations,
    // and cross-platform compatibility.

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Demo needs access to constants.zig which uses @cImport
    demo_mod.addIncludePath(b.path("."));

    const demo_exe = b.addExecutable(.{
        .name = "zerotier-zig-demo",
        .root_module = demo_mod,
    });

    b.installArtifact(demo_exe);

    // `zig build zig-demo` -- build and run the Zig demonstration
    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.step.dependOn(b.getInstallStep());
    const demo_step = b.step("zig-demo", "Build and run the ZeroTier Zig demonstration");
    demo_step.dependOn(&run_demo.step);

    // ---------------------------------------------------------------
    // Simple benchmark comparison info
    // ---------------------------------------------------------------
    const bench_simple_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark_simple.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_simple_exe = b.addExecutable(.{
        .name = "zerotier-benchmark-simple",
        .root_module = bench_simple_mod,
    });

    b.installArtifact(bench_simple_exe);

    const run_bench_simple = b.addRunArtifact(bench_simple_exe);
    run_bench_simple.step.dependOn(b.getInstallStep());
    const bench_simple_step = b.step("bench-info", "Show Zig vs C++ benchmark comparison info");
    bench_simple_step.dependOn(&run_bench_simple.step);

    // ---------------------------------------------------------------
    // Zig selftest (`zig build selftest`)
    // ---------------------------------------------------------------
    // Pure Zig crypto performance benchmarks for direct comparison with C++
    // Compare with C++ version: make selftest
    // NOTE: Always use ReleaseFast for accurate performance measurements
    const selftest_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmark_crypto.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    const selftest_exe = b.addExecutable(.{
        .name = "zerotier-selftest",
        .root_module = selftest_mod,
    });

    b.installArtifact(selftest_exe);

    const run_selftest = b.addRunArtifact(selftest_exe);
    run_selftest.step.dependOn(b.getInstallStep());
    const selftest_step = b.step("selftest", "Run Zig crypto benchmarks (pure Zig, compare with: make selftest)");
    selftest_step.dependOn(&run_selftest.step);
}
