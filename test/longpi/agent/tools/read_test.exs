defmodule Longpi.Agent.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Read

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{ctx: %{cwd: dir}}
  end

  test "reads a file by absolute path", %{tmp_dir: dir, ctx: ctx} do
    path = Path.join(dir, "hello.txt")
    File.write!(path, "hello world\n")

    assert {:ok, content} = Read.run(%{path: path}, ctx)
    assert content =~ "hello world"
  end

  test "resolves relative paths against ctx cwd", %{tmp_dir: dir, ctx: ctx} do
    File.write!(Path.join(dir, "rel.txt"), "relative content")

    assert {:ok, content} = Read.run(%{path: "rel.txt"}, ctx)
    assert content =~ "relative content"
  end

  test "windows with offset and limit", %{tmp_dir: dir, ctx: ctx} do
    lines = Enum.map_join(1..100, "\n", &"line #{&1}")
    File.write!(Path.join(dir, "many.txt"), lines)

    assert {:ok, content} = Read.run(%{path: "many.txt", offset: 10, limit: 3}, ctx)
    assert content =~ "line 10"
    assert content =~ "line 12"
    refute content =~ "line 13"
    refute content =~ "line 9\n"
    assert content =~ "lines 10-12 of 100"
  end

  test "caps unwindowed reads at the default line limit", %{tmp_dir: dir, ctx: ctx} do
    lines = Enum.map_join(1..3000, "\n", &"line #{&1}")
    File.write!(Path.join(dir, "huge.txt"), lines)

    assert {:ok, content} = Read.run(%{path: "huge.txt"}, ctx)
    assert content =~ "line 2000"
    refute content =~ "line 2001\n"
    assert content =~ "truncated"
  end

  test "errors on missing file", %{ctx: ctx} do
    assert {:error, message} = Read.run(%{path: "nope.txt"}, ctx)
    assert message =~ "nope.txt"
  end

  test "errors on a directory", %{tmp_dir: dir, ctx: ctx} do
    assert {:error, message} = Read.run(%{path: dir}, ctx)
    assert message =~ "directory"
  end

  test "caps a huge single line by bytes (line cap alone wouldn't)", %{tmp_dir: dir, ctx: ctx} do
    File.write!(Path.join(dir, "min.js"), String.duplicate("x", 200_000))
    assert {:ok, content} = Read.run(%{path: "min.js"}, ctx)
    assert byte_size(content) < 60_000
    assert content =~ "exceeded 50000 bytes"
  end
end
