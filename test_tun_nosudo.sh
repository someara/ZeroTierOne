#!/bin/bash
# Test TUN device without requiring terminal password
# This script runs the TUN test and shows what happens

echo "═══════════════════════════════════════════════════════"
echo "  TUN Device Test Script"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "This test requires root privileges to create network interfaces."
echo ""
echo "Running test..."
echo ""

# Try to run with current privileges (might work if already root)
./test_tun 2>&1 || {
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 1 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  Root Required"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        echo "The TUN device test requires root privileges."
        echo "Please run manually:"
        echo ""
        echo "  sudo ./test_tun"
        echo ""
        echo "Then try: ping 10.147.20.1"
        echo ""
    fi
    exit $EXIT_CODE
}
