defmodule Longpi.Extensions do
  @moduledoc """
  Global extension management: the shared `~/.longpi/extensions/` directory and
  `~/.longpi/packages.json` that every session's host loads. Per-conversation
  (project) extensions live under each workspace's `.longpi/` and are managed
  from that conversation.
  """

  @doc "The global extensions directory (`~/.longpi/extensions`)."
  def global_dir, do: Path.expand("~/.longpi/extensions")

  @doc "The global packages config file (`~/.longpi/packages.json`)."
  def global_packages_path, do: Path.expand("~/.longpi/packages.json")

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
end
