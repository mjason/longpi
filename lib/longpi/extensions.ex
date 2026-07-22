defmodule Longpi.Extensions do
  @moduledoc """
  Global extension management: the shared `~/.longpi/extensions/` directory and
  `~/.longpi/packages.json` that every session's host loads. Per-conversation
  (project) extensions live under each workspace's `.longpi/` and are managed
  from that conversation.
  """

  @doc """
  The global extensions directory (`~/.longpi/extensions`).

  Overridable via `config :longpi, :global_extensions_dir` so tests don't read
  the developer's real global extensions.
  """
  def global_dir do
    Application.get_env(:longpi, :global_extensions_dir) || Path.expand("~/.longpi/extensions")
  end

  @doc """
  The global packages config file (`~/.longpi/packages.json`). Overridable via
  `config :longpi, :global_packages_path` so tests don't read the real one.
  """
  def global_packages_path do
    Application.get_env(:longpi, :global_packages_path) ||
      Path.expand("~/.longpi/packages.json")
  end

  @doc """
  Whether a Bun extension host is needed for this workspace at all: true only
  when some extension entry exists (global or project `*.ts`/`*.js` file, a
  `subdir/index.ts|js`, or a configured packages.json). Sessions skip spawning
  the Bun process entirely otherwise — the common no-extensions case costs
  nothing.
  """
  @spec any_for?(String.t()) :: boolean()
  def any_for?(cwd) do
    dirs = [global_dir(), Path.join(cwd, ".longpi/extensions")]

    packages = [
      global_packages_path(),
      Path.join(cwd, ".longpi/packages.json")
    ]

    Enum.any?(dirs, &dir_has_extension?/1) or Enum.any?(packages, &packages_configured?/1)
  end

  # Mirrors host.ts discovery: one level deep — *.ts/*.js files or
  # subdir/index.ts|index.js.
  defp dir_has_extension?(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            String.ends_with?(entry, [".ts", ".js"]) -> File.regular?(path)
            File.dir?(path) -> File.regular?(Path.join(path, "index.ts")) or
                                 File.regular?(Path.join(path, "index.js"))
            true -> false
          end
        end)

      {:error, _} ->
        false
    end
  end

  defp packages_configured?(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"packages" => packages}} when is_map(packages) and map_size(packages) > 0 <-
           Jason.decode(body) do
      true
    else
      _ -> false
    end
  end

  @doc "Extension files/dirs in the global directory, as `[%{name, dir?}]`."
  @spec list_global() :: [map()]
  def list_global do
    case File.ls(global_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn name ->
          %{name: name, dir?: File.dir?(Path.join(global_dir(), name))}
        end)

      {:error, _} ->
        []
    end
  end

  @doc "The global packages map (`%{name => spec}`); empty when unset/invalid."
  @spec read_packages() :: %{optional(String.t()) => String.t()}
  def read_packages do
    with {:ok, body} <- File.read(global_packages_path()),
         {:ok, %{"packages" => packages}} when is_map(packages) <- Jason.decode(body) do
      packages
    else
      _ -> %{}
    end
  end

  @doc "Writes the global packages map back to `~/.longpi/packages.json`."
  @spec write_packages(map()) :: :ok | {:error, term()}
  def write_packages(packages) when is_map(packages) do
    File.mkdir_p!(Path.dirname(global_packages_path()))
    File.write(global_packages_path(), Jason.encode!(%{packages: packages}, pretty: true))
  end

  @doc """
  All DB-stored extension secrets as a `%{name => value}` map, injected into
  the extension host as environment variables. Server-side only — the value is
  sensitive and never crosses the typescript RPC boundary.
  """
  @spec secret_env() :: %{optional(String.t()) => String.t()}
  def secret_env do
    case Longpi.Agent.list_extension_secrets() do
      {:ok, secrets} -> Map.new(secrets, &{&1.name, &1.value})
      _ -> %{}
    end
  end

  @doc "The names of stored extension secrets (no values), for the admin UI."
  @spec list_secret_names() :: [String.t()]
  def list_secret_names do
    case Longpi.Agent.list_extension_secrets() do
      {:ok, secrets} -> secrets |> Enum.map(& &1.name) |> Enum.sort()
      _ -> []
    end
  end

  @doc "Stores (upserts) a secret by name."
  @spec put_secret(String.t(), String.t()) :: :ok | {:error, term()}
  def put_secret(name, value) when is_binary(name) and is_binary(value) do
    case Longpi.Agent.put_extension_secret(%{name: name, value: value}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes a secret by name (no-op when it doesn't exist)."
  @spec delete_secret(String.t()) :: :ok
  def delete_secret(name) when is_binary(name) do
    case Longpi.Agent.list_extension_secrets() do
      {:ok, secrets} ->
        Enum.each(secrets, fn s ->
          if s.name == name, do: Longpi.Agent.destroy_extension_secret(s)
        end)

      _ ->
        :ok
    end

    :ok
  end
end
