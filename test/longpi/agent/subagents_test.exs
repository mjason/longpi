defmodule Longpi.Agent.SubagentsTest do
  use ExUnit.Case, async: false

  alias Longpi.Agent.Subagents

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    global = Path.join(dir, "global-agents")
    project = Path.join(dir, "project")
    File.mkdir_p!(global)
    File.mkdir_p!(Path.join(project, ".longpi/agents"))

    old = Application.get_env(:longpi, :subagents_global_dir)
    Application.put_env(:longpi, :subagents_global_dir, global)
    on_exit(fn -> Application.put_env(:longpi, :subagents_global_dir, old) end)

    %{global: global, project: project}
  end

  test "built-in roles are always available", %{project: project} do
    defs = Subagents.discover(project)
    names = Enum.map(defs, & &1.name)

    assert "scout" in names
    assert "worker" in names

    scout = Enum.find(defs, &(&1.name == "scout"))
    assert scout.tools == ["read", "grep", "find", "ls", "bash"]
    assert scout.source == :builtin
    assert scout.system_prompt =~ "scout"
  end

  test "parses frontmatter from a user-level agent file", %{global: global, project: project} do
    File.write!(Path.join(global, "reviewer.md"), """
    ---
    name: reviewer
    description: Review changes for correctness
    tools: read, grep, ls
    model: anthropic:claude-sonnet-4-5
    reasoning_effort: high
    ---
    You review code. Be brutal.
    """)

    {:ok, def} = Subagents.get(project, "reviewer")
    assert def.description == "Review changes for correctness"
    assert def.tools == ["read", "grep", "ls"]
    assert def.model == "anthropic:claude-sonnet-4-5"
    assert def.reasoning_effort == "high"
    assert def.extensions == false
    assert def.system_prompt =~ "Be brutal"
    assert def.source == :user
  end

  test "project agents override user agents of the same name", %{
    global: global,
    project: project
  } do
    for {dir, desc} <- [
          {global, "user version"},
          {Path.join(project, ".longpi/agents"), "project version"}
        ] do
      File.write!(Path.join(dir, "custom.md"), """
      ---
      name: custom
      description: #{desc}
      ---
      Do things.
      """)
    end

    {:ok, def} = Subagents.get(project, "custom")
    assert def.description == "project version"
    assert def.source == :project
  end

  test "user file overrides a built-in of the same name", %{global: global, project: project} do
    File.write!(Path.join(global, "scout.md"), """
    ---
    name: scout
    description: my scout
    extensions: true
    ---
    Custom scout prompt.
    """)

    {:ok, def} = Subagents.get(project, "scout")
    assert def.description == "my scout"
    assert def.extensions == true
    assert def.tools == nil
  end

  test "files without name/description are skipped", %{global: global, project: project} do
    File.write!(Path.join(global, "broken.md"), "no frontmatter at all")

    File.write!(Path.join(global, "half.md"), """
    ---
    name: half
    ---
    Missing description.
    """)

    names = project |> Subagents.discover() |> Enum.map(& &1.name)
    refute "broken" in names
    refute "half" in names
  end

  test "unknown agent returns error with available names", %{project: project} do
    assert :error = Subagents.get(project, "nope")
  end
end
