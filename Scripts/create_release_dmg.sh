#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-${ROOT_DIR}/Soria.xcodeproj}"
SCHEME="${SCHEME:-Soria}"
APP_NAME="${APP_NAME:-Soria}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-${ROOT_DIR}/.build/ReleaseDerivedData}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
MACOS_DESTINATION="${SORIA_MACOS_DESTINATION:-platform=macOS,arch=$(uname -m)}"
VOLUME_NAME="${VOLUME_NAME:-Soria}"
VERSION="${VERSION:-}"
CLEAN_FIRST="${CLEAN_FIRST:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--skip-build] [--version VERSION]

Builds a Release app bundle, ad-hoc signs it, and packages it as DMG and ZIP
artifacts for early GitHub Releases distribution.

Environment overrides:
  VERSION                Release version. Defaults to Xcode MARKETING_VERSION.
  CONFIGURATION          Xcode configuration. Defaults to Release.
  DERIVED_DATA_PATH      Build output path. Defaults to .build/ReleaseDerivedData.
  DIST_DIR               Artifact output path. Defaults to dist.
  SORIA_MACOS_DESTINATION
                         Xcode destination. Defaults to platform=macOS,arch=<host arch>.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --clean)
      CLEAN_FIRST=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    --version)
      if [ "$#" -lt 2 ]; then
        printf 'Missing value for --version\n' >&2
        exit 64
      fi
      VERSION="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required tool not found: %s\n' "$1" >&2
    exit 69
  fi
}

require_tool xcodebuild
require_tool hdiutil
require_tool codesign
require_tool ditto
require_tool shasum
require_tool xattr

if [ -z "${VERSION}" ]; then
  VERSION="$(
    xcodebuild \
      -project "${PROJECT_PATH}" \
      -scheme "${SCHEME}" \
      -configuration "${CONFIGURATION}" \
      -showBuildSettings 2>/dev/null \
      | awk -F'= ' '/ MARKETING_VERSION = / { print $2; exit }' \
      | tr -d '[:space:]'
  )"
fi

if [ -z "${VERSION}" ]; then
  VERSION="0.0.0"
fi

SAFE_VERSION="$(printf '%s' "${VERSION}" | tr -c 'A-Za-z0-9._-' '-')"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
STAGING_DIR=""
STAGING_APP=""
DMG_PATH="${DIST_DIR}/${APP_NAME}-${SAFE_VERSION}-macOS-unnotarized.dmg"
CHECKSUM_PATH="${DMG_PATH}.sha256"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${SAFE_VERSION}-macOS-unnotarized.zip"
ZIP_CHECKSUM_PATH="${ZIP_PATH}.sha256"
MOUNT_DIR=""
ZIP_VERIFY_DIR=""

cleanup() {
  if [ -n "${MOUNT_DIR}" ] && [ -d "${MOUNT_DIR}" ]; then
    hdiutil detach "${MOUNT_DIR}" -quiet >/dev/null 2>&1 || true
    rm -rf "${MOUNT_DIR}"
  fi
  if [ -n "${ZIP_VERIFY_DIR}" ] && [ -d "${ZIP_VERIFY_DIR}" ]; then
    rm -rf "${ZIP_VERIFY_DIR}"
  fi
  if [ -n "${STAGING_DIR}" ] && [ -d "${STAGING_DIR}" ]; then
    rm -rf "${STAGING_DIR}"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "${DIST_DIR}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soria-dmg-root.XXXXXX")"
STAGING_APP="${STAGING_DIR}/${APP_NAME}.app"

if [ "${CLEAN_FIRST}" -eq 1 ]; then
  xcodebuild clean \
    -scheme "${SCHEME}" \
    -project "${PROJECT_PATH}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination "${MACOS_DESTINATION}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
fi

if [ "${SKIP_BUILD}" -ne 1 ]; then
  xcodebuild build \
    -scheme "${SCHEME}" \
    -project "${PROJECT_PATH}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination "${MACOS_DESTINATION}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
fi

if [ ! -d "${APP_PATH}" ]; then
  printf 'Expected app bundle was not produced: %s\n' "${APP_PATH}" >&2
  exit 1
fi

ditto --noextattr --noqtn "${APP_PATH}" "${STAGING_APP}"
ln -s /Applications "${STAGING_DIR}/Applications"

cat > "${STAGING_DIR}/README-FIRST.txt" <<EOF
Soria ${VERSION}

This is an early open-source macOS build.

The app is ad-hoc signed, but it is not Developer ID signed and has not been
notarized by Apple. macOS Gatekeeper will warn before opening it. If you trust
this source, open it through System Settings > Privacy & Security > Open Anyway,
or build the app from source with Xcode.
EOF

xattr -cr "${STAGING_APP}"
codesign --force --deep --sign - "${STAGING_APP}"
codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

rm -f "${DMG_PATH}" "${CHECKSUM_PATH}" "${ZIP_PATH}" "${ZIP_CHECKSUM_PATH}"
ditto -c -k --sequesterRsrc --keepParent "${STAGING_APP}" "${ZIP_PATH}"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

(
  cd "${DIST_DIR}"
  shasum -a 256 "$(basename "${DMG_PATH}")" > "$(basename "${CHECKSUM_PATH}")"
  shasum -a 256 "$(basename "${ZIP_PATH}")" > "$(basename "${ZIP_CHECKSUM_PATH}")"
)

ZIP_VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soria-zip.XXXXXX")"
ditto -x -k "${ZIP_PATH}" "${ZIP_VERIFY_DIR}"
if [ ! -d "${ZIP_VERIFY_DIR}/${APP_NAME}.app" ]; then
  printf 'ZIP verification failed: app bundle not found in archive.\n' >&2
  exit 1
fi
rm -rf "${ZIP_VERIFY_DIR}"
ZIP_VERIFY_DIR=""

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soria-dmg.XXXXXX")"
hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_DIR}" -nobrowse -readonly -quiet
if [ ! -d "${MOUNT_DIR}/${APP_NAME}.app" ]; then
  printf 'DMG verification failed: app bundle not found in mounted image.\n' >&2
  exit 1
fi
hdiutil detach "${MOUNT_DIR}" -quiet
rm -rf "${MOUNT_DIR}"
MOUNT_DIR=""
rm -rf "${STAGING_DIR}"
STAGING_DIR=""

printf '\nCreated release artifacts:\n'
printf '  %s\n' "${DMG_PATH}"
printf '  %s\n' "${CHECKSUM_PATH}"
printf '  %s\n' "${ZIP_PATH}"
printf '  %s\n' "${ZIP_CHECKSUM_PATH}"
printf '\nNote: these artifacts are not Developer ID signed or notarized; Gatekeeper warnings are expected.\n'
