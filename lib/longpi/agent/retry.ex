defmodule Longpi.Agent.Retry do
  @moduledoc """
  Exponential-backoff retry for transient LLM failures (rate limits, 5xx,
  network blips). `transient?/1` classifies req_llm / transport errors; callers
  can pass a stricter `:retryable?` (e.g. "only if no tokens streamed yet").
  """

  # 429 rate limit, 408/409/425 request-timing, and 5xx server errors are worth
  # retrying. 4xx client errors (400/401/403/404) are not — a retry won't help.
  @retryable_status [408, 409, 425, 429, 500, 502, 503, 504]
  @transport_reasons [:timeout, :closed, :econnrefused, :nxdomain, :ehostunreach, :ehostdown]

  @doc """
  Calls `fun` (returning `{:ok, _}` | `{:error, reason}`), retrying retryable
  failures with exponential backoff.

  Options: `:max_attempts` (default 3), `:base_ms` (default 500), `:sleep`
  (default `Process.sleep/1`, injectable for tests), `:retryable?` (default
  `transient?/1`).
  """
  def with_backoff(fun, opts \\ []) when is_function(fun, 0) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_ms = Keyword.get(opts, :base_ms, 500)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    retryable? = Keyword.get(opts, :retryable?, &transient?/1)
    attempt(fun, 1, max_attempts, base_ms, sleep, retryable?)
  end

  defp attempt(fun, n, max, base, sleep, retryable?) do
    case fun.() do
      {:error, reason} = error when n < max ->
        if retryable?.(reason) do
          sleep.(backoff_ms(n, base))
          attempt(fun, n + 1, max, base, sleep, retryable?)
        else
          error
        end

      other ->
        other
    end
  end

  @doc "Backoff delay for a 1-based attempt number: base * 2^(n-1)."
  def backoff_ms(n, base), do: trunc(base * :math.pow(2, n - 1))

  @doc "Whether an error looks like a transient failure worth retrying."
  def transient?(reason) do
    status(reason) in @retryable_status or transport?(reason)
  end

  defp status(reason) when is_map(reason), do: Map.get(reason, :status)
  defp status(_), do: nil

  defp transport?(reason) when is_atom(reason), do: reason in @transport_reasons

  defp transport?(%{__struct__: mod})
       when mod in [Req.TransportError, Mint.TransportError, Finch.Error],
       do: true

  # req_llm wraps the underlying cause under :reason; unwrap one level.
  defp transport?(%{reason: reason}), do: transport?(reason)
  defp transport?(_), do: false
end
