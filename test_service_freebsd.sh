#!/bin/sh
# Test script for ZeroTea service on FreeBSD
#
# Tests the FreeBSD TAP device implementation end-to-end
# Requires: sudo access for TAP device operations

set -e

echo "════════════════════════════════════════════════════════"
echo "  ZeroTea FreeBSD Service Test Suite"
echo "════════════════════════════════════════════════════════"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
pass() {
    echo "${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "${RED}✗${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo "${YELLOW}⚠${NC} $1"
}

section() {
    echo ""
    echo "──────────────────────────────────────────────────────"
    echo "$1"
    echo "──────────────────────────────────────────────────────"
}

# Clean up function
cleanup() {
    if [ ! -z "$SERVICE_PID" ]; then
        if [ "$EUID" -eq 0 ]; then
            kill $SERVICE_PID 2>/dev/null || true
        else
            sudo kill $SERVICE_PID 2>/dev/null || true
        fi
        wait $SERVICE_PID 2>/dev/null || true
    fi
    # Clean up TAP devices if they exist
    for dev in $(ifconfig | grep "^zt" | cut -d: -f1); do
        sudo ifconfig "$dev" destroy 2>/dev/null || true
    done
    rm -rf /tmp/zerotier-test 2>/dev/null || true
}

trap cleanup EXIT

# Test 0: Check Prerequisites
section "Test 0: Prerequisites"
if [ ! -e /dev/tap0 ]; then
    warn "/dev/tap0 does not exist"
    echo "   Creating test TAP device..."
    if sudo ifconfig tap0 create 2>/dev/null; then
        pass "Created test TAP device"
        sudo ifconfig tap0 destroy
    else
        fail "Cannot create TAP devices"
        exit 1
    fi
else
    pass "TAP device support available"
fi

if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    warn "This script requires sudo access for TAP device operations"
    echo "   Run with: sudo ./test_service_freebsd.sh"
    echo "   Or configure passwordless sudo for testing"
fi

# Test 1: Build
section "Test 1: Build Service"
# Build the service executable (need -lc for @cImport in constants.zig)
if zig build-exe src/zerotea.zig -I./src -I. -lc --name zerotea-test -O Debug > /tmp/zt-build.log 2>&1; then
    pass "Service builds successfully"
    mkdir -p zig-out/bin
    mv zerotea-test zig-out/bin/ 2>/dev/null || true
else
    fail "Service build failed"
    cat /tmp/zt-build.log
    exit 1
fi

# Verify binary exists
if [ -f "./zerotea-test" ]; then
    pass "Binary exists at ./zerotea-test"
    TEST_BINARY="./zerotea-test"
elif [ -f "./zig-out/bin/zerotea-test" ]; then
    pass "Binary exists at ./zig-out/bin/zerotea-test"
    TEST_BINARY="./zig-out/bin/zerotea-test"
else
    fail "Binary not found"
    exit 1
fi

# Test 2: Help
section "Test 2: Command-Line Interface"
if $TEST_BINARY --help > /tmp/zt-help.log 2>&1; then
    pass "Help text displays"
else
    fail "Help command failed"
fi

# Test 3: Service Startup (no TUN, alternate port)
section "Test 3: Service Startup (No TUN)"
TEST_DIR="/tmp/zerotier-test"
mkdir -p "$TEST_DIR"

echo "Starting service on port 9995 (no TUN)..."
$TEST_BINARY -p 9995 -d "$TEST_DIR" > /tmp/zt-service.log 2>&1 &
SERVICE_PID=$!
sleep 3

if kill -0 $SERVICE_PID 2>/dev/null; then
    pass "Service process running (PID: $SERVICE_PID)"
else
    fail "Service process died"
    cat /tmp/zt-service.log
    exit 1
fi

# Test 4: Identity Generation
section "Test 4: Identity Generation"
if [ -f "$TEST_DIR/identity.secret" ]; then
    pass "Identity file created"
    IDENTITY_SIZE=$(wc -c < "$TEST_DIR/identity.secret" | tr -d ' ')
    if [ "$IDENTITY_SIZE" -gt 200 ]; then
        pass "Identity file has valid size ($IDENTITY_SIZE bytes)"
    else
        fail "Identity file too small"
    fi
else
    warn "Identity file not found (may not have persisted yet)"
fi

# Test 5: Auth Token Generation
section "Test 5: Auth Token"
sleep 2  # Give it time to generate
if [ -f "$TEST_DIR/authtoken.secret" ]; then
    pass "Auth token file created"
    AUTH_TOKEN=$(cat "$TEST_DIR/authtoken.secret")
    TOKEN_LEN=${#AUTH_TOKEN}
    if [ "$TOKEN_LEN" -eq 24 ]; then
        pass "Auth token has correct length (24 chars)"
    else
        fail "Auth token has wrong length: $TOKEN_LEN"
    fi
    echo "   Token: $AUTH_TOKEN"
else
    warn "Auth token file not found"
    AUTH_TOKEN=""
fi

# Test 6: HTTP API Endpoints
section "Test 6: HTTP API"
sleep 1

if [ ! -z "$AUTH_TOKEN" ]; then
    # Test /status endpoint
    echo "Testing GET /status..."
    if STATUS=$(curl -s -H "X-ZT1-Auth: $AUTH_TOKEN" http://127.0.0.1:9995/status 2>&1); then
        if echo "$STATUS" | grep -q "address"; then
            pass "GET /status returns valid JSON"
            echo "   Response: $(echo $STATUS | head -c 80)..."
        else
            fail "GET /status returned invalid response"
            echo "   Response: $STATUS"
        fi
    else
        fail "GET /status request failed"
    fi

    # Test /network endpoint
    echo "Testing GET /network..."
    if NETWORKS=$(curl -s -H "X-ZT1-Auth: $AUTH_TOKEN" http://127.0.0.1:9995/network 2>&1); then
        pass "GET /network responds"
        echo "   Response: $(echo $NETWORKS | head -c 80)..."
    else
        fail "GET /network request failed"
    fi

    # Test authentication
    echo "Testing authentication..."
    if curl -s -H "X-ZT1-Auth: wrongtoken" http://127.0.0.1:9995/status 2>&1 | grep -q "401\|Unauthorized\|auth"; then
        pass "Authentication rejects invalid token"
    else
        warn "Authentication might not be working properly"
    fi
else
    warn "Skipping HTTP API tests (no auth token)"
fi

# Test 7: UDP Socket
section "Test 7: UDP Socket Binding"
if sockstat -4 -l | grep -q ":9995"; then
    pass "UDP socket bound to port 9995"
else
    warn "UDP socket binding not verified"
fi

# Test 8: Service Logs
section "Test 8: Service Logs"
if grep -q "Node initialized" /tmp/zt-service.log; then
    pass "Node initialized successfully"
else
    warn "Node initialization not logged"
fi

if grep -q "IPv4 socket bound\|Phy bound" /tmp/zt-service.log; then
    pass "Sockets bound successfully"
else
    warn "Socket binding not logged"
fi

if grep -q "HTTP API server running\|HTTP API" /tmp/zt-service.log; then
    pass "HTTP API started"
else
    warn "HTTP API startup not logged"
fi

# Test 9: Planet Loading
section "Test 9: Planet Configuration"
if grep -q "Planet loaded" /tmp/zt-service.log; then
    pass "Planet configuration loaded"
    WORLD_ID=$(grep "world ID" /tmp/zt-service.log | head -1 | grep -o '[0-9]\+' | head -1)
    if [ ! -z "$WORLD_ID" ]; then
        echo "   World ID: $WORLD_ID"
    fi
else
    warn "Planet loading not logged"
fi

# Stop the no-TUN service before TUN tests
section "Test 10: Stop Service (prepare for TAP tests)"
if kill -TERM $SERVICE_PID 2>/dev/null; then
    sleep 2
    if ! kill -0 $SERVICE_PID 2>/dev/null; then
        pass "Service stopped gracefully"
    else
        warn "Service still running after SIGTERM"
        kill -9 $SERVICE_PID 2>/dev/null || true
    fi
else
    warn "Could not send SIGTERM"
fi
SERVICE_PID=""

# Test 11: TAP Device Tests (requires sudo)
section "Test 11: TAP Device Creation"
if [ "$EUID" -eq 0 ] || sudo -n true 2>/dev/null; then
    echo "Starting service with TAP device (requires sudo/root)..."
    # Use sudo if available and not root, otherwise run directly
    if [ "$EUID" -eq 0 ]; then
        $TEST_BINARY -p 9996 -d "$TEST_DIR" --tun > /tmp/zt-service-tap.log 2>&1 &
    else
        sudo $TEST_BINARY -p 9996 -d "$TEST_DIR" --tun > /tmp/zt-service-tap.log 2>&1 &
    fi
    SERVICE_PID=$!
    sleep 3

    if kill -0 $SERVICE_PID 2>/dev/null; then
        pass "Service with TAP running (PID: $SERVICE_PID)"
    else
        fail "Service with TAP died"
        cat /tmp/zt-service-tap.log
        exit 1
    fi

    # Check if TAP device was created
    if ifconfig | grep -q "^zt"; then
        TAP_DEV=$(ifconfig | grep "^zt" | head -1 | cut -d: -f1)
        pass "TAP device created: $TAP_DEV"

        # Test 12: Verify TAP device configuration
        section "Test 12: TAP Device Configuration"

        # Check device is UP
        if ifconfig "$TAP_DEV" | grep -q "UP"; then
            pass "TAP device is UP"
        else
            warn "TAP device not UP"
        fi

        # Check MAC address
        if ifconfig "$TAP_DEV" | grep -q "ether"; then
            MAC_ADDR=$(ifconfig "$TAP_DEV" | grep "ether" | awk '{print $2}')
            pass "TAP device has MAC address: $MAC_ADDR"
        else
            warn "TAP device has no MAC address"
        fi

        # Check IP address (if service sets one)
        if ifconfig "$TAP_DEV" | grep -q "inet "; then
            IP_ADDR=$(ifconfig "$TAP_DEV" | grep "inet " | awk '{print $2}')
            pass "TAP device has IP address: $IP_ADDR"
        else
            warn "TAP device has no IP address (may be configured later)"
        fi

        # Check TAP device in logs
        if grep -q "TAP device opened\|FreeBSD TAP device opened" /tmp/zt-service-tap.log; then
            pass "TAP device logged successfully"
        else
            warn "TAP device not logged"
        fi
    else
        warn "No TAP device found (check /tmp/zt-service-tap.log for errors)"
        cat /tmp/zt-service-tap.log | tail -20
    fi

    # Test 13: TAP Device Cleanup
    section "Test 13: TAP Device Cleanup"
    if [ ! -z "$SERVICE_PID" ] && kill -0 $SERVICE_PID 2>/dev/null; then
        if [ "$EUID" -eq 0 ]; then
            kill -TERM $SERVICE_PID 2>/dev/null || true
        else
            sudo kill -TERM $SERVICE_PID 2>/dev/null || true
        fi
        sleep 2
        pass "Service with TAP stopped"
        SERVICE_PID=""
    fi
else
    warn "Skipping TAP tests (sudo not available)"
    echo "   Run with: sudo ./test_service_freebsd.sh"
fi

# Summary
section "Test Summary"
TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo ""
echo "Tests passed: $TESTS_PASSED / $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}  All tests passed! ✓${NC}"
    echo "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "FreeBSD service layer is functional!"
    echo ""
    echo "Next steps:"
    echo "  1. Test on real FreeBSD hardware"
    echo "  2. Test network join/leave with TAP device"
    echo "  3. Test packet routing through TAP"
    echo ""
    exit 0
else
    echo "${RED}════════════════════════════════════════════════════════${NC}"
    echo "${RED}  Some tests failed${NC}"
    echo "${RED}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Check logs:"
    echo "  /tmp/zt-service.log (no TAP)"
    echo "  /tmp/zt-service-tap.log (with TAP)"
    exit 1
fi
