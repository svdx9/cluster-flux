#!/usr/bin/env bash
# Stop hook.
#
# Fires when Claude tries to end its turn. Runs whatever verification the
# project defines (typecheck/lint/test) and, if anything fails, blocks the
# stop (exit 2) so Claude sees the failure and keeps working instead of
# handing back broken code. `stop_hook_active` guards against looping
# forever if a check can never pass.
set -uo pipefail

INPUT="$(cat)"

STOP_HOOK_ACTIVE="false"
if command -v python3 >/dev/null 2>&1; then
  STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print("true" if data.get("stop_hook_active") else "false")
except Exception:
    print("false")
' 2>/dev/null || echo false)"
fi

# We already asked once for this stop; do not loop forever.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

FAILURES=""
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

run_check() {
  local label="$1"
  shift
  if ! "$@" >"$TMP" 2>&1; then
    FAILURES="${FAILURES}
--- ${label} failed ---
$(tail -n 40 "$TMP")
"
  fi
}

has_npm_script() {
  command -v node >/dev/null 2>&1 || return 1
  node -e "
    const s = (require('./package.json').scripts) || {};
    process.exit(s['$1'] ? 0 : 1);
  " 2>/dev/null
}

if [ -f package.json ]; then
  has_npm_script typecheck && run_check "npm run typecheck" npm run typecheck --silent
  has_npm_script lint && run_check "npm run lint" npm run lint --silent
  has_npm_script test && run_check "npm test" npm test --silent
elif [ -f Makefile ]; then
  grep -Eq '^(check|verify)[[:space:]]*:' Makefile && run_check "make check" make check
  grep -Eq '^lint[[:space:]]*:' Makefile && run_check "make lint" make lint
  grep -Eq '^test[[:space:]]*:' Makefile && run_check "make test" make test
elif [ -f go.mod ]; then
  command -v go >/dev/null 2>&1 && run_check "go vet" go vet ./...
  command -v go >/dev/null 2>&1 && run_check "go test" go test ./...
elif [ -f pyproject.toml ] || [ -f setup.py ]; then
  command -v ruff >/dev/null 2>&1 && run_check "ruff check" ruff check .
  command -v pytest >/dev/null 2>&1 && run_check "pytest" pytest -q
fi

if [ -n "$FAILURES" ]; then
  {
    echo "Cannot stop yet: verification checks are failing."
    echo "$FAILURES"
    echo "Fix these, then finish."
  } >&2
  exit 2
fi

exit 0
