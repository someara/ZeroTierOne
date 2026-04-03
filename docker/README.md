# ZeroTier Docker Test Environment

Multi-container test environment for validating the complete ZeroTier network join flow.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Bridge Network: 172.20.0.0/16                              │
│                                                              │
│  ┌──────────────┐    ┌──────────────┐   ┌──────────────┐  │
│  │ Root Server  │    │  Controller  │   │   Client 1   │  │
│  │ 172.20.0.10  │    │ 172.20.0.11  │   │ 172.20.0.101 │  │
│  │   :9993      │    │   :9993      │   │   :9993      │  │
│  └──────────────┘    └──────────────┘   └──────────────┘  │
│         │                    │                   │          │
│         │                    │                   │          │
│         │  HELLO/OK          │  NET_CONFIG_REQ   │          │
│         │<───────────────────┼───────────────────┤          │
│         │                    │<──────────────────┤          │
│         │                    │                   │          │
│                                                              │
│                             ┌──────────────┐                │
│                             │   Client 2   │                │
│                             │ 172.20.0.102 │                │
│                             │   :9993      │                │
│                             └──────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Root Server (test-root-server)
- **Purpose**: Handles HELLO/OK handshake
- **Address**: 172.20.0.10:9993
- **Source**: `src/test_root_server.zig`
- **Build**: `zig build root-server`

### Controller (test-controller)
- **Purpose**: Issues network configurations, authorizes members
- **Address**: 172.20.0.11:9993
- **Source**: `src/test_controller.zig`
- **Build**: `zig build controller`
- **Network ID**: 0x8056c2e21c000001
- **IP Range**: 10.147.x.x/24

### Clients (zerotier-one)
- **Purpose**: Join network, receive configuration
- **Addresses**: 172.20.0.101, 172.20.0.102
- **Source**: `src/zerotier_one.zig`
- **Build**: `zig build service`

## Usage

### Build Images
```bash
cd /path/to/ZeroTierOne
docker-compose -f docker/docker-compose.yml build
```

### Start Network
```bash
docker-compose -f docker/docker-compose.yml up
```

### Run Tests
```bash
./docker/test-network.sh
```

### Manual Testing

#### Enter a container
```bash
docker exec -it zt-client1 bash
```

#### Watch logs
```bash
# Root server
docker logs -f zt-root-server

# Controller
docker logs -f zt-controller

# Client
docker logs -f zt-client1
```

#### Test connectivity
```bash
# From host
docker exec zt-client1 ping -c 3 172.20.0.10

# From inside container
docker exec -it zt-client1 bash
ping 172.20.0.11
```

### Stop Network
```bash
docker-compose -f docker/docker-compose.yml down
```

## Expected Flow

1. **Client starts** → generates identity
2. **Client sends HELLO** → root-server (172.20.0.10:9993)
3. **Root server sends HELLO_OK** → client (establishes shared key)
4. **Client sends NETWORK_CONFIG_REQUEST** → controller (172.20.0.11:9993)
5. **Controller authorizes member** → assigns IP (10.147.x.x)
6. **Controller sends NETWORK_CONFIG** → client
7. **Client creates TUN device** → applies configuration
8. **Success** → client is on the network

## Debugging

### Root Server Not Responding
```bash
docker logs zt-root-server | grep ERROR
```

Check:
- Port 9993/udp is exposed
- Identity generation succeeded
- Socket bound successfully

### Controller Not Responding
```bash
docker logs zt-controller | grep "NETWORK_CONFIG_REQUEST"
```

Check:
- Network 0x8056c2e21c000001 was created
- Shared key computation succeeded
- MAC validation passed

### Client Can't Join
```bash
docker logs zt-client1 | grep -E "(HELLO|NETWORK_CONFIG)"
```

Check:
- HELLO packets being sent
- HELLO_OK responses received
- NETWORK_CONFIG_REQUEST sent
- NETWORK_CONFIG response received

### Network Issues
```bash
# Check bridge network exists
docker network ls | grep zerotier

# Inspect network
docker network inspect zerotier-net

# Check container IPs
docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zt-client1
```

## Files

- `Dockerfile.root-server` - Root server image
- `Dockerfile.zig-zerotier` - Client/controller image
- `docker-compose.yml` - Multi-container orchestration
- `test-network.sh` - Automated test script
- `README.md` - This file

## Troubleshooting

### Build Fails
```bash
# Clean Docker cache
docker system prune -a

# Rebuild from scratch
docker-compose -f docker/docker-compose.yml build --no-cache
```

### Port Already in Use
```bash
# Find process using port
lsof -i :9993

# Kill process
pkill -9 <process-name>
```

### Zig Build Errors
```bash
# Verify Zig version in container
docker run --rm <image-name> zig version

# Should output: 0.15.2
```

## Next Steps

Once the basic network join flow works:

1. **Multi-peer communication** - Test packet routing between client1 and client2
2. **NAT traversal** - Test hole punching through simulated NAT
3. **Relay paths** - Test relaying when direct connection fails
4. **Network changes** - Test configuration updates, IP reassignment
5. **Stress testing** - 100+ clients, packet loss, timeouts
6. **QEMU integration** - Full VPN testing with TUN devices

## Alternative: QEMU

For testing TUN device creation and actual packet routing:

```bash
# Build QEMU VM image
qemu-img create -f qcow2 zerotier-test.qcow2 10G

# Boot VM with network
qemu-system-x86_64 \
  -m 2048 \
  -hda zerotier-test.qcow2 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0
```

QEMU advantages:
- Full kernel support (TUN/TAP)
- Real routing table manipulation
- Actual VPN traffic flow

Docker advantages:
- Faster iteration
- Easier debugging
- Container isolation
- CI/CD integration
