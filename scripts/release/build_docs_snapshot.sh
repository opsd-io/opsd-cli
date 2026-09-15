#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${APP_ROOT}/dist}"
VERSION="${OPSD_RELEASE_VERSION:-$("${RUBY_BIN:-ruby}" --disable-gems -I"${APP_ROOT}/lib" -ropsd/version -e 'puts OPSd::VERSION')}"

SNAPSHOT_ROOT="${OUTPUT_DIR}/opsd_${VERSION}_docs"
ARCHIVE_PATH="${SNAPSHOT_ROOT}.tar.gz"

rm -rf "${SNAPSHOT_ROOT}" "${ARCHIVE_PATH}"
mkdir -p "${SNAPSHOT_ROOT}"

copy_path() {
  src_path="$1"
  dst_path="${SNAPSHOT_ROOT}/$1"

  if [ -d "${APP_ROOT}/${src_path}" ]; then
    mkdir -p "$(dirname "${dst_path}")"
    cp -R "${APP_ROOT}/${src_path}" "${dst_path}"
  elif [ -f "${APP_ROOT}/${src_path}" ]; then
    mkdir -p "$(dirname "${dst_path}")"
    cp "${APP_ROOT}/${src_path}" "${dst_path}"
  fi
}

for path in \
  docs/index.md \
  docs/INSTALL.md \
  docs/QUICKSTART.md \
  docs/getting-started/install.md \
  docs/getting-started/development-setup.md \
  docs/getting-started/quickstart.md \
  docs/release/packaging.md \
  docs/release/process.md \
  docs/reference/commands.md
do
  copy_path "${path}"
done

mkdir -p "${SNAPSHOT_ROOT}/lib/opsd"
cp "${APP_ROOT}/lib/opsd/cli.rb" "${SNAPSHOT_ROOT}/lib/opsd/cli.rb"
cp "${APP_ROOT}/lib/opsd/version.rb" "${SNAPSHOT_ROOT}/lib/opsd/version.rb"

for file in README.md SUPPORT.md CONTRIBUTING.md SECURITY.md RELEASE.md CHANGELOG.md; do
  if [ -f "${APP_ROOT}/${file}" ]; then
    cp "${APP_ROOT}/${file}" "${SNAPSHOT_ROOT}/${file}"
  fi
done

cat > "${SNAPSHOT_ROOT}/release.json" <<EOF
{
  "name": "opsd-cli-docs",
  "version": "${VERSION}"
}
EOF

tar -C "${OUTPUT_DIR}" -czf "${ARCHIVE_PATH}" "$(basename "${SNAPSHOT_ROOT}")"

echo "${ARCHIVE_PATH}"
