#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${ROOT_DIR}/.build/DerivedData"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/Soria.app"
BUNDLE_ID="bluepenguin.Soria"

CLEAN_FIRST=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean]

Builds the Debug app bundle and launches it through Launch Services.
EOF
}

case "${1:-}" in
  "")
    ;;
  --clean)
    CLEAN_FIRST=1
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown option: %s\n\n' "${1}" >&2
    usage >&2
    exit 64
    ;;
esac

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

if [ ! -d "${APP_PATH}" ]; then
  printf 'Expected app bundle was not produced: %s\n' "${APP_PATH}" >&2
  exit 1
fi

/usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

for _ in $(seq 1 20); do
  if ! /usr/bin/pgrep -x "Soria" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done

/usr/bin/open -n "${APP_PATH}"

for _ in $(seq 1 40); do
  if /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to activate" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done

printf 'Launched %s\n' "${APP_PATH}"
