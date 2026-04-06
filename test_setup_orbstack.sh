#!/bin/bash
# Setup OrbStack Ubuntu VM for ZeroTea Linux testing
#
# This script automates the setup of an OrbStack VM for testing
# the Linux TUN device implementation.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  ZeroTea OrbStack Test Setup${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo ""

VM_NAME="zerotier-test"
PROJECT_DIR=$(pwd)

# Check if OrbStack is installed
if ! command -v orb &> /dev/null; then
    echo -e "${RED}✗ OrbStack not found${NC}"
    echo ""
    echo "Please install OrbStack:"
    echo "  https://orbstack.dev/"
    echo ""
    echo "Or use brew:"
    echo "  brew install orbstack"
    exit 1
fi

echo -e "${GREEN}✓ OrbStack found${NC}"
echo ""

# Check if VM already exists
if orb list -q | grep -q "^${VM_NAME}$"; then
    echo -e "${YELLOW}⚠ VM '${VM_NAME}' already exists${NC}"
    read -p "Delete and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing VM..."
        orb delete -f "$VM_NAME"
    else
        echo "Using existing VM..."
    fi
fi

# Create VM if it doesn't exist
if ! orb list -q | grep -q "^${VM_NAME}$"; then
    echo -e "${BLUE}Creating Ubuntu VM: ${VM_NAME}${NC}"
    orb create ubuntu:22.04 "$VM_NAME"
    echo -e "${GREEN}✓ VM created${NC}"
    sleep 2
fi

echo ""
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}Installing Dependencies${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"

# Install dependencies
echo "Updating package list..."
orb run -m "$VM_NAME" -- sudo apt-get update -qq

echo "Installing build tools..."
orb run -m "$VM_NAME" -- sudo apt-get install -y -qq \
    build-essential \
    curl \
    wget \
    git \
    linux-headers-generic \
    iproute2 \
    net-tools \
    iputils-ping

echo -e "${GREEN}✓ Dependencies installed${NC}"
echo ""

# Install Zig
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}Installing Zig${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"

ZIG_VERSION="0.14.0"
ZIG_ARCH="aarch64"

if orb run -m "$VM_NAME" -- test -d /opt/zig; then
    echo -e "${GREEN}✓ Zig already installed${NC}"
else
    echo "Downloading Zig ${ZIG_VERSION} for Linux ARM64..."
    orb run -m "$VM_NAME" -- "curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz | sudo tar -xJ -C /opt"

    echo "Setting up Zig symlink..."
    orb run -m "$VM_NAME" -- "sudo ln -sf /opt/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}/zig /usr/local/bin/zig"

    echo -e "${GREEN}✓ Zig installed${NC}"
fi

# Verify Zig installation
echo "Verifying Zig installation..."
if orb run -m "$VM_NAME" -- zig version > /dev/null 2>&1; then
    ZIG_VER=$(orb run -m "$VM_NAME" -- zig version)
    echo -e "${GREEN}✓ Zig version: ${ZIG_VER}${NC}"
else
    echo -e "${RED}✗ Zig verification failed${NC}"
    exit 1
fi

echo ""

# Sync project directory
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}Syncing Project Files${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"

echo "Copying ZeroTea project to VM..."
# OrbStack mounts macOS home directory automatically, but we'll copy for isolation
orb run -m "$VM_NAME" -- mkdir -p /home/ubuntu/ZeroTierOne

# Use rsync for efficient transfer
echo "Using rsync to sync files..."
# Get the mount point for the VM
VM_HOME="/Users/$USER/.orbstack/machines/$VM_NAME/home/ubuntu"
if [ -d "$VM_HOME" ]; then
    rsync -av --exclude='.git' --exclude='zig-out' --exclude='zig-cache' \
        --exclude='*.o' --exclude='*.a' --exclude='zerotier-one' \
        "$PROJECT_DIR/" "$VM_HOME/ZeroTierOne/"
    echo -e "${GREEN}✓ Project synced via filesystem${NC}"
else
    # Fallback: use orb push (slower)
    echo "Filesystem mount not found, using orb push..."
    tar -czf /tmp/zerotier-sync.tar.gz \
        --exclude='.git' --exclude='zig-out' --exclude='zig-cache' \
        --exclude='*.o' --exclude='*.a' --exclude='zerotier-one' \
        -C "$PROJECT_DIR" .
    orb run -m "$VM_NAME" -- "mkdir -p /home/ubuntu/ZeroTierOne && cd /home/ubuntu/ZeroTierOne && tar -xzf -" < /tmp/zerotier-sync.tar.gz
    rm /tmp/zerotier-sync.tar.gz
    echo -e "${GREEN}✓ Project synced via tar${NC}"
fi

echo ""

# Load TUN kernel module
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}Configuring TUN Device Support${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────────${NC}"

echo "Loading TUN kernel module..."
orb run -m "$VM_NAME" -- sudo modprobe tun

echo "Verifying /dev/net/tun..."
if orb run -m "$VM_NAME" -- test -e /dev/net/tun; then
    echo -e "${GREEN}✓ /dev/net/tun exists${NC}"
else
    echo -e "${RED}✗ /dev/net/tun not found${NC}"
    exit 1
fi

echo ""

# Run tests
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Running Tests${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo ""

echo "Executing test_service_linux.sh in VM..."
echo ""

orb run -m "$VM_NAME" -- "cd /home/ubuntu/ZeroTierOne && sudo ./test_service_linux.sh"

TEST_RESULT=$?

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"

if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}  ✓ All tests passed!${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Linux TUN device implementation verified!"
    echo ""
    echo "VM details:"
    echo "  Name: $VM_NAME"
    echo "  Access: orb run -m $VM_NAME"
    echo "  Project: /home/ubuntu/ZeroTierOne"
    echo ""
    echo "To run tests again:"
    echo "  orb run -m $VM_NAME -- 'cd /home/ubuntu/ZeroTierOne && sudo ./test_service_linux.sh'"
    echo ""
    echo "To delete VM:"
    echo "  orb delete $VM_NAME"
else
    echo -e "${RED}  ✗ Tests failed${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Check logs in VM:"
    echo "  orb run -m $VM_NAME -- cat /tmp/zt-service.log"
    echo "  orb run -m $VM_NAME -- cat /tmp/zt-service-tun.log"
    echo ""
    echo "Debug in VM:"
    echo "  orb shell $VM_NAME"
    echo "  cd /home/ubuntu/ZeroTierOne"
    echo "  sudo ./test_service_linux.sh"
fi

exit $TEST_RESULT
