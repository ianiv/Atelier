#!/bin/bash
# Regenerates Sources/ProjectFormat from the History schemas of the pinned engine revision.
# Needs bazelisk (brew install bazelisk). Builds dflat's codegen tools in a temporary copy of the
# dflat checkout, so neither the package checkouts nor the engine checkout is modified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKOUTS="$ROOT/build/SourcePackages/checkouts"
SCHEMAS="$CHECKOUTS/draw-things-community/Libraries/History/Sources"
DFLAT="$CHECKOUTS/dflat"
OUT="$ROOT/Sources/ProjectFormat"
[[ -d "$SCHEMAS" && -d "$DFLAT" ]] || { echo "Run Scripts/build.sh first to check out the packages." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$DFLAT" "$WORK/dflat"
rm -rf "$WORK/dflat/.git"
(cd "$WORK/dflat" && bazel build src/parser:dflats src/parser:dflatc)
TOOLS="$WORK/dflat/bazel-bin/src/parser"

mkdir -p "$WORK/gen"
for schema in clip script_session tensor_data tensor_history tensor_moodboard_data \
  thumbnail_history thumbnail_history_half; do
  "$TOOLS/dflats" -o "$WORK/gen" "$SCHEMAS/$schema.fbs"
  "$TOOLS/dflatc" -o "$WORK/gen" "$WORK/gen/${schema}_generated.json"
done
rm -f "$WORK"/gen/*.json
rm -f "$OUT"/*_generated.swift
mkdir -p "$OUT"
cp "$WORK"/gen/*_generated.swift "$OUT/"
(cd "$WORK/dflat" && bazel shutdown) >/dev/null 2>&1 || true
echo "Generated $(ls "$OUT"/*_generated.swift | wc -l | tr -d ' ') files in $OUT"
