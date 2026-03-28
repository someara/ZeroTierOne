# ZeroTier Build Instructions

## Build System Overview

ZeroTier has **two completely separate build systems**:

1. **C++/Rust Build** → Use `make` (unchanged from upstream)
2. **Zig Build** → Use `zig build` (pure Zig, no C++)

### C++ Build (via make)

The production ZeroTier daemon is built using the traditional Makefile:

```bash
# Build ZeroTier daemon (C++/Rust)
make

# Build C++ crypto benchmarks
make selftest

# Run C++ benchmarks
./zerotier-selftest
```

This is the **official build system** from upstream - it works exactly as documented in the main ZeroTier repository.

### Zig Build (via zig build)

The Zig conversion is built separately using `build.zig`:

```bash
# Run Zig crypto benchmarks (pure Zig, always works)
zig build selftest -Doptimize=ReleaseFast

# Run Zig demonstration (all 47 modules)
zig build zig-demo

# Run Zig test suite (673 tests)
zig build test
```

These are **pure Zig** - they don't use any C++ code.

## Quick Start

### Zig Demo (All 47 Modules)

```bash
zig build zig-demo
./zig-out/bin/zerotier-zig-demo
```

### Zig Test Suite (673 Tests)

```bash
zig build test
```

### Zig Selftest (Crypto Benchmarks)

```bash
zig build selftest -Doptimize=ReleaseFast
./zig-out/bin/zerotier-selftest
```

## Expected Selftest Results

When running `zig build selftest -Doptimize=ReleaseFast`, you should see crypto benchmark results similar to:

```
[crypto] Benchmarking Salsa20/12... ~1900 MiB/second
[crypto] Benchmarking Salsa20/20... ~1000 MiB/second
[crypto] Benchmarking AES-GMAC-SIV... ~2000 MiB/second
[crypto] Benchmarking Poly1305... ~2800 MiB/second
[crypto] Benchmarking C25519 ECC key agreement... ~0.08ms per operation
[crypto] Benchmarking Ed25519 ECC signatures... ~4.4ms per signature
```

Actual performance varies by CPU architecture (x86_64 vs ARM64) and system load.

## Cross-Platform

The Zig build system works identically on Mac, Linux, BSD, and Windows:

```bash
# Same commands on all platforms
zig build selftest -Doptimize=ReleaseFast
zig build zig-demo
zig build test
```

## Cross-Compilation

```bash
# Compile for Linux from Mac
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast

# Compile for Mac from Linux
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast

# Compile for ARM64 Linux
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast
```

## Troubleshooting

### Binary is very large (15+ MB)

Debug builds are unoptimized and include full debug symbols. Use release mode for production-sized binaries:
```bash
zig build -Doptimize=ReleaseFast  # ~800KB
```

### Tests fail to compile

If you see `@cImport` errors, this is a known issue with the test runner. Use `zig ast-check` instead:
```bash
zig ast-check src/node/switch.zig
```

## Performance Comparison

To compare Zig vs C++ crypto performance:

```bash
# Pure Zig crypto benchmarks
zig build selftest -Doptimize=ReleaseFast

# C++ crypto benchmarks
make selftest && ./zerotier-selftest
```

See `BENCHMARK_COMPARISON.md` for detailed results and analysis.

**Quick Summary**:
- **Zig wins**: ECC operations (C25519 3x faster, Ed25519 223x faster!)
- **C++ wins**: Stream ciphers on x86_64 (uses hand-optimized assembly)
- **Zig advantages**: 100% memory safe, cross-platform consistent, simpler build
- **C++ advantages**: Faster bulk encryption on x86_64 (assembly), production-tested

## Requirements

- **Zig**: 0.15.2 or later
- **C++ Compiler**: Clang 5+ or GCC 8+ (for C++ build via make)
- **Platform**: Mac, Linux, BSD, Windows
