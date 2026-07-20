defmodule Longpi.Agent.ProvidersTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Providers

  test "request_opts is empty when the provider is not configured" do
    assert Providers.request_opts("openai:gpt-5.4") == []
  end

  test "request_opts returns base_url and api_key for a configured provider" do
    {:ok, provider} = Longpi.Agent.put_provider(%{name: "openai", base_url: "https://gw/v1"})
    {:ok, _} = Longpi.Agent.set_provider_key(provider, %{api_key: "sk-secret"})

    opts = Providers.request_opts("openai:gpt-5.4")
    assert Keyword.get(opts, :base_url) == "https://gw/v1"
    assert Keyword.get(opts, :api_key) == "sk-secret"
  end

  test "resolves the provider from the model spec prefix" do
    {:ok, provider} = Longpi.Agent.put_provider(%{name: "anthropic"})
    {:ok, _} = Longpi.Agent.set_provider_key(provider, %{api_key: "sk-ant"})

    assert Providers.request_opts("anthropic:claude-sonnet-4-5") == [api_key: "sk-ant"]
    assert Providers.request_opts("openai:gpt-5.4") == []
  end

  test "set_key with a blank value leaves the existing key unchanged" do
    {:ok, provider} = Longpi.Agent.put_provider(%{name: "openai"})
    {:ok, provider} = Longpi.Agent.set_provider_key(provider, %{api_key: "sk-first"})
    {:ok, _} = Longpi.Agent.set_provider_key(provider, %{api_key: ""})

    assert Keyword.get(Providers.request_opts("openai:x"), :api_key) == "sk-first"
  end

  test "put updates base_url without wiping the stored key" do
    {:ok, provider} = Longpi.Agent.put_provider(%{name: "openai", base_url: "https://a"})
    {:ok, _} = Longpi.Agent.set_provider_key(provider, %{api_key: "sk-keep"})
    {:ok, _} = Longpi.Agent.put_provider(%{name: "openai", base_url: "https://b"})

    opts = Providers.request_opts("openai:x")
    assert Keyword.get(opts, :base_url) == "https://b"
    assert Keyword.get(opts, :api_key) == "sk-keep"
  end

  test "api_key is not a public attribute (never sent over RPC)" do
    public =
      Ash.Resource.Info.public_attributes(Longpi.Agent.Provider) |> Enum.map(& &1.name)

    refute :api_key in public
    assert :base_url in public
  end
end
