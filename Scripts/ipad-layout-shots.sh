#!/bin/bash
# Screenshots every main screen of a Debug iPad simulator build at a range of window sizes, for
# checking layouts. The simulator can't be resized from a script, so each launch passes
# -AtelierWindowSize and the app draws itself in a window that size at the top left of the screen,
# scaled down to fit when larger, on a gray background (LayoutCheckFrame, Debug only).
# Usage: ipad-layout-shots.sh [output folder] (default build/layout-shots)
# Needs: Scripts/build.sh Debug ipad-sim, and an iPad simulator on iPadOS 27 (SIMULATOR=<udid>
# picks one; default is the last listed iPad Pro 13-inch, whose screen is 1032x1376 points).

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT="${1:-build/layout-shots}"
mkdir -p "$OUT"
if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
APP=build/Atelier-iPadSimulator.app
BUNDLE=ca.blogaholics.Atelier
DEVICE="${SIMULATOR:-$(xcrun simctl list devices available | grep -E 'iPad Pro 13-inch' | grep -oE '[0-9A-F-]{36}' | tail -1)}"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"

# name width height: full-screen 13" and 11" in both orientations, Split View halves and thirds,
# Stage Manager style windows, and about the smallest window iPadOS allows.
SIZES="13-landscape 1376 1032
13-portrait 1032 1376
11-landscape 1210 834
11-portrait 834 1210
split-half 684 1032
split-third 450 1032
window-1100x800 1100 800
window-900x700 900 700
window-600x800 600 800
window-400x600 400 600
smallest 360 480"
# Settings is the Settings sheet, opened over Create.
SECTIONS="${SECTIONS:-Create Queue History Models LoRAs Settings}"

while read -r name width height; do
  for section in $SECTIONS; do
    xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
    screen="$section" settings=NO
    [ "$section" = Settings ] && screen=Create settings=YES
    xcrun simctl spawn "$DEVICE" defaults write "$BUNDLE" section "$screen"
    # Start each shot with the inspector's default (shown), from the app's own preferences.
    prefs="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)/Library/Preferences/$BUNDLE.plist"
    [ -f "$prefs" ] && plutil -remove inspectorShown "$prefs" >/dev/null 2>&1 || true
    # Sample images in a project of their own (SampleData.swift) and every model in Models.
    xcrun simctl launch "$DEVICE" "$BUNDLE" -AtelierWindowSize "${width}x${height}" \
      --project "Layout Sample" -AtelierSampleData YES -modelsFilter All \
      -AtelierShowSettings "$settings" $EXTRA_ARGS >/dev/null
    sleep "${WAIT:-5}"
    file="$OUT/$section-$name.png"
    xcrun simctl io "$DEVICE" screenshot "$file" >/dev/null 2>&1
  done
done <<< "$SIZES"
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
echo "Screenshots in $OUT"
