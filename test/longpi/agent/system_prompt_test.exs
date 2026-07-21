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

  test "teaches self-extension and resolves the on-disk guide + examples paths" do
    prompt = SystemPrompt.resolve(@ctx)
    priv = :code.priv_dir(:longpi)

    # The agent is told it can extend itself, and where to read the real docs.
    assert prompt =~ "Extending yourself"
    assert prompt =~ ".longpi/extensions/"
    # The system auto-loads the extension; the prompt says so positively and
    # never mentions /reload (a negative "don't say /reload" would just prime it).
    assert prompt =~ "automatically"
    refute prompt =~ "/reload"
    # Secrets go in the app UI, not the OS env; built-in tools over system utils.
    assert prompt =~ "Settings"
    assert prompt =~ "apply_patch"
    assert prompt =~ Path.join([priv, "ext_host", "README.md"])
    assert prompt =~ Path.join([priv, "ext_host", "examples"])
    # No placeholders leak through.
    refute prompt =~ "{{ext_guide}}"
    refute prompt =~ "{{ext_examples}}"
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
