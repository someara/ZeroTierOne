# Integration Test Plan - Docker Environment

**Date**: 2026-04-03
**Purpose**: Validate all bug fixes and verify end-to-end network join flow
**Status**: Ready to execute after Docker build completes

---

## Test Environment

### Architecture
```
┌─────────────────────────────────────────────────────────────┐
│                   Docker Bridge Network                      │
│                      172.20.0.0/16                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐ │
│  │ Root Server  │    │ Controller   │    │  Client 1    │ │
│  │ 172.20.0.10  │    │ 172.20.0.11  │    │ 172.20.0.101 │ │
│  │   :9993      │    │   :9993      │    │   :9993      │ │
│  └──────────────┘    └──────────────┘    └──────────────┘ │
│         │                   │                    │          │
│  HELLO/OK           NETWORK_CONFIG        Env vars:        │
│  handshake          issuance              - ROOT_SERVER    │
│                                           - CONTROLLER      │
│                                           - NETWORK_ID      │
│                                                              │
│  ┌──────────────┐                                          │
│  │  Client 2    │                                          │
│  │ 172.20.0.102 │                                          │
│  │   :9993      │                                          │
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
```

### Network Configuration
- **Network ID**: 0x8056c2e21c000001
- **Network Name**: TestNetwork
- **IP Subnet**: 10.147.0.0/16
- **MTU**: 2800
- **Multicast Limit**: 32

---

## Test Phases

### Phase 1: Build and Startup ✅

**Commands**:
```bash
cd docker
docker-compose build           # Build all images
docker-compose up -d          # Start containers in background
docker-compose ps             # Verify all containers running
```

**Expected Output**:
```
NAME               IMAGE                           STATUS
zt-root-server     zerotierone-root-server        Up
zt-controller      zerotierone-controller         Up
zt-client1         zerotierone-client1            Up
zt-client2         zerotierone-client2            Up
```

**Success Criteria**:
- [ ] All 4 containers start without errors
- [ ] No immediate crashes or restarts
- [ ] All ports bound successfully

---

### Phase 2: Root Server Initialization

**Commands**:
```bash
docker logs zt-root-server
```

**Expected Output**:
```
Initializing root server on port 9993...
  Root server identity: [10-digit hex address]
  ✓ Listening on 0.0.0.0:9993

════════════════════════════════════════════════════════════
  ROOT SERVER RUNNING
════════════════════════════════════════════════════════════
Press Ctrl+C to stop
```

**Success Criteria**:
- [ ] Root server generates identity
- [ ] Socket binds to port 9993
- [ ] No BUG #23 errors (socket errors should continue, not abort)
- [ ] Server enters main event loop

---

### Phase 3: Controller Initialization

**Commands**:
```bash
docker logs zt-controller
```

**Expected Output**:
```
Initializing network controller on port 9993...
  Controller identity: [10-digit hex address]
  ✓ Listening on 0.0.0.0:9993
  ✓ Created network: TestNetwork (ID: 0x8056c2e21c000001)

════════════════════════════════════════════════════════════
  NETWORK CONTROLLER RUNNING
════════════════════════════════════════════════════════════
Press Ctrl+C to stop
```

**Success Criteria**:
- [ ] Controller generates identity
- [ ] Socket binds to port 9993
- [ ] Network 0x8056c2e21c000001 created with name "TestNetwork"
- [ ] No BUG #17/#18 errors (should catch sendto failures)

---

### Phase 4: Client Initialization and Environment Variables

**Commands**:
```bash
docker logs zt-client1
```

**Expected Output**:
```
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║           ZeroTier One — Zig Implementation           ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝

  Environment: ROOT_SERVER=172.20.0.10:9993      ← BUG #28 FIX
  Environment: CONTROLLER=172.20.0.11:9993       ← BUG #28 FIX
  Environment: NETWORK_ID=0x8056c2e21c000001     ← BUG #36 FIX
  Environment: ROLE=client

Initializing ZeroTier service on port 9993...
  ✓ Node initialized with address: [10-digit hex]
Starting HTTP API on 127.0.0.1:9993...
  ✓ HTTP API server running
  ✓ Listening on 0.0.0.0:9993
  ✓ IPv6 socket bound

Joining network 0x8056c2e21c000001...           ← BUG #37 FIX
  ✓ Network joined: 0x8056c2e21c000001           ← BUG #37 FIX
```

**Success Criteria**:
- [ ] **BUG #28 FIX VERIFIED**: Environment variables read correctly
- [ ] **BUG #36 FIX VERIFIED**: NETWORK_ID present in environment
- [ ] **BUG #37 FIX VERIFIED**: Network join logic executes
- [ ] Service initializes without crashes
- [ ] HTTP API starts successfully

---

### Phase 5: HELLO Handshake

**Root Server Logs**:
```bash
docker logs zt-root-server | grep -A 10 "HELLO"
```

**Expected Output**:
```
[1] Received 112 bytes from 172.20.0.101:9993
  Source: [client1 address]
  Dest: [root server address]
  Verb: hello
  → Processing HELLO
    No shared key yet, parsing identity from HELLO
    ✓ Parsed client identity: [client1 address]
    ✓ Shared key computed
    ✓ Sent HELLO OK (87 bytes)                  ← BUG #26 FIX
```

**Client Logs**:
```bash
docker logs zt-client1 | grep -i "hello\|ok"
```

**Expected Output**:
```
Sending HELLO to root server...
Received HELLO OK from [root server address]
✓ Handshake complete with root server
```

**Success Criteria**:
- [ ] Client sends HELLO to 172.20.0.10:9993
- [ ] **BUG #24 FIX VERIFIED**: No identity memory leak on peer storage
- [ ] **BUG #25 FIX VERIFIED**: Shared key computed with correct pointer
- [ ] **BUG #27 FIX VERIFIED**: Identity parsing validates bounds
- [ ] Root server sends HELLO OK
- [ ] Client receives and processes HELLO OK
- [ ] Shared keys established bidirectionally

---

### Phase 6: Network Config Request

**Controller Logs**:
```bash
docker logs zt-controller | grep -A 15 "NETWORK_CONFIG_REQUEST"
```

**Expected Output**:
```
[1] Received 98 bytes from 172.20.0.101:9993
  Source: [client1 address]
  Dest: [controller address]
  Verb: network_config_request
  → Processing NETWORK_CONFIG_REQUEST
    ⚠️  Unknown peer, skipping MAC validation (INSECURE!)   ← BUG #2 (known limitation)
    Requested network: 0x8056c2e21c000001
    ✓ New member authorized: 10.147.0.0
  → Sending NETWORK_CONFIG
    ✓ Sent NETWORK_CONFIG (189 bytes)
```

**Client Logs**:
```bash
docker logs zt-client1 | grep -i "network.*config"
```

**Expected Output**:
```
Requesting network configuration for 0x8056c2e21c000001...
Received NETWORK_CONFIG from controller
  Network: 0x8056c2e21c000001
  Assigned IP: 10.147.0.0/24
  MTU: 2800
✓ Network configuration applied
```

**Success Criteria**:
- [ ] Client sends NETWORK_CONFIG_REQUEST
- [ ] Controller receives and processes request
- [ ] Controller authorizes member automatically
- [ ] IP assignment starts at 10.147.0.0 (first member)
- [ ] **BUG #7 FIX VERIFIED**: IP calculation correct (no off-by-one)
- [ ] Controller sends NETWORK_CONFIG response
- [ ] Client receives and applies configuration

---

### Phase 7: Multiple Client Join

**Commands**:
```bash
# Check both clients joined
docker logs zt-client1 | grep "10.147"
docker logs zt-client2 | grep "10.147"

# Check controller assigned IPs
docker logs zt-controller | grep "10.147"
```

**Expected Output**:
```
# Client 1
Assigned IP: 10.147.0.0/24

# Client 2
Assigned IP: 10.147.0.1/24

# Controller
✓ New member authorized: 10.147.0.0
✓ New member authorized: 10.147.0.1
```

**Success Criteria**:
- [ ] Client1 gets 10.147.0.0
- [ ] Client2 gets 10.147.0.1
- [ ] No IP conflicts
- [ ] Sequential assignment working

---

### Phase 8: Error Resilience

**Test Socket Errors**:
```bash
# Temporarily block traffic to trigger socket errors
docker exec zt-root-server iptables -A OUTPUT -p udp --dport 9993 -j DROP
sleep 2
docker exec zt-root-server iptables -D OUTPUT -p udp --dport 9993 -j DROP

# Check logs
docker logs zt-root-server | tail -20
```

**Expected Output**:
```
Socket error: NetworkUnreachable           ← BUG #23 FIX
[continues running, doesn't abort]
```

**Success Criteria**:
- [ ] **BUG #23 FIX VERIFIED**: Socket errors logged, server continues
- [ ] **BUG #26 FIX VERIFIED**: sendto errors caught, server continues
- [ ] Server recovers when network restored
- [ ] No crashes or restarts

---

### Phase 9: Memory Leak Test (Reconnection)

**Commands**:
```bash
# Restart client multiple times
for i in {1..5}; do
  docker restart zt-client1
  sleep 2
done

# Check root server memory usage and logs
docker stats zt-root-server --no-stream
docker logs zt-root-server | grep "identity"
```

**Expected Output**:
```
# Should see multiple HELLOs from same client
[1] Received HELLO from [client1]...
    ✓ Parsed client identity: [address]
[2] Received HELLO from [client1]...
    ✓ Parsed client identity: [address]  ← Old identity freed (BUG #24)
[3] Received HELLO from [client1]...
    ✓ Parsed client identity: [address]  ← Old identity freed (BUG #24)

# Memory should not grow significantly
CONTAINER         MEM USAGE
zt-root-server    15MB / 2GB    ← Should stay roughly constant
```

**Success Criteria**:
- [ ] **BUG #24 FIX VERIFIED**: Old identities freed on replacement
- [ ] Memory usage stable across reconnections
- [ ] No memory leak over 5 reconnections
- [ ] Shared keys recomputed correctly each time

---

### Phase 10: Buffer Safety Validation

**Test Crypto API**:
```bash
# Check that agree() validates buffer size
docker exec zt-client1 /zerotier/test_crypto 2>&1 | grep "agree"
```

**Expected Output**:
```
Testing Identity.agree() with invalid buffer...
✗ Rejected buffer < 32 bytes (expected)    ← BUG #30 FIX
✓ Accepted buffer >= 32 bytes
```

**Success Criteria**:
- [ ] **BUG #30 FIX VERIFIED**: agree() rejects buffers < 32 bytes
- [ ] No buffer overflows possible
- [ ] Crypto operations safe

---

## Success Metrics

### Critical (Must Pass)
- ✅ All containers start successfully
- ✅ Environment variables read correctly (BUG #28, #36)
- ✅ Network join logic executes (BUG #37)
- ✅ HELLO handshake completes
- ✅ Network config request/response works
- ✅ IP addresses assigned correctly (BUG #7)
- ✅ Error handling graceful (BUG #23, #26)
- ✅ No memory leaks on reconnection (BUG #24, #25)
- ✅ Buffer safety enforced (BUG #27, #30)

### Important (Should Pass)
- Multiple clients join successfully
- IP assignment sequential and correct
- Logs show complete protocol flow
- No crashes or restarts under load

### Nice to Have (Stretch Goals)
- Client-to-client ping works (requires TUN)
- Packet routing functional
- Performance acceptable

---

## Failure Scenarios and Debugging

### If Containers Don't Start
```bash
# Check build logs
docker-compose build 2>&1 | grep -i error

# Check individual container logs
docker logs zt-root-server
docker logs zt-controller
docker logs zt-client1
docker logs zt-client2

# Check port conflicts
netstat -an | grep 9993
```

### If Environment Variables Not Read
```bash
# Verify docker-compose.yml
cat docker/docker-compose.yml | grep -A 5 "environment:"

# Check if env vars present in container
docker exec zt-client1 env | grep -E "ROOT_SERVER|CONTROLLER|NETWORK_ID"
```

### If Handshake Fails
```bash
# Enable debug logging (if available)
docker exec zt-client1 kill -USR1 1    # Send signal to enable debug

# Capture packets
docker exec zt-root-server tcpdump -i any -n udp port 9993 -X

# Check firewall rules
docker exec zt-root-server iptables -L -n
```

### If Memory Leaks Detected
```bash
# Monitor memory over time
watch -n 1 'docker stats --no-stream | grep zt-'

# Check for growing peer maps
docker exec zt-root-server kill -USR2 1    # Dump state (if implemented)
```

---

## Expected Timeline

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Build | 5-10 min | 10 min |
| Startup | 10 sec | 10 min 10 sec |
| Initialization | 5 sec | 10 min 15 sec |
| Handshake | 2 sec | 10 min 17 sec |
| Config Request | 2 sec | 10 min 19 sec |
| Full Test Suite | 5 min | 15 min 19 sec |

**Total**: ~15-20 minutes for complete validation

---

## Test Execution Checklist

- [ ] Docker daemon running
- [ ] No port 9993 conflicts
- [ ] Sufficient disk space for images (~2GB)
- [ ] Network connectivity available
- [ ] docker-compose version >= 3.8

**Start Command**:
```bash
cd /Users/someara/src/ZeroTierOne/docker
docker-compose up
```

**Stop Command**:
```bash
docker-compose down
```

**Clean Restart**:
```bash
docker-compose down -v          # Remove volumes
docker-compose build --no-cache # Rebuild from scratch
docker-compose up
```

---

## Post-Test Actions

### If All Tests Pass ✅
1. Document successful test in TEST_RESULTS.md
2. Commit test results
3. Update BUG_STATUS_TRACKER.md with verification status
4. Plan next phase: TUN device integration or performance testing

### If Tests Fail ❌
1. Capture full logs: `docker-compose logs > test-failure-logs.txt`
2. Document failure symptoms
3. Identify root cause (refer to Failure Scenarios)
4. Create bug report with reproduction steps
5. Fix and re-test

---

## Next Steps After Successful Test

1. **TUN Device Integration**: Add virtual network interfaces to clients
2. **Client-to-Client Routing**: Enable packet forwarding between peers
3. **Performance Testing**: Measure throughput and latency
4. **NAT Traversal**: Test with simulated NAT (iptables)
5. **Stress Testing**: 100+ concurrent clients
6. **Production Hardening**: Address remaining low-priority bugs

---

**Test Status**: ⏳ Pending Docker build completion
**Expected Result**: ✅ All critical bug fixes verified working
**Confidence Level**: High (all 20 critical bugs addressed)
