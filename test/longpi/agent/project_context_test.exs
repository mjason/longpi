defmodule Longpi.Agent.ProjectContextTest do
  use ExUnit.Case, async: false

  alias Longpi.Agent.ProjectContext

  setup do
    # A hermetic root under the system tmp dir (NOT the repo's tmp/, whose
    # ancestors include the repo's own CLAUDE.md).
    root =
      Path.join(System.tmp_dir!(), "longpi_pc_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(:longpi, :project_context_enabled, true)
    Application.put_env(:longpi, :global_dir, Path.join(root, "empty_global"))

    on_exit(fn ->
      Application.put_env(:longpi, :project_context_enabled, false)
      Application.delete_env(:longpi, :global_dir)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "loads AGENTS.md and CLAUDE.md from the workspace", %{root: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Use tabs.")
    File.write!(Path.join(dir, "CLAUDE.md"), "Run mix format.")

    loaded = ProjectContext.load(dir)
    paths = Enum.map(loaded, & &1.path)

    assert Path.join(dir, "AGENTS.md") in paths
    assert Path.join(dir, "CLAUDE.md") in paths
    assert Enum.find(loaded, &(&1.content == "Use tabs."))
  end

  test "the workspace file comes after (wins over) an ancestor's", %{root: dir} do
    child = Path.join(dir, "sub/pkg")
    File.mkdir_p!(child)
    File.write!(Path.join(dir, "AGENTS.md"), "ROOT rule")
    File.write!(Path.join(child, "AGENTS.md"), "CHILD rule")

    contents = child |> ProjectContext.load() |> Enum.map(& &1.content)
    root_idx = Enum.find_index(contents, &(&1 == "ROOT rule"))
    child_idx = Enum.find_index(contents, &(&1 == "CHILD rule"))

    assert root_idx < child_idx
  end

  test "no files → empty", %{root: dir} do
    assert ProjectContext.load(dir) == []
  end

  test "disabled by config → empty even when files exist", %{root: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "x")
    Application.put_env(:longpi, :project_context_enabled, false)
    assert ProjectContext.load(dir) == []
  end
end
