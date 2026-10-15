#!/usr/bin/env bash
#
# Apply the dsh-mcp-client session-recovery patch to an installed DSH.
#
# Idempotent: re-running on an already-patched file is a no-op. Always backs up
# the original next to the repo's backup dir before touching anything.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$REPO_DIR/patches/dsh-mcp-client-session-recovery.patch"
BACKUP_ROOT="${DSH_PATCH_BACKUP_DIR:-$HOME/.dsh/backups/dsh-mcp-client-pre-onerror-fix}"

# sha256 of the pristine upstream file, and of the patched result.
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

if [ -z "$TARGET" ]; then
  echo "error: could not find the installed @deepseek-ai/dsh-mcp-client/lib/index.js" >&2
  echo "       set DSH_MCP_CLIENT_LIB=/path/to/lib/index.js and re-run" >&2
  echo "       (find it with: npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/lib/index.js" >&2
  exit 1
fi

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# `node --check` parses with the nearest package.json's module type. The target
# lives inside a "type": "module" package, but a copy elsewhere would be parsed
# as CommonJS, so check through a .mjs copy to stay independent of location.
check_syntax() {
  local f="$1" d
  d="$(mktemp -d)"
  cp "$f" "$d/check.mjs"
  node --check "$d/check.mjs"
  rm -rf "$d"
}

current="$(sha_of "$TARGET")"
echo "target : $TARGET"
echo "sha256 : $current"

if [ "$current" = "$PATCHED_SHA" ]; then
  echo "already patched — nothing to do."
  exit 0
fi

if [ "$current" != "$BASE_SHA" ]; then
  echo
  echo "warning: this file does not match the upstream revision this patch was cut against."
  echo "         expected $BASE_SHA"
  echo "         A newer DSH may have changed the surrounding code, or fixed this bug itself."
  echo "         Inspect patches/dsh-mcp-client-session-recovery.patch before continuing."
  printf "continue anyway? [y/N] "
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "aborted."; exit 1 ;; esac
fi

# Back up before mutating.
mkdir -p "$BACKUP_ROOT"
stamp="$(date +%Y%m%d-%H%M%S)"
backup="$BACKUP_ROOT/index.$stamp.js"
cp -p "$TARGET" "$backup"
echo "backup : $backup"

# Apply inside a scratch git repo so a partial application can never land.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/lib"
cp "$TARGET" "$scratch/lib/index.js"
( cd "$scratch" && git init -q . && git add -A \
  && git -c user.email=patch@local -c user.name=patch commit -qm base \
  && git apply "$PATCH_FILE" )

result="$(sha_of "$scratch/lib/index.js")"
if [ "$result" != "$PATCHED_SHA" ]; then
  echo "error: patched file has an unexpected digest ($result)." >&2
  echo "       refusing to install; nothing was changed." >&2
  exit 1
fi

cp "$scratch/lib/index.js" "$TARGET"
check_syntax "$TARGET"
echo "applied: ok (syntax verified)"

cat <<'EOF'

Next: restart DSH so the patched plugin is loaded, e.g.

  kill $(lsof -ti tcp:3080 -sTCP:LISTEN); dsh web

Verify it actually works by restarting the MCP server underneath a running DSH
and confirming its tools recover without restarting DSH again.
EOF
