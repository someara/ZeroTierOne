# Zig Roadmap

## Truth

- roadmap: this file
- commands: `build.zig`, `DEVELOPMENT.md`, `TESTING.md`
- style: `STYLE.md`, `CODING_STANDARDS.md`

Project name: `ZeroTea`.
Daemon name: `zerotea`.

Do not infer Zig support from `service/README.md`.

## Goal

- reach broad upstream ZeroTier feature parity in Zig
- make `ZeroTea` operationally comparable to upstream `zerotier-one`
- improve maintainability with idiomatic Zig design
- preserve or improve performance where measured

## Support

- `stable`: foundation, crypto, basic types, test steps
- `active`: peer/topology/network/switch/node/service work; most parity work lives here
- `experimental`: controller, root-server, tray, long integration/fuzz paths
- `deferred`: parity claims without verification; release-grade replacement claims

Support level is not a completion percentage.
It shows priority and confidence, not proof of end-to-end parity.

## Success

- parity: verified Zig behavior matches upstream across implemented ZeroTier features
- replacement: `ZeroTea` can replace specific upstream workflows where verified
- maintainability: APIs follow Zig ownership and composition rules
- performance: claims require measurements

## Priorities

1. ownership and lifetime cleanup
2. remove internal C++-shaped APIs where practical
3. keep `test-fast`, `test-peer`, `test-topology`, and `test-core` useful
4. close verified feature gaps against upstream
5. expand the set of workflows where `ZeroTea` can replace upstream `zerotier-one`
6. keep Zig service scope honest and documented while parity is incomplete
7. keep docs aligned with `build.zig`

## Work Rules

1. check support level first
2. use `DEVELOPMENT.md` and `TESTING.md` for commands
3. report `verified`, `untested`, `blocked`, and `broken` separately
4. update docs when support or commands change

## Status Answers

- do not infer "what is built" from filenames alone
- do not infer parity from imports, type names, or broad module presence
- when asked "how close are we", answer from verified runs and explicit support levels
- if only `test-fast` was run, say that only `test-fast` is verified
