# ZeroTierOne

ZeroTea is the Zig port in this repository.

- upstream build: `make`
- Zig build: `zig build`
- ZeroTea goal: broad ZeroTier parity, idiomatic Zig, measured performance

## Read First

- `ZIG.md`
- `DEVELOPMENT.md`
- `TESTING.md`
- `CONTRIBUTING.md`
- `STYLE.md`
- `CODING_STANDARDS.md`

## Layout

- `node/` - upstream C++ core
- `src/node/` - Zig core
- `service/` - upstream service docs
- `doc/` - manpages
- `docker/` - Zig integration environment

## Quick Start

```sh
make
zig build test-fast --summary all
zig build zig-demo
zig build selftest
```

`zig build service` builds and runs the ZeroTea daemon.
