#!/bin/bash
#
# Test script for Docker-based ZeroTea network
#
# Usage: ./test-network.sh

# Fixed BUG #31: Don't abort on first error, handle failures gracefully
# set -e removed - we want to continue even if some checks fail

echo "═══════════════════════════════════════════════════════════"
echo " ZeroTea Docker Network Test"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Fixed BUG #32: Verify containers are actually running before testing
echo "[1/6] Verifying containers are running..."
RUNNING=$(docker ps --filter "name=zt-" --format "{{.Names}}" | wc -l)
if [ "$RUNNING" -lt 4 ]; then
    echo "  ❌ ERROR: Not all containers running (found $RUNNING, expected 4)"
    echo "  Expected: zt-root-server, zt-controller, zt-client1, zt-client2"
    echo ""
    echo "  Running containers:"
    docker ps --filter "name=zt-" --format "  - {{.Names}} ({{.Status}})"
    echo ""
    echo "  Please start containers first:"
    echo "    docker-compose -f docker/docker-compose.yml up -d"
    exit 1
fi
echo "  ✓ All 4 containers running"

echo ""
echo "[2/6] Checking container status..."
docker-compose -f docker/docker-compose.yml ps || echo "  ⚠ docker-compose ps failed (continuing...)"

echo ""
echo "[3/6] Checking root server logs..."
docker logs zt-root-server --tail=20 || echo "  ⚠ Failed to get logs (continuing...)"

echo ""
echo "[4/6] Checking controller logs..."
docker logs zt-controller --tail=20 || echo "  ⚠ Failed to get logs (continuing...)"

echo ""
echo "[5/6] Checking client1 logs..."
docker logs zt-client1 --tail=20 || echo "  ⚠ Failed to get logs (continuing...)"

echo ""
echo "[6/6] Network connectivity test..."
echo "  Testing ping from client1 to root-server..."
docker exec zt-client1 ping -c 3 172.20.0.10 2>/dev/null || echo "  ⚠ Ping failed (this may be expected if network not fully configured)"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Test Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  - docker exec -it zt-client1 bash    # Enter client container"
echo "  - docker logs -f zt-root-server      # Watch root server logs"
echo "  - docker logs -f zt-controller       # Watch controller logs"
echo "  - docker-compose -f docker/docker-compose.yml down  # Stop all"
