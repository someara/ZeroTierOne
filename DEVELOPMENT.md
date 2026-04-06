# Development

## Build

- upstream: `make`, `make selftest`
- Zig: `zig build`

## Common Zig Commands

```sh
zig build zig-demo
zig build selftest
zig build test-fast --summary all
zig build service -- --help
```

`zig build service` builds and runs the executable.

## Other Steps

- `zig build bench-info`
- `zig build bench-packets`
- `zig build controller`
- `zig build root-server`
- `zig build tray`
- `zig build test-tray`

## Service Path

- `src/zerotea.zig`
- `src/zerotea_service.zig`
- `src/node/http_api.zig`
- `src/node/tun_device.zig`
- `src/node/phy.zig`

Flags: `-p`, `-d`, `--tun`, `--help`

Env: `NETWORK_ID`, `ROOT_SERVER`, `CONTROLLER`, `ROLE`
