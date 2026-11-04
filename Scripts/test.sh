#!/bin/bash
# Runs the unit tests in Sources/AtelierTests (Mac only), building into build/ like build.sh. They
# need no models. Signed ad hoc, so the test bundle always matches the app that hosts it, and under
# its own bundle id (see Config/Atelier.xcconfig), so it runs beside an open Atelier.
# Usage: test.sh [xcodebuild test options, e.g. -only-testing:AtelierTests/StyleTests]

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Each test's line and the summary; without the filter a run prints every compiler command.
xcodebuild -project Atelier.xcodeproj -scheme Atelier -configuration Debug \
  -derivedDataPath build/DerivedData-Tests -clonedSourcePackagesDirPath build/SourcePackages \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ATELIER_BUNDLE_SUFFIX=.tests "$@" test 2>&1 |
  grep -E '^(◇|↳|✔|✘|􀟈|􁁛|􀢄|􀇾)|Test run with|Test Suite .* (passed|failed)|: error:|: warning: .*AtelierTests|\*\* TEST'
