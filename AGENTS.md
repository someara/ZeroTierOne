# ZeroTierOne C++ to Zig Conversion

You are a security minded software engineer.
You practice defensive coding. You think carefully about every line of before you write it.
You test obsessively.

## Overview

Incremental conversion of `node/` (the core library, ~37,500 lines across 78
files) from C/C++ to Zig. The C API (`include/ZeroTierOne.h`) is preserved as
the stable public interface throughout. Target platforms: Linux + macOS.

**Zig version**: 0.15.2
**Coding standards**: See `STYLE.md` and `CODING_STANDARDS.md`

---

## Conversion Strategy

Bottom-up, tier-by-tier. Each module is converted starting from leaf
dependencies and working up to `Node.zig` (which exports the C API). The
project remains buildable and all tests pass at every step.

**Interop during transition**:
- Zig modules export `extern "C"` functions so unconverted C++ can call them
- Zig uses `@cImport` to call into unconverted C++ (via thin C wrappers for
  template-heavy code like Buffer, Hashtable, SharedPtr)
- `ZeroTierOne.h` types (`ZT_*` structs/enums) are C and work in both
  languages natively

---

## Progress Tracker

### Phase 0: Prerequisites
- [x] Verify Zig 0.15.2 toolchain installed
- [x] Review `selftest.cpp` test structure
- [x] Read and adopt `STYLE.md` and `CODING_STANDARDS.md` conventions

### Phase 1: Zig Build System Bootstrap
- [x] Create `build.zig` compiling all `node/*.cpp` into `libzerotiercore.a`
- [x] Handle platform-specific assembly (x64 salsa via `__attribute__((target(...)))`, ARM crypto via compiler defaults)
- [x] Handle AES intrinsic flags (x86_64 uses per-function target attrs, ARM64 defines enabled by default on Apple Silicon)
- [x] Build `selftest.cpp` via `zig build` (links against `libzerotiercore.a`)
- [x] Verify `selftest` passes identically to Makefile-built version (`zig build -Doptimize=ReleaseFast`, all tests PASS)
- [x] Add `build.zig.zon` with project metadata

### Phase 2: Leaf Modules & Crypto (~9,900 lines)

#### 2a. Pure Leaf Types (~970 lines) -- COMPLETE
- [x] `AtomicCounter.hpp` (73) -> `src/node/atomic_counter.zig`
- [x] `Credential.hpp` (34) -> `src/node/credential.zig`
- [x] `Mutex.hpp` (158) -> `src/node/mutex.zig`
- [x] `SharedPtr.hpp` (170) -> `src/node/shared_ptr.zig`
- [x] `RingBuffer.hpp` (338) -> `src/node/ring_buffer.zig`
- [x] `Buffer.hpp` (511) -> `src/node/buffer.zig`
- [x] `Hashtable.hpp` (433) -> `src/node/hashtable.zig`
- [x] `Metrics.hpp/.cpp` (324) -> `src/node/metrics.zig`

#### 2b. Foundation (~1,930 lines) -- COMPLETE
- [x] `Constants.hpp` (762) -> `src/node/constants.zig`
- [x] `Utils.hpp/.cpp` (1,171) -> `src/node/utils.zig`

#### 2c. Crypto Primitives (~6,960 lines) -- COMPLETE
- [x] `SHA512.hpp/.cpp` (359) -> `src/node/sha512.zig`
- [x] `Poly1305.hpp/.cpp` (644) -> `src/node/poly1305.zig`
- [x] `Salsa20.hpp/.cpp` (1,522) -> `src/node/salsa20.zig`
- [x] `ECC.hpp/.cpp` (2,803) -> `src/node/ecc.zig`
- [x] `AES.hpp + 3 .cpp` (2,382) -> `src/node/aes.zig`

### Phase 3: Core Types & Protocol (~8,600 lines)

#### 3a. Network Address Types (~2,530 lines) -- COMPLETE
- [x] `Address.hpp` (224) -> `src/node/address.zig`
- [x] `MAC.hpp` (290) -> `src/node/mac.zig`
- [x] `InetAddress.hpp/.cpp` (1,285) -> `src/node/inet_address.zig`
- [x] `MulticastGroup.hpp` (129) -> `src/node/multicast_group.zig`
- [x] `DNS.hpp` (50) -> `src/node/dns.zig`
- [x] `Dictionary.hpp` (501) -> `src/node/dictionary.zig`

#### 3b. Identity + Packet (~3,330 lines) -- COMPLETE
- [x] `Identity.hpp/.cpp` -> `src/node/identity.zig`
- [x] `Packet.hpp/.cpp` -> `src/node/packet.zig` (includes native Zig LZ4 in `src/node/lz4.zig`)

#### 3c. Credentials (~1,940 lines) -- COMPLETE
- [x] `Capability.hpp/.cpp` -> `src/node/capability.zig`
- [x] `CertificateOfMembership.hpp/.cpp` -> `src/node/certificate_of_membership.zig`
- [x] `CertificateOfOwnership.hpp/.cpp` -> `src/node/certificate_of_ownership.zig`
- [x] `Revocation.hpp/.cpp` -> `src/node/revocation.zig`
- [x] `Tag.hpp/.cpp` -> `src/node/tag.zig`

#### 3d. Configuration (~1,810 lines) -- COMPLETE
- [x] `World.hpp` -> `src/node/world.zig`
- [x] `RuntimeEnvironment.hpp` -> `src/node/runtime_environment.zig`
- [x] `NetworkConfig.hpp/.cpp` -> `src/node/network_config.zig`
- [x] `NetworkController.hpp` -> `src/node/network_controller.zig`

### Phase 4: Peer Management (~4,000 lines) -- COMPLETE
- [x] `Path.hpp/.cpp` -> `src/node/path.zig`
- [x] `Trace.hpp/.cpp` -> `src/node/trace.zig`
- [x] `SelfAwareness.hpp/.cpp` -> `src/node/self_awareness.zig`
- [x] `Peer.hpp/.cpp` -> `src/node/peer.zig`
- [x] `Topology.hpp/.cpp` -> `src/node/topology.zig`

### Phase 5: Network & Multicast (~6,770 lines)
- [ ] `Membership.hpp/.cpp` -> `src/node/membership.zig`
- [ ] `OutboundMulticast.hpp/.cpp` -> `src/node/outbound_multicast.zig`
- [ ] `Multicaster.hpp/.cpp` -> `src/node/multicaster.zig`
- [ ] `Network.hpp/.cpp` -> `src/node/network.zig`
- [ ] `Bond.hpp/.cpp` -> `src/node/bond.zig`

### Phase 6: Packet Processing & Node (~5,000 lines)
- [ ] `IncomingPacket.hpp/.cpp` -> `src/node/incoming_packet.zig`
- [ ] `Switch.hpp/.cpp` -> `src/node/switch.zig`
- [ ] `PacketMultiplexer.hpp/.cpp` -> `src/node/packet_multiplexer.zig`
- [ ] `Node.hpp/.cpp` -> `src/node/node.zig` (C API bridge -- LAST)

---

## Dependency Tiers (conversion order)

```
Tier 0  Leaves        AtomicCounter, Credential, Poly1305.hpp, RingBuffer, Metrics
Tier 1  Foundation    Constants (imports ZeroTierOne.h)
Tier 2  Utilities     Mutex, Hashtable, Utils, SharedPtr, Buffer, SHA512
Tier 3  Crypto        Salsa20, Poly1305.cpp, ECC, AES
Tier 4  Types         Address, MAC, InetAddress, MulticastGroup, DNS, Dictionary
Tier 5  Identity      Identity, Packet (wire protocol)
Tier 6  Credentials   Capability, CertOfMembership, CertOfOwnership, Revocation, Tag
Tier 7  Config        World, RuntimeEnvironment, NetworkConfig, NetworkController
Tier 8  Paths         Path, Trace, SelfAwareness
Tier 9  Peers         Peer, Topology
Tier 10 Networks      Membership, OutboundMulticast, Multicaster, Network, Bond
Tier 11 Switching     IncomingPacket, Switch, PacketMultiplexer
Tier 12 Node          Node (C API bridge)
```

## Key Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Crypto correctness | Validate against selftest vectors + wire-compat with C++ peer |
| Template interop | Buffer, Hashtable, SharedPtr are C++ templates; convert early or provide C wrappers |
| Tightly coupled cluster | {Node, Switch, Topology, Peer, Network, Bond, IncomingPacket} -- convert in compressed timeline |
| Bond osdep dependency | Bond.hpp includes ../osdep/Phy.hpp -- introduce interface or @cImport |
| Zig 0.15.x instability | Pin version, avoid experimental features |

---

## Architecture After Conversion

```
include/ZeroTierOne.h          (C header -- UNCHANGED)
    |
    v
src/node/node.zig              (exports extern "C" matching ZeroTierOne.h)
    |
    +-- switch.zig, incoming_packet.zig, packet_multiplexer.zig
    +-- network.zig, bond.zig, multicaster.zig, membership.zig
    +-- peer.zig, topology.zig, path.zig, trace.zig
    +-- identity.zig, packet.zig, credentials...
    +-- address.zig, mac.zig, inet_address.zig
    +-- aes.zig, ecc.zig, salsa20.zig, poly1305.zig, sha512.zig
    +-- constants.zig, utils.zig, buffer.zig, ...
```

## Session Log

- **Session 1**: Created conversion plan. Set up build.zig to compile existing
  C/C++ with Zig's build system. Verified toolchain (Zig 0.15.2, macOS arm64).
- **Session 2**: Completed Phase 1. Fixed `build.zig` for Zig 0.15.2 API
  (`ArrayList` is now unmanaged; replaced with compile-time arrays). Removed
  unnecessary osdep sources from selftest (only `selftest.cpp` needed; all
  osdep deps are header-only or in core lib). All selftest tests PASS with
  `zig build -Doptimize=ReleaseFast`. Added `build.zig.zon`. Note: Debug
  builds trap UB in ECC code (left-shift of negative value) — use ReleaseFast
  to match Makefile behavior.
- **Session 3**: Completed Phase 2a (all 8 pure leaf types). Verified all 46/46
  Zig tests pass (`zig build test --summary all`), C++ core lib builds
  (`zig build -Doptimize=ReleaseFast`), and selftest passes. Fixed
  `std.crypto.secureZero` path in buffer.zig (0.15.2 moved it from
  `std.crypto.utils.secureZero`). Beginning Phase 2b (Constants, Utils).
- **Session 4**: Completed Phase 2b (Constants, Utils — 20 new tests, 66 total).
  Beginning Phase 2c (Crypto Primitives). Converting SHA512 first, using Zig
  stdlib `std.crypto.hash.sha2` for SHA-512/384 and `std.crypto.auth.hmac` for
  HMAC-SHA384. Validating against selftest vectors.
- **Session 5**: Completed SHA512, Poly1305, and Salsa20 conversions in Phase 2c
  (3 of 5 crypto modules done, 109 total tests across 13 modules). SHA512 wraps
  `std.crypto.hash.sha2`, Poly1305 wraps `std.crypto.onetimeauth.Poly1305`,
  Salsa20 wraps `std.crypto.stream.salsa.Salsa(rounds)` with a stateful context
  matching C++ API (init/crypt12/crypt20 with auto-advancing block counter).
  All verified against selftest.cpp test vectors. Next: ECC (2,803 lines),
  then AES (2,382 lines).
- **Session 6**: Completed Phase 2c (ECC + AES — 64 new tests, 173 total across
  16 modules). ECC wraps `std.crypto.ecc.Edwards25519` and
  `std.crypto.dh.X25519` with C++ API compatibility. AES provides ECB, GMAC,
  streaming CTR, and GMAC-SIV (two-pass authenticated encryption). Used Zig
  stdlib `Aes256` (compile-time HW accel), `Ghash` (PCLMUL/PMULL), and manual
  streaming CTR. Cross-validated against C++ via `tmp/gen_aes_vectors.cpp`:
  GMAC (48-byte, empty, 7-byte partial, chunked), AES-CTR (69 bytes),
  GMAC-SIV (with/without AAD, 8 length variants 0-100 bytes) — all byte-identical.
  Phase 2 complete: ~9,900 C++ lines converted (~26.4% of core library).
- **Session 7**: Completed Phase 3a (Network Address Types — 6 modules, 84 new
  tests, 257 total across 21 modules). Converted Address (40-bit node ID),
  MAC (48-bit Ethernet), InetAddress (IPv4/IPv6 sockaddr wrapper with CIDR),
  MulticastGroup (MAC+ADI), DNS (C API wrapper), Dictionary (comptime-generic
  packed key=value store with escape encoding). Key challenges: macOS vs Linux
  sockaddr layout differences (sa_len field), AF constant differences
  (AF_INET6=30 on macOS vs 10 on Linux), C API sockaddr_storage type mismatch
  requiring raw byte ptrCast, Buffer API differences from C++. All 575 Zig
  tests pass, C++ selftest passes. Phase 3a: ~2,479 C++ lines converted
  (~33% cumulative of core library).
- **Session 8**: Completed Phase 3b (Identity + Packet — 3 modules, 56 new
  tests, 631 total across 24 modules). Identity converts memory-hard PoW
  generation (SHA-512 + Salsa20 over 2 MiB), Ed25519/X25519 keypair management,
  binary + ASCII serialization. LZ4 is a native Zig block codec (~477 lines)
  replacing ~990 lines of embedded C in Packet.cpp. Packet converts the full
  wire protocol: header accessors, Salsa20/12+Poly1305 and AES-GMAC-SIV
  armor/dearmor, cryptField for HELLO masking, extended armor (ephemeral ECC +
  AES-CTR), LZ4 compress/uncompress. Fixed Zig 0.15.2 ambiguous reference
  errors (inner struct constants shadowing file-level constants, resolved with
  `@This()`) and parameter shadowing (renamed `source` → `src_addr`). All 838
  Zig tests pass, C++ selftest passes. Phase 3b: ~3,330 C++ lines converted
  (~42% cumulative of core library).
- **Session 9**: Completed Phase 3c (Credentials — 5 modules, 41 new tests,
  879 total across 29 modules). Converted Tag, Revocation,
  CertificateOfMembership, CertificateOfOwnership, and Capability. Capability
  includes public `serializeRules`/`deserializeRules` functions (shared with
  future NetworkConfig). COM uses a distinct signing format (packed qualifier
  triples, no sentinels). Capability has custody chain support for transferable
  credentials. All credential `verify()` methods take signer identity directly
  (full RuntimeEnvironment lookup deferred to Phase 4-6). Fixed catch block
  errors in all 5 modules (replaced non-existent error names with `else =>
  return`). All 1441 Zig tests pass, C++ selftest passes. Phase 3c: ~1,940
  C++ lines converted (~47% cumulative of core library).
- **Session 10**: Completed Phase 3d (Configuration — 4 modules). Converted
  World (planet/moon hierarchy with root servers), RuntimeEnvironment (context
  struct with callback pointers), NetworkConfig (network configuration with
  rule deserialization), and NetworkController (controller interface). Phase 3
  complete.
- **Session 11**: Completed Phase 4 (Peer Management — 5 modules, 296 new
  tests, 3003 total across 38 modules). Converted Path (canonical network
  path with bond quality metrics, HashKey for dedup), Trace (diagnostic event
  logging via callbacks), SelfAwareness (external IP discovery with scope-aware
  reset), Peer (full peer state: ECDH key agreement, AES-GMAC-SIV/Salsa20
  session keys, multi-path management, rate limiting, relay quality scoring),
  and Topology (peer/path database with fixed-size arrays, planet/moon world
  management, upstream root tracking, physical path configuration). Key fixes:
  `Identity.generate()` takes allocator (not optional), `utils.burn()` doesn't
  exist (use `std.crypto.secureZero`), `Path.address()` not `addressConst()`,
  timing test values must exceed timeout constants, `HashKey` at module level
  not inside `Path` struct, `Address.init()` not `fromInt()`, Topology struct
  too large for stack (~5 MB) — tests heap-allocate via `testing.allocator`.
  All 3003 Zig tests pass across 77/77 build steps. Phase 4: ~4,000 C++ lines
  converted (~58% cumulative of core library).
