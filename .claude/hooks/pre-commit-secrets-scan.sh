#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash).
#
# Fires before every Bash tool call. When the command looks like `git commit`,
# it inspects the staged files for secret-shaped filenames and blocks the
# commit (exit 2) before it ever reaches git. This is the last line of
# defense before .env/.pem/secrets.json-style files leave the sandbox --
# it does not replace SOPS encryption, it backstops it.
set -uo pipefail

INPUT="$(cat)"

COMMAND=""
if command -v python3 >/dev/null 2>&1; then
  COMMAND="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)"
fi
# Fall back to scanning the raw hook payload if we could not parse JSON
# (e.g. python3 unavailable) -- err on the side of running the scan.
[ -z "$COMMAND" ] && COMMAND="$INPUT"

if ! printf '%s' "$COMMAND" | grep -Eq 'git[[:space:]]+commit'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

STAGED="$(git diff --cached --name-only 2>/dev/null || true)"
[ -z "$STAGED" ] && exit 0

# Filenames that must never be committed in the clear. *.sops.yaml is
# intentionally excluded -- that pattern is this repo's encrypted-secret
# convention (see AGENTS.md).
BLOCKED_PATTERN='(^|/)\.env(\..+)?$|\.pem$|(^|/)secrets\.json$|\.p12$|\.pfx$|(^|/)id_rsa$|(^|/)id_ed25519$|(^|/)\.npmrc$'

MATCHES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if printf '%s' "$f" | grep -Eq "$BLOCKED_PATTERN"; then
    MATCHES="${MATCHES}${f}"$'\n'
  fi
done <<<"$STAGED"

if [ -n "$MATCHES" ]; then
  {
    echo "BLOCKED: staged files look like secrets and must not be committed in the clear:"
    printf '%s' "$MATCHES" | sed 's/^/  - /'
    echo
    echo "Fix by doing one of:"
    echo "  - unstage them:      git restore --staged <file>"
    echo "  - encrypt them:      sops --encrypt --in-place <file>.sops.yaml   (see AGENTS.md)"
    echo "  - gitignore them if they are local-only artifacts"
  } >&2
  exit 2
fi

exit 0
