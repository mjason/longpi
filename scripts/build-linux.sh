#!/usr/bin/env bash
#
# Reproducible local production build for Linux.
#
# Produces  dist/longpi-v<version>-linux-<arch>.tar.gz  (+ .sha256): a
# self-contained release (bundled ERTS + Rust shim/search binaries + web
# assets) that runs with no Elixir/Rust toolchain on the target.
#
# Configuration is NOT baked in: the release reads ~/.config/longpi/config.jsonc
# at runtime (Longpi.RuntimeConfig). No environment variables are needed to
# deploy — see docs/deploy.md.
#
# Extensions run in an embedded QuickJS (rquickjs) host in the release — no
# Bun or other JS runtime is needed on the target.
#
# Usage:  scripts/build-linux.sh
set -euo pipefail

cd "$(dirname "$0")/.."
export MIX_ENV=prod

# --- toolchain preflight -----------------------------------------------------
missing=0
for bin in mix cargo npm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "!! missing required tool: $bin" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || { echo "install the tools above and re-run." >&2; exit 1; }

VERSION="$(sed -n 's/^ *version: *"\([^"]*\)".*/\1/p' mix.exs | head -1)"
ARCH="$(uname -m)"
OUT="longpi-v${VERSION}-linux-${ARCH}.tar.gz"

echo "==> longpi v${VERSION}  (linux/${ARCH}, MIX_ENV=prod)"

echo "==> fetching prod deps"
mix deps.get --only prod

echo "==> installing frontend deps (assets/)"
npm install --prefix assets

echo "==> compiling"
mix compile

echo "==> building Rust binaries (shim + search)"
mix shim.build
mix search.build

echo "==> building web assets (minified + digested)"
mix tailwind.install --if-missing
mix esbuild.install --if-missing
mix assets.deploy

echo "==> assembling release"
mix release --overwrite

echo "==> packaging dist/${OUT}"
mkdir -p dist
tar -C _build/prod/rel/longpi -czf "dist/${OUT}" .
( cd dist && sha256sum "${OUT}" > "${OUT}.sha256" )

echo
echo "==> done."
ls -lh "dist/${OUT}" "dist/${OUT}.sha256"
echo
echo "Deploy: unpack into a versioned dir, write ~/.config/longpi/config.jsonc"
echo "(see priv/config.sample.jsonc), then run bin/longpi start. See docs/deploy.md."
