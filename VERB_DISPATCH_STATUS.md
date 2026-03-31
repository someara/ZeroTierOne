# Verb Dispatch Implementation Status

**Date:** 2026-03-28
**Status:** 🟡 **In Progress** - Callbacks partially implemented

---

## What Was Done

Started implementation of IncomingPacket callbacks bridge to enable verb processing. Created stub implementations for ~30 of 71 required callbacks.

### Created: createIncomingPacketCallbacks()

**Location:** `src/node/node.zig` lines 815-1003

**Purpose:** Bridge between Node context and IncomingPacket requirements

**Callbacks Implemented:**

| Category | Implemented | Total | Status |
|----------|-------------|-------|--------|
| **Time** | 1 / 1 | 100% | ✅ Complete |
| **Topology** | 2 / 10 | 20% | 🟡 Partial |
| **Switch** | 1 / 2 | 50% | 🟡 Partial |
| **Node** | 2 / 8 | 25% | 🟡 Partial |
| **Peer** | 14 / 25 | 56% | 🟡 Partial |
| **Path** | 4 / 6 | 67% | 🟡 Partial |
| **Trace** | 3 / 3 | 100% | ✅ Complete |
| **Identity** | 3 / 5 | 60% | 🟡 Partial |
| **Network** | 0 / 11 | 0% | ❌ TODO |
| **Total** | **30 / 71** | **42%** | 🟡 **In Progress** |

---

## Architecture Challenge

### The Problem

There's a circular dependency issue:

```
Node (has createIncomingPacketCallbacks)
  ↓ creates
Switch.Callbacks
  ↓ receives packet in
Switch.handlePacketHead
  ↓ needs to create
IncomingPacket.Callbacks
  ↓ requires access to
Node (circular!)
```

### Current Flow

```
Service.onPhyDatagram
  ↓
Node.processWirePacket
  ↓ creates Switch.Callbacks{ctx: Node}
Switch.onRemotePacket
  ↓
Switch.handlePacketHead
  ↓ creates IncomingPacket
IncomingPacket.init ✅
  ↓ needs to call
IncomingPacket.tryDecode ❌ blocked
```

### Solutions Considered

#### Option 1: Pass IncomingPacket Callbacks Through Switch

**How it works:**
- Add `incoming_pkt_callbacks` field to Switch.Callbacks
- Node sets it when creating Switch callbacks
- Switch passes it to IncomingPacket.tryDecode

**Pros:**
- Clean separation of concerns
- No circular dependencies
- Each layer only knows about its immediate dependencies

**Cons:**
- Adds complexity to Switch.Callbacks
- Need to update all Switch callback creation sites

#### Option 2: Switch Gets Node Pointer

**How it works:**
- Switch.Callbacks.ctx is typed as *Node (not ?*anyopaque)
- Switch can call node.createIncomingPacketCallbacks()

**Pros:**
- Simple and direct
- No extra indirection

**Cons:**
- Tight coupling between Switch and Node
- Loses abstraction benefit of opaque pointers

#### Option 3: Two-Phase Decoding

**How it works:**
- Switch.handlePacketHead just creates IncomingPacket
- Returns it to Node
- Node calls tryDecode with proper callbacks

**Pros:**
- Clean architectural layers
- Switch doesn't need Node dependencies

**Cons:**
- Changes packet flow significantly
- More complex control flow

#### Option 4: Defer Full Verb Dispatch (Current Approach)

**How it works:**
- Acknowledge we successfully decoded the packet
- Log packet metadata (src, dest, verb)
- Implement full verb dispatch as separate task

**Pros:**
- Unblocks other work (TUN device, peer management)
- Incremental progress
- Can test packet flow without verb logic

**Cons:**
- Cannot respond to peers yet
- Need to come back and finish this

---

## Current Implementation Status

### ✅ What Works

- Packet reception via UDP
- Packet header parsing
- Address validation
- Fragment detection
- IncomingPacket creation
- 30 / 71 callbacks stubbed

### ⚠️ What's Partial

- IncomingPacket.Callbacks structure (42% complete)
- Most callbacks return stub/default values
- No actual verb processing

### ❌ What's Missing

- Network operation callbacks (11 callbacks)
- Remaining topology callbacks (8 callbacks)
- Remaining peer callbacks (11 callbacks)
- Remaining path callbacks (2 callbacks)
- Remaining node callbacks (6 callbacks)
- Actual tryDecode() call

---

## Recommended Next Steps

### Immediate: Complete Minimal Callbacks

**Goal:** Get tryDecode() callable with minimum viable callbacks

**Tasks:**
1. Implement remaining stubs (41 callbacks)
2. Choose architecture option (recommend Option 1)
3. Wire up tryDecode() call in handlePacketHead
4. Test that tryDecode() is called

**Effort:** 1-2 days

**Blockers:** None - just coding work

### Short Term: Implement Basic Verbs

**Goal:** Respond to HELLO packets

**Tasks:**
1. Implement VERB_HELLO handler
2. Construct OK response packets
3. Send OK via wireSend
4. Test with real ZeroTier client

**Effort:** 2-3 days

**Blockers:** Need peer tracking (Topology module)

### Alternative: Defer and Focus on TUN Device

**Goal:** Get end-to-end traffic routing working first

**Rationale:**
- TUN device is independent of verb dispatch
- Can test with synthetic traffic
- Demonstrates more visible progress
- Verb dispatch can come later

**Trade-off:** Can't communicate with real ZeroTier network yet

---

## Decision Point

### Option A: Complete Verb Dispatch Now

**Timeline:** 3-5 days total
- Complete callbacks (1-2 days)
- Implement HELLO/OK (2-3 days)

**Pros:**
- Enables peer communication
- Can join real ZeroTier networks
- Unblocks network testing

**Cons:**
- Still can't route OS traffic (no TUN)
- More work before visible demo

### Option B: Defer Verb Dispatch, Do TUN Device

**Timeline:** 3-5 days total
- Implement TUN device (3-4 days)
- Test with synthetic packets (1 day)

**Pros:**
- Visible end-to-end demo (ping through VPN)
- Independent of peer communication
- Proves OS integration works

**Cons:**
- Can't talk to real ZeroTier network
- Need to come back to verb dispatch

---

## Recommendation

**Go with Option B (TUN Device First)** for these reasons:

1. **Visible Progress** - Being able to route traffic is more impressive
2. **Independent Work** - TUN doesn't depend on verbs
3. **Parallel Path** - Can implement verbs later without blocking
4. **Testing** - Can test with synthetic packets (bypass peer comms)

Then circle back to verb dispatch once we have:
- TUN device working
- Packet routing verified
- OS integration complete

This gives us a working VPN demo, even if it can't join real networks yet.

---

## Files Modified

- `src/node/node.zig` - Added createIncomingPacketCallbacks() (188 lines)
- No other files changed yet

---

## What's Next

### If Continuing Verb Dispatch:
1. Implement remaining 41 callbacks
2. Choose architecture (Option 1 or 2)
3. Wire up tryDecode() call
4. Test verb processing

### If Switching to TUN Device:
1. Create `src/node/tun_device.zig`
2. Implement utun device opening (macOS)
3. Wire up frame injection callbacks
4. Test packet routing

---

**Status:** 🟡 Verb dispatch 42% complete, awaiting architectural decision

**Recommendation:** Defer to next session, focus on TUN device

**Estimated completion:** 3-5 days for either path

---

**Last Updated:** 2026-03-28
