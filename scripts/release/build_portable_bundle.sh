#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${APP_ROOT}/dist}"
RUBY_BIN="${OPSD_RUBY_BIN:-ruby}"
VERSION="${OPSD_RELEASE_VERSION:-$("${RUBY_BIN}" --disable-gems -I"${APP_ROOT}/lib" -ropsd/version -e 'puts OPSd::VERSION')}"
OS_NAME="${OPSD_RELEASE_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
ARCH_NAME="${OPSD_RELEASE_ARCH:-$(uname -m)}"

case "${ARCH_NAME}" in
  x86_64) ARCH_NAME="amd64" ;;
  aarch64|arm64) ARCH_NAME="arm64" ;;
esac

RUBY_VERSION="$("${RUBY_BIN}" --disable-gems -e 'print RUBY_VERSION')"
EXPECTED_RUBY_VERSION="$(tr -d '[:space:]' < "${APP_ROOT}/.ruby-version")"
RUBY_PREFIX="${OPSD_RUBY_PREFIX:-$("${RUBY_BIN}" --disable-gems -rrbconfig -e 'puts RbConfig::CONFIG.fetch("prefix")')}"

if [ "${RUBY_VERSION}" != "${EXPECTED_RUBY_VERSION}" ]; then
  echo "Portable bundles must be built with Ruby ${EXPECTED_RUBY_VERSION}, got ${RUBY_VERSION} from ${RUBY_BIN}" >&2
  exit 1
fi

case "${RUBY_PREFIX}" in
  /System/Library/Frameworks/Ruby.framework/*)
    echo "Portable bundles cannot be built from the macOS system Ruby at ${RUBY_PREFIX}" >&2
    echo "Use a relocatable Ruby install that matches .ruby-version instead." >&2
    exit 1
    ;;
esac

BUNDLE_ROOT="${OUTPUT_DIR}/opsd_${VERSION}_${OS_NAME}_${ARCH_NAME}"
ARCHIVE_PATH="${BUNDLE_ROOT}.tar.gz"

rm -rf "${BUNDLE_ROOT}" "${ARCHIVE_PATH}"
mkdir -p "${BUNDLE_ROOT}/bin"

cp "${APP_ROOT}/bin/opsd" "${BUNDLE_ROOT}/bin/opsd"
chmod +x "${BUNDLE_ROOT}/bin/opsd"
cp "${APP_ROOT}/bin/opsd-mcp" "${BUNDLE_ROOT}/bin/opsd-mcp"
chmod +x "${BUNDLE_ROOT}/bin/opsd-mcp"
cp -R "${APP_ROOT}/lib" "${BUNDLE_ROOT}/lib"
cp -R "${APP_ROOT}/composer" "${BUNDLE_ROOT}/composer"
# MCP reads the installed contract, documentation pointers, and shipped examples.
cp -R "${APP_ROOT}/docs" "${BUNDLE_ROOT}/docs"
cp -R "${APP_ROOT}/examples" "${BUNDLE_ROOT}/examples"
cp "${APP_ROOT}/README.md" "${BUNDLE_ROOT}/README.md"
cp "${APP_ROOT}/LICENSE" "${BUNDLE_ROOT}/LICENSE"
cp "${APP_ROOT}/.ruby-version" "${BUNDLE_ROOT}/.ruby-version"
cp -R "${RUBY_PREFIX}" "${BUNDLE_ROOT}/runtime"

# Ruby builds can embed their installation prefix; prepend the copied stdlib and
# native extension paths before Ruby loads rbconfig or any application library.
"${RUBY_BIN}" --disable-gems -rrbconfig -rpathname -e '
  prefix = Pathname(ARGV.fetch(0))
  paths = %w[rubylibdir rubyarchdir].map { |key| Pathname(RbConfig::CONFIG.fetch(key)).relative_path_from(prefix) }
  puts "# Generated runtime lookup paths, relative to the extracted bundle."
  puts %q(RUBYLIB=") + paths.map { |path| "${OPSD_RUBY_RUNTIME_ROOT}/#{path}" }.join(":") + %q(${RUBYLIB:+:${RUBYLIB}}")
  puts "export RUBYLIB"
  puts %q(LD_LIBRARY_PATH="${OPSD_RUBY_RUNTIME_ROOT}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}")
  puts "export LD_LIBRARY_PATH"
' "${RUBY_PREFIX}" > "${BUNDLE_ROOT}/runtime/environment.sh"
"${RUBY_BIN}" "${APP_ROOT}/scripts/release/relocate_ruby_runtime.rb" "${BUNDLE_ROOT}/runtime" "${RUBY_PREFIX}"

cat > "${BUNDLE_ROOT}/release.json" <<EOF
{
  "name": "opsd",
  "version": "${VERSION}",
  "os": "${OS_NAME}",
  "arch": "${ARCH_NAME}",
  "ruby_version": "${RUBY_VERSION}",
  "ruby_runtime": "runtime"
}
EOF

tar -C "${OUTPUT_DIR}" -czf "${ARCHIVE_PATH}" "$(basename "${BUNDLE_ROOT}")"

VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opsd-bundle-XXXXXX")"
cleanup() {
  rm -rf "${VALIDATION_DIR}"
}
trap cleanup EXIT INT TERM

tar -xzf "${ARCHIVE_PATH}" -C "${VALIDATION_DIR}"
"${VALIDATION_DIR}/$(basename "${BUNDLE_ROOT}")/bin/opsd" version >/dev/null
"${VALIDATION_DIR}/$(basename "${BUNDLE_ROOT}")/bin/opsd-mcp" config >/dev/null

# Fail before release upload if the extracted artifact cannot serve actual MCP workflows.
sh "${APP_ROOT}/scripts/ci/run_mcp_bundle_tests.sh" "${ARCHIVE_PATH}" >&2

echo "${ARCHIVE_PATH}"
