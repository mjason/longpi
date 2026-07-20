defmodule Longpi.Agent.ContextWindowTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.{ContextWindow, Settings}

  test "reads the window from req_llm model metadata" do
    # gpt-4o is a well-known 128k model in LLMDB.
    assert ContextWindow.for_model("openai:gpt-4o") == 128_000
  end

  test "a Model override wins over metadata" do
    Longpi.Agent.create_model!(%{spec: "openai:gpt-4o", context_window: 50_000})
    assert ContextWindow.for_model("openai:gpt-4o") == 50_000
  end

  test "falls back to the default for unknown gateway models" do
    assert ContextWindow.for_model("openai:some-gateway-only-model") == 128_000
  end

  test "threshold is the window times the ratio" do
    Settings.put("compaction_ratio", "0.75")
    Longpi.Agent.create_model!(%{spec: "x:y", context_window: 200_000})
    assert ContextWindow.compaction_threshold("x:y") == 150_000
  end

  test "enabled defaults true and honors the setting" do
    assert ContextWindow.enabled?()
    Settings.put("compaction_enabled", "false")
    refute ContextWindow.enabled?()
  end
end
