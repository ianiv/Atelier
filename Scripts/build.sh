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
source "$SCRIPT_DIR/hide-build-from-spotlight.sh"
CONFIGURATION="${1:-Release}"
PLATFORM="${2:-mac}"

# xcodebuild needs full Xcode; use it even when xcode-select points at the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

SIGNING=()
# Mac builds are Apple silicon only. The app target says so (ARCHS), but Swift packages would
# still build an Intel slice in Release, and the engine's Float16 code doesn't compile for Intel.
ARCH_SETTINGS=()
case "$PLATFORM" in
  mac)
    DESTINATION='platform=macOS'
    ARCH_SETTINGS=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
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
    else
      # Lets Xcode make the development profile, with the iPad's memory entitlements.
      SIGNING=(-allowProvisioningUpdates)
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
  -destination "$DESTINATION" -quiet "${SIGNING[@]}" "${ARCH_SETTINGS[@]}" build

rm -rf "$OUTPUT"
cp -R "$DERIVED/Build/Products/$PRODUCTS/Atelier.app" "$OUTPUT"
# macOS registers every built copy with Launch Services, so they pile up in Open With. Keep the
# installed app the only one listed. hide-build-from-spotlight.sh does the same for Spotlight.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$DERIVED/Build/Products/$PRODUCTS/Atelier.app" "$OUTPUT" 2>/dev/null || true
echo "Built $PROJECT_ROOT/$OUTPUT"
