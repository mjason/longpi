#!/usr/bin/env bash
#
# longpi updater — downloads the latest Linux release, switches the `current`
# symlink and restarts the user service. The data dir (secrets, database) lives
# outside the versioned tree, so it is preserved across upgrades. Migrations run
# via the service's ExecStartPre before the new version boots.
#
#   curl -fsSL https://raw.githubusercontent.com/mjason/longpi/main/update.sh | bash
#   ./update.sh [vX.Y.Z]        # specific version (default: latest)
set -euo pipefail

REPO="${LONGPI_REPO:-mjason/longpi}"
ROOT="${LONGPI_HOME:-$HOME/.local/longpi}"
SERVICE_NAME="${LONGPI_SERVICE:-longpi}"

# --- GitHub token (optional) -------------------------------------------------
# A token (env, else the config file's "githubToken") is attached to the GitHub
# API + release-asset requests when present. Anonymous downloads intermittently
# hit 403 (rate limit) or 404 from the release CDN; an authenticated request
# avoids both. With no token, everything falls back to anonymous.
CONFIG_FILE="${LONGPI_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/longpi/config.jsonc}"
gh_token() {
  [ -n "${LONGPI_GITHUB_TOKEN:-}" ] && { printf '%s' "$LONGPI_GITHUB_TOKEN"; return; }
  [ -n "${GITHUB_TOKEN:-}" ] && { printf '%s' "$GITHUB_TOKEN"; return; }
  [ -f "$CONFIG_FILE" ] && sed -n 's/.*"githubToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -1
}
TOKEN="$(gh_token || true)"
AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: token $TOKEN")

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) PLATFORM="linux-x86_64" ;;
  *) die "no prebuilt release for $(uname -s)/$(uname -m) (Linux/x86_64 only for now)" ;;
esac

[ -e "$ROOT/current" ] || die "no existing install at $ROOT — run install.sh first"
CURRENT=$(basename "$(cd "$ROOT/current" && pwd -P)")

TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG=$(curl -fsSL "${AUTH[@]}" "https://api.github.com/repos/$REPO/releases?per_page=15" |
    grep '"tag_name"' | cut -d'"' -f4 | grep -m1 '^v[0-9]') || true
  [ -n "$TAG" ] || die "could not resolve the latest release"
fi

if [ "$TAG" = "$CURRENT" ]; then
  say "already on $TAG — nothing to do"
  exit 0
fi

ASSET="longpi-$TAG-$PLATFORM.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
DEST="$ROOT/versions/$TAG"

if [ ! -x "$DEST/bin/longpi" ]; then
  say "downloading $ASSET"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  curl -fSL "${AUTH[@]}" --progress-bar -o "$TMP/$ASSET" "$URL"
  if curl -fsSL "${AUTH[@]}" -o "$TMP/$ASSET.sha256" "$URL.sha256" 2>/dev/null; then
    (cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null) || die "checksum mismatch"
    say "checksum ok"
  fi
  mkdir -p "$DEST"
  tar -xzf "$TMP/$ASSET" -C "$DEST"
fi

say "switching $CURRENT -> $TAG"
ln -sfn "$DEST" "$ROOT/current"

# ExecStartPre migrates the database before the new version boots.
systemctl --user restart "$SERVICE_NAME"

ls -1dt "$ROOT"/versions/* 2>/dev/null | tail -n +4 | while read -r old; do
  [ "$old" = "$DEST" ] && continue
  say "pruning $(basename "$old")"
  rm -rf "$old"
done

say "updated to $TAG"
