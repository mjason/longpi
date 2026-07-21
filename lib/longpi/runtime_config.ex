defmodule Longpi.RuntimeConfig do
  @moduledoc """
  File-first production configuration for longpi.

  Deployment is configured through `~/.config/longpi/config.jsonc` (XDG), never
  environment variables. `config/runtime.exs` reads every prod setting from here.

  Env vars are consulted **only** when no config file exists yet — a dev
  convenience and a legacy fallback for older env-based installs. Once the file
  is present it is the sole authority.

  Secrets (`secretKeyBase`, `tokenSigningSecret`) are **never** stored in the
  config file: they are generated on first boot and persisted with 0600
  permissions at `<data_dir>/secrets.json`.
  """

  @doc "Loads and parses the config file, or `%{}` when absent/unreadable (defaults win)."
  @spec load() :: map()
  def load do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, %{} = map} <- raw |> Longpi.Jsonc.strip() |> Jason.decode() do
      map
    else
      _ -> %{}
    end
  end

  @doc "Resolved path to the config file (`$LONGPI_CONFIG` overrides the XDG default)."
  def config_path do
    System.get_env("LONGPI_CONFIG") || Path.join([config_home(), "longpi", "config.jsonc"])
  end

  @doc """
  Reads a value: config-file key first (the authority), else env vars (only when
  no file exists), else the default. `env_names` is one name or a list tried in
  order (`LONGPI_`-prefixed names should come before bare legacy names).
  """
  def get(cfg, env_names, file_key, default \\ nil) do
    from_file = Map.get(cfg, file_key)
    from_env = if env_enabled?(cfg), do: env_first(List.wrap(env_names)), else: nil

    cond do
      from_file != nil -> from_file
      from_env != nil -> from_env
      true -> default
    end
  end

  @doc "Like `get/4`, coerced to a boolean (accepts `true`/`\"true\"`/`\"1\"`)."
  def get_bool(cfg, env_names, file_key, default \\ false) do
    case get(cfg, env_names, file_key) do
      nil -> default
      true -> true
      false -> false
      v when is_binary(v) -> v in ~w(true 1)
      _ -> default
    end
  end

  @doc "Like `get/4`, coerced to a positive integer; raises on non-integer garbage."
  def get_int(cfg, env_names, file_key, default) do
    case get(cfg, env_names, file_key) do
      nil ->
        default

      v when is_integer(v) ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> raise "config #{file_key}: expected an integer, got #{inspect(v)}"
        end

      other ->
        raise "config #{file_key}: expected an integer, got #{inspect(other)}"
    end
  end

  @doc """
  Data directory (secrets.json, and the default DB location). From `dataDir` /
  `LONGPI_DATA_DIR`, else `$XDG_DATA_HOME/longpi`, else `~/.local/share/longpi`.
  """
  def data_dir(cfg) do
    dir =
      get(cfg, "LONGPI_DATA_DIR", "dataDir") ||
        Path.join(data_home(), "longpi")

    Path.expand(dir)
  end

  @doc """
  Resolves a secret: env (legacy) first, else `<data_dir>/secrets.json`; when
  still absent, generates a fresh one and persists it (0600). Never reads/writes
  the config file. `file_key` is the JSON key inside secrets.json.
  """
  def secret(cfg, env_names, file_key) do
    from_env = if env_enabled?(cfg), do: env_first(List.wrap(env_names)), else: nil

    from_env || read_or_create_secret(data_dir(cfg), file_key)
  end

  @doc "Base config directory: `$XDG_CONFIG_HOME` or `~/.config`."
  def config_home, do: System.get_env("XDG_CONFIG_HOME") || Path.join(home(), ".config")

  defp data_home, do: System.get_env("XDG_DATA_HOME") || Path.join([home(), ".local", "share"])

  defp home, do: System.get_env("HOME") || System.user_home!()

  # Env vars only apply when there is no config file at all.
  defp env_enabled?(cfg), do: map_size(cfg) == 0

  defp env_first(names), do: Enum.find_value(names, fn n -> System.get_env(n) end)

  defp read_or_create_secret(data_dir, key) do
    path = Path.join(data_dir, "secrets.json")
    secrets = read_secrets(path)

    case Map.get(secrets, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        value = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
        write_secrets(path, Map.put(secrets, key, value))
        value
    end
  end

  defp read_secrets(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(raw) do
      map
    else
      _ -> %{}
    end
  end

  defp write_secrets(path, secrets) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(secrets, pretty: true))
    File.chmod!(path, 0o600)
  end
end
