defmodule Longpi.Agent.Tools.BashTest do
  use ExUnit.Case, async: false

  alias Longpi.Agent.Tools.Bash

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  setup %{tmp_dir: dir} do
    %{ctx: %{cwd: dir}}
  end

  test "returns command output", %{ctx: ctx} do
    assert {:ok, text} = Bash.run(%{command: "echo from-bash-tool"}, ctx)
    assert text =~ "from-bash-tool"
  end

  test "runs in the ctx cwd", %{tmp_dir: dir, ctx: ctx} do
    assert {:ok, text} = Bash.run(%{command: "pwd"}, ctx)
    assert text =~ Path.basename(dir)
  end

  test "notes non-zero exit codes", %{ctx: ctx} do
    assert {:ok, text} = Bash.run(%{command: "exit 3"}, ctx)
    assert text =~ "exit code: 3"
  end

  test "notes empty output", %{ctx: ctx} do
    assert {:ok, text} = Bash.run(%{command: "true"}, ctx)
    assert text =~ "no output"
  end

  test "kills and reports on timeout", %{ctx: ctx} do
    assert {:ok, text} = Bash.run(%{command: "sleep 30", timeout_ms: 300}, ctx)
    assert text =~ "timed out"
  end

  test "notes truncated output", %{ctx: ctx} do
    assert {:ok, text} =
             Bash.run(%{command: "yes trunc | head -c 500000", max_output_bytes: 32_768}, ctx)

    assert text =~ "truncated"
  end
end
