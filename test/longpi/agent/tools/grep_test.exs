defmodule Longpi.Agent.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Grep

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "alpha.ex"), "defmodule Alpha do\n  def hello, do: :world\nend\n")
    File.write!(Path.join(dir, "beta.txt"), "hello there\nHELLO AGAIN\ngoodbye\n")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "sub/gamma.ex"), "defmodule Gamma do\nend\n")
    %{ctx: %{cwd: dir}}
  end

  test "finds matches with file:line:text lines", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "defmodule"}, ctx)
    assert out =~ "alpha.ex:1:"
    assert out =~ "defmodule Alpha"
    assert out =~ "sub/gamma.ex:1:"
  end

  test "filters files by glob", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "defmodule", glob: "*.ex"}, ctx)
    assert out =~ "alpha.ex"
    refute out =~ "beta.txt"
  end

  test "case-insensitive search", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "hello", ignore_case: true, glob: "*.txt"}, ctx)
    assert out =~ "hello there"
    assert out =~ "HELLO AGAIN"
  end

  test "literal treats the pattern as plain text", %{ctx: ctx} do
    File.write!(Path.join(ctx.cwd, "re.txt"), "a.b\naxb\n")
    assert {:ok, out} = Grep.run(%{pattern: "a.b", literal: true, glob: "re.txt"}, ctx)
    assert out =~ "a.b"
    refute out =~ "axb"
  end

  test "context lines surround the match", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "def hello", context: 1, glob: "*.ex"}, ctx)
    assert out =~ "defmodule Alpha"
    assert out =~ "def hello"
  end

  test "reports no matches", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "nonexistent_zzz"}, ctx)
    assert out =~ "No matches"
  end

  test "notes when the match limit is hit", %{ctx: ctx} do
    for i <- 1..10, do: File.write!(Path.join(ctx.cwd, "f#{i}.log"), "needle\n")
    assert {:ok, out} = Grep.run(%{pattern: "needle", glob: "*.log", limit: 3}, ctx)
    assert out =~ "limit"
  end

  test "searches a relative subpath", %{ctx: ctx} do
    assert {:ok, out} = Grep.run(%{pattern: "defmodule", path: "sub"}, ctx)
    assert out =~ "gamma.ex"
    refute out =~ "alpha.ex"
  end

  test "errors on an invalid regex", %{ctx: ctx} do
    assert {:error, message} = Grep.run(%{pattern: "("}, ctx)
    assert message =~ "pattern" or message =~ "regex"
  end
end
