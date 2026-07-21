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

## Upgrading

Build a new tarball, unpack it into a new `versions/<vN>` dir, repoint the
`current` symlink, and `systemctl --user restart longpi`. The data dir
(`secrets.json`, database) is outside the versioned tree, so it is preserved.
