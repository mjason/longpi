defmodule Longpi.Agent.ModelDiscovery do
  @moduledoc """
  Lists the models an OpenAI-compatible endpoint offers by calling its
  `/v1/models` route (the same endpoint OpenAI, OpenRouter, and gateways like
  ListenAI expose). Used to auto-populate the Models list from just a base URL
  and key.
  """

  @doc """
  Fetches model ids for a configured provider (by name). Uses the stored
  base_url and api_key, so the browser never handles the key.
  """
  def list(provider_name) when is_binary(provider_name) do
    case Longpi.Agent.get_provider_by_name(provider_name, not_found_error?: false) do
      {:ok, %{base_url: base_url} = provider} when is_binary(base_url) and base_url != "" ->
        fetch(models_url(base_url), provider.api_key)

      {:ok, %{}} ->
        {:error, "provider has no base URL"}

      _ ->
        {:error, "unknown provider: #{provider_name}"}
    end
  end

  defp fetch(url, api_key) do
    headers = if api_key in [nil, ""], do: [], else: [{"authorization", "Bearer #{api_key}"}]

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse(body)}
      {:ok, %{status: status}} -> {:error, "models endpoint returned HTTP #{status}"}
      {:error, reason} -> {:error, "could not reach models endpoint: #{inspect(reason)}"}
    end
  end

  # OpenAI shape: %{"data" => [%{"id" => "gpt-5.4"}, ...]}
  defp parse(%{"data" => data}) when is_list(data) do
    data
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  defp parse(_body), do: []

  defp models_url(base_url) do
    base = String.trim_trailing(base_url, "/")
    if String.ends_with?(base, "/v1"), do: base <> "/models", else: base <> "/v1/models"
  end

  @doc false
  def __models_url__(base_url), do: models_url(base_url)
  @doc false
  def __parse__(body), do: parse(body)
end
