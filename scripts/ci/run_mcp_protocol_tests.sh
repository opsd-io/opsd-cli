#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Pass the activated Ruby explicitly because GUI/SDK subprocess environments differ.
RUBY_BIN="${RUBY_BIN:-$(ruby -rrbconfig -e 'print RbConfig.ruby')}"
export RUBY_BIN

# SDK and validator versions are locked separately from the dependency-free CLI runtime.
exec uv run --project "${APP_ROOT}/test/mcp" --locked --python 3.11 \
  python -m unittest discover -s "${APP_ROOT}/test/mcp" -p '*_test.py' -v
