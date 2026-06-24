#!/bin/bash
set -euo pipefail

# Build Itsypad.app using ONLY the Swift toolchain that ships with the
# Xcode Command Line Tools – no Xcode.app and no xcodegen required.
#
#   ./scripts/build-app.sh            # release build  (recommended)
#   ./scripts/build-app.sh debug      # faster, unoptimised build
#
# Output: dist/Itsypad.app  (real app icon, installable into /Applications)

CONFIG="${1:-release}"
APP_NAME="Itsypad"
# Distinct bundle id from the official upstream app so this fork can live in
# /Applications and hold its own settings / Accessibility grant independently.
BUNDLE_ID="com.wienkers.itsypad"
# Keep in sync with project.yml (MARKETING_VERSION / CURRENT_PROJECT_VERSION).
VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/dist/$APP_NAME.app"
echo "==> Assembling $APP (v$VERSION build $BUILD, id $BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Executable
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundle(s). The generated Bundle.module accessor resolves these
# at Bundle.main.bundleURL/<name>.bundle, i.e. the .app's top level (next to
# Contents/), NOT inside Contents/Resources – so copy them there.
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
    cp -R "$b" "$APP/"
done
shopt -u nullglob

# App icon. SwiftPM only copies Assets.xcassets (it doesn't compile it), so build a
# real AppIcon.icns from the asset-catalog PNGs with iconutil (ships with the CLT).
ICONSET_SRC="Sources/Resources/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET_SRC" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    cp "$ICONSET_SRC/icon_16x16.png"     "$ICONSET/icon_16x16.png"
    cp "$ICONSET_SRC/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET_SRC/icon_32x32.png"     "$ICONSET/icon_32x32.png"
    cp "$ICONSET_SRC/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET_SRC/icon_128x128.png"   "$ICONSET/icon_128x128.png"
    cp "$ICONSET_SRC/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET_SRC/icon_256x256.png"   "$ICONSET/icon_256x256.png"
    cp "$ICONSET_SRC/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET_SRC/icon_512x512.png"   "$ICONSET/icon_512x512.png"
    cp "$ICONSET_SRC/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Info.plist – the source uses Xcode $(...) build variables, so substitute real
# values. (A bundled Contents/Info.plist takes precedence over the copy embedded
# in the binary, giving the app a clean bundle identifier and version.)
sed -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
    -e "s/\$(EXECUTABLE_NAME)/$APP_NAME/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
    -e "s/\$(PRODUCT_NAME)/$APP_NAME/g" \
    -e "s/\$(MARKETING_VERSION)/$VERSION/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/g" \
    Sources/Info.plist > "$APP/Contents/Info.plist"
# Point the bundle at the icon we just built.
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# No codesign step needed: `swift build` already ad-hoc signs the executable via the
# linker (required to run on Apple Silicon), and that signature is preserved by the
# copy above. We deliberately do NOT seal the whole .app bundle, because SwiftPM's
# Bundle.module resolves resources at the .app's top level and a sealed bundle
# disallows content outside Contents/. (The ad-hoc signature changes every build, so
# macOS may ask you to re-grant Accessibility after a rebuild.)

# Refresh the Finder/Dock icon cache for this path.
touch "$APP"

echo "==> Done: $APP"
echo "    Run it with:      open \"$APP\""
echo "    Install with:     cp -R \"$APP\" /Applications/   (then grant Accessibility)"
echo "    Bundle id $BUNDLE_ID is independent of any official Itsypad install."
