# End-to-End VPN Testing Guide

This guide walks through testing the complete ZeroTier Zig implementation with real network connectivity.

## Prerequisites

- ZeroTier service built: `zig build service`
- sudo access for TUN device operations
- Network connectivity to ZeroTier root servers

## Test 1: Basic Service (No TUN)

Start the service without TUN device:

```bash
# Clean test environment
rm -rf /tmp/zerotier-e2e-test
mkdir -p /tmp/zerotier-e2e-test

# Start service
./zig-out/bin/zerotier-one -p 9993 -d /tmp/zerotier-e2e-test &
ZT_PID=$!

# Wait for startup
sleep 3

# Get auth token
AUTH_TOKEN=$(cat /tmp/zerotier-e2e-test/authtoken.secret)
echo "Auth token: $AUTH_TOKEN"

# Check status
curl -H "X-ZT1-Auth: $AUTH_TOKEN" http://127.0.0.1:9993/status | jq .
```

**Expected output**:
```json
{
  "online": true,
  "address": "8a78f24aab",
  "version": "2.0.0-zig",
  "clock": 1775126920264
}
```

## Test 2: Join a Network

Join ZeroTier Earth (public test network):

```bash
# Join network
curl -X POST -H "X-ZT1-Auth: $AUTH_TOKEN" \
  http://127.0.0.1:9993/network/8056c2e21c000001 | jq .

# Wait for configuration
sleep 10

# Check network status
curl -H "X-ZT1-Auth: $AUTH_TOKEN" \
  http://127.0.0.1:9993/network | jq .
```

**Expected output**:
```json
[
  {
    "id": "8056c2e21c000001",
    "name": "ZeroTier Earth",
    "status": "OK",
    "assignedAddresses": ["28.0.0.1/7"]
  }
]
```

## Test 3: Service with TUN Device

**IMPORTANT**: This requires sudo access.

```bash
# Stop non-TUN service
kill $ZT_PID

# Start with TUN device (in a terminal where you can enter sudo password)
sudo ./zig-out/bin/zerotier-one -p 9993 -d /tmp/zerotier-e2e-test --tun
```

**In another terminal**:

```bash
# Get auth token
AUTH_TOKEN=$(cat /tmp/zerotier-e2e-test/authtoken.secret)

# Check status
curl -H "X-ZT1-Auth: $AUTH_TOKEN" http://127.0.0.1:9993/status | jq .

# Join network (if not already joined)
curl -X POST -H "X-ZT1-Auth: $AUTH_TOKEN" \
  http://127.0.0.1:9993/network/8056c2e21c000001 | jq .

# Wait for network configuration
sleep 15

# Check TUN device was created
ifconfig | grep -A 10 utun
```

**Expected output**:
- TUN device created (utun5 or similar)
- IP address assigned from ZeroTier network
- Interface is UP and RUNNING

## Test 4: Verify Connectivity

Once the network is configured and TUN device has an IP:

```bash
# Find your ZeroTier IP
ZT_IP=$(ifconfig | grep -A 5 utun5 | grep inet | grep -v inet6 | awk '{print $2}')
echo "My ZeroTier IP: $ZT_IP"

# Ping another node on ZeroTier Earth (if you have one)
# Or test with ZeroTier's test infrastructure
ping -c 4 28.0.0.1  # Example Earth network IP
```

## Test 5: Leave Network

```bash
# Leave the network
curl -X DELETE -H "X-ZT1-Auth: $AUTH_TOKEN" \
  http://127.0.0.1:9993/network/8056c2e21c000001 | jq .

# Verify network list is empty
curl -H "X-ZT1-Auth: $AUTH_TOKEN" \
  http://127.0.0.1:9993/network | jq .

# Check TUN device was removed
ifconfig | grep utun5
```

## Test Results Checklist

- [ ] Service starts and binds to port 9993
- [ ] HTTP API responds to /status
- [ ] Identity and auth token generated
- [ ] Can join a network via HTTP POST
- [ ] Network status transitions: REQUESTING_CONFIGURATION → OK
- [ ] Receives NETWORK_CONFIG from root servers
- [ ] TUN device created when using --tun flag
- [ ] IP address assigned to TUN device
- [ ] Can ping other nodes on the network
- [ ] Can leave network via HTTP DELETE
- [ ] TUN device removed when leaving network
- [ ] Service shuts down gracefully (Ctrl+C)

## Known Issues

### TUN Device Requires sudo

The TUN device operations require root privileges. You must run the service with sudo:

```bash
sudo ./zig-out/bin/zerotier-one --tun
```

### Network Configuration Delay

It may take 10-15 seconds to receive network configuration from root servers after joining. This is normal for the ZeroTier protocol.

### ZeroTier Earth Membership

ZeroTier Earth (8056c2e21c000001) is a public test network. Your node will be automatically authorized, but connectivity depends on:
- Other active nodes on the network
- Your network's firewall rules
- NAT traversal (STUN/TURN)

## Logs and Debugging

View real-time service logs:

```bash
tail -f /tmp/zerotier-e2e.log
```

Look for:
- `HELLO` packets sent to root servers
- `OK` responses from root servers
- `NETWORK_CONFIG` received
- `NETWORK_CREDENTIALS` received
- `TUN device opened` messages

## Performance Testing

Once connectivity is established:

```bash
# Throughput test (requires iperf3 on both ends)
# On peer: iperf3 -s
# On this node: iperf3 -c <peer_zt_ip>

# Latency test
ping -c 100 <peer_zt_ip>
```

## Success Criteria

The end-to-end test is successful when:

1. ✅ Service starts and initializes
2. ✅ Communicates with ZeroTier root servers
3. ✅ Joins a network successfully
4. ✅ Receives network configuration
5. ✅ Creates TUN device with assigned IP
6. ✅ Can route packets through the network
7. ✅ Can leave the network cleanly
8. ✅ Service shuts down without errors

## Next Steps

After successful end-to-end testing:

1. **Test with multiple networks** - Join 2-3 networks simultaneously
2. **Test peer-to-peer** - Set up two nodes and verify direct connectivity
3. **Performance benchmarking** - Measure throughput and latency
4. **Stress testing** - Join/leave networks repeatedly, high packet rates
5. **Platform testing** - Test on Linux (we've verified in Docker already)

## Documentation Updates Needed

After successful testing, update:
- [ ] STATUS.md - Mark service layer as 100% complete
- [ ] README.md - Add installation and usage instructions
- [ ] COMPLETION_SUMMARY.md - Document what was achieved
- [ ] Performance comparison - Zig vs C++ throughput/latency
