#!/bin/bash
# Build Atelier.app from Atelier.xcodeproj without opening Xcode, for scripted runs. In Xcode, just
# build and run the Atelier scheme.
# Output: build/Atelier.app. Usage: build.sh [Debug|Release] (default Release)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
CONFIGURATION="${1:-Release}"

# xcodebuild needs full Xcode; use it even when xcode-select points at the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodebuild -project Atelier.xcodeproj -scheme Atelier -configuration "$CONFIGURATION" \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -destination 'platform=macOS' -quiet build

rm -rf build/Atelier.app
cp -R "build/DerivedData/Build/Products/$CONFIGURATION/Atelier.app" build/Atelier.app
echo "Built $PROJECT_ROOT/build/Atelier.app"
