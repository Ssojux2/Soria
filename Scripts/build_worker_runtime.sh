#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ARCH="${SORIA_RELEASE_ARCH:-$(uname -m)}"
PYTHON_VERSION="${SORIA_WORKER_PYTHON_VERSION:-3.11.15}"
PYTHON_STANDALONE_TAG="${SORIA_WORKER_PYTHON_STANDALONE_TAG:-20260602}"
BUILD_ROOT="${SORIA_WORKER_RUNTIME_BUILD_ROOT:-${ROOT_DIR}/.build/worker-runtime}"
CACHE_DIR="${SORIA_WORKER_RUNTIME_CACHE_DIR:-${ROOT_DIR}/.build/worker-runtime-cache}"
REQUIREMENTS_PATH="${SORIA_WORKER_REQUIREMENTS:-${ROOT_DIR}/analysis-worker/requirements.txt}"

case "${ARCH}" in
  arm64|aarch64)
    ARCH="arm64"
    TARGET_TRIPLE="aarch64-apple-darwin"
    ;;
  x86_64|amd64)
    ARCH="x86_64"
    TARGET_TRIPLE="x86_64-apple-darwin"
    ;;
  *)
    printf 'Unsupported worker runtime architecture: %s\n' "${ARCH}" >&2
    exit 64
    ;;
esac

ASSET_NAME="cpython-${PYTHON_VERSION}+${PYTHON_STANDALONE_TAG}-${TARGET_TRIPLE}-install_only_stripped.tar.gz"
ASSET_URL="${SORIA_WORKER_PYTHON_STANDALONE_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_STANDALONE_TAG}/${ASSET_NAME}}"
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
RUNTIME_ROOT="${BUILD_ROOT}/${ARCH}"
PYTHON_ROOT="${RUNTIME_ROOT}/python"
STAMP_PATH="${RUNTIME_ROOT}/.runtime-stamp"
EXPECTED_STAMP="${ASSET_NAME}|$(/sbin/md5 -q "${REQUIREMENTS_PATH}")"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force]

Builds a relocatable Python worker runtime for Soria release bundles.

Environment overrides:
  SORIA_RELEASE_ARCH                    arm64 or x86_64. Defaults to host arch.
  SORIA_WORKER_PYTHON_VERSION           Defaults to ${PYTHON_VERSION}.
  SORIA_WORKER_PYTHON_STANDALONE_TAG    Defaults to ${PYTHON_STANDALONE_TAG}.
  SORIA_WORKER_PYTHON_STANDALONE_URL    Full archive URL override.
  SORIA_WORKER_RUNTIME_BUILD_ROOT       Defaults to .build/worker-runtime.
  SORIA_WORKER_RUNTIME_CACHE_DIR        Defaults to .build/worker-runtime-cache.
EOF
}

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
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

require_tool curl
require_tool tar
require_tool xattr

if [ ! -f "${REQUIREMENTS_PATH}" ]; then
  printf 'Requirements file not found: %s\n' "${REQUIREMENTS_PATH}" >&2
  exit 66
fi

if [ "${FORCE}" -eq 0 ] && [ -x "${PYTHON_ROOT}/bin/python3" ] && [ -f "${STAMP_PATH}" ] && [ "$(cat "${STAMP_PATH}")" = "${EXPECTED_STAMP}" ]; then
  printf 'Worker runtime is up to date: %s\n' "${PYTHON_ROOT}"
  printf '%s\n' "${PYTHON_ROOT}"
  exit 0
fi

mkdir -p "${CACHE_DIR}" "${RUNTIME_ROOT}"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  printf 'Downloading portable Python runtime:\n  %s\n' "${ASSET_URL}"
  curl -fL --retry 3 --retry-delay 2 -o "${ARCHIVE_PATH}.tmp" "${ASSET_URL}"
  mv "${ARCHIVE_PATH}.tmp" "${ARCHIVE_PATH}"
fi

rm -rf "${PYTHON_ROOT}" "${RUNTIME_ROOT}/extract"
mkdir -p "${RUNTIME_ROOT}/extract"
tar -xzf "${ARCHIVE_PATH}" -C "${RUNTIME_ROOT}/extract"

if [ -d "${RUNTIME_ROOT}/extract/python/install" ]; then
  mv "${RUNTIME_ROOT}/extract/python/install" "${PYTHON_ROOT}"
elif [ -x "${RUNTIME_ROOT}/extract/python/bin/python3" ]; then
  mv "${RUNTIME_ROOT}/extract/python" "${PYTHON_ROOT}"
else
  printf 'Unexpected python-build-standalone archive layout: %s\n' "${ARCHIVE_PATH}" >&2
  exit 65
fi
rm -rf "${RUNTIME_ROOT}/extract"

"${PYTHON_ROOT}/bin/python3" -m pip install \
  --disable-pip-version-check \
  --no-compile \
  --only-binary=:all: \
  -r "${REQUIREMENTS_PATH}"

"${PYTHON_ROOT}/bin/python3" -m pip check

find "${PYTHON_ROOT}" \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) -prune -exec rm -rf {} +
xattr -cr "${PYTHON_ROOT}" 2>/dev/null || true
printf '%s\n' "${EXPECTED_STAMP}" > "${STAMP_PATH}"

printf 'Built worker runtime: %s\n' "${PYTHON_ROOT}"
printf '%s\n' "${PYTHON_ROOT}"
