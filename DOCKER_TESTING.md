# Docker-Based Network Testing

## Quick Start

```bash
# Build images (takes ~5 minutes first time)
docker-compose -f docker/docker-compose.yml build

# Start all containers
docker-compose -f docker/docker-compose.yml up

# Run test script (in another terminal)
./docker/test-network.sh

# Stop all containers
docker-compose -f docker/docker-compose.yml down
```

## What This Tests

The Docker environment validates the **complete network join flow**:

1. **Client generates identity** → Unique ZeroTier address
2. **Client sends HELLO** → Root server (172.20.0.10:9993)
3. **Root server sends HELLO_OK** → Establishes shared secret
4. **Client requests network config** → Controller (172.20.0.11:9993)
5. **Controller authorizes member** → Assigns IP (10.147.x.x)
6. **Controller sends config** → Client receives network parameters
7. **Client creates TUN device** → Joins virtual network
8. **Success!** → Client is online

## Why Docker?

### Problem
On the dev machine, GlobalProtect VPN software blocks incoming UDP packets, preventing real ZeroTier testing.

### Solution
Docker provides an isolated network environment where all containers can communicate freely without firewall interference.

### Benefits
- **Isolated**: No interference from host firewall/VPN
- **Reproducible**: Same environment every time
- **Multi-peer**: Easy to test 2+ clients
- **Fast iteration**: Rebuild and test in seconds
- **CI-ready**: Can automate in GitHub Actions

## Components

### Root Server
- **Image**: `Dockerfile.root-server`
- **Binary**: `test-root-server`
- **Purpose**: Handles HELLO/OK handshake, establishes peer relationships
- **Port**: 9993/udp
- **IP**: 172.20.0.10

### Controller
- **Image**: `Dockerfile.zig-zerotier`
- **Binary**: `test-controller`
- **Purpose**: Issues network configurations, authorizes members
- **Port**: 9993/udp
- **IP**: 172.20.0.11
- **Network**: 0x8056c2e21c000001 (auto-created)

### Clients
- **Image**: `Dockerfile.zig-zerotier`
- **Binary**: `zerotier-one`
- **Purpose**: Join network, receive config, create TUN device
- **Port**: 9993/udp
- **IPs**: 172.20.0.101 (client1), 172.20.0.102 (client2)

## Debugging

### View logs
```bash
docker logs -f zt-root-server
docker logs -f zt-controller
docker logs -f zt-client1
```

### Enter container
```bash
docker exec -it zt-client1 bash
```

### Check network
```bash
# From host
docker exec zt-client1 ping -c 3 172.20.0.10

# Inspect bridge network
docker network inspect zerotier-net
```

### Rebuild after code changes
```bash
# Stop containers
docker-compose -f docker/docker-compose.yml down

# Rebuild images
docker-compose -f docker/docker-compose.yml build

# Restart
docker-compose -f docker/docker-compose.yml up
```

## Expected Output

### Root Server
```
Initializing root server on port 9993...
  Root identity: .{ ._a = 412345678901 }
  ✓ Listening on 0.0.0.0:9993

[1] Received 128 bytes from 172.20.0.101:54321
  Source: .{ ._a = 512345678902 }
  Verb: hello
  → Processing HELLO from unknown peer
  ✓ Identity extracted
  ✓ Shared key computed
  ✓ Sent HELLO OK (96 bytes)
```

### Controller
```
Initializing network controller on port 9993...
  Controller identity: .{ ._a = 612345678903 }
  ✓ Created network: TestNetwork (ID: 0x8056c2e21c000001)
  ✓ Listening on 0.0.0.0:9993

[1] Received 64 bytes from 172.20.0.101:54321
  Source: .{ ._a = 512345678902 }
  Verb: network_config_request
  → Processing NETWORK_CONFIG_REQUEST
    Requested network: 0x8056c2e21c000001
    ✓ New member authorized: 10.147.0.1
    ✓ Sent NETWORK_CONFIG (256 bytes)
```

### Client
```
ZeroTier One Service Starting...
  Identity: .{ ._a = 512345678902 }

Connecting to root server...
  → Sent HELLO to 172.20.0.10:9993
  ✓ Received HELLO OK
  ✓ Peer relationship established

Joining network 0x8056c2e21c000001...
  → Sent NETWORK_CONFIG_REQUEST to 172.20.0.11:9993
  ✓ Received NETWORK_CONFIG
  ✓ Authorized: true
  ✓ IP assigned: 10.147.0.1/24
  ✓ TUN device created: zt0

Network status: ONLINE
```

## Common Issues

### Build Fails
```bash
# Clean Docker cache
docker system prune -a

# Rebuild from scratch
docker-compose -f docker/docker-compose.yml build --no-cache
```

### Port Already in Use
```bash
lsof -i :9993
pkill -9 <process-name>
```

### No Response from Root Server
- Check firewall rules in container
- Verify socket binding succeeded
- Check identity generation worked
- Use `tcpdump` to capture packets:
  ```bash
  docker exec zt-root-server apt-get install tcpdump
  docker exec zt-root-server tcpdump -i any -n udp port 9993
  ```

### Client Can't Join Network
- Verify HELLO/OK handshake completed
- Check shared key was computed
- Verify controller has network 0x8056c2e21c000001
- Check packet MAC validation

## Architecture Comparison

### Before (Blocked)
```
┌─────────────┐
│ Your Laptop │
│             │
│ ┌─────────┐ │     ❌ GlobalProtect blocks
│ │  Client │ │────────────────────────────> Internet
│ └─────────┘ │     incoming UDP
└─────────────┘
```

### After (Working)
```
┌──────────────────────────────────────────────┐
│ Docker Bridge (172.20.0.0/16)                │
│                                              │
│ ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│ │  Root    │  │Controller│  │ Client 1 │   │
│ │ :9993    │  │  :9993   │  │  :9993   │   │
│ └──────────┘  └──────────┘  └──────────┘   │
│      ↕              ↕             ↕          │
│      └──────────────┴─────────────┘          │
│           All traffic flows freely           │
└──────────────────────────────────────────────┘
```

## Next Steps

Once Docker testing proves the protocol works:

1. **Multi-peer routing** - Client1 pings Client2 through network
2. **NAT traversal** - Simulate NAT with iptables
3. **Relay paths** - Test relaying when direct fails
4. **Config updates** - Test dynamic IP reassignment
5. **Stress testing** - 100+ clients, packet loss
6. **QEMU testing** - Full VPN with real TUN devices

## Files

- `docker/` - Docker environment
  - `Dockerfile.root-server` - Root server image
  - `Dockerfile.zig-zerotier` - Client/controller image
  - `docker-compose.yml` - Multi-container setup
  - `test-network.sh` - Automated test script
  - `README.md` - Detailed documentation
- `DOCKER_TESTING.md` - This file (quick reference)

## See Also

- `docker/README.md` - Complete Docker documentation
- `src/test_root_server.zig` - Root server implementation
- `src/test_controller.zig` - Controller implementation
- `src/zerotier_one.zig` - Client service implementation
