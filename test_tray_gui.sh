#!/bin/bash
# GUI smoke test for ZeroTier tray app
#
# Prerequisites:
#   - zerotier-one running on localhost:9993
#   - Terminal needs Accessibility permissions:
#     System Settings > Privacy & Security > Accessibility > Terminal (enable)
#
# Usage: bash test_tray_gui.sh

set -euo pipefail

PASS=0
FAIL=0
TRAY_PID=""

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() {
    if [ -n "$TRAY_PID" ]; then
        kill "$TRAY_PID" 2>/dev/null || true
        wait "$TRAY_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== ZeroTier Tray App - GUI Smoke Test ==="
echo ""

# Build
echo "Building..."
zig build -Doptimize=Debug 2>&1
echo ""

# Launch app in background
echo "Launching ZeroTierTray..."
./zig-out/bin/ZeroTierTray &
TRAY_PID=$!
sleep 2

# Check process is still running
if ! kill -0 "$TRAY_PID" 2>/dev/null; then
    echo "FATAL: App crashed on startup"
    exit 1
fi
echo "App running (PID $TRAY_PID)"
echo ""

# Test 1: Menu bar item exists
echo "Test 1: Menu bar item exists"
if osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            return exists menu bar item 1 of menu bar 2
        end tell
    end tell
' 2>/dev/null | grep -q "true"; then
    pass "Menu bar item found"
else
    fail "Menu bar item not found (check Accessibility permissions)"
fi

# Test 2: Menu opens and has items
echo "Test 2: Menu opens with expected items"
MENU_ITEMS=$(osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            click menu bar item 1 of menu bar 2
            delay 0.5
            set itemNames to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
            -- Close menu
            key code 53
            return itemNames
        end tell
    end tell
' 2>/dev/null || echo "")

if echo "$MENU_ITEMS" | grep -q "Join Network"; then
    pass "Join Network menu item found"
else
    fail "Join Network menu item not found"
fi

if echo "$MENU_ITEMS" | grep -q "Copy Node ID"; then
    pass "Copy Node ID menu item found"
else
    fail "Copy Node ID menu item not found"
fi

if echo "$MENU_ITEMS" | grep -q "Quit"; then
    pass "Quit menu item found"
else
    fail "Quit menu item not found"
fi

# Test 3: Join Network dialog appears and accepts input
echo "Test 3: Join Network dialog"
DIALOG_RESULT=$(osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            click menu bar item 1 of menu bar 2
            delay 0.5
            click menu item "Join Network..." of menu 1 of menu bar item 1 of menu bar 2
            delay 1
            -- Check dialog appeared
            if exists window 1 then
                -- Type a test network ID
                set value of text field 1 of window 1 to "8056c2e21c000001"
                delay 0.3
                -- Click Cancel (don't actually join)
                click button "Cancel" of window 1
                return "dialog_ok"
            else
                return "no_dialog"
            end if
        end tell
    end tell
' 2>/dev/null || echo "error")

if [ "$DIALOG_RESULT" = "dialog_ok" ]; then
    pass "Join Network dialog works (opened, accepted text, cancelled)"
else
    fail "Join Network dialog did not appear ($DIALOG_RESULT)"
fi

# Test 4: Copy Node ID to clipboard
echo "Test 4: Copy Node ID"
# Save current clipboard
OLD_CLIPBOARD=$(pbpaste 2>/dev/null || echo "")
# Clear clipboard
echo -n "CLEAR" | pbcopy

osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            click menu bar item 1 of menu bar 2
            delay 0.5
            click menu item "Copy Node ID" of menu 1 of menu bar item 1 of menu bar 2
        end tell
    end tell
' 2>/dev/null || true
sleep 1

NEW_CLIPBOARD=$(pbpaste 2>/dev/null || echo "")
if [ "$NEW_CLIPBOARD" != "CLEAR" ] && [ ${#NEW_CLIPBOARD} -eq 10 ]; then
    pass "Node ID copied to clipboard ($NEW_CLIPBOARD)"
elif [ "$NEW_CLIPBOARD" = "CLEAR" ]; then
    fail "Clipboard was not modified (service may not be running)"
else
    fail "Clipboard content unexpected: '$NEW_CLIPBOARD' (length ${#NEW_CLIPBOARD}, expected 10)"
fi

# Test 5: Status header reflects service state
echo "Test 5: Status header"
HEADER=$(osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            click menu bar item 1 of menu bar 2
            delay 0.5
            set firstItem to name of menu item 1 of menu 1 of menu bar item 1 of menu bar 2
            key code 53
            return firstItem
        end tell
    end tell
' 2>/dev/null || echo "")

if echo "$HEADER" | grep -q "ZeroTier"; then
    pass "Status header present: $HEADER"
else
    fail "Status header not found (got: '$HEADER')"
fi

# Test 6: Quit works
echo "Test 6: Quit"
osascript -e '
    tell application "System Events"
        tell process "ZeroTierTray"
            click menu bar item 1 of menu bar 2
            delay 0.5
            click menu item "Quit" of menu 1 of menu bar item 1 of menu bar 2
        end tell
    end tell
' 2>/dev/null || true
sleep 1

if ! kill -0 "$TRAY_PID" 2>/dev/null; then
    pass "App quit cleanly"
    TRAY_PID=""  # Don't try to kill in cleanup
else
    fail "App did not quit"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
