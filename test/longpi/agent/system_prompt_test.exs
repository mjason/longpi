defmodule Longpi.Agent.SystemPromptTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.{Settings, SystemPrompt}

  @ctx %{cwd: "/work/proj"}

  test "falls back to the built-in default and interpolates cwd" do
    assert prompt = SystemPrompt.resolve(@ctx)
    assert prompt =~ "You are Longpi"
    assert prompt =~ "/work/proj"
    refute prompt =~ "{{cwd}}"
  end

  test "a global setting overrides the default" do
    Settings.put("system_prompt", "Custom prompt for {{cwd}}.")
    assert SystemPrompt.resolve(@ctx) == "Custom prompt for /work/proj."
  end

  test "a conversation override beats the global setting" do
    Settings.put("system_prompt", "global one")

    assert SystemPrompt.resolve(@ctx, "conversation says {{cwd}}") ==
             "conversation says /work/proj"
  end

  test "blank override/setting falls through to the default" do
    Settings.put("system_prompt", "   ")
    prompt = SystemPrompt.resolve(@ctx, "")
    assert prompt =~ "You are Longpi"
  end
end
