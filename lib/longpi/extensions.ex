defmodule Longpi.Extensions do
  @moduledoc """
  Global extension management: the shared `~/.longpi/extensions/` directory
  that every session's host loads. Per-conversation (project) extensions live
  under each workspace's `.longpi/` and are managed from that conversation.
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
  Whether an extension host is needed for this workspace at all: true only
  when some extension entry exists (global or project `*.ts`/`*.js`/`*.mjs`
  file, or a `subdir/index.ts|js`). Sessions skip booting the QuickJS host
  otherwise — the common no-extensions case costs nothing.
  """
  @spec any_for?(String.t()) :: boolean()
  def any_for?(cwd) do
    dirs = [global_dir(), Path.join(cwd, ".longpi/extensions")]
    Enum.any?(dirs, &dir_has_extension?/1)
  end

  # Mirrors the harness's discovery: one level deep — *.ts/*.js/*.mjs files
  # or subdir/index.ts|index.js.
  defp dir_has_extension?(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            String.ends_with?(entry, [".ts", ".js", ".mjs"]) -> File.regular?(path)
            File.dir?(path) -> File.regular?(Path.join(path, "index.ts")) or
                                 File.regular?(Path.join(path, "index.js"))
            true -> false
          end
        end)

      {:error, _} ->
        false
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
