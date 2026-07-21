defmodule Longpi.Updater.Source do
  @moduledoc "Boundary for fetching release metadata, so it can be stubbed in tests."
  @callback latest_stable() :: {:ok, map()} | {:error, term()}
end

defmodule Longpi.Updater.GitHub do
  @moduledoc """
  Default `Longpi.Updater.Source`: the newest stable release from the GitHub
  releases API. `/releases/latest` can lag or point at a draft, so we list
  recent releases and pick the newest stable `vX.Y.Z` one.
  """
  @behaviour Longpi.Updater.Source

  alias Longpi.Updater.Release

  @impl true
  def latest_stable do
    url = "https://api.github.com/repos/#{Longpi.Updater.repo()}/releases?per_page=15"

    case Req.get(url,
           headers: [{"accept", "application/vnd.github+json"}, {"user-agent", "longpi-updater"}],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        case Enum.find(body, &Release.stable_release?/1) do
          nil -> {:error, "no releases published yet"}
          release -> {:ok, release}
        end

      {:ok, %{status: 404}} ->
        {:error, "no releases published yet"}

      {:ok, %{status: status}} ->
        {:error, "GitHub responded with #{status}"}

      {:error, reason} ->
        {:error, "could not reach GitHub: #{Exception.message(reason)}"}
    end
  end
end
