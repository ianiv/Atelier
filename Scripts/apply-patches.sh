#!/bin/bash
# Applies Patches/<package>/*.patch to the package checkouts in build/SourcePackages, resolving
# the packages first. A patch that's already applied is skipped, so this is safe to rerun.
# build.sh and release.sh call it; run it yourself after a package update to check the patches
# still apply.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodebuild -resolvePackageDependencies -project Atelier.xcodeproj -scheme Atelier \
  -clonedSourcePackagesDirPath build/SourcePackages >/dev/null

for dir in Patches/*/; do
  package="$(basename "$dir")"
  checkout="build/SourcePackages/checkouts/$package"
  [ -d "$checkout" ] || { echo "error: no checkout for $package" >&2; exit 1; }
  for patch in "$dir"*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$checkout" apply --reverse --check "$PROJECT_ROOT/$patch" 2>/dev/null; then
      continue
    fi
    # Package checkouts are read-only.
    git -C "$checkout" apply --numstat "$PROJECT_ROOT/$patch" | cut -f3 |
      while read -r file; do chmod u+w "$checkout/$file"; done
    if ! git -C "$checkout" apply "$PROJECT_ROOT/$patch"; then
      echo "error: $patch doesn't apply to $package; update it for the pinned revision" >&2
      exit 1
    fi
    echo "Applied $patch"
  done
done
