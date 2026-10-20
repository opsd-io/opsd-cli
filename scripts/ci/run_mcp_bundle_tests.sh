#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
ARCHIVE="${1:?Usage: run_mcp_bundle_tests.sh <portable-bundle.tar.gz>}"
command -v uv >/dev/null 2>&1 || { echo 'MCP bundle qualification requires uv and Python 3.11.' >&2; exit 1; }

QUALIFICATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opsd MCP bundle.XXXXXX")"
cleanup() { rm -rf "${QUALIFICATION_DIR}"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${QUALIFICATION_DIR}/extracted" "${QUALIFICATION_DIR}/host cwd"
tar -xzf "${ARCHIVE}" -C "${QUALIFICATION_DIR}/extracted"
# Build artifacts have exactly one root; do not accidentally qualify a source checkout.
set -- "${QUALIFICATION_DIR}/extracted"/*
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'Expected one bundle root.' >&2; exit 1; }
BUNDLE_ROOT="$1"
RUBY_BIN="${BUNDLE_ROOT}/runtime/bin/ruby"
[ -x "${RUBY_BIN}" ] || { echo 'Bundled Ruby is missing.' >&2; exit 1; }
export RUBY_BIN
OPSD_RUBY_RUNTIME_ROOT="${BUNDLE_ROOT}/runtime"
. "${OPSD_RUBY_RUNTIME_ROOT}/environment.sh"
export OPSD_MCP_TEST_APP_ROOT="${BUNDLE_ROOT}"

# Verify both the executable and required standard libraries relocate with the artifact.
"${RUBY_BIN}" --disable-gems "${APP_ROOT}/scripts/ci/verify_bundled_ruby.rb" "${BUNDLE_ROOT}"
cd "${QUALIFICATION_DIR}/host cwd"
sh "${APP_ROOT}/scripts/ci/run_mcp_protocol_tests.sh"
# Qualify warmed-cache platform validation with real external tools as well.
sh "${APP_ROOT}/scripts/ci/run_mcp_real_tools_tests.sh"
