const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cpu_arch = target.result.cpu.arch;
    const is_x86_64 = cpu_arch == .x86_64;

    // ── Shared include paths (mirrors make-mac.mk / make-linux.mk) ──
    const include_paths = [_][]const u8{
        ".",
        "ext",
        "ext/prometheus-cpp-lite-1.0/core/include",
        "ext/prometheus-cpp-lite-1.0/simpleapi/include",
        "ext/opentelemetry-cpp-api-only/include",
    };

    // ── Base C++ compile flags ──────────────────────────────────────
    const core_cpp_flags: []const []const u8 = if (is_x86_64)
        &.{
            "-std=c++17",
            "-Wall",
            "-DNDEBUG",
            "-Wno-unused-private-field",
            "-fstack-protector-strong",
            "-DZT_USE_X64_ASM_SALSA2012",
        }
    else
        &.{
            "-std=c++17",
            "-Wall",
            "-DNDEBUG",
            "-Wno-unused-private-field",
            "-fstack-protector-strong",
        };

    // ---------------------------------------------------------------
    // libzerotiercore.a  (static library from existing C/C++ sources)
    // ---------------------------------------------------------------
    const core_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    for (include_paths) |dir| {
        core_mod.addIncludePath(b.path(dir));
    }

    // Core C++ source files (matches CORE_OBJS in objects.mk)
    core_mod.addCSourceFiles(.{
        .files = &.{
            "node/AES.cpp",
            "node/AES_aesni.cpp",
            "node/AES_armcrypto.cpp",
            "node/ECC.cpp",
            "node/Capability.cpp",
            "node/CertificateOfMembership.cpp",
            "node/CertificateOfOwnership.cpp",
            "node/Identity.cpp",
            "node/IncomingPacket.cpp",
            "node/InetAddress.cpp",
            "node/Membership.cpp",
            "node/Metrics.cpp",
            "node/Multicaster.cpp",
            "node/Network.cpp",
            "node/NetworkConfig.cpp",
            "node/Node.cpp",
            "node/OutboundMulticast.cpp",
            "node/Packet.cpp",
            "node/Path.cpp",
            "node/Peer.cpp",
            "node/Poly1305.cpp",
            "node/Revocation.cpp",
            "node/Salsa20.cpp",
            "node/SelfAwareness.cpp",
            "node/SHA512.cpp",
            "node/Switch.cpp",
            "node/Tag.cpp",
            "node/Topology.cpp",
            "node/Trace.cpp",
            "node/Utils.cpp",
            "node/Bond.cpp",
            "node/PacketMultiplexer.cpp",
            "osdep/OSUtils.cpp",
        },
        .flags = core_cpp_flags,
    });

    // x86_64 assembly: Salsa20/12 fast path
    if (is_x86_64) {
        core_mod.addAssemblyFile(b.path("ext/x64-salsa2012-asm/salsa2012.s"));
    }

    const core_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zerotiercore",
        .root_module = core_mod,
    });

    b.installArtifact(core_lib);

    // ---------------------------------------------------------------
    // selftest executable
    // ---------------------------------------------------------------

    const selftest_cpp_flags: []const []const u8 = if (is_x86_64)
        &.{
            "-std=c++17",
            "-Wall",
            "-DNDEBUG",
            "-Wno-unused-private-field",
            "-fstack-protector-strong",
            "-DOMIT_JSON_SUPPORT",
            "-DZT_USE_X64_ASM_SALSA2012",
        }
    else
        &.{
            "-std=c++17",
            "-Wall",
            "-DNDEBUG",
            "-Wno-unused-private-field",
            "-fstack-protector-strong",
            "-DOMIT_JSON_SUPPORT",
        };

    const selftest_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    for (include_paths) |dir| {
        selftest_mod.addIncludePath(b.path(dir));
    }

    // selftest.cpp only -- it uses node/* (via core lib), osdep/OSUtils
    // (in core lib), and header-only osdep templates (Phy.hpp, Thread.hpp).
    selftest_mod.addCSourceFiles(.{
        .files = &.{"selftest.cpp"},
        .flags = selftest_cpp_flags,
    });

    const selftest_exe = b.addExecutable(.{
        .name = "zerotier-selftest",
        .root_module = selftest_mod,
    });

    selftest_exe.linkLibrary(core_lib);

    b.installArtifact(selftest_exe);

    // `zig build selftest` -- build and run the selftest
    const run_selftest = b.addRunArtifact(selftest_exe);
    run_selftest.step.dependOn(b.getInstallStep());
    const selftest_step = b.step("selftest", "Build and run the ZeroTier selftest");
    selftest_step.dependOn(&run_selftest.step);

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
}
