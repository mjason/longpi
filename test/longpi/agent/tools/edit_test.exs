defmodule Longpi.Agent.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.Edit

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "code.ex")
    File.write!(path, "def alpha, do: 1\ndef beta, do: 2\ndef alpha_two, do: 3\n")
    %{ctx: %{cwd: dir}, path: path}
  end

  test "replaces a unique occurrence", %{ctx: ctx, path: path} do
    args = %{path: path, old_string: "def beta, do: 2", new_string: "def beta, do: 22"}

    assert {:ok, _} = Edit.run(args, ctx)
    assert File.read!(path) =~ "def beta, do: 22"
  end

  test "errors when old_string is absent", %{ctx: ctx, path: path} do
    args = %{path: path, old_string: "not there", new_string: "x"}

    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "not found"
  end

  test "errors with count when old_string is ambiguous", %{ctx: ctx, path: path} do
    args = %{path: path, old_string: "def alpha", new_string: "def gamma"}

    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "2"
  end

  test "replace_all rewrites every occurrence", %{ctx: ctx, path: path} do
    args = %{path: path, old_string: "def alpha", new_string: "def gamma", replace_all: true}

    assert {:ok, message} = Edit.run(args, ctx)
    assert message =~ "2"
    content = File.read!(path)
    assert content =~ "def gamma, do: 1"
    assert content =~ "def gamma_two, do: 3"
    refute content =~ "def alpha"
  end

  test "errors when old_string equals new_string", %{ctx: ctx, path: path} do
    args = %{path: path, old_string: "def beta", new_string: "def beta"}

    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "identical"
  end

  test "errors on missing file", %{ctx: ctx} do
    args = %{path: "ghost.ex", old_string: "a", new_string: "b"}

    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "ghost.ex"
  end

  # ── Layered matching ──

  test "matches across CRLF line endings when old_string is LF-only", %{ctx: ctx, tmp_dir: dir} do
    path = Path.join(dir, "crlf.txt")
    File.write!(path, "alpha\r\nbeta\r\ngamma\r\n")

    args = %{path: path, old_string: "alpha\nbeta", new_string: "ALPHA\nBETA"}
    assert {:ok, msg} = Edit.run(args, ctx)
    assert msg =~ "CRLF"
    # The file keeps CRLF endings.
    assert File.read!(path) == "ALPHA\r\nBETA\r\ngamma\r\n"
  end

  test "tolerates trailing whitespace differences (fuzzy line match)", %{ctx: ctx, tmp_dir: dir} do
    path = Path.join(dir, "ws.ex")
    # File has trailing spaces the model won't reproduce.
    File.write!(path, "def a do   \n  :ok  \nend\n")

    args = %{path: path, old_string: "def a do\n  :ok\nend", new_string: "def a do\n  :yes\nend"}
    assert {:ok, msg} = Edit.run(args, ctx)
    assert msg =~ "normalization"
    assert File.read!(path) =~ ":yes"
  end

  test "reports a no-op edit rather than silently writing", %{ctx: ctx, tmp_dir: dir} do
    path = Path.join(dir, "noop.ex")
    File.write!(path, "foo\n")
    # old (trailing space) fuzzy-matches "foo", but the replacement equals what's
    # already there, so the file wouldn't change.
    args = %{path: path, old_string: "foo ", new_string: "foo"}
    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "unchanged"
  end
end
