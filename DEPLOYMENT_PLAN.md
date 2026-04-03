# Deployment Plan: Cloud VM Testing

## Objective

Deploy ZeroTier Zig service to a clean Linux VM to validate end-to-end VPN functionality without firewall restrictions.

## Why This Is Needed

**Current Blocker:** Dev machine (macOS with GlobalProtect) blocks incoming UDP packets from ZeroTier root servers.

**Evidence:**
- Service sends HELLO packets (verified in logs)
- **Zero responses received** from any root server
- Service stuck at "REQUESTING_CONFIGURATION" indefinitely
- No way to verify bidirectional communication works

**What We Need to Prove:**
1. Can complete HELLO handshake with real root servers
2. Can receive and decrypt HELLO OK responses
3. Can receive network configuration from controllers
4. Can establish peer relationships
5. Can route actual VPN traffic

## Target Environment

### Option 1: AWS EC2 (Recommended)
- **Instance Type:** t3.micro (free tier eligible)
- **OS:** Ubuntu 24.04 LTS (ARM64 for M-series Mac parity)
- **Region:** us-west-2 (low latency)
- **Security Group:** Allow UDP 9993 inbound/outbound
- **Cost:** ~$0.01/hour or free tier

### Option 2: DigitalOcean Droplet
- **Size:** Basic ($4/month, ~$0.006/hour)
- **OS:** Ubuntu 24.04 LTS (ARM64)
- **Firewall:** Allow UDP 9993
- **Cost:** Prorated hourly billing

### Option 3: Hetzner Cloud (Cheapest)
- **Type:** CAX11 (ARM64)
- **OS:** Ubuntu 24.04
- **Cost:** €4.15/month (~$0.006/hour)
- **Location:** EU or US

## Deployment Steps

### 1. Provision VM
```bash
# AWS EC2 example
aws ec2 run-instances \
  --image-id ami-0abcdef1234567890 \
  --instance-type t3.micro \
  --key-name my-key \
  --security-groups zerotier-test \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=zerotier-zig-test}]'
```

### 2. Install Dependencies
```bash
# SSH to VM
ssh ubuntu@<vm-ip>

# Install Zig
wget https://ziglang.org/download/0.15.2/zig-linux-aarch64-0.15.2.tar.xz
tar xf zig-linux-aarch64-0.15.2.tar.xz
sudo mv zig-linux-aarch64-0.15.2 /usr/local/zig
export PATH=/usr/local/zig:$PATH

# Verify
zig version  # Should show 0.15.2
```

### 3. Transfer Code
```bash
# On local machine
cd ~/src/ZeroTierOne
git bundle create zerotier.bundle zerotea

# Copy to VM
scp zerotier.bundle ubuntu@<vm-ip>:~/

# On VM
git clone zerotier.bundle zerotier-zig
cd zerotier-zig
git checkout zerotea
```

### 4. Build and Run
```bash
# Build
zig build

# Create home directory
mkdir -p /tmp/zerotier-test

# Run service
zig build service -- -d /tmp/zerotier-test

# In another terminal, test API
TOKEN=$(cat /tmp/zerotier-test/authtoken.secret)
curl -H "X-ZT1-Auth: $TOKEN" http://127.0.0.1:9993/status

# Join test network
curl -X POST -H "X-ZT1-Auth: $TOKEN" \
  http://127.0.0.1:9993/network/8056c2e21c000001
```

### 5. Monitor Logs
```bash
# Watch for incoming packets
tail -f /tmp/zerotier-service.log | grep "→"

# Expected success indicators:
# → UDP [packet] from <root-server>  [INCOMING PACKET!]
# [HELLO OK] Received from <peer>
# [CONFIG] Network configuration received
# → Event: NETWORK_CONFIG_UPDATED
```

## Success Criteria

### ✅ Minimum Viable Success
1. **Receive HELLO OK** from at least one root server
2. **Decrypt response** successfully (see verb=OK in logs)
3. **Peer relationship** established (have root server identity)

### ✅ Full Success
1. All of above, plus:
2. **Network configuration received** from controller
3. **Status changes** from REQUESTING_CONFIGURATION to OK
4. **IP address assigned** to node
5. **(Bonus) TUN device created** and can ping other nodes

### ❌ Failure Modes to Watch For
- Still no incoming packets (VM firewall issue)
- Incoming packets but decryption fails (crypto bug)
- Decryption works but verb=ERROR (protocol issue)
- Configuration received but can't parse (parsing bug)

## Rollback/Cleanup

```bash
# Stop service
pkill zerotier-one

# Clean up
rm -rf /tmp/zerotier-test

# Terminate VM (if using AWS)
aws ec2 terminate-instances --instance-ids <instance-id>
```

## Cost Estimate

- **Setup time:** ~30 minutes
- **Testing time:** 1-2 hours
- **Total cost:** $0.01-0.02 (using free tier) or $0.01-0.02 (paid)

## Alternative: Docker Container

If VM setup is too heavyweight:

```dockerfile
# Dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y wget xz-utils
RUN wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz && \
    tar xf zig-linux-x86_64-0.15.2.tar.xz && \
    mv zig-linux-x86_64-0.15.2 /usr/local/zig
ENV PATH="/usr/local/zig:$PATH"
COPY . /zerotier
WORKDIR /zerotier
RUN zig build
EXPOSE 9993/udp 9993/tcp
CMD ["zig", "build", "service", "--", "-d", "/tmp/zerotier"]
```

```bash
# Build and run
docker build -t zerotier-zig .
docker run -p 9993:9993/udp -p 9993:9993/tcp zerotier-zig

# Test from host
curl http://localhost:9993/status
```

**Note:** Docker may still have NAT/firewall issues. VM is more reliable for network testing.

## Next Steps After Deployment

Once deployed:
1. **Capture first HELLO OK response** → Proves crypto works end-to-end
2. **Debug any decryption failures** → Fix crypto bugs if found
3. **Complete full network join** → Validate configuration protocol
4. **Test multi-peer** → Join same network from another node, verify can communicate
5. **Stress test** → Send 1000+ packets, verify no leaks/crashes

Then we can legitimately say "VPN functionality verified" ✅
