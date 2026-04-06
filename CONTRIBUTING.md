# Contributing

Read first:

- `README.md`
- `ZIG.md`
- `DEVELOPMENT.md`
- `TESTING.md`
- `STYLE.md`
- `CODING_STANDARDS.md`

Be explicit about whether a change affects upstream, Zig, or both.

## Expectations

- clear problem statement
- small scope
- docs when behavior changes
- tests or regressions when behavior changes

## Zig Validation

```sh
zig build test-fast --summary all
zig build test-peer
zig build test-topology
zig build test-core
```

Use `zig build test --summary all` only for the broader suite.

## Doc Rules

- only document real commands
- keep `README.md`, `ZIG.md`, `DEVELOPMENT.md`, and `TESTING.md` aligned
- do not reintroduce stale counts or unsupported parity claims
