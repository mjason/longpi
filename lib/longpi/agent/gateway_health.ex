defmodule Longpi.Agent.GatewayHealth do
  @moduledoc """
  A per-provider circuit breaker shared by every session on the node.

  Single-session CLIs (pi, Claude Code, Codex) each probe a dead gateway on
  their own schedule — ten parallel loops burn ten retry budgets against the
  same outage. Here all sessions share one verdict: after `@open_after`
  consecutive transient failures the provider is marked open, and
  `delay_for/1` tells callers how long to hold off (sessions stretch their
  retry backoff to it; the scheduler skips the occurrence). One success —
  anyone's — closes it again.

  Keyed by the provider prefix of the model spec (`"openai:gpt-4.1"` →
  `"openai"`), since an outage is a gateway property, not a model property.
  """

  use GenServer

  @open_after 3

  # Env-tunable so tests can use millisecond windows.
  defp base_open_ms, do: Application.get_env(:longpi, :gateway_breaker_base_ms, 30_000)
  defp max_open_ms, do: Application.get_env(:longpi, :gateway_breaker_max_ms, 600_000)

  # Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records a turn outcome for the model's provider (`:ok` closes, `:error` counts)."
  @spec report(String.t(), :ok | :error, GenServer.server()) :: :ok
  def report(model_spec, verdict, server \\ __MODULE__) do
    GenServer.cast(server, {:report, provider(model_spec), verdict, now_ms()})
  end

  @doc "Milliseconds to hold off before talking to this model's provider (0 = healthy)."
  @spec delay_for(String.t(), GenServer.server()) :: non_neg_integer()
  def delay_for(model_spec, server \\ __MODULE__) do
    GenServer.call(server, {:delay_for, provider(model_spec), now_ms()})
  catch
    # A missing/busy breaker must never block a retry decision.
    :exit, _ -> 0
  end

  @doc "Clears all breaker state (test isolation)."
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  catch
    :exit, _ -> :ok
  end

  @doc "The provider key for a model spec (the part before the first colon)."
  def provider(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [prefix, _rest] -> prefix
      _ -> spec
    end
  end

  def provider(_spec), do: "unknown"

  # Server

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:report, provider, :ok, _now}, state) do
    {:noreply, Map.delete(state, provider)}
  end

  def handle_cast({:report, provider, :error, now}, state) do
    # open_until is nil while closed — monotonic time can be NEGATIVE, so a
    # numeric "0 = not open" sentinel would read as a date far in the future.
    entry = Map.get(state, provider, %{failures: 0, open_until: nil})
    failures = entry.failures + 1

    open_until =
      if failures >= @open_after do
        # 30s at the threshold, doubling per further failure, capped at 10min.
        backoff = min(base_open_ms() * Integer.pow(2, failures - @open_after), max_open_ms())
        now + backoff
      else
        entry.open_until
      end

    {:noreply, Map.put(state, provider, %{failures: failures, open_until: open_until})}
  end

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  def handle_call({:delay_for, provider, now}, _from, state) do
    delay =
      case state do
        %{^provider => %{open_until: until}} when is_integer(until) and until > now -> until - now
        _ -> 0
      end

    {:reply, delay, state}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
