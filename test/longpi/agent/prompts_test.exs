defmodule Longpi.Agent.PromptsTest do
  use Longpi.DataCase, async: false

  alias Longpi.Agent.{Prompts, Settings}

  test "tool_description falls back to the default when unset" do
    assert Prompts.tool_description("read", "default read desc") == "default read desc"
  end

  test "tool_description honors an admin override" do
    Settings.put(Prompts.tool_desc_key("bash"), "Custom bash guidance.")
    assert Prompts.tool_description("bash", "original") == "Custom bash guidance."
  end

  test "tool_catalog lists every built-in tool with default and effective text" do
    catalog = Prompts.tool_catalog()
    names = Enum.map(catalog, & &1.name) |> Enum.sort()
    assert names == ["apply_patch", "bash", "continue_later", "edit", "find", "grep", "ls", "name_secret", "read", "schedule", "write"]

    for entry <- catalog do
      assert is_binary(entry.default_description)
      assert entry.description == entry.default_description
    end
  end

  test "tool_catalog reflects an override" do
    Settings.put(Prompts.tool_desc_key("grep"), "Overridden grep.")
    entry = Prompts.tool_catalog() |> Enum.find(&(&1.name == "grep"))
    assert entry.description == "Overridden grep."
    assert entry.default_description != "Overridden grep."
  end
end
