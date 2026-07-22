defmodule Longpi.ExtensionsLazyTest do
  use ExUnit.Case, async: false

  alias Longpi.Extensions

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    global = Path.join(dir, "global-ext")
    project = Path.join(dir, "project")
    File.mkdir_p!(global)
    File.mkdir_p!(project)

    old = Application.get_env(:longpi, :global_extensions_dir)
    Application.put_env(:longpi, :global_extensions_dir, global)
    on_exit(fn -> Application.put_env(:longpi, :global_extensions_dir, old) end)

    %{global: global, project: project}
  end

  test "no extensions anywhere → no host needed", %{project: project} do
    refute Extensions.any_for?(project)
  end

  test "a top-level .ts file in the global dir counts", %{global: global, project: project} do
    File.write!(Path.join(global, "tool.ts"), "// ext")
    assert Extensions.any_for?(project)
  end

  test "a project subdir with index.ts counts", %{project: project} do
    dir = Path.join(project, ".longpi/extensions/mytool")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.ts"), "// ext")
    assert Extensions.any_for?(project)
  end

  test "a subdir without an index does not count", %{project: project} do
    dir = Path.join(project, ".longpi/extensions/notes")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "readme.md"), "docs only")
    refute Extensions.any_for?(project)
  end

end
