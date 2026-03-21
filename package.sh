#!/bin/bash
set -euo pipefail

APP_NAME="Infinite Scroll"
BUNDLE_NAME="InfiniteScroll"
VERSION="1.0.10"

echo "=== Building release binary ==="
swift build -c release

echo "=== Creating .app bundle ==="
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Frameworks"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Copy main binary
cp ".build/release/$BUNDLE_NAME" "$APP_NAME.app/Contents/MacOS/$BUNDLE_NAME"

# Copy app icon
cp "Resources/AppIcon.icns" "$APP_NAME.app/Contents/Resources/AppIcon.icns"

# Bundle tmux
TMUX_BIN="$(readlink -f /opt/homebrew/bin/tmux 2>/dev/null || readlink -f /usr/local/bin/tmux 2>/dev/null || echo "")"
if [ -z "$TMUX_BIN" ]; then
    echo "WARNING: tmux not found — session persistence will not work"
else
    echo "=== Bundling tmux from $TMUX_BIN ==="
    cp "$TMUX_BIN" "$APP_NAME.app/Contents/MacOS/tmux"
    chmod +x "$APP_NAME.app/Contents/MacOS/tmux"

    # Copy dylib dependencies
    FRAMEWORKS="$APP_NAME.app/Contents/Frameworks"

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
        "$APP_NAME.app/Contents/MacOS/tmux"

    install_name_tool -change \
        "/opt/homebrew/opt/ncurses/lib/libncursesw.6.dylib" \
        "@executable_path/../Frameworks/libncursesw.6.dylib" \
        "$APP_NAME.app/Contents/MacOS/tmux"

    install_name_tool -change \
        "/opt/homebrew/opt/utf8proc/lib/libutf8proc.3.dylib" \
        "@executable_path/../Frameworks/libutf8proc.3.dylib" \
        "$APP_NAME.app/Contents/MacOS/tmux"

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
    codesign --force --sign - "$APP_NAME.app/Contents/MacOS/tmux"

    echo "=== Verifying tmux dependencies ==="
    otool -L "$APP_NAME.app/Contents/MacOS/tmux"

    # Verify bundled tmux actually works
    echo "=== Testing bundled tmux ==="
    "$APP_NAME.app/Contents/MacOS/tmux" -V && echo "OK" || echo "FAILED — bundled tmux broken"
fi

# Write Info.plist
cat > "$APP_NAME.app/Contents/Info.plist" << 'PLIST'
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
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/g" "$APP_NAME.app/Contents/Info.plist"

# Sign the whole .app bundle
echo "=== Signing app bundle ==="
codesign --force --deep --sign - "$APP_NAME.app"

echo "=== Creating DMG ==="
rm -rf dmg_staging "$BUNDLE_NAME.dmg"
mkdir dmg_staging
cp -R "$APP_NAME.app" dmg_staging/
ln -s /Applications dmg_staging/Applications
hdiutil create -volname "$APP_NAME" -srcfolder dmg_staging -ov -format UDZO "$BUNDLE_NAME.dmg"
rm -rf dmg_staging

echo ""
echo "=== Done ==="
ls -lh "$BUNDLE_NAME.dmg"
echo "App: $APP_NAME.app"
echo "DMG: $BUNDLE_NAME.dmg"
