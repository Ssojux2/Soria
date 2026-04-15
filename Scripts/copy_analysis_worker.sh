#!/bin/sh
set -eu

SRC_DIR="${PROJECT_DIR}/analysis-worker"
DST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/analysis-worker"

if [ ! -d "${SRC_DIR}" ]; then
  echo "analysis-worker source directory not found: ${SRC_DIR}" >&2
  exit 1
fi

mkdir -p "${DST_DIR}"

/usr/bin/rsync -a --delete \
  --exclude='.pytest_cache' \
  --exclude='__pycache__' \
  --exclude='tests' \
  "${SRC_DIR}/" "${DST_DIR}/"

if [ -f "${DST_DIR}/.venv/bin/python" ]; then
  /bin/chmod +x "${DST_DIR}/.venv/bin/python"
fi
