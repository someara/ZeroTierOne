# Testing ZeroTier on Linux

This document describes how to test the ZeroTier Zig service layer on Linux, particularly the TUN device implementation.

## Quick Start (OrbStack - Recommended)

The easiest way to test on Linux from macOS is using OrbStack:

```bash
# One command to set up VM and run all tests
./test_setup_orbstack.sh
```

This script will:
1. Create an Ubuntu 22.04 ARM64 VM
2. Install dependencies (Zig, build tools)
3. Sync the project directory
4. Configure TUN device support
5. Run the full test suite

**Requirements**:
- macOS with Apple Silicon (M1/M2/M3)
- [OrbStack](https://orbstack.dev/) installed
- ~2GB free disk space for VM

## Manual Testing in OrbStack

If you want more control:

```bash
# Create VM
orb create ubuntu:22.04 zerotier-test

# Install dependencies
orb run -m zerotier-test -- sudo apt-get update
orb run -m zerotier-test -- sudo apt-get install -y \\
    build-essential curl linux-headers-generic

# Install Zig
orb run -m zerotier-test -- "curl -L https://ziglang.org/download/0.14.0/zig-linux-aarch64-0.14.0.tar.xz | sudo tar -xJ -C /opt"
orb run -m zerotier-test -- "sudo ln -sf /opt/zig-linux-aarch64-0.14.0/zig /usr/local/bin/zig"

# Copy project
rsync -av . ~/.orbstack/machines/zerotier-test/home/ubuntu/ZeroTierOne/

# Run tests
orb run -m zerotier-test -- 'cd ~/ZeroTierOne && sudo ./test_service_linux.sh'

# Or get a shell
orb shell zerotier-test
cd ~/ZeroTierOne
sudo ./test_service_linux.sh
```

## Test Script: `test_service_linux.sh`

The Linux test script is based on the macOS version but adapted for Linux:

### What it Tests

**Without TUN (no sudo required)**:
- ✓ Service builds on Linux
- ✓ Service starts and runs
- ✓ Identity generation and persistence
- ✓ Auth token generation
- ✓ HTTP API endpoints (GET /status, GET /network)
- ✓ UDP socket binding
- ✓ Planet configuration loading

**With TUN (requires sudo)**:
- ✓ TUN device creation (`/dev/net/tun`)
- ✓ Device opened successfully (tun0, tun1, etc.)
- ✓ IP address configuration
- ✓ Interface brought UP
- ✓ Device cleanup on shutdown

### Running Tests

```bash
# Full test suite (requires sudo for TUN tests)
sudo ./test_service_linux.sh

# Or build and test manually
zig build service
sudo ./zig-out/bin/zerotier-one --tun
```

### Expected Output

```
════════════════════════════════════════════════════════
  ZeroTier Linux Service Test Suite
════════════════════════════════════════════════════════

──────────────────────────────────────────────────────
Test 0: Prerequisites
──────────────────────────────────────────────────────
✓ /dev/net/tun exists

──────────────────────────────────────────────────────
Test 1: Build Service
──────────────────────────────────────────────────────
✓ Service builds successfully
✓ Binary exists

... (more tests)

──────────────────────────────────────────────────────
Test 11: TUN Device Creation
──────────────────────────────────────────────────────
✓ Service with TUN running
✓ TUN device created: tun0
✓ TUN device is UP
✓ TUN device logged successfully

════════════════════════════════════════════════════════
  ✓ All tests passed!
════════════════════════════════════════════════════════
```

## Troubleshooting

### TUN Device Not Available

```bash
# Check if module is loaded
lsmod | grep tun

# Load TUN module
sudo modprobe tun

# Verify device exists
ls -l /dev/net/tun
```

### Permission Denied

TUN device operations require root:

```bash
# Run with sudo
sudo ./test_service_linux.sh

# Or configure passwordless sudo for testing
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER
```

### Build Failures

```bash
# Check Zig version
zig version  # Should be 0.14.0 or later

# Clean build
rm -rf zig-cache zig-out
zig build service
```

### VM Issues (OrbStack)

```bash
# Restart VM
orb restart zerotier-test

# Delete and recreate
orb delete zerotier-test
./test_setup_orbstack.sh

# Check VM status
orb list
orb status zerotier-test
```

## Cross-Platform Verification

The Linux and macOS implementations should behave identically:

| Feature | macOS (utun) | Linux (/dev/net/tun) |
|---------|-------------|---------------------|
| Device Creation | ✓ | ✓ |
| IP Configuration | ✓ (ifconfig) | ✓ (ioctl) |
| Route Management | ✓ (route) | ✓ (ip route) |
| Non-blocking I/O | ✓ | ✓ |
| Packet Read/Write | ✓ | ✓ |

## Testing on Real Linux Hardware

If you have access to a Linux machine:

```bash
# Clone the repo
git clone https://github.com/someara/ZeroTierOne.git
cd ZeroTierOne
git checkout zerotea

# Install Zig
curl -L https://ziglang.org/download/0.14.0/zig-linux-$(uname -m)-0.14.0.tar.xz | tar -xJ
sudo ln -sf $(pwd)/zig-linux-*/zig /usr/local/bin/zig

# Run tests
sudo ./test_service_linux.sh
```

## CI/CD Integration

GitHub Actions runners support TUN devices. Add to `.github/workflows/test-linux-tun.yml`:

```yaml
name: Test Linux TUN Device
on: [pull_request, push]
jobs:
  test-tun:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Zig
        run: |
          curl -L https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz | tar -xJ
          sudo ln -sf $(pwd)/zig-linux-*/zig /usr/local/bin/zig
      - name: Test TUN device
        run: sudo ./test_service_linux.sh
```

## Next Steps

After verifying Linux TUN device:
1. Test network join/leave operations
2. Test packet routing through TUN
3. Test multi-network scenarios
4. Performance testing (throughput, latency)
5. Stress testing (many peers, high packet rate)

## Resources

- [OrbStack Documentation](https://docs.orbstack.dev/)
- [Linux TUN/TAP Documentation](https://www.kernel.org/doc/Documentation/networking/tuntap.txt)
- [ZeroTier Protocol Specification](https://docs.zerotier.com/)
