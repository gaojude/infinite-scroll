#!/bin/bash
set -euo pipefail

APP_NAME="Infinite Scroll"
BUNDLE_NAME="InfiniteScroll"
VERSION="1.0.19"
APP_BUNDLE="$APP_NAME.app"
DMG_PATH="$BUNDLE_NAME.dmg"
RW_DMG_PATH="$BUNDLE_NAME-rw.dmg"
DMG_ARROW_ASSET="Resources/DMGArrow.png"
DMG_ARROW_FILE="Drag to Applications.png"
DMG_MOUNTPOINT=""
DMG_ATTACHED=0

echo "=== Building release binary ==="
# Stamp CLI version (auto-restored on exit so source tree stays clean)
CLI_VERSION_FILE="Sources/InfiniteScrollCLI/main.swift"
restore_cli_version() {
    sed -i '' "s/infinite-scroll CLI $VERSION\"/infinite-scroll CLI CLI_VERSION_PLACEHOLDER\"/g" "$CLI_VERSION_FILE"
}

cleanup() {
    restore_cli_version
    if [ "$DMG_ATTACHED" -eq 1 ]; then
        hdiutil detach "$DMG_MOUNTPOINT" -quiet || true
    fi
    if [ -n "$DMG_MOUNTPOINT" ] && [ -d "$DMG_MOUNTPOINT" ]; then
        rmdir "$DMG_MOUNTPOINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
sed -i '' "s/CLI_VERSION_PLACEHOLDER/$VERSION/g" "$CLI_VERSION_FILE"
swift build -c release

echo "=== Creating .app bundle ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy main binary
cp ".build/release/$BUNDLE_NAME" "$APP_BUNDLE/Contents/MacOS/$BUNDLE_NAME"

# Copy CLI binary
cp ".build/release/infinite-scroll" "$APP_BUNDLE/Contents/MacOS/infinite-scroll"
chmod +x "$APP_BUNDLE/Contents/MacOS/infinite-scroll"

# Copy app icon
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Copy bundled CLI prompt (read by the "Copy CLI Prompt" menu item)
cp "Resources/cli-prompt.md" "$APP_BUNDLE/Contents/Resources/cli-prompt.md"

# Bundle tmux
TMUX_BIN="$(readlink -f /opt/homebrew/bin/tmux 2>/dev/null || readlink -f /usr/local/bin/tmux 2>/dev/null || echo "")"
if [ -z "$TMUX_BIN" ]; then
    echo "WARNING: tmux not found — session persistence will not work"
else
    echo "=== Bundling tmux from $TMUX_BIN ==="
    cp "$TMUX_BIN" "$APP_BUNDLE/Contents/MacOS/tmux"
    chmod +x "$APP_BUNDLE/Contents/MacOS/tmux"

    # Copy dylib dependencies
    FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"

    copy_dylib() {
        local src="$1"
        local name="$(basename "$src")"
        # Resolve symlink
        src="$(readlink -f "$src" 2>/dev/null || echo "$src")"
        cp "$src" "$FRAMEWORKS/$name"
    }

    copy_dylib "/opt/homebrew/opt/libevent/lib/libevent_core-2.1.7.dylib"
    copy_dylib "/opt/homebrew/opt/ncurses/lib/libncursesw.6.dylib"
    copy_dylib "/opt/homebrew/opt/utf8proc/lib/libutf8proc.3.dylib"

    # Fix tmux rpaths to use @executable_path/../Frameworks/
    install_name_tool -change \
        "/opt/homebrew/opt/libevent/lib/libevent_core-2.1.7.dylib" \
        "@executable_path/../Frameworks/libevent_core-2.1.7.dylib" \
        "$APP_BUNDLE/Contents/MacOS/tmux"

    install_name_tool -change \
        "/opt/homebrew/opt/ncurses/lib/libncursesw.6.dylib" \
        "@executable_path/../Frameworks/libncursesw.6.dylib" \
        "$APP_BUNDLE/Contents/MacOS/tmux"

    install_name_tool -change \
        "/opt/homebrew/opt/utf8proc/lib/libutf8proc.3.dylib" \
        "@executable_path/../Frameworks/libutf8proc.3.dylib" \
        "$APP_BUNDLE/Contents/MacOS/tmux"

    # Fix dylib IDs
    install_name_tool -id "@executable_path/../Frameworks/libevent_core-2.1.7.dylib" \
        "$FRAMEWORKS/libevent_core-2.1.7.dylib"
    install_name_tool -id "@executable_path/../Frameworks/libncursesw.6.dylib" \
        "$FRAMEWORKS/libncursesw.6.dylib"
    install_name_tool -id "@executable_path/../Frameworks/libutf8proc.3.dylib" \
        "$FRAMEWORKS/libutf8proc.3.dylib"

    # Re-sign everything after rpath changes
    echo "=== Signing bundled binaries ==="
    codesign --force --sign - "$FRAMEWORKS/libevent_core-2.1.7.dylib"
    codesign --force --sign - "$FRAMEWORKS/libncursesw.6.dylib"
    codesign --force --sign - "$FRAMEWORKS/libutf8proc.3.dylib"
    codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/tmux"

    echo "=== Verifying tmux dependencies ==="
    otool -L "$APP_BUNDLE/Contents/MacOS/tmux"

    # Verify bundled tmux actually works
    echo "=== Testing bundled tmux ==="
    "$APP_BUNDLE/Contents/MacOS/tmux" -V && echo "OK" || echo "FAILED — bundled tmux broken"
fi

# Write Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Infinite Scroll</string>
    <key>CFBundleDisplayName</key>
    <string>Infinite Scroll</string>
    <key>CFBundleIdentifier</key>
    <string>com.judegao.infinite-scroll</string>
    <key>CFBundleVersion</key>
    <string>VERSION_PLACEHOLDER</string>
    <key>CFBundleShortVersionString</key>
    <string>VERSION_PLACEHOLDER</string>
    <key>CFBundleExecutable</key>
    <string>InfiniteScroll</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/g" "$APP_BUNDLE/Contents/Info.plist"

# Sign the CLI binary
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/infinite-scroll"

# Sign the whole .app bundle
echo "=== Signing app bundle ==="
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "=== Creating Finder-layout DMG ==="
if [ ! -f "$DMG_ARROW_ASSET" ]; then
    echo "Missing DMG arrow asset: $DMG_ARROW_ASSET" >&2
    exit 1
fi

rm -f "$DMG_PATH" "$RW_DMG_PATH"
hdiutil create -size 120m -fs HFS+ -volname "$APP_NAME" -type UDIF -ov "$RW_DMG_PATH"

DMG_MOUNTPOINT="$(mktemp -d /tmp/infinite-scroll-dmg.XXXXXX)"
hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen -mountpoint "$DMG_MOUNTPOINT" >/dev/null
DMG_ATTACHED=1
DMG_FINDER_DISK_NAME="$(basename "$DMG_MOUNTPOINT")"

ditto "$APP_BUNDLE" "$DMG_MOUNTPOINT/$APP_BUNDLE"
cp "$DMG_ARROW_ASSET" "$DMG_MOUNTPOINT/$DMG_ARROW_FILE"
ln -s /Applications "$DMG_MOUNTPOINT/Applications"

# Keep the installer deliberately native: app, direction marker, and the
# Applications shortcut are positioned as a clear drag-and-drop flow.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_FINDER_DISK_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {240, 180, 920, 590}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 14
        set shows icon preview of viewOptions to true
        set position of item "$APP_BUNDLE" of container window to {170, 190}
        set extension hidden of item "$DMG_ARROW_FILE" of container window to true
        set position of item "$DMG_ARROW_FILE" of container window to {335, 190}
        set position of item "Applications" of container window to {500, 190}
        close
        open
        update without registering applications
    end tell
end tell
APPLESCRIPT

sleep 1
sync
hdiutil detach "$DMG_MOUNTPOINT" -quiet
DMG_ATTACHED=0
rmdir "$DMG_MOUNTPOINT"
DMG_MOUNTPOINT=""

hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

echo ""
echo "=== Done ==="
ls -lh "$DMG_PATH"
echo "App: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
