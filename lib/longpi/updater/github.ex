defmodule Longpi.Updater.Source do
  @moduledoc "Boundary for fetching release metadata, so it can be stubbed in tests."
  @callback latest_stable() :: {:ok, map()} | {:error, term()}
end

defmodule Longpi.Updater.GitHub do
  @moduledoc """
  Default `Longpi.Updater.Source`: the newest stable release from the GitHub
  releases API. `/releases/latest` can lag or point at a draft, so we list
  recent releases and pick the newest stable `vX.Y.Z` one.

  Unauthenticated GitHub API calls are limited to 60/hour/IP, so a naive
  check-on-every-request updater trips a `403` quickly. This module avoids that:

    * caches the result for #{15} minutes, so repeated page loads don't re-query;
    * revalidates with an `ETag` (`If-None-Match`) — a `304` costs no rate limit;
    * on a `403`/`429` (or any transient failure) serves the last known release
      instead of erroring, so the UI stays useful; and
    * uses a configured `github_token` (5000/hour) when one is set.
  """
  @behaviour Longpi.Updater.Source

  alias Longpi.Updater.Release

  @cache_key {__MODULE__, :cache}
  @ttl_seconds 15 * 60

  @impl true
  def latest_stable, do: latest_stable(System.system_time(:second))

  @doc false
  def latest_stable(now) do
    cache = cache_get()

    if fresh?(cache, now) do
      {:ok, cache.release}
    else
      revalidate(cache, now)
    end
  end

  # Fresh only while we hold a real release inside the TTL.
  defp fresh?(%{release: release, fetched_at: t}, now) when not is_nil(release),
    do: now - t < @ttl_seconds

  defp fresh?(_, _), do: false

  defp revalidate(cache, now) do
    result = Req.get(releases_url(), headers: request_headers(cache), retry: false)
    {reply, new_cache} = interpret(result, cache, now)
    if new_cache, do: cache_put(new_cache)
    reply
  end

  @doc """
  Turn a `Req.get` result into `{reply, new_cache | nil}` given the prior cache.

  Pure (no HTTP, no clock) so the caching and rate-limit-fallback policy is
  unit-testable. `new_cache` is nil when nothing should be written.
  """
  def interpret(result, cache, now) do
    case result do
      # Not modified — conditional requests don't spend rate limit. Keep the
      # cached release and just bump its freshness.
      {:ok, %{status: 304}} ->
        {{:ok, cache.release}, %{cache | fetched_at: now}}

      {:ok, %{status: 200, body: body} = resp} when is_list(body) ->
        case Enum.find(body, &Release.stable_release?/1) do
          nil -> {{:error, "no releases published yet"}, nil}
          release -> {{:ok, release}, %{release: release, etag: etag(resp), fetched_at: now}}
        end

      {:ok, %{status: 404}} ->
        {{:error, "no releases published yet"}, nil}

      # Rate-limited (or forbidden): keep serving the last known release.
      {:ok, %{status: status}} when status in [403, 429] ->
        fallback(cache, "GitHub rate limit reached — showing the last known release")

      {:ok, %{status: status}} ->
        fallback(cache, "GitHub responded with #{status}")

      {:error, reason} ->
        fallback(cache, "could not reach GitHub: #{Exception.message(reason)}")
    end
  end

  # A transient failure shouldn't blank out a known-good answer.
  defp fallback(%{release: release}, _msg) when not is_nil(release), do: {{:ok, release}, nil}
  defp fallback(_cache, msg), do: {{:error, msg}, nil}

  defp releases_url,
    do: "https://api.github.com/repos/#{Longpi.Updater.repo()}/releases?per_page=15"

  defp request_headers(cache) do
    [{"accept", "application/vnd.github+json"}, {"user-agent", "longpi-updater"}]
    |> maybe_add("if-none-match", cache && cache.etag)
    |> maybe_add("authorization", token() && "Bearer #{token()}")
  end

  defp maybe_add(headers, _key, value) when value in [nil, false], do: headers
  defp maybe_add(headers, key, value), do: [{key, value} | headers]

  defp token, do: Application.get_env(:longpi, :github_token)

  defp etag(%{headers: %{} = headers}), do: headers |> Map.get("etag", []) |> List.first()
  defp etag(%{headers: headers}) when is_list(headers), do: for({"etag", v} <- headers, do: v) |> List.first()
  defp etag(_), do: nil

  defp cache_get, do: :persistent_term.get(@cache_key, nil)
  defp cache_put(cache), do: :persistent_term.put(@cache_key, cache)
end
