#!/bin/bash
# Build Atelier from Atelier.xcodeproj without opening Xcode, for scripted runs. In Xcode, just
# build and run the Atelier scheme.
# Usage: build.sh [Debug|Release] [mac|ipad|ipad-sim] (default Release, mac)
#   mac       build/Atelier.app
#   ipad      build/Atelier-iPad.app, for an iPad. Signed when Config/Local.xcconfig sets a
#             DEVELOPMENT_TEAM; otherwise unsigned, so it builds but can't be installed.
#   ipad-sim  build/Atelier-iPadSimulator.app, for the iPad simulator.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
CONFIGURATION="${1:-Release}"
PLATFORM="${2:-mac}"

# xcodebuild needs full Xcode; use it even when xcode-select points at the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SIGNING=()
case "$PLATFORM" in
  mac)
    DESTINATION='platform=macOS'
    DERIVED=build/DerivedData
    PRODUCTS="$CONFIGURATION"
    OUTPUT=build/Atelier.app
    ;;
  ipad)
    DESTINATION='generic/platform=iOS'
    DERIVED=build/DerivedData-iOS
    PRODUCTS="$CONFIGURATION-iphoneos"
    OUTPUT=build/Atelier-iPad.app
    if ! grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]+' Config/Local.xcconfig 2>/dev/null; then
      echo "warning: no DEVELOPMENT_TEAM in Config/Local.xcconfig; building unsigned"
      SIGNING=(CODE_SIGNING_ALLOWED=NO)
    fi
    ;;
  ipad-sim)
    DESTINATION='generic/platform=iOS Simulator'
    DERIVED=build/DerivedData-iOS
    PRODUCTS="$CONFIGURATION-iphonesimulator"
    OUTPUT=build/Atelier-iPadSimulator.app
    ;;
  *)
    echo "Unknown platform $PLATFORM (use mac, ipad or ipad-sim)" >&2
    exit 1
    ;;
esac

xcodebuild -project Atelier.xcodeproj -scheme Atelier -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath build/SourcePackages \
  -destination "$DESTINATION" -quiet build "${SIGNING[@]}"

rm -rf "$OUTPUT"
cp -R "$DERIVED/Build/Products/$PRODUCTS/Atelier.app" "$OUTPUT"
echo "Built $PROJECT_ROOT/$OUTPUT"
