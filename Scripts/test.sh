#!/bin/bash
# Runs the unit tests in Sources/AtelierTests (Mac only), building into build/ like build.sh. They
# need no models. Signed ad hoc, so the test bundle always matches the app that hosts it, and under
# its own bundle id (see Config/Atelier.xcconfig), so it runs beside an open Atelier.
#
# Usage: test.sh [mode] [options] [xcodebuild test options]
#   (no mode), --smoke  the smoke set: suites tagged `.smoke` (Sources/AtelierTests/Tags.swift),
#                       fast pure logic, for iterating
#   --changed [BASE]    the suites for what changed since BASE (default origin/main): commits since
#                       the merge base, the working tree and untracked files, mapped by name
#                       (Foo.swift runs the suites in *Foo*Tests.swift) and by Scripts/test-map.txt.
#                       Prints the automation checks that cover the change; --checks runs them
#   --suite A,B         just these suites (struct names)
#   --all               every suite: before a release or after touching shared types
#   --lint-map          fails when Scripts/test-map.txt misses a source folder, suite or check flag
#   --timings           after the run, the slowest suites from its result bundle; alone, from the
#                       last run's (build/TestResults/last.xcresult)
# Options:
#   --checks --model FILE [--project NAME]   with --changed: run the printed checks with the
#                       worktree's build/Atelier.app, in a scratch project (default test-checks)
#   --serial            run suites one at a time instead of in parallel (the default), ~3x the
#                       test time for --all; for telling a test that breaks only alongside others
#   --parallel          run suites in parallel (the default)
# Anything else goes to xcodebuild, e.g. -only-testing:AtelierTests/StyleTests.
# Bash 3.2 (macOS /bin/bash): no associative arrays.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

TESTS_DIR=Sources/AtelierTests
MAP=Scripts/test-map.txt
RESULT=build/TestResults/last.xcresult
APP=build/Atelier.app/Contents/MacOS/Atelier

MODE=
BASE=origin/main
SUITE_ARG=
RUN_CHECKS=false
CHECK_MODEL=
CHECK_PROJECT=test-checks
PARALLEL=YES
TIMINGS=false
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) MODE=smoke ;;
    --all) MODE=all ;;
    --lint-map) MODE=lint ;;
    --changed)
      MODE=changed
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
        BASE="$2"
        shift
      fi
      ;;
    --suite)
      MODE=suite
      SUITE_ARG="${2:-}"
      shift
      ;;
    --suite=*)
      MODE=suite
      SUITE_ARG="${1#--suite=}"
      ;;
    --checks) RUN_CHECKS=true ;;
    --model)
      CHECK_MODEL="${2:-}"
      shift
      ;;
    --project)
      CHECK_PROJECT="${2:-}"
      shift
      ;;
    --parallel) PARALLEL=YES ;;
    --serial) PARALLEL=NO ;;
    --timings) TIMINGS=true ;;
    *) PASSTHROUGH+=("$1") ;;
  esac
  shift
done
if [ -z "$MODE" ]; then
  if $RUN_CHECKS; then
    MODE=changed
  elif $TIMINGS && [ ${#PASSTHROUGH[@]} -eq 0 ]; then
    MODE=timings-only
  else
    MODE=smoke
  fi
fi
if $RUN_CHECKS && [ "$MODE" != changed ]; then
  echo "error: --checks goes with --changed" >&2
  exit 2
fi

# MARK: - Suites

# Top-level suite types (`struct XTests` or `class XTests` at the start of a line, after any
# attributes; indented only inside `#if`) in the given files.
suites_in() {
  [ $# -gt 0 ] || return 0
  sed -nE 's/^[[:space:]]*(@[^ ]+ )*(struct|final class|class) ([A-Za-z0-9_]+Tests)[ :{].*/\3/p' "$@"
}

all_suites() {
  suites_in "$TESTS_DIR"/*.swift | sort -u
}

# Suites marked `@Suite(.tags(.smoke))`, on the struct's line or the lines just above it.
smoke_suites() {
  awk '
    /@Suite\(.*\.smoke/ { tagged = 1 }
    /^[ \t]*(@[^ ]+ )*(struct|final class|class) [A-Za-z0-9_]+Tests[ :{]/ {
      if (tagged) {
        name = $0
        sub(/^.*(struct|class) /, "", name)
        sub(/[ :{].*$/, "", name)
        print name
      }
      tagged = 0
    }
  ' "$TESTS_DIR"/*.swift | sort -u
}

# Suites a source file selects by name: Foo.swift runs the suites in *Foo*Tests.swift.
convention_suites() {
  local stem file matches=()
  stem="$(basename "$1" .swift)"
  for file in "$TESTS_DIR"/*"$stem"*Tests.swift; do
    [ -f "$file" ] && matches+=("$file")
  done
  if [ ${#matches[@]} -gt 0 ]; then suites_in "${matches[@]}"; fi
  return 0
}

# MARK: - Map

# The map's lines as `prefix|suites|checks`, trimmed, without comments.
map_lines() {
  sed -e 's/#.*//' "$MAP" | awk -F'|' '
    NF >= 2 {
      for (i = 1; i <= 3; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
      if ($1 != "") print $1 "|" $2 "|" $3
    }'
}

# The longest map line whose prefix (a shell pattern) matches the start of the path, as
# `suites|checks`; empty when none does.
map_lookup() {
  local path="$1" best="" bestlen=0 line prefix
  while IFS= read -r line; do
    prefix="${line%%|*}"
    # shellcheck disable=SC2254
    case "$path" in
      $prefix*)
        if [ ${#prefix} -gt $bestlen ]; then
          best="${line#*|}"
          bestlen=${#prefix}
        fi
        ;;
    esac
  done < <(map_lines)
  echo "$best"
}

# Scripted-run flags the app knows (`Automation.isRequested`), less --show, which only picks a
# section, plus --generate's own --reuse.
known_flags() {
  (
    sed -n '/let flags = \[/,/\]/p' Sources/Atelier/Automation/Automation.swift |
      grep -oE '"--[a-z0-9-]+"' | tr -d '"' | grep -vx -- '--show'
  ) | sort -u
}

# `flag function` for each check `Automation.runIfRequested` dispatches.
flag_functions() {
  awk '
    /if args\.contains\("--[a-z0-9-]+"\)/ {
      match($0, /"--[a-z0-9-]+"/)
      flag = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    flag != "" {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (match(line, /^[A-Za-z0-9_]+\(/)) print flag, substr(line, 1, RLENGTH - 1)
      flag = ""
    }
  ' Sources/Atelier/Automation/Automation.swift
}

# The checks an Automation*.swift file implements.
checks_in_automation_file() {
  [ -f "$1" ] || return 0
  local funcs flag fn
  funcs="$(sed -nE 's/^ *(private |fileprivate )?static func ([A-Za-z0-9_]+)\(.*/\2/p' "$1")"
  [ -n "$funcs" ] || return 0
  flag_functions | while read -r flag fn; do
    if grep -qx "$fn" <<<"$funcs"; then echo "$flag"; fi
  done
}

# MARK: - Running

if [ -z "$DEVELOPER_DIR" ] && ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Each suite's summed test time, slowest first (in a parallel run suites overlap, so the sum isn't
# the wall time).
print_timings() {
  local bundle="$1"
  if [ ! -d "$bundle" ]; then
    echo "error: no result bundle at $bundle; run the tests first" >&2
    return 1
  fi
  echo "Slowest suites (summed test time):"
  xcrun xcresulttool get test-results tests --path "$bundle" --compact |
    jq -r '
      [.. | objects | select(.nodeType? == "Test Suite") |
        {name, total: ([.. | objects | select(.nodeType? == "Test Case") | (.durationInSeconds // 0)] | add // 0)}]
      | sort_by(-.total) | .[:15][] | "\(.total * 100 | round / 100)\t\(.name)"' |
    awk -F'\t' '{ printf "  %7ss  %s\n", $1, $2 } END { if (NR == 0) print "  (no suites in the result bundle)" }'
}

# Runs xcodebuild test once: every suite, or only the ones given.
run_tests() {
  local parallel="$1" suite started status=0
  shift
  local only=() parallel_args=()
  for suite in "$@"; do
    only+=("-only-testing:AtelierTests/$suite")
  done
  [ "$parallel" = NO ] && parallel_args=(-parallel-testing-enabled NO)
  source "$SCRIPT_DIR/hide-build-from-spotlight.sh"
  mkdir -p "$(dirname "$RESULT")"
  rm -rf "$RESULT"
  started=$(date +%s)
  # Each test's line and the summary; without the filter a run prints every compiler command.
  xcodebuild -project Atelier.xcodeproj -scheme Atelier -configuration Debug \
    -derivedDataPath build/DerivedData-Tests -clonedSourcePackagesDirPath build/SourcePackages \
    -destination 'platform=macOS' -resultBundlePath "$RESULT" ${parallel_args[@]+"${parallel_args[@]}"} \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ATELIER_BUNDLE_SUFFIX=.tests \
    ${only[@]+"${only[@]}"} ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} test 2>&1 |
    grep -E '^(◇|↳|✔|✘|􀟈|􁁛|􀢄|􀇾)|Test run with|Test Suite .* (passed|failed)|: error:|: warning: .*AtelierTests|\*\* TEST' ||
    status=$?
  echo "($(($(date +%s) - started)) s including the build; parallel testing $( [ "$parallel" = NO ] && echo off || echo on))"
  if $TIMINGS; then print_timings "$RESULT" || true; fi
  return $status
}

# MARK: - Lint

lint_map() {
  local errors=0 name mapped_suites mapped_checks folders covered suites flags prefixes
  prefixes="$(map_lines | cut -d'|' -f1)"
  mapped_suites="$(map_lines | cut -d'|' -f2 | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u)"
  mapped_checks="$(map_lines | cut -d'|' -f3 | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u)"
  suites="$(all_suites)"
  flags="$(known_flags)"

  # Every folder of app sources has its own line.
  folders="$(find Sources/Atelier -name '*.swift' -exec dirname {} \; | sort -u)"
  for name in $folders; do
    if ! grep -qxF "$name/" <<<"$prefixes"; then
      echo "lint: no line for folder $name/ in $MAP"
      errors=$((errors + 1))
    fi
  done

  # Every suite runs for some change: tagged smoke, named in the map, or picked by a source file's name.
  covered="$( (
    smoke_suites
    echo "$mapped_suites"
    find Sources/Atelier -name '*.swift' | while read -r file; do convention_suites "$file"; done
  ) | sort -u)"
  for name in $suites; do
    if ! grep -qxF "$name" <<<"$covered"; then
      echo "lint: suite $name has no .smoke tag, no line in $MAP and no source file named after it"
      errors=$((errors + 1))
    fi
  done

  # Every check flag has a line, and every name in the map still exists.
  for name in $flags; do
    if ! grep -qxF -- "$name" <<<"$mapped_checks"; then
      echo "lint: check $name is in no line of $MAP"
      errors=$((errors + 1))
    fi
  done
  for name in $mapped_suites; do
    case "$name" in all | smoke | none) continue ;; esac
    if ! grep -qxF "$name" <<<"$suites"; then
      echo "lint: $MAP names suite $name, which doesn't exist"
      errors=$((errors + 1))
    fi
  done
  for name in $mapped_checks; do
    if ! grep -qxF -- "$name" <<<"$flags"; then
      echo "lint: $MAP names check $name, which the app doesn't know"
      errors=$((errors + 1))
    fi
  done

  if [ $errors -gt 0 ]; then
    echo "lint-map: $errors problem(s)"
    return 1
  fi
  echo "lint-map: OK ($(echo "$suites" | wc -l | tr -d ' ') suites, $(echo "$flags" | wc -l | tr -d ' ') checks, $(echo "$folders" | wc -l | tr -d ' ') folders)"
}

# MARK: - Checks

# A check's arguments beyond its flag, --project, --model and --quit.
check_extra_args() {
  case "$1" in
    --generate) echo '--prompt "a red apple on a wooden table" --width 512 --height 512 --steps 2' ;;
    --reuse) echo latest ;;
  esac
}

check_command() {
  local extra
  extra="$(check_extra_args "$1")"
  echo "$APP $1${extra:+ $extra} --project $CHECK_PROJECT --model ${CHECK_MODEL:-<model.ckpt>} --quit"
}

run_checks() {
  local flag failed=0 log app_time head_time
  if [ -z "$CHECK_MODEL" ]; then
    echo "error: --checks needs --model FILE (a model in your models folder)" >&2
    return 2
  fi
  if [ ! -x "$APP" ]; then
    echo "error: no $APP; build it with Scripts/build.sh Debug mac" >&2
    return 2
  fi
  if pgrep -x Atelier >/dev/null; then
    echo "error: Atelier is running; quit it first (a check would share its settings and models)" >&2
    return 2
  fi
  app_time="$(stat -f %m "$APP")"
  head_time="$(git log -1 --format=%ct HEAD)"
  if [ "$app_time" -lt "$head_time" ]; then
    echo "warning: $APP is older than HEAD; rebuild with Scripts/build.sh Debug mac"
  fi
  log="$(mktemp -t atelier-checks)"
  for flag in "$@"; do
    echo "== $(check_command "$flag")"
    local cmd=("$APP" "$flag")
    case "$flag" in
      --generate) cmd+=(--prompt "a red apple on a wooden table" --width 512 --height 512 --steps 2) ;;
      --reuse) cmd+=(latest) ;;
    esac
    cmd+=(--project "$CHECK_PROJECT" --model "$CHECK_MODEL" --quit)
    "${cmd[@]}" >"$log" 2>&1 || true
    grep -E 'PASS|FAIL' "$log" || tail -5 "$log"
    if grep -q FAIL "$log"; then failed=$((failed + 1)); fi
  done
  rm -f "$log"
  echo "checks: $failed of $# printed FAIL lines"
  [ $failed -eq 0 ]
}

# MARK: - Modes

case "$MODE" in
  lint)
    lint_map
    ;;
  timings-only)
    print_timings "$RESULT"
    ;;
  smoke)
    SMOKE=($(smoke_suites))
    if [ ${#SMOKE[@]} -eq 0 ]; then
      echo "error: no suite is tagged .smoke" >&2
      exit 1
    fi
    echo "Smoke set: ${SMOKE[*]}"
    run_tests "$PARALLEL" "${SMOKE[@]}"
    ;;
  all)
    run_tests "$PARALLEL"
    ;;
  suite)
    SUITES=()
    for name in $(echo "$SUITE_ARG" | tr ',' ' '); do
      if ! grep -qxF "$name" <<<"$(all_suites)"; then
        echo "error: no suite $name in $TESTS_DIR" >&2
        exit 2
      fi
      SUITES+=("$name")
    done
    if [ ${#SUITES[@]} -eq 0 ]; then
      echo "error: --suite needs suite names, e.g. --suite StyleTests,ValueTests" >&2
      exit 2
    fi
    run_tests "$PARALLEL" "${SUITES[@]}"
    ;;
  changed)
    if ! git rev-parse --verify -q "$BASE" >/dev/null; then
      echo "error: no such base $BASE" >&2
      exit 2
    fi
    FILES="$( (
      git diff --name-only "$BASE"...HEAD
      git diff --name-only HEAD
      git ls-files --others --exclude-standard
    ) | sort -u)"
    RUN_ALL=false RUN_SMOKE=false RUN_LINT=false
    SUITES="" CHECKS="" UNCOVERED=""
    for file in $FILES; do
      case "$file" in
        *.md) continue ;;
        Scripts/test.sh | Scripts/test-map.txt | Sources/AtelierTests/*) RUN_LINT=true ;;
      esac
      found=false
      entry="$(map_lookup "$file")"
      if [ -n "$entry" ]; then
        found=true
        for name in $(echo "${entry%%|*}" | tr ',' ' '); do
          case "$name" in
            all) RUN_ALL=true ;;
            smoke) RUN_SMOKE=true ;;
            none) ;;
            *) SUITES="$SUITES $name" ;;
          esac
        done
        CHECKS="$CHECKS $(echo "${entry#*|}" | tr ',' ' ')"
      fi
      case "$file" in
        "$TESTS_DIR"/*.swift)
          found=true
          if [ -f "$file" ]; then SUITES="$SUITES $(suites_in "$file" | tr '\n' ' ')"; fi
          ;;
        Sources/Atelier/*.swift)
          if [[ "$file" == Sources/Atelier/Automation/* ]]; then
            CHECKS="$CHECKS $(checks_in_automation_file "$file" | tr '\n' ' ')"
          fi
          by_name="$(convention_suites "$file" | tr '\n' ' ')"
          if [ -n "${by_name// /}" ]; then
            SUITES="$SUITES $by_name"
            found=true
          fi
          ;;
      esac
      if ! $found; then
        UNCOVERED="$UNCOVERED $file"
        RUN_SMOKE=true
      fi
    done
    for file in $UNCOVERED; do
      echo "warning: no suite covers $file (add a line to $MAP); running the smoke set for it"
    done
    if $RUN_SMOKE; then SUITES="$SUITES $(smoke_suites | tr '\n' ' ')"; fi
    # shellcheck disable=SC2086
    SUITES="$(printf '%s\n' $SUITES | sort -u | tr '\n' ' ')"
    # shellcheck disable=SC2086
    CHECKS="$(printf '%s\n' $CHECKS | sort -u | tr '\n' ' ')"
    if ! $RUN_ALL && [ -z "${SUITES// /}" ] && [ -z "${CHECKS// /}" ] && ! $RUN_LINT; then
      echo "Nothing but docs changed since $BASE: no tests needed."
      exit 0
    fi
    if $RUN_LINT; then lint_map; fi
    if $RUN_ALL; then
      echo "Shared or build files changed: running every suite."
      run_tests "$PARALLEL"
    elif [ -n "${SUITES// /}" ]; then
      echo "Suites: $SUITES"
      # shellcheck disable=SC2086
      run_tests "$PARALLEL" $SUITES
    else
      echo "No unit suite covers this change."
    fi
    if [ -n "${CHECKS// /}" ]; then
      if $RUN_CHECKS; then
        # shellcheck disable=SC2086
        run_checks $CHECKS
      else
        echo
        echo "Automation checks for this change (they need models; run them, or add --checks --model FILE):"
        for flag in $CHECKS; do echo "  $(check_command "$flag")"; done
      fi
    fi
    ;;
esac
