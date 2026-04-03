#!/bin/bash
#
# Test script for Docker-based ZeroTier network
#
# Usage: ./test-network.sh

set -e

echo "═══════════════════════════════════════════════════════════"
echo " ZeroTier Docker Network Test"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check if containers are running
echo "[1/5] Checking container status..."
docker-compose -f docker/docker-compose.yml ps

echo ""
echo "[2/5] Checking root server logs..."
docker logs zt-root-server --tail=20

echo ""
echo "[3/5] Checking controller logs..."
docker logs zt-controller --tail=20

echo ""
echo "[4/5] Checking client1 logs..."
docker logs zt-client1 --tail=20

echo ""
echo "[5/5] Network connectivity test..."
echo "  Testing ping from client1 to root-server..."
docker exec zt-client1 ping -c 3 172.20.0.10 || true

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
