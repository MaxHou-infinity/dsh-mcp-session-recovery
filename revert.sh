#!/usr/bin/env bash
#
# Restore the pristine @deepseek-ai/dsh-mcp-client/lib/index.js from the newest
# backup taken by apply.sh.

set -euo pipefail

BACKUP_ROOT="${DSH_PATCH_BACKUP_DIR:-$HOME/.dsh/backups/dsh-mcp-client-pre-onerror-fix}"
BASE_SHA="758d8fc473b700b5d351158d06ce9f9e92c16e8b25497b08bb7bd2122a87f5dd"
PATCHED_SHA="384be38d4f27804c101f3157150805b2185bf404be72532a0fdbc165e5000816"

candidates=(
  "${DSH_MCP_CLIENT_LIB:-}"
  "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js"
  "/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js"
  "$HOME/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js"
  "$HOME/.local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js"
)

TARGET=""
for c in "${candidates[@]}"; do
  [ -n "$c" ] && [ -f "$c" ] && { TARGET="$c"; break; }
done
[ -n "$TARGET" ] || { echo "error: installed mcp-client not found; set DSH_MCP_CLIENT_LIB" >&2; exit 1; }

if [ ! -d "$BACKUP_ROOT" ]; then
  echo "error: no backups found at $BACKUP_ROOT" >&2
  echo "       (if a newer DSH was installed, simply reinstalling DSH also reverts this)" >&2
  exit 1
fi

# Newest backup first.
backup="$(ls -1t "$BACKUP_ROOT"/index.*.js 2>/dev/null | head -1 || true)"
[ -n "$backup" ] || { echo "error: no backup files in $BACKUP_ROOT" >&2; exit 1; }

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Parse through a .mjs copy: `node --check` otherwise uses the nearest
# package.json's module type, which makes the result location-dependent.
check_syntax() {
  local f="$1" d
  d="$(mktemp -d)"
  cp "$f" "$d/check.mjs"
  node --check "$d/check.mjs"
  rm -rf "$d"
}

echo "target : $TARGET"
echo "restore: $backup"
echo "backup sha256: $(sha_of "$backup")"

case "$(sha_of "$backup")" in
  "$BASE_SHA") ;;
  "$PATCHED_SHA") echo "error: that backup is itself the patched file; refusing to restore it." >&2; exit 1 ;;
  *) echo "warning: backup digest is neither the known base nor the known patched revision." >&2 ;;
esac

cp -p "$backup" "$TARGET"
check_syntax "$TARGET"
echo "restored: ok (syntax verified)"

if [ "$(sha_of "$TARGET")" = "$PATCHED_SHA" ]; then
  echo "error: restore did not take effect" >&2
  exit 1
fi

echo
echo "Restart DSH for the change to take effect."
