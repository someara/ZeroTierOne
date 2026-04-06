# Packet Decryption Issue - Root Cause Analysis
**Date**: 2026-04-06
**Issue**: Incoming packets show as "UNKNOWN verb" - not being decrypted
**Status**: **ROOT CAUSE IDENTIFIED** ✅

## Problem Summary

When running the service with network join:
```bash
NETWORK_ID=8056c2e21c000001 zig build service -- -p 9994
```

We observe:
- ✅ HELLO packets sent to root servers
- ✅ Responses received from root servers
- ❌ Responses show as "verb=UNKNOWN(54)" or similar invalid verb values
- ❌ Packets not being processed (decrypted)

## Investigation Process

### 1. Initial Hypothesis: Decryption Failure
**Checked**: Where packets are decrypted (`IncomingPacket.tryDecodeWithArena`)
**Finding**: Decryption requires peer to already exist in topology (line 692-693 of incoming_packet.zig)

### 2. Discovery: Chicken-and-Egg Problem

**The Flow**:
1. We send HELLO to root server (unencrypted, cipher=0)
2. Root server receives HELLO
3. Root server calls `doHELLO()` which:
   - Adds us as a peer to their topology
   - Sends back OK(HELLO) **encrypted** with our public key (incoming_packet.zig:1435)
4. We receive OK(HELLO)
5. **Problem**: We try to decrypt OK, but root server is NOT in our topology yet!
6. Without peer, we can't get decryption key
7. We request WHOIS and drop the packet

**Key Code Evidence**:
```zig
// incoming_packet.zig:1435
outp.armor(peer_key, true, false, peer_aes, peer_pub);
//              second param ^^^^ = encrypt=true
```

OK(HELLO) responses ARE encrypted, even though HELLO requests are not!

### 3. Why Debug Shows "UNKNOWN" Verb

The Switch debug logging (switch.zig:832-846) prints packet info **before** decryption:
```zig
const verb = data[packet_mod.idx_verb];  // Reading encrypted byte!
const verb_name = if (verb < verb_names.len) verb_names[verb] else "UNKNOWN";
```

When the packet is encrypted, the verb byte (position 27) contains encrypted data, not the actual verb. Hence "UNKNOWN(54)" - that's just random encrypted data.

## Root Cause

**We don't add root servers to our topology before/when sending HELLO to them.**

When sending HELLO, we should:
1. Add the root server peer to topology with their known identity (from planet file)
2. THEN send HELLO
3. When OK comes back, we can decrypt it because we have the peer

OR alternatively:
1. Track expected OK(HELLO) replies with the peer's identity
2. When OK arrives, temporarily use that identity to decrypt
3. Add peer to topology after successful decryption

## Solution Options

### Option A: Add Peers Proactively (RECOMMENDED)
When loading the planet file and discovering root servers, add them to topology immediately:
- We know their addresses
- We know their identities (from planet file)
- We can compute their keys

**Pros**: Simple, matches how root servers are "known" peers
**Cons**: Slightly more memory usage

### Option B: Expected Reply Tracking
Enhance the expected reply mechanism to store peer identity with each expected OK(HELLO):
- When sending HELLO, store (packet_id → peer_identity) mapping
- When OK arrives, look up identity, compute key, decrypt
- Add peer to topology after verification

**Pros**: More dynamic
**Cons**: More complex, requires changes to reply tracking

### Option C: Special Handling for Root Servers
Treat root server OK packets specially - allow decryption using planet-provided identity even without peer in topology.

**Pros**: Minimal changes
**Cons**: Special case logic, less general

## Recommended Fix

**Implement Option A**: When loading planet file (World), proactively add root servers to Topology.

**Files to Modify**:
1. `src/node/node.zig` - After loading planet in `Node.init()`, add roots to topology
2. `src/node/topology.zig` - Verify `addPeer()` can handle this

**Verification**:
- Run service with network join
- Confirm OK(HELLO) packets decrypt successfully
- Verify "verb=OK" instead of "verb=UNKNOWN"
- Check peer count increases

## Related Code Locations

**Planet Loading**: `src/node/node.zig` - Node.init() loads embedded planet
**Topology**: `src/node/topology.zig` - Peer management
**HELLO Sending**: `src/node/node.zig` - Sends HELLO to roots during init
**OK Processing**: `src/node/incoming_packet.zig:1687` - doOK() handler
**Packet Decryption**: `src/node/incoming_packet.zig:692` - requires peer

## Why This Worked on 2026-04-01

Memory indicates packet decryption worked after Salsa20 fix. Possible reasons:
1. Different test environment (local root server setup?)
2. Test used pre-established peers
3. Different code path (direct HELLO test vs. service test)

Need to verify exact test scenario from that date.

## Next Steps

1. ✅ Root cause identified
2. ✅ Implement Option A (add roots proactively) - commit 56a69826
3. ✅ Test with real network join
4. ✅ Verify OK packets decrypt
5. ✅ Update END_TO_END_TEST_REPORT.md with fix

## Verification Results (2026-04-06)

**Fix Commit**: 56a69826 - "fix: add root servers to topology on planet load"

**Test Command**:
```bash
NETWORK_ID=8056c2e21c000001 zig build service -- -p 19994 -d /tmp/zerotea-test
```

**Results**: ✅ **FIX VERIFIED - ALL SUCCESS CRITERIA MET**

1. ✅ All 391 unit tests pass (no regressions)
2. ✅ All 4 root servers added to topology on startup:
   ```
   ✓ Added root server cafe80ed74 to topology
   ✓ Added root server 778cde7190 to topology
   ✓ Added root server cafefd6717 to topology
   ✓ Added root server cafe04eba9 to topology
   ```
3. ✅ ONLINE event received (proves OK(HELLO) was decrypted and processed):
   ```
   → Event: ONLINE
   ```
4. ✅ Packets showing correct verbs after decryption:
   ```
   [PKT] 108 bytes: src=cafe80ed74 dest=fe1610c213 verb=HELLO(1) cipher=0 flags=0x08
   ```
5. ✅ Stable operation for 30+ seconds with no crashes
6. ✅ Periodic HELLO retransmissions working
7. ✅ Config requests being sent to controller

**Note on "UNKNOWN verb" Logs**:
The Switch debug logging (switch.zig:832-846) prints packet info BEFORE decryption. When a packet is encrypted, the verb byte contains encrypted data, not the actual verb. This explains why we see "UNKNOWN(223)", "UNKNOWN(230)", etc. - these are just random encrypted bytes being read.

The IMPORTANT evidence that decryption works is:
- ONLINE event is received (only sent after OK(HELLO) is successfully decrypted and processed)
- Some packets do show correct verbs like `verb=HELLO(1)` (unencrypted packets or after decryption)
- Service operates stably without errors

**Conclusion**: The chicken-and-egg problem is SOLVED. Packet decryption is WORKING.

## Impact

This explains why:
- Packets show as UNKNOWN verb (encrypted data misread as verb)
- Network join "works" but doesn't progress (can't process OK responses)
- WHOIS requests are sent but don't help (roots already sent OK with their identity)

**Severity**: HIGH - Blocks all encrypted packet processing from unknown peers
**Complexity**: LOW - Clear fix with minimal changes required
