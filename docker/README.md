# Docker Test Environment

Short Zig integration environment for network join testing.

## Purpose

- `zig build root-server`
- `zig build controller`
- `zig build service`
- run the join flow in containers

## Commands

```sh
docker-compose -f docker/docker-compose.yml build
docker-compose -f docker/docker-compose.yml up
./docker/test-network.sh
docker-compose -f docker/docker-compose.yml down
```

## Components

- root server: `src/test_root_server.zig`
- controller: `src/test_controller.zig`
- client: `src/zerotea.zig`

## Expected Flow

1. client starts
2. client sends `HELLO`
3. root server sends `HELLO_OK`
4. client sends `NETWORK_CONFIG_REQUEST`
5. controller sends `NETWORK_CONFIG`
6. client joins the network

## Quick Debugging

```sh
docker logs -f zt-root-server
docker logs -f zt-controller
docker logs -f zt-client1
docker exec -it zt-client1 bash
```

Use this environment for Zig integration work. For command truth, see `DEVELOPMENT.md`, `TESTING.md`, and `build.zig`.
