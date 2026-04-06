# Testing

Use this order:

1. `zig build test-fast --summary all`
2. `zig build test-peer` or `zig build test-topology`
3. `zig build test-core`
4. `zig build test --summary all`

`test` includes long integration and fuzz targets.

## Direct Filters

```sh
zig test src/test_core.zig -I . --test-filter "node.node.test.Node:"
zig test src/test_core.zig -I . --test-filter "node.network.test.Network:"
zig test src/test_slow_core.zig -I . --test-filter "node.peer.test.Peer:"
zig test src/test_slow_core.zig -I . --test-filter "node.topology.test.Topology:"
```

## Roots

- `src/test_fast.zig`
- `src/test_core.zig`
- `src/test_slow_core.zig`

## Opt-In Steps

- `zig build test-tray`
- `zig build test-timeout-retry`
- `zig build test-error-recovery`
- `zig build test-stress`
- `zig build test-real-handshake`
- `zig build test-earth`
- `zig build test-earth-debug`
- `zig build test-http-client`

## Docs Eval

- `./test_docs_claude.sh sonnet`
- `./test_docs_claude.sh --timeout 60 haiku`
- `./test_docs_opencode.sh github-copilot/gpt-5-mini`
- `./test_docs_models.sh --timeout 60 --claude sonnet --opencode github-copilot/gpt-5-mini`
