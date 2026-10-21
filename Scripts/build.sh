#!/bin/bash
# Build the release Atelier binary with SwiftPM.
# Uses the native build system because the default (swiftbuild) breaks Metal 4 / i8x models.
# Usage: build.sh [extra swift build args ...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

swift build -c release --build-system native --product Atelier "$@"
echo "Built $PROJECT_ROOT/.build/release/Atelier"
