defmodule Longpi.Agent.GatewayHealthTest do
  # Behavior: one shared circuit breaker per provider — three consecutive
  # transient failures open it (everyone backs off), one success closes it.
  use ExUnit.Case, async: false

  alias Longpi.Agent.GatewayHealth

  setup do
    name = :"gateway_health_#{System.unique_integer([:positive])}"
    start_supervised!({GatewayHealth, name: name})
    %{breaker: name}
  end

  test "healthy provider reports zero delay", %{breaker: breaker} do
    assert GatewayHealth.delay_for("openai:gpt-4.1", breaker) == 0
  end

  test "opens after three consecutive failures, keyed by provider", %{breaker: breaker} do
    for _ <- 1..2, do: GatewayHealth.report("openai:gpt-4.1", :error, breaker)
    assert GatewayHealth.delay_for("openai:gpt-4.1", breaker) == 0

    GatewayHealth.report("openai:gpt-4.1", :error, breaker)
    # An outage is a GATEWAY property: any model on the provider is covered…
    assert GatewayHealth.delay_for("openai:o4-mini", breaker) > 0
    # …but other providers are unaffected.
    assert GatewayHealth.delay_for("anthropic:claude", breaker) == 0
  end

  test "one success — anyone's — closes it again", %{breaker: breaker} do
    for _ <- 1..4, do: GatewayHealth.report("openai:gpt-4.1", :error, breaker)
    assert GatewayHealth.delay_for("openai:gpt-4.1", breaker) > 0

    GatewayHealth.report("openai:gpt-4.1", :ok, breaker)
    assert GatewayHealth.delay_for("openai:gpt-4.1", breaker) == 0
  end

  test "the hold-off grows with further failures but is capped", %{breaker: breaker} do
    for _ <- 1..3, do: GatewayHealth.report("x:y", :error, breaker)
    first = GatewayHealth.delay_for("x:y", breaker)

    for _ <- 1..10, do: GatewayHealth.report("x:y", :error, breaker)
    later = GatewayHealth.delay_for("x:y", breaker)

    assert later >= first
    assert later <= Application.get_env(:longpi, :gateway_breaker_max_ms, 600_000)
  end

  test "a dead breaker never blocks callers" do
    assert GatewayHealth.delay_for("openai:gpt-4.1", :no_such_breaker) == 0
    assert GatewayHealth.reset(:no_such_breaker) == :ok
  end
end
