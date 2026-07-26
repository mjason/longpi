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

  # Ported from pi's battle-tested classifier (retry.ts) — every pattern here
  # is backed by a real provider/gateway failure mode: mid-stream drops
  # ("stream ended before message_stop"), proxy wording ("upstream connect",
  # "Provider returned error"), transport text ("socket hang up"), and the
  # generic 5xx/overload family.
  @retryable_text ~r/overloaded|rate.?limit|too many requests|\b(429|500|502|503|504|524)\b|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|network.?error|connection.?(error|refused|lost|reset)|other side closed|fetch failed|upstream.?connect|reset before headers|socket hang up|socket connection was closed|connection closed|transport.?error|disconnected|:closed|timed?.?out|timeout|terminated|websocket.?(closed|error)|ended without|stream ended before|http2 request did not get a response|you can retry your request|try your request again|please retry your request|ResourceExhausted/i

  # Account/quota exhaustion looks 429-ish but a retry can never fix it —
  # these override the retryable patterns (also from pi).
  @non_retryable_text ~r/insufficient_quota|out of budget|quota exceeded|billing|usage limit reached|available balance/i

  @doc "Whether an error looks like a transient failure worth retrying."
  def transient?(reason) do
    not permanent_text?(reason) and
      (status(reason) in @retryable_status or transport?(reason) or retryable_text?(reason))
  end

  defp status(reason) when is_map(reason), do: Map.get(reason, :status)
  defp status(_), do: nil

  defp retryable_text?(reason) do
    case error_text(reason) do
      nil -> false
      text -> Regex.match?(@retryable_text, text)
    end
  end

  defp permanent_text?(reason) do
    case error_text(reason) do
      nil -> false
      text -> Regex.match?(@non_retryable_text, text)
    end
  end

  # Pull a human-readable message out of the many error shapes req_llm and
  # transports produce; nil when there is none to classify.
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(%{message: text}) when is_binary(text), do: text
  defp error_text(%{reason: text}) when is_binary(text), do: text
  defp error_text(%{reason: nested}) when is_map(nested), do: error_text(nested)

  defp error_text(%{__struct__: _} = exception) when is_exception(exception),
    do: Exception.message(exception)

  defp error_text(_), do: nil

  defp transport?(reason) when is_atom(reason), do: reason in @transport_reasons

  defp transport?(%{__struct__: mod})
       when mod in [Req.TransportError, Mint.TransportError, Finch.Error, Finch.TransportError],
       do: true

  # req_llm wraps the underlying cause under :reason; unwrap one level.
  defp transport?(%{reason: reason}), do: transport?(reason)
  defp transport?(_), do: false
end
