#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${ROOT_DIR}/.build/DerivedData"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/Soria.app"

CLEAN_FIRST=0
if [ "${1:-}" = "--clean" ]; then
  CLEAN_FIRST=1
fi

if [ "${CLEAN_FIRST}" -eq 1 ]; then
  xcodebuild clean \
    -scheme Soria \
    -project "${ROOT_DIR}/Soria.xcodeproj" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
fi

xcodebuild build \
  -scheme Soria \
  -project "${ROOT_DIR}/Soria.xcodeproj" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

/usr/bin/osascript -e 'tell application id "bluepenguin.Soria" to quit' >/dev/null 2>&1 || true
/bin/sleep 1
/usr/bin/open "${APP_PATH}"

printf 'Launched %s\n' "${APP_PATH}"
