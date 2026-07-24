defmodule LongpiWeb.LoginThrottle do
  @moduledoc """
  Per-IP brute-force throttle for the mobile login endpoint: after
  #{10} failed attempts within the window, further tries get 429 until the
  window expires. Backed by a public ETS table owned by this GenServer;
  bcrypt already slows a single guess — this stops unattended scripting.
  """

  use GenServer

  @table :longpi_login_throttle
  @max_failures 10
  @window_ms 10 * 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "False once the IP has burned its attempts for the current window."
  def allowed?(ip) do
    case :ets.lookup(@table, ip) do
      [{^ip, count, first_ms}] ->
        cond do
          now_ms() - first_ms > @window_ms ->
            :ets.delete(@table, ip)
            true

          count >= @max_failures ->
            false

          true ->
            true
        end

      [] ->
        true
    end
  end

  @doc "Records a failed attempt for the IP."
  def record_failure(ip) do
    case :ets.lookup(@table, ip) do
      [{^ip, count, first_ms}] ->
        if now_ms() - first_ms > @window_ms do
          :ets.insert(@table, {ip, 1, now_ms()})
        else
          :ets.insert(@table, {ip, count + 1, first_ms})
        end

      [] ->
        :ets.insert(@table, {ip, 1, now_ms()})
    end

    :ok
  end

  @doc "Clears the IP's counter (successful login)."
  def reset(ip) do
    :ets.delete(@table, ip)
    :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
