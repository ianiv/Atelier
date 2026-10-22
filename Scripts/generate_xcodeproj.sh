#!/bin/bash
# Generate Atelier.xcodeproj from project.yml with XcodeGen (brew install xcodegen), taking the
# engine pin from Package.swift so the two can't drift. Re-run after changing either file or
# adding source files.
# Usage: generate_xcodeproj.sh [--open]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

if ! command -v xcodegen >/dev/null; then
  echo "error: xcodegen not found; install it with: brew install xcodegen" >&2
  exit 1
fi

ATELIER_DRAW_THINGS_REVISION="$(
  grep -A2 'drawthingsai/draw-things-community' Package.swift | sed -n 's/.*revision: "\([0-9a-f]*\)".*/\1/p'
)"
if [ -z "$ATELIER_DRAW_THINGS_REVISION" ]; then
  echo "error: couldn't read the draw-things-community revision from Package.swift" >&2
  exit 1
fi
export ATELIER_DRAW_THINGS_REVISION

xcodegen generate --spec project.yml
echo "Generated $PROJECT_ROOT/Atelier.xcodeproj (draw-things-community @ $ATELIER_DRAW_THINGS_REVISION)"

if [ "$1" = "--open" ]; then
  open Atelier.xcodeproj
fi
