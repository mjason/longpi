defmodule Longpi.Agent.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias Longpi.Agent.Tools.ApplyPatch

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "code.ex"), "def alpha, do: 1\ndef beta, do: 2\ndef gamma, do: 3\n")
    %{ctx: %{cwd: dir}, dir: dir}
  end

  defp wrap(body), do: "*** Begin Patch\n" <> body <> "*** End Patch\n"

  test "updates a file using a context hunk", %{ctx: ctx, dir: dir} do
    input =
      wrap("""
      *** Update File: code.ex
      @@
       def alpha, do: 1
      -def beta, do: 2
      +def beta, do: 22
       def gamma, do: 3
      """)

    assert {:ok, msg} = ApplyPatch.run(%{input: input}, ctx)
    assert msg =~ "code.ex"
    assert File.read!(Path.join(dir, "code.ex")) == "def alpha, do: 1\ndef beta, do: 22\ndef gamma, do: 3\n"
  end

  test "applies multiple hunks in one file", %{ctx: ctx, dir: dir} do
    input =
      wrap("""
      *** Update File: code.ex
      @@
      -def alpha, do: 1
      +def alpha, do: 11
      @@
      -def gamma, do: 3
      +def gamma, do: 33
      """)

    assert {:ok, _} = ApplyPatch.run(%{input: input}, ctx)
    content = File.read!(Path.join(dir, "code.ex"))
    assert content =~ "def alpha, do: 11"
    assert content =~ "def gamma, do: 33"
    assert content =~ "def beta, do: 2"
  end

  test "adds a new file", %{ctx: ctx, dir: dir} do
    input =
      wrap("""
      *** Add File: hello.txt
      +hello
      +world
      """)

    assert {:ok, _} = ApplyPatch.run(%{input: input}, ctx)
    assert File.read!(Path.join(dir, "hello.txt")) == "hello\nworld\n"
  end

  test "deletes a file", %{ctx: ctx, dir: dir} do
    input = wrap("*** Delete File: code.ex\n")

    assert {:ok, _} = ApplyPatch.run(%{input: input}, ctx)
    refute File.exists?(Path.join(dir, "code.ex"))
  end

  test "parses without the Begin/End envelope", %{ctx: ctx, dir: dir} do
    input = "*** Update File: code.ex\n@@\n-def beta, do: 2\n+def beta, do: 99\n"

    assert {:ok, _} = ApplyPatch.run(%{input: input}, ctx)
    assert File.read!(Path.join(dir, "code.ex")) =~ "def beta, do: 99"
  end

  test "reports a clear error when a hunk does not match", %{ctx: ctx} do
    input =
      wrap("""
      *** Update File: code.ex
      @@
      -def nonexistent, do: 9
      +def nonexistent, do: 10
      """)

    assert {:error, msg} = ApplyPatch.run(%{input: input}, ctx)
    assert msg =~ "code.ex"
  end

  test "reports a parse error for non-patch input", %{ctx: ctx} do
    assert {:error, msg} = ApplyPatch.run(%{input: "just some prose, not a patch"}, ctx)
    assert msg =~ "patch"
  end
end
