#!/bin/bash
# Build Atelier and wrap the binary in build/Atelier.app (Info.plist, ad-hoc codesign).
# Usage: package_app.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

"$SCRIPT_DIR/build.sh"

APP="$PROJECT_ROOT/build/Atelier.app"
BIN_DIR="$(swift build -c release --build-system native --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Atelier" "$APP/Contents/MacOS/Atelier"

# SwiftPM resource bundles (engine catalogs etc.) must sit next to the executable.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Live previews decode through the engine's tiny autoencoders (TAE), which it loads from
# Bundle.main as *_tae.zip. They aren't in the community repo, so borrow them from an installed
# Draw Things.app. Without them the app still generates, just without step previews.
DRAWTHINGS_APP="${DRAWTHINGS_APP:-/Applications/Draw Things.app}"
TAE_COUNT=0
for zip in "$DRAWTHINGS_APP"/Contents/Resources/*_tae.zip; do
  [ -e "$zip" ] || continue
  cp "$zip" "$APP/Contents/Resources/"
  TAE_COUNT=$((TAE_COUNT + 1))
done
if [ "$TAE_COUNT" -eq 0 ]; then
  echo "warning: no *_tae.zip found in $DRAWTHINGS_APP; live previews will be disabled"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Atelier</string>
  <key>CFBundleDisplayName</key><string>Atelier</string>
  <key>CFBundleIdentifier</key><string>local.atelier.Atelier</string>
  <key>CFBundleExecutable</key><string>Atelier</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Icon placeholder: no AppIcon.icns yet, macOS falls back to the generic icon.
codesign --force --deep --sign - "$APP"
echo "Packaged $APP"
