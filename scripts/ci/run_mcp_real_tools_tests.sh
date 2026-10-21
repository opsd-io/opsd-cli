#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)"
RUBY_BIN="${RUBY_BIN:-$(ruby -rrbconfig -e 'print RbConfig.ruby')}"
export RUBY_BIN
exec uv run --project "${APP_ROOT}/test/mcp" --locked --python 3.11 \
  python "${APP_ROOT}/test/mcp/qualification/real_workflow.py"
