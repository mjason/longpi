defmodule Longpi.Agent.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Write

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{ctx: %{cwd: dir}}
  end

  test "writes content to a new file", %{tmp_dir: dir, ctx: ctx} do
    assert {:ok, message} = Write.run(%{path: "new.txt", content: "fresh"}, ctx)
    assert message =~ "new.txt"
    assert File.read!(Path.join(dir, "new.txt")) == "fresh"
  end

  test "creates missing parent directories", %{tmp_dir: dir, ctx: ctx} do
    assert {:ok, _} = Write.run(%{path: "a/b/c.txt", content: "nested"}, ctx)
    assert File.read!(Path.join(dir, "a/b/c.txt")) == "nested"
  end

  test "overwrites an existing file", %{tmp_dir: dir, ctx: ctx} do
    path = Path.join(dir, "over.txt")
    File.write!(path, "old")

    assert {:ok, _} = Write.run(%{path: path, content: "new"}, ctx)
    assert File.read!(path) == "new"
  end

  test "errors when the target is a directory", %{tmp_dir: dir, ctx: ctx} do
    assert {:error, message} = Write.run(%{path: dir, content: "x"}, ctx)
    assert message =~ "director" or message =~ "eisdir"
  end
end
