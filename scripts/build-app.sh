#!/bin/bash
# Builds a universal (Apple silicon + Intel) Quotacat.app into ./build.
#   --install    also copy it to ~/Applications
#   --zip        also produce build/Quotacat.zip for a GitHub release
#   --notarize   with --zip: submit to Apple's notary service and staple the ticket
#                (needs a Developer ID certificate and a stored notarytool profile)
#
# Signing: uses your "Developer ID Application" certificate when one is in the Keychain
# (or QUOTACAT_SIGN_IDENTITY), otherwise falls back to ad-hoc signing.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; ZIP=0; NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        --notarize) NOTARIZE=1; ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

NOTARY_PROFILE="${QUOTACAT_NOTARY_PROFILE:-quotacat-notary}"
SIGN_IDENTITY="${QUOTACAT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"

# The version lives in ./VERSION; QUOTACAT_VERSION overrides it (used to test updates).
VERSION="${QUOTACAT_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="io.github.mrte1122.Quotacat"
# Assemble and sign outside the repo: if it lives in an iCloud-synced folder (like ~/Documents),
# File Provider keeps adding extended attributes to the bundle and codesign rejects them.
STAGE="${TMPDIR:-/tmp}/quotacat-build"
APP="$STAGE/Quotacat.app"
mkdir -p build

# Build each architecture separately and merge with lipo; a single multi-arch
# `swift build` needs full Xcode, while this works with the Command Line Tools.
BINS=()
# Separate scratch paths per architecture: newer SwiftPM (Xcode 27+) otherwise writes both
# builds to the same .build/out folder and the second overwrites the first.
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --scratch-path ".build/$arch"
    BINS+=("$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)/Quotacat")
done

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Quotacat"

# App icon: render the fallback if missing, then pack every macOS size into an .icns.
[[ -f Resources/AppIcon.png ]] || swift scripts/make-icon.swift Resources/AppIcon.png
ICONSET="$STAGE/AppIcon.iconset"
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
if [[ -n "$SIGN_IDENTITY" ]]; then
    # Hardened runtime + secure timestamp are both required for notarization.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    SIGNED_AS="$SIGN_IDENTITY"
else
    if [[ $NOTARIZE -eq 1 ]]; then echo "error: --notarize needs a Developer ID Application certificate" >&2; exit 1; fi
    codesign --force --sign - --timestamp=none "$APP"
    SIGNED_AS="ad-hoc"
fi
codesign --verify --strict "$APP"
echo "Built Quotacat.app ($(lipo -archs "$APP/Contents/MacOS/Quotacat"), signed: $SIGNED_AS)"

if [[ $ZIP -eq 1 ]]; then
    # Stable name so releases/latest/download/Quotacat.zip always works.
    rm -f build/Quotacat.zip
    ditto -c -k --keepParent "$APP" build/Quotacat.zip
    if [[ $NOTARIZE -eq 1 ]]; then
        echo "Submitting to Apple's notary service (usually 1-5 minutes)…"
        xcrun notarytool submit build/Quotacat.zip --keychain-profile "$NOTARY_PROFILE" --wait
        # Staple the ticket into the app so it opens offline, then re-zip the stapled copy.
        xcrun stapler staple "$APP"
        spctl --assess --type execute "$APP" && echo "Gatekeeper accepts the notarized app"
        rm -f build/Quotacat.zip
        ditto -c -k --keepParent "$APP" build/Quotacat.zip
    fi
    echo "Packaged build/Quotacat.zip"
fi

# Keep a copy in ./build for running and testing (the zip above is what gets shipped).
rm -rf build/Quotacat.app
ditto "$APP" build/Quotacat.app

if [[ $INSTALL -eq 1 ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Quotacat.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Quotacat.app"
fi
