#!/bin/sh
set -eu

SRC_DIR="${PROJECT_DIR}/analysis-worker"
DST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/analysis-worker"

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

# Python virtual environments are disposable and not safe to relocate inside app bundles.
/bin/rm -rf "${DST_DIR}/.venv"

# shellcheck disable=SC2086
/usr/bin/rsync -a --delete --delete-excluded \
  ${RSYNC_EXCLUDES} \
  "${SRC_DIR}/" "${DST_DIR}/"
