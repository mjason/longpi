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

  test "streams live output through ctx.progress", %{ctx: base} do
    test_pid = self()
    ctx = Map.put(base, :progress, fn chunk -> send(test_pid, {:chunk, chunk}) end)

    assert {:ok, text} = Bash.run(%{command: "printf 'alpha\\nbeta\\ngamma\\n'"}, ctx)

    streamed = collect_chunks()
    # The live stream carried the output before the final result was returned.
    assert streamed =~ "alpha"
    assert streamed =~ "gamma"
    assert text =~ "alpha"
  end

  test "the shell process tree dies when the owner (turn) is interrupted", %{tmp_dir: dir} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, pid} =
          Longpi.Shell.start("sleep 30", cwd: dir, stream_to: self(), ref: make_ref())

        send(parent, {:cmd, pid})
        Process.sleep(:infinity)
      end)

    cmd_pid =
      receive do
        {:cmd, p} -> p
      after
        5_000 -> flunk("shell command never started")
      end

    assert Process.alive?(cmd_pid)

    # Simulate an interrupt: the turn task dies. The command must follow.
    ref = Process.monitor(cmd_pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^cmd_pid, _reason}, 3_000
  end

  defp collect_chunks(acc \\ "") do
    receive do
      {:chunk, c} -> collect_chunks(acc <> c)
    after
      200 -> acc
    end
  end
end
