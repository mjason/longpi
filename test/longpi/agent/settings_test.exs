defmodule Longpi.Agent.SettingsTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.Settings

  test "get returns the default when unset" do
    assert Settings.get("default_model", "openai:gpt-5.4") == "openai:gpt-5.4"
    assert Settings.get("missing") == nil
  end

  test "put then get roundtrips" do
    {:ok, _} = Settings.put("default_model", "anthropic:claude-sonnet-4-5")
    assert Settings.get("default_model") == "anthropic:claude-sonnet-4-5"
  end

  test "put upserts an existing key" do
    {:ok, _} = Settings.put("system_prompt", "v1")
    {:ok, _} = Settings.put("system_prompt", "v2")
    assert Settings.get("system_prompt") == "v2"
    assert length(Longpi.Agent.list_settings!()) == 1
  end

  test "blank value is treated as unset" do
    {:ok, _} = Settings.put("system_prompt", "")
    assert Settings.get("system_prompt", "fallback") == "fallback"
  end
end
