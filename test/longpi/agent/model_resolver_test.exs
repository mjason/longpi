defmodule Longpi.Agent.ModelResolverTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.ModelResolver

  test "nil and empty mean inherit" do
    assert {:ok, %{spec: nil, reasoning_effort: nil}} = ModelResolver.resolve(nil)
    assert {:ok, %{spec: nil, reasoning_effort: nil}} = ModelResolver.resolve("")
  end

  test "resolves a tier alias case-insensitively, with its bundled effort" do
    Longpi.Agent.put_model_alias!(%{
      name: "J",
      spec: "openai:gpt-mini",
      note: "light",
      reasoning_effort: "low"
    })

    assert {:ok, %{spec: "openai:gpt-mini", reasoning_effort: "low"}} = ModelResolver.resolve("J")
    assert {:ok, %{spec: "openai:gpt-mini"}} = ModelResolver.resolve("j")
  end

  test "a tier without effort resolves effort to nil (inherit)" do
    Longpi.Agent.put_model_alias!(%{name: "Q", spec: "openai:balanced"})

    assert {:ok, %{spec: "openai:balanced", reasoning_effort: nil}} = ModelResolver.resolve("Q")
  end

  test "upserting a tier remaps it in place" do
    Longpi.Agent.put_model_alias!(%{name: "K", spec: "openai:one"})
    Longpi.Agent.put_model_alias!(%{name: "K", spec: "openai:two", reasoning_effort: "high"})

    assert {:ok, %{spec: "openai:two", reasoning_effort: "high"}} = ModelResolver.resolve("K")
    assert [_] = Longpi.Agent.list_model_aliases!()
  end

  test "passes through a configured model spec" do
    Longpi.Agent.create_model!(%{spec: "openai:direct-spec"})

    assert {:ok, %{spec: "openai:direct-spec", reasoning_effort: nil}} =
             ModelResolver.resolve("openai:direct-spec")
  end

  test "unknown ref errors and lists tiers + models" do
    Longpi.Agent.put_model_alias!(%{name: "Q", spec: "openai:balanced"})

    assert {:error, message} = ModelResolver.resolve("no-such-model")
    assert message =~ "no-such-model"
    assert message =~ "Q → openai:balanced"
  end
end
