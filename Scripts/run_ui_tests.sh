#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${SORIA_UI_DERIVED_DATA_PATH:-/tmp/Soria-DerivedData}"
RESULT_BUNDLE_PATH="${SORIA_UI_RESULT_BUNDLE_PATH:-}"
SCHEME="${SORIA_UI_SCHEME:-Soria}"
PROJECT_PATH="${SORIA_UI_PROJECT_PATH:-$ROOT_DIR/Soria.xcodeproj}"
DESTINATION="${SORIA_UI_DESTINATION:-platform=macOS,arch=$(uname -m)}"
SIGNING_MODE="${SORIA_UI_SIGNING_MODE:-signed}"
RUN_MODE="${SORIA_UI_RUN_MODE:-direct}"
TEST_ARGS=("$@")

if [[ ${#TEST_ARGS[@]} -eq 0 ]]; then
  TEST_ARGS=(
    -only-testing:SoriaUITests
  )
fi

kill_matching_processes() {
  local pattern="$1"
  local pids

  pids="$(pgrep -f "$pattern" || true)"
  if [[ -z "$pids" ]]; then
    return
  fi

  echo "Cleaning up stale processes matching: $pattern"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 1

  pids="$(pgrep -f "$pattern" || true)"
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
}

cleanup_stale_processes() {
  kill_matching_processes "SoriaUITests-Runner"
  kill_matching_processes "/Soria\\.app/Contents/MacOS/Soria"
  kill_matching_processes "xcodebuild.*Soria.*(test|xctestrun)"
}

cleanup_stale_processes
rm -rf "$DERIVED_DATA_PATH"
if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
  rm -rf "$RESULT_BUNDLE_PATH"
fi

BUILD_ARGS=()
if [[ "$SIGNING_MODE" == "unsigned" ]]; then
  BUILD_ARGS+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
  )
fi

RESULT_BUNDLE_ARGS=()
if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
  RESULT_BUNDLE_ARGS+=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi

if [[ "$RUN_MODE" == "two-phase" ]]; then
  echo "Building UI tests into $DERIVED_DATA_PATH"
  BUILD_FOR_TESTING_ARGS=(
    build-for-testing
    -scheme "$SCHEME" \
    -project "$PROJECT_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION"
  )
  if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
    BUILD_FOR_TESTING_ARGS+=("${BUILD_ARGS[@]}")
  fi

  SORIA_SKIP_BUNDLED_VENV_FOR_UI_TESTS=1 \
  xcodebuild "${BUILD_FOR_TESTING_ARGS[@]}"

  XCTESTRUN_PATH="$(find "$DERIVED_DATA_PATH/Build/Products" -name '*.xctestrun' -print -quit)"
  if [[ -z "$XCTESTRUN_PATH" ]]; then
    echo "Unable to find an .xctestrun file under $DERIVED_DATA_PATH/Build/Products" >&2
    exit 1
  fi

  echo "Running UI tests from $XCTESTRUN_PATH"
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN_PATH" \
    -destination "$DESTINATION" \
    "${RESULT_BUNDLE_ARGS[@]}" \
    "${TEST_ARGS[@]}"
else
  echo "Running UI tests directly into $DERIVED_DATA_PATH"
  DIRECT_TEST_ARGS=(
    test
    -scheme "$SCHEME" \
    -project "$PROJECT_PATH" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION"
  )
  if [[ ${#RESULT_BUNDLE_ARGS[@]} -gt 0 ]]; then
    DIRECT_TEST_ARGS+=("${RESULT_BUNDLE_ARGS[@]}")
  fi
  if [[ ${#BUILD_ARGS[@]} -gt 0 ]]; then
    DIRECT_TEST_ARGS+=("${BUILD_ARGS[@]}")
  fi
  DIRECT_TEST_ARGS+=("${TEST_ARGS[@]}")

  SORIA_SKIP_BUNDLED_VENV_FOR_UI_TESTS=1 \
  xcodebuild "${DIRECT_TEST_ARGS[@]}"
fi

cleanup_stale_processes
if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
  echo "UI test result bundle: $RESULT_BUNDLE_PATH"
fi
