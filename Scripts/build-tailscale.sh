#!/bin/bash
# Builds TailscaleKit (libtailscale, Tailscale's own code as a library) into build/Tailscale, where
# the app finds it. Atelier then joins your tailnet by itself, with no Tailscale app installed. Without
# it Atelier still builds, and Settings ▸ Compute says how to add it. Needs Go (brew install go) and
# Xcode; takes a few minutes the first time. Rerun after Scripts/clean-builds.sh --all.
# Usage: build-tailscale.sh [--with-test-control]
#   --with-test-control also builds Tailscale's test control server, which --remote-tailnet-check uses
#                       to try real connections without a real sign-in.

set -euo pipefail

# The revision of github.com/tailscale/libtailscale. BSD 3-Clause, compatible with Atelier's GPL-3.0.
REVISION=ac7ed43af14e19e1c1810ee9f8319872c6beb412

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT="$PROJECT_ROOT/build/Tailscale"
SOURCE="$OUT/source"

# Homebrew's Go isn't on PATH in every shell. xcodebuild needs full Xcode.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/go/bin"
if ! command -v go >/dev/null; then
  echo "error: Go isn't installed. Install it (brew install go) and run this again." >&2
  exit 1
fi
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$OUT"
if [ ! -d "$SOURCE/.git" ]; then
  git clone --quiet https://github.com/tailscale/libtailscale "$SOURCE"
fi
git -C "$SOURCE" fetch --quiet origin
git -C "$SOURCE" checkout --quiet --force "$REVISION"

cd "$SOURCE/swift"
make macos ios ios-sim
PRODUCTS="$SOURCE/swift/build/Build/Products"
rm -rf "$OUT/TailscaleKit.xcframework"
xcodebuild -create-xcframework \
  -framework "$PRODUCTS/Release/TailscaleKit.framework" \
  -framework "$PRODUCTS/Release-iphoneos/TailscaleKit.framework" \
  -framework "$PRODUCTS/Release-iphonesimulator/TailscaleKit.framework" \
  -output "$OUT/TailscaleKit.xcframework"

# Read by Config/Atelier.xcconfig when it's there: this is what makes `canImport(TailscaleKit)` true.
cat >"$OUT/Tailscale.xcconfig" <<'CONFIG'
// Written by Scripts/build-tailscale.sh.
ATELIER_TAILSCALEKIT = $(SRCROOT)/build/Tailscale/TailscaleKit.xcframework
FRAMEWORK_SEARCH_PATHS[sdk=macosx*] = $(inherited) $(ATELIER_TAILSCALEKIT)/macos-arm64
FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] = $(inherited) $(ATELIER_TAILSCALEKIT)/ios-arm64
FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) $(ATELIER_TAILSCALEKIT)/ios-arm64_x86_64-simulator
OTHER_LDFLAGS = $(inherited) -framework AVKit -framework TailscaleKit
CONFIG

if [ "${1:-}" = "--with-test-control" ]; then
  cd "$SOURCE/tstestcontrol"
  go build -buildmode=c-shared -o "$OUT/libtstestcontrol.dylib"
  # The hardened runtime only loads libraries signed by the same team as the app.
  IDENTITY="$(sed -n 's/^CODE_SIGN_IDENTITY *= *//p' "$PROJECT_ROOT/Config/Local.xcconfig" 2>/dev/null || true)"
  codesign --force --sign "${IDENTITY:--}" "$OUT/libtstestcontrol.dylib"
fi

echo "Built $OUT/TailscaleKit.xcframework. Build Atelier again to include it."
