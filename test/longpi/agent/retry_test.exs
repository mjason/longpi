defmodule Longpi.Agent.RetryTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Retry

  # No real sleeping in tests.
  defp no_sleep, do: fn _ms -> :ok end

  test "returns success without retrying" do
    assert {:ok, 42} = Retry.with_backoff(fn -> {:ok, 42} end, sleep: no_sleep())
  end

  test "retries a transient error until it succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      Retry.with_backoff(
        fn ->
          n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          if n < 3, do: {:error, %{status: 429}}, else: {:ok, :done}
        end,
        sleep: no_sleep()
      )

    assert result == {:ok, :done}
    assert Agent.get(counter, & &1) == 3
  end

  test "gives up after max_attempts and returns the last error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      Retry.with_backoff(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, %{status: 503}}
        end,
        max_attempts: 3,
        sleep: no_sleep()
      )

    assert result == {:error, %{status: 503}}
    assert Agent.get(counter, & &1) == 3
  end

  test "does not retry a non-transient error" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      Retry.with_backoff(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, %{status: 401}}
        end,
        sleep: no_sleep()
      )

    assert result == {:error, %{status: 401}}
    assert Agent.get(counter, & &1) == 1
  end

  test "a custom retryable? can veto retries (e.g. tokens already streamed)" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    result =
      Retry.with_backoff(
        fn ->
          Agent.update(counter, &(&1 + 1))
          {:error, %{status: 429}}
        end,
        retryable?: fn _ -> false end,
        sleep: no_sleep()
      )

    assert result == {:error, %{status: 429}}
    assert Agent.get(counter, & &1) == 1
  end

  describe "transient?/1" do
    test "true for retryable statuses" do
      for s <- [408, 429, 500, 502, 503, 504], do: assert(Retry.transient?(%{status: s}))
    end

    test "false for client errors" do
      for s <- [400, 401, 403, 404], do: refute(Retry.transient?(%{status: s}))
    end

    test "true for transport errors and reasons" do
      assert Retry.transient?(%Req.TransportError{reason: :closed})
      assert Retry.transient?(:timeout)
      assert Retry.transient?(%{reason: :econnrefused})
    end

    test "false for unknown errors" do
      refute Retry.transient?(:something_else)
      refute Retry.transient?(%{reason: :bad_request})
    end
  end

  test "backoff grows exponentially" do
    assert Retry.backoff_ms(1, 500) == 500
    assert Retry.backoff_ms(2, 500) == 1000
    assert Retry.backoff_ms(3, 500) == 2000
  end
end
