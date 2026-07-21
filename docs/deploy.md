# Deploying longpi (Linux)

longpi ships as a self-contained Elixir release: a single tree with the BEAM
runtime, the Rust `shim`/`search` binaries, and the built web assets. It runs
with **no Elixir or Rust toolchain on the target**.

Configuration is a **file, not environment variables**: the release reads
`~/.config/longpi/config.jsonc` at boot (`Longpi.RuntimeConfig`). Secrets are
generated automatically on first boot — you never set `SECRET_KEY_BASE` etc.

> The target host still needs **`bun`** on `PATH` for the extension host, and
> the runtime working directory the agent operates in needs whatever tools the
> agent will use.

## 1. Build (on a Linux x86_64 box with the toolchain)

Requires `mix` (Elixir/OTP), `cargo` (Rust), and `npm` (Node).

```sh
scripts/build-linux.sh
```

This fetches prod deps, builds the Rust binaries and minified/digested assets,
assembles the release, and writes:

```
dist/longpi-v<version>-linux-<arch>.tar.gz
dist/longpi-v<version>-linux-<arch>.tar.gz.sha256
```

The tarball unpacks to a release root (`bin/`, `lib/`, `releases/`, `erts-*`).

> The release bundles the build machine's ERTS, so build on a glibc/arch
> compatible with the target (e.g. build and run on the same distro family).

## 2. Install on the target

```sh
# unpack into a versioned location
mkdir -p ~/.local/longpi/versions/v<version>
tar -xzf longpi-v<version>-linux-x86_64.tar.gz -C ~/.local/longpi/versions/v<version>
ln -sfn ~/.local/longpi/versions/v<version> ~/.local/longpi/current
```

## 3. Configure

```sh
mkdir -p ~/.config/longpi
cp priv/config.sample.jsonc ~/.config/longpi/config.jsonc   # from the source tree
chmod 600 ~/.config/longpi/config.jsonc
$EDITOR ~/.config/longpi/config.jsonc
```

Every key is documented in `config.sample.jsonc`. At minimum set `server: true`
and a `port`. Secrets and the database are created under `dataDir` (default
`~/.local/share/longpi`) on first boot.

## 4. Run

```sh
~/.local/longpi/current/bin/longpi start          # foreground
# or run migrations explicitly first (also runs automatically at boot):
~/.local/longpi/current/bin/longpi eval "Longpi.Release.migrate()"
```

Open `http://<host>:<port>`.

## 5. Run as a service (systemd user unit)

`~/.config/systemd/user/longpi.service`:

```ini
[Unit]
Description=longpi
After=network-online.target

[Service]
Type=exec
ExecStartPre=%h/.local/longpi/current/bin/longpi eval "Longpi.Release.migrate()"
ExecStart=%h/.local/longpi/current/bin/longpi start
ExecStop=%h/.local/longpi/current/bin/longpi stop
Restart=on-failure
# BEAM shutdown should not take down child PTYs abruptly during a restart
KillMode=process

[Install]
WantedBy=default.target
```

```sh
loginctl enable-linger "$USER"          # keep the unit running without a login session
systemctl --user daemon-reload
systemctl --user enable --now longpi
systemctl --user status longpi
```

## TLS / reverse proxy

longpi serves plain HTTP (loopback by default). For public HTTPS, terminate TLS
in a reverse proxy (Caddy/nginx) in front and set in `config.jsonc`:

```jsonc
"scheme": "https",
"checkOrigin": true,
"host": "your.domain"
```

## Install / upgrade with the scripts

`install.sh` and `update.sh` automate steps 2–5 against the published GitHub
releases (built by `.github/workflows/release.yml` on a `v*` tag).

```sh
# first install (latest release): downloads, writes config.jsonc, installs the
# systemd unit, starts the service
curl -fsSL https://raw.githubusercontent.com/mjason/longpi/main/install.sh | bash

# upgrade to the latest release: downloads, repoints `current`, restarts,
# prunes to the newest 3 versions
curl -fsSL https://raw.githubusercontent.com/mjason/longpi/main/update.sh | bash

# or pin a version
./update.sh v0.1.1
```

Both keep the data dir (`secrets.json`, database) — it lives outside the
versioned tree, so upgrades preserve it. `update.sh` swaps the `current` symlink
and restarts; the unit's `ExecStartPre` migrates the database before the new
version boots. Override with `LONGPI_PORT`, `LONGPI_SERVICE`, `LONGPI_HOME`,
`LONGPI_DATA_DIR` env vars (installer only — they do not affect the running
service, which reads config.jsonc).
