defmodule Longpi.Agent.Tools.FindTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Find

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "alpha.ex"), "")
    File.write!(Path.join(dir, "readme.md"), "")
    File.mkdir_p!(Path.join(dir, "lib/nested"))
    File.write!(Path.join(dir, "lib/mod.ex"), "")
    File.write!(Path.join(dir, "lib/nested/deep.ex"), "")
    %{ctx: %{cwd: dir}}
  end

  test "finds files by basename glob across the tree", %{ctx: ctx} do
    assert {:ok, out} = Find.run(%{pattern: "*.ex"}, ctx)
    assert out =~ "alpha.ex"
    assert out =~ "lib/mod.ex"
    assert out =~ "lib/nested/deep.ex"
    refute out =~ "readme.md"
  end

  test "path-containing glob matches the relative path", %{ctx: ctx} do
    assert {:ok, out} = Find.run(%{pattern: "lib/**/*.ex"}, ctx)
    assert out =~ "lib/mod.ex"
    assert out =~ "lib/nested/deep.ex"
    refute out =~ "alpha.ex"
  end

  test "searches within a subpath", %{ctx: ctx} do
    assert {:ok, out} = Find.run(%{pattern: "*.ex", path: "lib/nested"}, ctx)
    assert out =~ "deep.ex"
    refute out =~ "mod.ex"
  end

  test "reports no matches", %{ctx: ctx} do
    assert {:ok, out} = Find.run(%{pattern: "*.zzz"}, ctx)
    assert out =~ "No files"
  end
end
