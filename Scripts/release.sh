#!/bin/bash
# Build a Developer ID-signed, notarized and stapled Atelier.app for download, zipped for a GitHub Release.
# Output: build/release/Atelier-<version>.zip. Usage: release.sh [version] (default: MARKETING_VERSION in the
# project). The build number is the commit count, so every release from a newer commit has a higher one.
#
# One-time setup on the Mac that signs:
# - A "Developer ID Application" certificate for your team in the login keychain.
# - Notary credentials saved in the keychain:
#     xcrun notarytool store-credentials atelier-notary --apple-id <you@example.com> --team-id <TEAM>
#   (use an app-specific password from account.apple.com). Set NOTARY_PROFILE to use another profile name.
# - DEVELOPMENT_TEAM in Config/Local.xcconfig (untracked), or the DEVELOPMENT_TEAM environment variable.
#
# Draw Things' preview decoders (*_tae.zip) are left out of release builds; they aren't ours to redistribute.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
NOTARY_PROFILE="${NOTARY_PROFILE:-atelier-notary}"
VERSION_SETTINGS=(CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)")
[ -n "$1" ] && VERSION_SETTINGS+=(MARKETING_VERSION="$1")

if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if [ -z "$DEVELOPMENT_TEAM" ] && [ -f Config/Local.xcconfig ]; then
  DEVELOPMENT_TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig | head -1)"
fi
[ -n "$DEVELOPMENT_TEAM" ] || { echo "error: set DEVELOPMENT_TEAM in Config/Local.xcconfig or the environment" >&2; exit 1; }

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($DEVELOPMENT_TEAM)"; then
  echo "error: no \"Developer ID Application\" certificate for team $DEVELOPMENT_TEAM in the keychain" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: no notary credentials in keychain profile \"$NOTARY_PROFILE\"; see the setup notes at the top of this script" >&2
  exit 1
fi

OUT=build/release
EMPTY_DIR="$(mktemp -d)"
trap 'rm -rf "$EMPTY_DIR"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild -project Atelier.xcodeproj -scheme Atelier -configuration Release \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -destination 'platform=macOS' -quiet clean build \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" PROVISIONING_PROFILE_SPECIFIER="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DRAWTHINGS_APP="$EMPTY_DIR" "${VERSION_SETTINGS[@]}"

APP="$OUT/Atelier.app"
ditto build/DerivedData/Build/Products/Release/Atelier.app "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)"
ZIP="$OUT/Atelier-$VERSION.zip"

# Notarize a zip of the app, staple the ticket to the app, then zip the stapled app for download.
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built $PROJECT_ROOT/$ZIP"
