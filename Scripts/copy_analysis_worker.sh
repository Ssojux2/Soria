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
  --exclude=.pytest_cache
  --exclude=__pycache__
  --exclude=tests
"

if [ "${SORIA_SKIP_BUNDLED_VENV_FOR_UI_TESTS:-0}" = "1" ]; then
  RSYNC_EXCLUDES="${RSYNC_EXCLUDES}
  --exclude=.venv
"
fi

# shellcheck disable=SC2086
/usr/bin/rsync -a --delete \
  ${RSYNC_EXCLUDES} \
  "${SRC_DIR}/" "${DST_DIR}/"

if [ -f "${DST_DIR}/.venv/bin/python" ]; then
  /bin/chmod +x "${DST_DIR}/.venv/bin/python"
fi
