#!/bin/bash
# Set the app's version for a release and commit it, so the tagged source says which version it is.
# Usage: set-version.sh <version>, e.g. set-version.sh 0.16.0
#
# Builds from a source zip have no git history, so they take MARKETING_VERSION and
# CURRENT_PROJECT_VERSION from the project. The build number written here is the commit count
# including this commit, which is what release.sh and build.sh use when git is there, so a source
# build reports the same version and build as the release made from that commit.
# Run it on the commit to release, then Scripts/release.sh, then tag that commit v<version>.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$SCRIPT_DIR")"
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "usage: set-version.sh <version>, e.g. 0.16.0" >&2; exit 1; }
PROJECT=Atelier.xcodeproj/project.pbxproj
git diff --quiet -- "$PROJECT" && git diff --cached --quiet -- "$PROJECT" ||
  { echo "error: $PROJECT has uncommitted changes; commit or stash them first" >&2; exit 1; }

BUILD=$(($(git rev-list --count HEAD) + 1))
sed -i '' -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/" \
  -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PROJECT"
# Commit only the project file: other work may be staged in this checkout.
git commit -m "Version $VERSION ($BUILD)" -- "$PROJECT" >/dev/null
echo "Committed version $VERSION ($BUILD) as $(git rev-parse --short HEAD)"
