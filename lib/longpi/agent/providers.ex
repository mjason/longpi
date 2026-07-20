defmodule Longpi.Agent.Providers do
  @moduledoc """
  Resolves per-provider credentials for a model spec, from the `Provider`
  resource, to inject into req_llm requests. Falls back to whatever req_llm
  reads from config/env when a provider isn't configured in the db.
  """

  @doc """
  Request options (`:api_key`, `:base_url`) for a model spec like
  `"openai:gpt-5.4"`, or `[]` to fall back to req_llm's env/config lookup.
  """
  def request_opts(model_spec) when is_binary(model_spec) do
    name = model_spec |> String.split(":", parts: 2) |> hd()

    case Longpi.Agent.get_provider_by_name(name, not_found_error?: false) do
      {:ok, %{} = provider} ->
        []
        |> maybe_put(:api_key, provider.api_key)
        |> maybe_put(:base_url, provider.base_url)

      _ ->
        []
    end
  end

  defp maybe_put(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
