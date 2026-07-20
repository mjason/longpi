defmodule Longpi.Agent.ModelTest do
  use Longpi.DataCase, async: false

  test "creates and lists models by position" do
    Longpi.Agent.create_model!(%{spec: "openai:gpt-5.4", label: "GPT-5.4", position: 1})

    Longpi.Agent.create_model!(%{
      spec: "anthropic:claude-sonnet-4-5",
      label: "Sonnet",
      position: 0
    })

    specs = Longpi.Agent.list_models!() |> Enum.map(& &1.spec)
    assert specs == ["anthropic:claude-sonnet-4-5", "openai:gpt-5.4"]
  end

  test "enabled action returns only enabled models" do
    Longpi.Agent.create_model!(%{spec: "openai:gpt-5.4", enabled: true})
    Longpi.Agent.create_model!(%{spec: "openai:old", enabled: false})

    specs = Longpi.Agent.list_enabled_models!() |> Enum.map(& &1.spec)
    assert specs == ["openai:gpt-5.4"]
  end

  test "spec is unique" do
    Longpi.Agent.create_model!(%{spec: "openai:gpt-5.4"})
    assert {:error, _} = Longpi.Agent.create_model(%{spec: "openai:gpt-5.4"})
  end

  test "update toggles enabled" do
    model = Longpi.Agent.create_model!(%{spec: "openai:gpt-5.4", enabled: true})
    {:ok, updated} = Longpi.Agent.update_model(model, %{enabled: false})
    refute updated.enabled
  end
end
