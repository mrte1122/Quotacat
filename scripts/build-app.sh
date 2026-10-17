#!/bin/bash
# Builds a universal (Apple silicon + Intel) Quotacat.app into ./build.
#   --install   also copy it to ~/Applications
#   --zip       also produce build/Quotacat.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

# The version lives in ./VERSION; QUOTACAT_VERSION overrides it (used to test updates).
VERSION="${QUOTACAT_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="io.github.mrte1122.Quotacat"
APP="build/Quotacat.app"

# Build each architecture separately and merge with lipo; a single multi-arch
# `swift build` needs full Xcode, while this works with the Command Line Tools.
BINS=()
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch"
    BINS+=("$(swift build -c release --arch "$arch" --show-bin-path)/Quotacat")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Quotacat"

# App icon: render the fallback if missing, then pack every macOS size into an .icns.
[[ -f Resources/AppIcon.png ]] || swift scripts/make-icon.swift Resources/AppIcon.png
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Quotacat</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Quotacat</string>
    <key>CFBundleDisplayName</key><string>Quotacat</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Tyler Lovelady. MIT License.</string>
</dict>
</plist>
PLIST

# sips leaves extended attributes that codesign rejects.
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Quotacat"))"

for arg in "$@"; do
    case "$arg" in
        --install)
            mkdir -p "$HOME/Applications"
            rm -rf "$HOME/Applications/Quotacat.app"
            cp -R "$APP" "$HOME/Applications/"
            echo "Installed to ~/Applications/Quotacat.app"
            ;;
        --zip)
            # Stable name so releases/latest/download/Quotacat.zip always works.
            rm -f build/Quotacat.zip
            ditto -c -k --keepParent "$APP" build/Quotacat.zip
            echo "Packaged build/Quotacat.zip"
            ;;
    esac
done
