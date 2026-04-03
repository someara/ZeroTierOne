# ZeroTier Zig Conversion — Claude Instructions

## Completion Criteria

**CRITICAL:** Do not declare anything "complete", "production ready", or "essentially done" unless ALL of the following criteria are met for that component.

### What "Working" Actually Means

#### ❌ NOT Working (Do NOT claim these are done):
- "Compiles without errors"
- "Sends packets to servers"
- "No crashes in the first 30 seconds"
- "Test passes with mocked data"
- "Should work in theory"

#### ✅ Actually Working (Required to claim completion):
- **Bidirectional communication verified** — Can send AND receive responses from real servers
- **End-to-end data flow tested** — Packet goes through full pipeline: encode → transmit → receive → decode → process
- **Real-world validation** — Works with actual ZeroTier infrastructure, not just unit tests
- **Error cases handled** — Gracefully handles malformed packets, timeouts, connection failures
- **Performance validated** — Meets or exceeds baseline (C++ version) performance

### Specific Blocking Criteria

#### Network Layer "Done" Checklist
- [ ] HELLO packet sent to root server
- [ ] **HELLO OK response received and decrypted**
- [ ] Peer relationship established (have their identity)
- [ ] Can send follow-up packets after handshake
- [ ] Handles retransmission on timeout

#### VPN Functionality "Done" Checklist
- [ ] Join network via API
- [ ] **Receive network configuration from controller**
- [ ] Configuration applied to node
- [ ] TUN device created with assigned IP
- [ ] Can ping another node on the network
- [ ] **Actual packets routed through virtual interface**

#### Crypto "Done" Checklist
- [ ] All test vectors pass
- [ ] **Works with real packets from ZeroTier servers** (not just our own test data)
- [ ] SIMD optimizations enabled and tested
- [ ] Performance meets or exceeds C++ baseline
- [ ] Constant-time operations verified (no timing leaks)

#### Service "Done" Checklist
- [ ] Starts without crashes
- [ ] HTTP API responds to all endpoints
- [ ] **Can join network and complete full handshake**
- [ ] **Routes real traffic for >5 minutes without issues**
- [ ] Graceful shutdown (no leaks, no panics)
- [ ] Survives basic stress testing (100+ packets/sec)

## Known Issues Must Be Explicit

When reporting status, clearly separate:
1. **What works** (meets criteria above)
2. **What compiles but is untested**
3. **What is blocked** (and why)
4. **What is broken** (known bugs)

### Example Good Status Report:
```
## Current Status

### ✅ Working (verified end-to-end)
- Identity generation and persistence
- Packet encoding/decoding with test data
- HTTP API authentication

### ⚠️ Compiles But Untested
- HELLO handshake (sends but never receives responses)
- Network join protocol (stuck at REQUESTING_CONFIGURATION)
- Packet reassembly (no fragmented packets seen in testing)

### 🚫 Blocked
- Full VPN testing: Firewall prevents incoming packets on dev machine
- Need: Deploy to cloud VM without firewall restrictions

### 🐛 Known Broken
- Salsa20/20 NEON SIMD: Produces incorrect output, disabled
- Poly1305 context reuse: Doesn't match C++ behavior in edge case
```

### Example Bad Status Report (Do NOT do this):
```
✅ HELLO handshake working  [NO: only sends, never got response]
✅ Network join protocol working  [NO: stuck at REQUESTING_CONFIGURATION]
✅ Crypto verified correct  [NO: SIMD disabled due to bug]
✅ Production ready  [NO: never routed a single real packet]
```

## Language and Phrasing Rules

### Forbidden Phrases (Do NOT Use):
- "essentially complete"
- "production ready" (unless deployed and tested in production)
- "should work" (either it works or it doesn't)
- "functionally complete" (unless all functions verified end-to-end)
- "ready for deployment" (unless actually deployed and tested)
- "works correctly" (unless proven with real data)

### Required Phrases (Use These):
- "compiles but untested with real servers"
- "blocked on [specific external issue]"
- "tested with mocked data, needs real-world validation"
- "sends packets but has not received responses"
- "never completed full handshake with live server"
- "requires testing on clean machine"

## Testing Standards

### Unit Tests Are Not Enough
Passing unit tests ≠ working code. Unit tests prove correctness of isolated functions, not integration or real-world behavior.

### Integration Testing Required
Before claiming something works:
1. Test with real ZeroTier infrastructure
2. Verify end-to-end data flow
3. Test error conditions (timeouts, bad packets, disconnects)
4. Run for extended period (not just 30 seconds)

### Performance Testing Required
Before claiming optimization works:
1. Benchmark against C++ baseline
2. Test with representative workload (not just 16-byte test vectors)
3. Verify SIMD code actually gets used (check assembly)
4. Profile to find bottlenecks

## Default Behavior

When in doubt:
1. **Report what you know** (verified facts only)
2. **List what's unknown** (needs testing)
3. **Ask user what to do next** (don't assume completion)
4. **Never declare victory prematurely**

The user will tell you when something is done. Your job is to provide accurate status and identify what's left to do.
