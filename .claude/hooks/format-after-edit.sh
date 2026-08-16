#!/usr/bin/env bash
# PostToolUse hook (matcher: Edit|Write).
#
# Fires after every file edit/write. Runs the formatter appropriate to the
# touched file's extension so builder agents never have to think about
# style -- and so "did you run the formatter" is never a review comment.
# Always exits 0: a missing/failing formatter must never block the agent.
set -uo pipefail

INPUT="$(cat)"

FILE=""
if command -v python3 >/dev/null 2>&1; then
  FILE="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("file_path", ""))
except Exception:
    pass
' 2>/dev/null || true)"
fi

[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

try_run() {
  local bin="$1"
  shift
  command -v "$bin" >/dev/null 2>&1 && "$bin" "$@" >/dev/null 2>&1
  return 0
}

case "$FILE" in
  *.go)
    try_run gofmt -w "$FILE"
    ;;
  *.py)
    try_run black -q "$FILE" || try_run ruff format "$FILE"
    ;;
  *.rs)
    try_run rustfmt "$FILE"
    ;;
  *.sh|*.bash)
    try_run shfmt -w "$FILE"
    ;;
  *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx|*.json|*.md|*.mdx|*.css|*.scss|*.html|*.yaml|*.yml)
    if [ -f "${CLAUDE_PROJECT_DIR:-.}/node_modules/.bin/prettier" ]; then
      "${CLAUDE_PROJECT_DIR:-.}/node_modules/.bin/prettier" --write "$FILE" >/dev/null 2>&1 || true
    else
      try_run prettier --write "$FILE"
    fi
    ;;
esac

exit 0
