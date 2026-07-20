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
    assert message =~ "different"
  end

  test "errors on missing file", %{ctx: ctx} do
    args = %{path: "ghost.ex", old_string: "a", new_string: "b"}

    assert {:error, message} = Edit.run(args, ctx)
    assert message =~ "ghost.ex"
  end
end
