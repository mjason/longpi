defmodule Longpi.Agent.Tools.LsTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Ls

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "hi")
    File.mkdir_p!(Path.join(dir, "subdir"))
    %{ctx: %{cwd: dir}}
  end

  test "lists entries, marking directories", %{ctx: ctx} do
    assert {:ok, out} = Ls.run(%{}, ctx)
    assert out =~ "file.txt"
    assert out =~ "subdir/"
  end

  test "lists a relative subpath", %{tmp_dir: dir, ctx: ctx} do
    File.write!(Path.join(dir, "subdir/inner.ex"), "")
    assert {:ok, out} = Ls.run(%{path: "subdir"}, ctx)
    assert out =~ "inner.ex"
    refute out =~ "file.txt"
  end

  test "errors on a missing path", %{ctx: ctx} do
    assert {:error, message} = Ls.run(%{path: "nope"}, ctx)
    assert message =~ "nope"
  end

  test "errors when the path is a file", %{ctx: ctx} do
    assert {:error, message} = Ls.run(%{path: "file.txt"}, ctx)
    assert message =~ "not a directory" or message =~ "file.txt"
  end
end
