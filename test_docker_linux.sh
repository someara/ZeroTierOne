#!/bin/bash
# Test ZeroTea Linux TUN device using Docker
#
# Uses Docker with --privileged flag to access TUN devices

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  ZeroTea Docker Linux Test${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo ""

PROJECT_DIR=$(pwd)
CONTAINER_NAME="zerotier-test-$$"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Docker found${NC}"

# Create temporary Dockerfile
DOCKERFILE=$(mktemp)
cat > "$DOCKERFILE" <<'EOF'
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    curl \
    linux-headers-generic \
    iproute2 \
    net-tools \
    iputils-ping \
    kmod \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2 (match macOS version)
RUN curl -L https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz | tar -xJ -C /opt && \
    ln -sf /opt/zig-aarch64-linux-0.15.2/zig /usr/local/bin/zig

WORKDIR /src

CMD ["/bin/bash"]
EOF

echo "Building Docker image..."
if ! docker build -t zerotier-linux-test -f "$DOCKERFILE" . > /tmp/docker-build.log 2>&1; then
    echo -e "${RED}✗ Docker build failed${NC}"
    cat /tmp/docker-build.log
    rm "$DOCKERFILE"
    exit 1
fi

rm "$DOCKERFILE"
echo -e "${GREEN}✓ Docker image built${NC}"
echo ""

echo "Running tests in container (with --privileged for TUN access)..."
echo ""

# Run container with privileged access for TUN
docker run --rm --privileged \
    --name "$CONTAINER_NAME" \
    -v "$PROJECT_DIR:/src" \
    -w /src \
    zerotier-linux-test \
    /bin/bash -c "
        set -e
        echo 'Loading TUN kernel module...'
        modprobe tun || true

        echo 'Verifying /dev/net/tun...'
        if [ ! -e /dev/net/tun ]; then
            echo 'ERROR: /dev/net/tun not available'
            exit 1
        fi

        echo ''
        echo 'Running Linux test suite...'
        echo ''

        exec ./test_service_linux.sh
    "

TEST_RESULT=$?

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"

if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}  ✓ All tests passed!${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Linux TUN device implementation verified!"
    echo ""
else
    echo -e "${RED}  ✗ Tests failed${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "To debug:"
    echo "  docker run --rm -it --privileged -v \$(pwd):/src zerotier-linux-test"
    echo "  cd /src && ./test_service_linux.sh"
fi

exit $TEST_RESULT
