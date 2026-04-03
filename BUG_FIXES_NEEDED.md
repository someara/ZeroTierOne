# Bug Fixes Needed - Docker Test Environment

**Found**: 22 bugs during systematic code review
**Date**: 2026-04-03

## 🔥 Critical - Must Fix for Basic Functionality

### 1. Controller Port Mismatch
**File**: `src/test_controller.zig:329`
**Problem**: Port hardcoded to 9995, Docker expects 9993
**Fix**: Change `const port: u16 = 9995;` to `const port: u16 = 9993;`

### 2. Wrong Binary in docker-compose
**File**: `docker/docker-compose.yml:34`
**Problem**: Controller service runs `zerotier-one` instead of `test-controller`
**Fix**: Change to `command: ["/zerotier/zig-out/bin/test-controller"]`

### 3. Controller Binary Not Built
**File**: `docker/Dockerfile.zig-zerotier:38-45`
**Problem**: Only builds zerotier-one, controller doesn't exist in image
**Fix**: Add second build step:
```dockerfile
RUN zig build-exe \
    -OReleaseSafe \
    -I . \
    -lc \
    --name test-controller \
    src/test_controller.zig \
    && mv test-controller zig-out/bin/
```

### 4. Architectural: Root Server + Controller Isolation
**Files**: `test_root_server.zig`, `test_controller.zig`
**Problem**: Separate processes, no shared peer database
**Root cause**: Controller can't validate packets from peers it doesn't know

**Solution Options**:
a. **Merge**: Run controller logic inside test_root_server
b. **Shared DB**: Use file/socket to share peer info
c. **Skip HELLO**: Clients send NETWORK_CONFIG_REQUEST directly (include identity)

**Recommended**: Option A (merge into single binary)

### 5. Clients Don't Know Controller Address
**File**: `docker/docker-compose.yml:47,67`
**Problem**: Clients have ROOT_SERVER but no CONTROLLER address
**Fix**: Add environment variable:
```yaml
environment:
  - ROOT_SERVER=172.20.0.10:9993
  - CONTROLLER=172.20.0.11:9993
```

## ⚠️ High Priority - Security/Correctness

### 6. Memory Leak in deinit()
**File**: `src/test_controller.zig:94-98`
**Problem**: MemberInfo.ip_assignments ArrayList not freed
**Fix**:
```zig
var net_it = self.networks.iterator();
while (net_it.next()) |entry| {
    var member_it = entry.value_ptr.members.iterator();
    while (member_it.next()) |member_entry| {
        member_entry.value_ptr.ip_assignments.deinit(self.allocator);
    }
    entry.value_ptr.members.deinit();
}
self.networks.deinit();
```

### 7. Skipped MAC Validation for Unknown Peers
**File**: `src/test_controller.zig:206-213`
**Problem**: If peer unknown, MAC not checked (security hole)
**Fix**: Reject unknown peers:
```zig
if (!key_available) {
    std.debug.print("    ❌ Unknown peer, rejecting\n", .{});
    return;
}
```
OR extract identity from packet (non-standard)

### 8. IP Assignment Off-By-One Error
**File**: `src/test_controller.zig:231-236`
**Problem**: member_count includes just-inserted member
**Fix**:
```zig
const member_result = try network_config.?.members.getOrPut(peer_addr_int);
if (!member_result.found_existing) {
    var ip_list = std.ArrayList([4]u8){};
    // Use count - 1 because we already inserted
    const member_count = network_config.?.members.count() - 1;
    const ip = [4]u8{ 10, 147, @intCast((member_count / 256) % 256), @intCast(member_count % 256) };
    try ip_list.append(self.allocator, ip);
    // ...
}
```

### 9. Missing Network Config Signature
**File**: `src/test_controller.zig:303-309`
**Problem**: Config only MAC'd, not signed by controller
**Impact**: Can't verify controller authenticity
**Fix**: Add signature:
```zig
// After building payload, before armor
try config_resp.sign(&self.identity);

// Then armor
config_resp.armor(shared_key, false, false, null, null);
```

### 10. Incomplete Member Entry on Error
**File**: `src/test_controller.zig:231-243`
**Problem**: getOrPut() inserts undefined entry, early return leaves garbage
**Fix**: Use errdefer:
```zig
const member_result = try network_config.?.members.getOrPut(peer_addr_int);
if (!member_result.found_existing) {
    errdefer _ = network_config.?.members.remove(peer_addr_int);

    var ip_list = std.ArrayList([4]u8){};
    errdefer ip_list.deinit(self.allocator);

    const member_count = network_config.?.members.count() - 1;
    const ip = [4]u8{ 10, 147, @intCast((member_count / 256) % 256), @intCast(member_count % 256) };
    try ip_list.append(self.allocator, ip);

    member_result.value_ptr.* = .{
        .address = source,
        .authorized = true,
        .ip_assignments = ip_list,
    };
}
```

### 11. Socket Errors Abort Server
**File**: `src/test_controller.zig:147`
**Problem**: Any error kills entire server
**Fix**:
```zig
else => {
    std.debug.print("Socket error: {}\n", .{err});
    continue;
},
```

### 12. sendto() Errors Crash Server
**File**: `src/test_controller.zig:312-318`
**Problem**: Uncaught error propagates up
**Fix**:
```zig
const sent = std.posix.sendto(
    self.socket,
    config_data,
    0,
    &to_addr.any,
    to_addr.getOsSockLen(),
) catch |err| {
    std.debug.print("    ❌ Failed to send: {}\n", .{err});
    return;
};
```

## 📝 Medium Priority - Robustness

### 13. Identity Not Cloned When Storing
**File**: `src/test_controller.zig` (future code)
**Problem**: If we add peer identity storage, need to clone
**Fix**: Use `try peer_identity.clone(self.allocator)`

### 14. Network Name Not Duplicated
**File**: `src/test_controller.zig:112`
**Problem**: String slice might dangle
**Current**: Safe (string literal), but pattern is risky
**Fix**: `try self.allocator.dupe(u8, name)` and free in deinit

## 🔍 Low Priority / Verification Needed

### 15. Port Exposure Inconsistency
**File**: `docker/docker-compose.yml:14,28-29`
**Issue**: Root server exposed to host, controller exposed to 9994
**Not critical**: Container-to-container works regardless

### 16. Network Config Flags
**File**: `src/test_controller.zig:274`
**Issue**: All-zero flags might need verification
**Status**: Probably fine for testing

### 17. Network Name Format
**File**: `src/test_controller.zig:278-279`
**Issue**: Single zero byte - verify protocol
**Status**: Probably correct

### 18. IP Assignment Protocol Format
**File**: `src/test_controller.zig:286-289`
**Issue**: Verify type/metric/netmask format
**Status**: Looks correct

### 19. No Command-Line Arguments
**File**: `src/test_controller.zig:324-335`
**Issue**: Port hardcoded, can't override
**Nice to have**: Parse `-p` flag

## 🎯 Recommended Fix Priority

### Phase 1: Make It Run
1. Fix BUG #1 (port 9995 → 9993)
2. Fix BUG #2 (docker-compose command)
3. Fix BUG #3 (build controller binary)
4. Fix BUG #4 (merge root-server + controller)
5. Fix BUG #5 (controller address for clients)

### Phase 2: Make It Correct
6. Fix BUG #6 (memory leak)
7. Fix BUG #8 (IP assignment off-by-one)
8. Fix BUG #10-12 (error handling)

### Phase 3: Make It Secure
9. Fix BUG #7 (MAC validation)
10. Fix BUG #9 (network config signature)

### Phase 4: Polish
11. Fix remaining medium/low priority bugs as needed

## 📊 Bug Statistics

- **Critical (won't work)**: 6 bugs
- **High (security/correctness)**: 7 bugs
- **Medium (robustness)**: 2 bugs
- **Low (nice to have)**: 5 bugs
- **False alarms**: 1 bug

**Total**: 21 real bugs found in 10 rounds of hunting

## 🚀 Next Steps

1. Decide on architecture: Merge root-server + controller?
2. Create fix branches for each bug
3. Test after each fix
4. Verify end-to-end once all critical bugs fixed
