defmodule Longpi.Agent.ModelDiscoveryTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.ModelDiscovery

  test "errors when the provider is unknown" do
    assert {:error, message} = ModelDiscovery.list("nope")
    assert message =~ "unknown provider"
  end

  test "errors when the provider has no base URL" do
    {:ok, _} = Longpi.Agent.put_provider(%{name: "openai"})
    assert {:error, message} = ModelDiscovery.list("openai")
    assert message =~ "base URL"
  end

  # The models_url normalization and JSON parsing are the fiddly bits; exercise
  # them directly (the HTTP call itself is covered by the live gateway test).
  test "normalizes base URLs with and without /v1" do
    assert ModelDiscovery.__models_url__("https://gw.example/v1") ==
             "https://gw.example/v1/models"

    assert ModelDiscovery.__models_url__("https://gw.example/v1/") ==
             "https://gw.example/v1/models"

    assert ModelDiscovery.__models_url__("https://gw.example") == "https://gw.example/v1/models"
  end

  test "parses the OpenAI models shape and sorts ids" do
    body = %{"data" => [%{"id" => "b"}, %{"id" => "a"}, %{"other" => 1}]}
    assert ModelDiscovery.__parse__(body) == ["a", "b"]
    assert ModelDiscovery.__parse__(%{}) == []
  end
end
