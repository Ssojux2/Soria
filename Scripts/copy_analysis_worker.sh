#!/bin/sh
set -eu

SRC_DIR="${PROJECT_DIR}/analysis-worker"
DST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/analysis-worker"
CONFIGURATION_NAME="${CONFIGURATION:-Debug}"
RUNTIME_ARCH="${SORIA_RELEASE_ARCH:-${CURRENT_ARCH:-$(uname -m)}}"

if [ -z "${RUNTIME_ARCH}" ] || [ "${RUNTIME_ARCH}" = "undefined_arch" ]; then
  RUNTIME_ARCH="$(uname -m)"
fi
case "${RUNTIME_ARCH}" in
  arm64|aarch64)
    RUNTIME_ARCH="arm64"
    ;;
  x86_64|amd64)
    RUNTIME_ARCH="x86_64"
    ;;
esac

RUNTIME_SRC="${SORIA_WORKER_RUNTIME_DIR:-${PROJECT_DIR}/.build/worker-runtime/${RUNTIME_ARCH}/python}"

if [ ! -d "${SRC_DIR}" ]; then
  echo "analysis-worker source directory not found: ${SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${DST_DIR}"

RSYNC_EXCLUDES="
  --exclude=.venv
  --exclude=.pytest_cache
  --exclude=__pycache__
  --exclude=.env
  --exclude=.env.*
  --exclude=*.key
  --exclude=*.pem
  --exclude=*.p8
  --exclude=tests
"

# Repository virtual environments are disposable and not safe to relocate inside app bundles.
/bin/rm -rf "${DST_DIR}/.venv"
/bin/rm -rf "${DST_DIR}/python"

# shellcheck disable=SC2086
/usr/bin/rsync -a --delete --delete-excluded \
  ${RSYNC_EXCLUDES} \
  "${SRC_DIR}/" "${DST_DIR}/"

if [ "${CONFIGURATION_NAME}" = "Debug" ]; then
  printf '%s\n' "${PROJECT_DIR}" > "${DST_DIR}/project-root.txt"
else
  /bin/rm -f "${DST_DIR}/project-root.txt"
fi

if [ "${CONFIGURATION_NAME}" = "Release" ]; then
  if [ ! -x "${RUNTIME_SRC}/bin/python3" ]; then
    cat >&2 <<EOF
Release builds require a bundled worker runtime at:
  ${RUNTIME_SRC}

Build it first with:
  SORIA_RELEASE_ARCH=${RUNTIME_ARCH} "${PROJECT_DIR}/Scripts/build_worker_runtime.sh"
EOF
    exit 1
  fi

  /usr/bin/rsync -a --delete --delete-excluded \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.pyo' \
    "${RUNTIME_SRC}/" "${DST_DIR}/python/"
fi

if [ -x /usr/bin/xattr ]; then
  /usr/bin/xattr -cr "${DST_DIR}" 2>/dev/null || true
  if [ -n "${FULL_PRODUCT_NAME:-}" ] && [ -d "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}" ]; then
    /usr/bin/xattr -cr "${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}" 2>/dev/null || true
  fi
fi
