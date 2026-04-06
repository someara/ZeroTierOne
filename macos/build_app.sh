#!/bin/bash
set -e

echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║  Building ZeroTea Tray App Bundle                    ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$SCRIPT_DIR/ZeroTeaTray.app"

cd "$PROJECT_DIR"

# Build the Zig executable
echo "→ Building Zig executable..."
zig build -Doptimize=ReleaseFast

if [ ! -f "zig-out/bin/ZeroTeaTray" ]; then
    echo "✗ Build failed - executable not found"
    exit 1
fi

echo "✓ Build successful"

# Copy executable to app bundle
echo "→ Creating app bundle..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "zig-out/bin/ZeroTeaTray" "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/ZeroTeaTray"

echo "✓ Copied executable"

# Verify Info.plist exists
if [ ! -f "$APP_DIR/Contents/Info.plist" ]; then
    echo "✗ Info.plist not found"
    exit 1
fi

echo "✓ Info.plist present"

# Create a simple icon (text-based for now)
# In production, you'd create a proper .icns file
echo "→ App icon: (using default for now)"

# Show bundle structure
echo ""
echo "✓ App bundle created at:"
echo "  $APP_DIR"
echo ""
echo "Structure:"
tree -L 3 "$APP_DIR" 2>/dev/null || find "$APP_DIR" -maxdepth 3 -print | sed 's|[^/]*/|  |g'

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║  ✓ Build Complete!                                   ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "To run:"
echo "  open $APP_DIR"
echo ""
echo "Or double-click the app in Finder!"
echo ""
