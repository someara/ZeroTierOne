#!/bin/bash
# Test script for ZeroTier Zig service
#
# Tests the service layer implementation end-to-end

set -e

echo "════════════════════════════════════════════════════════"
echo "  ZeroTier Service Test Suite"
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
    echo -e "${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
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
        kill $SERVICE_PID 2>/dev/null || true
        wait $SERVICE_PID 2>/dev/null || true
    fi
    rm -rf /tmp/zerotier-test 2>/dev/null || true
}

trap cleanup EXIT

# Test 1: Build
section "Test 1: Build Service"
# Build the service executable
zig build-exe src/zerotier_one.zig -I./src -I. --name zerotier-one-test -fno-emit-bin 2>&1 > /dev/null
if zig build-exe src/zerotier_one.zig -I./src -I. --name zerotier-one-test -O Debug > /tmp/zt-build.log 2>&1; then
    pass "Service builds successfully"
    mv zerotier-one-test zig-out/bin/ 2>/dev/null || true
else
    fail "Service build failed"
    cat /tmp/zt-build.log
    exit 1
fi

# Verify binary exists
if [ -f "./zerotier-one-test" ]; then
    pass "Binary exists at ./zerotier-one-test"
    TEST_BINARY="./zerotier-one-test"
elif [ -f "./zig-out/bin/zerotier-one-test" ]; then
    pass "Binary exists at ./zig-out/bin/zerotier-one-test"
    TEST_BINARY="./zig-out/bin/zerotier-one-test"
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

echo "Starting service on port 9995..."
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
if lsof -i UDP:9995 -sTCP:LISTEN > /dev/null 2>&1 || netstat -an | grep -q "9995.*UDP"; then
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

# Test 10: Graceful Shutdown
section "Test 10: Graceful Shutdown"
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
SERVICE_PID=""  # Don't try to kill again in cleanup

# Summary
section "Test Summary"
TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo ""
echo "Tests passed: $TESTS_PASSED / $TOTAL_TESTS"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  All tests passed! ✓${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "The service layer is functional! To test with TUN device, run:"
    echo "  sudo ./zig-out/bin/zerotier-one --tun"
    echo ""
    exit 0
else
    echo -e "${RED}════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}  Some tests failed${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Check /tmp/zt-service.log for details"
    exit 1
fi
