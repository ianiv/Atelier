#!/bin/bash
# Clear out old Atelier builds: drop every Atelier copy except /Applications/Atelier.app from Launch Services
# (the duplicates in Spotlight and Open With), and delete Xcode's own DerivedData for Atelier, which
# Scripts/build.sh doesn't use. The installed app and this checkout's build/ folder are left alone.
# Usage: clean-builds.sh [--all]
#   --all  also delete this checkout's build products and caches (build/DerivedData*, build/*.app), keeping
#          build/SourcePackages and build/release. The next build is a full one.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$LSREGISTER" -dump | sed -n -E 's/^path: +(.*Atelier[^/]*\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u |
  while read -r app; do
    [ "$app" = /Applications/Atelier.app ] && continue
    "$LSREGISTER" -u "$app" 2>/dev/null || true
    echo "Unregistered $app"
  done

for derived in "$HOME"/Library/Developer/Xcode/DerivedData/Atelier-*; do
  [ -d "$derived" ] || continue
  rm -rf "$derived"
  echo "Deleted $derived"
done

if [ "$1" = --all ]; then
  rm -rf build/DerivedData* build/*.app
  echo "Deleted $PROJECT_ROOT/build/DerivedData* and build/*.app"
fi
