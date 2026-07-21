import Config

# Point the OpenAI provider at an OpenAI-compatible gateway
# (e.g. https://openrouter.listenai.com/v1). Key comes from OPENAI_API_KEY.
# NOTE: production LLM/provider config lives in the database (the Provider
# resource, managed from the web UI), not here — these env vars are only a dev
# convenience.
if openai_base_url = System.get_env("LONGPI_OPENAI_BASE_URL") do
  config :req_llm, :openai, base_url: openai_base_url
end

if model = System.get_env("LONGPI_LLM_MODEL") do
  config :longpi, llm_model: model
end

# Optional auth (any env, so a dev preview can flip it on). Off by default —
# see Longpi.Auth. Prod re-derives these below, adding config.jsonc's "auth".
if System.get_env("LONGPI_AUTH_ENABLED") in ~w(true 1) do
  config :longpi, auth_enabled: true
end

if users = System.get_env("LONGPI_USERS") do
  config :longpi, bootstrap_users: users
end

if System.get_env("LONGPI_USERS_RESET") in ~w(true 1) do
  config :longpi, bootstrap_users_reset: true
end

if embed_token = System.get_env("LONGPI_EMBED_TOKEN") do
  config :longpi, embed_token: embed_token
end

# config/runtime.exs runs for all environments, including inside a release.
# Production is configured from ~/.config/longpi/config.jsonc (Longpi.RuntimeConfig),
# NOT environment variables — see docs/deploy.md. dev/test keep their in-repo
# config and must never pick up a machine's personal server config.

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :longpi, LongpiWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/longpi_web/router\.ex$"E,
        ~r"lib/longpi_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  alias Longpi.RuntimeConfig, as: RC

  cfg = RC.load()

  # The data dir holds secrets.json (0600) and, by default, the SQLite db.
  data_dir = RC.data_dir(cfg)
  File.mkdir_p!(data_dir)

  # Serve the endpoint only when asked. `bin/longpi start` with "server": true
  # in config.jsonc runs the web server; `bin/longpi eval/remote` do not.
  if System.get_env("PHX_SERVER") || cfg["server"] == true do
    config :longpi, LongpiWeb.Endpoint, server: true
  end

  database_path =
    RC.get(cfg, ["LONGPI_DATABASE_PATH", "DATABASE_PATH"], "databasePath") ||
      Path.join(data_dir, "longpi.db")

  config :longpi, Longpi.Repo,
    database: database_path,
    pool_size: RC.get_int(cfg, ["LONGPI_POOL_SIZE", "POOL_SIZE"], "poolSize", 10)

  # Cookie/session signing. Generated on first boot into <data_dir>/secrets.json.
  secret_key_base = RC.secret(cfg, ["LONGPI_SECRET_KEY_BASE", "SECRET_KEY_BASE"], "secretKeyBase")

  config :longpi,
    token_signing_secret:
      RC.secret(
        cfg,
        ["LONGPI_TOKEN_SIGNING_SECRET", "TOKEN_SIGNING_SECRET"],
        "tokenSigningSecret"
      )

  host = RC.get(cfg, ["LONGPI_HOST", "PHX_HOST"], "host", "localhost")
  scheme = RC.get(cfg, ["LONGPI_SCHEME", "PHX_SCHEME"], "scheme", "http")
  port = RC.get_int(cfg, ["LONGPI_PORT", "PORT"], "port", 4000)

  url_port =
    RC.get_int(cfg, ["LONGPI_URL_PORT", "PHX_URL_PORT"], "urlPort", nil) ||
      if(scheme == "https", do: 443, else: port)

  # Origin check breaks WebSockets when reached by IP / alternate host (common
  # for a self-hosted server on a LAN), so it is opt-in for reverse-proxied setups.
  check_origin =
    RC.get_bool(cfg, ["LONGPI_CHECK_ORIGIN", "PHX_CHECK_ORIGIN"], "checkOrigin", false)

  # Loopback-only by default — exposing the server is opt-in via
  # "listenIp": "0.0.0.0" (bind all IPv4) in config.jsonc.
  listen_ip =
    with raw = RC.get(cfg, "LONGPI_LISTEN_IP", "listenIp", "127.0.0.1"),
         {:ok, ip} <- raw |> String.to_charlist() |> :inet.parse_address() do
      ip
    else
      _ -> raise "invalid listenIp (expected an IPv4/IPv6 address)"
    end

  config :longpi, LongpiWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [ip: listen_ip, port: port],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  config :longpi, :dns_cluster_query, RC.get(cfg, "DNS_CLUSTER_QUERY", "dnsClusterQuery")

  # Self-updater. The install root is the segment of RELEASE_ROOT
  # (`.../longpi/versions/<tag>`) before `/versions/`; a config.jsonc
  # `releaseRoot` overrides it. Absent (a bare `mix` run) leaves it nil, which
  # disables in-app upgrades.
  release_root =
    RC.get(cfg, "LONGPI_RELEASE_ROOT", "releaseRoot") ||
      case System.get_env("RELEASE_ROOT") do
        root when is_binary(root) ->
          case String.split(root, "/versions/") do
            [base, _tag] -> base
            _ -> nil
          end

        _ ->
          nil
      end

  config :longpi, release_root: release_root
  config :longpi, update_repo: RC.get(cfg, "LONGPI_UPDATE_REPO", "updateRepo", "mjason/longpi")
  config :longpi, service_name: RC.get(cfg, "LONGPI_SERVICE", "serviceName", "longpi")

  # Optional: a GitHub token lifts the update check's rate limit from 60/hour to
  # 5000/hour. Unset is fine — the updater caches results and revalidates with an
  # ETag, so unauthenticated checks rarely hit the limit.
  config :longpi, github_token: RC.get(cfg, ["LONGPI_GITHUB_TOKEN", "GITHUB_TOKEN"], "githubToken")

  # Optional username/password auth (dala's model): off by default; accounts
  # are seeded at boot from "users" ("email:password,..." — remove after first
  # boot) rather than self-registration.
  auth_cfg = cfg["auth"] || %{}

  config :longpi,
    auth_enabled:
      System.get_env("LONGPI_AUTH_ENABLED", "") in ~w(true 1) or auth_cfg["enabled"] == true,
    bootstrap_users: System.get_env("LONGPI_USERS") || auth_cfg["users"] || "",
    # Where the bootstrap credentials came from: the seeder warns when a
    # password is left sitting in config.jsonc (env vars don't persist).
    bootstrap_users_source:
      (cond do
         System.get_env("LONGPI_USERS") not in [nil, ""] -> :env
         auth_cfg["users"] not in [nil, ""] -> :config
         true -> :none
       end),
    bootstrap_users_reset:
      System.get_env("LONGPI_USERS_RESET") in ~w(true 1) or auth_cfg["usersReset"] == true,
    # Static token a host app (dala) uses to iframe /embed without a browser
    # sign-in. Auto-generated into <data_dir>/secrets.json on first boot;
    # override via auth.embedToken / LONGPI_EMBED_TOKEN.
    embed_token:
      System.get_env("LONGPI_EMBED_TOKEN") || auth_cfg["embedToken"] ||
        RC.secret(cfg, [], "embedToken")
end
