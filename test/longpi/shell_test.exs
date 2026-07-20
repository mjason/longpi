defmodule Longpi.ShellTest do
  use ExUnit.Case, async: false

  alias Longpi.Shell
  alias Longpi.Shell.{Command, Result}

  @moduletag timeout: 30_000

  defp tmp_path do
    dir = System.tmp_dir!()
    Path.join(dir, "longpi_shell_test_#{System.unique_integer([:positive])}")
  end

  defp os_process_alive?(pid) when is_integer(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  describe "basic execution" do
    test "captures output and zero exit code" do
      assert {:ok, %Result{} = result} = Shell.run("echo hello")
      assert result.exit_code == 0
      assert result.output =~ "hello"
      assert result.timed_out? == false
      assert result.dropped_bytes == 0
    end

    test "reports non-zero exit codes" do
      assert {:ok, result} = Shell.run("exit 42")
      assert result.exit_code == 42
    end

    test "respects :cwd" do
      assert {:ok, result} = Shell.run("pwd", cwd: "/tmp")
      assert result.output =~ "/tmp"
    end

    test "passes :env" do
      assert {:ok, result} =
               Shell.run("echo $LONGPI_TEST_VAR", env: %{"LONGPI_TEST_VAR" => "marker42"})

      assert result.output =~ "marker42"
    end

    test "merges stderr into the PTY stream" do
      assert {:ok, result} = Shell.run("echo oops 1>&2")
      assert result.output =~ "oops"
    end

    test "runs under a real TTY" do
      assert {:ok, result} = Shell.run("test -t 1 && echo is-a-tty")
      assert result.output =~ "is-a-tty"
    end
  end

  describe "streaming" do
    test "delivers output chunks and exit to :stream_to" do
      ref = make_ref()
      {:ok, pid} = Shell.start("echo streamed; sleep 0.1", stream_to: self(), ref: ref)

      assert_receive {:shell_output, ^ref, chunk}, 5_000
      assert chunk =~ "streamed"
      assert_receive {:shell_exit, ^ref, %Result{exit_code: 0}}, 5_000
      assert {:ok, %Result{}} = Command.await(pid)
    end
  end

  describe "timeout and kill" do
    test "kills a command on timeout" do
      started = System.monotonic_time(:millisecond)
      assert {:ok, result} = Shell.run("sleep 30", timeout_ms: 300)
      elapsed = System.monotonic_time(:millisecond) - started

      assert result.timed_out? == true
      assert elapsed < 10_000
    end

    test "kills the whole process tree, including grandchildren" do
      pid_file = tmp_path()

      # bash (child) spawns sleep (grandchild) and writes its OS pid to a file
      {:ok, result} =
        Shell.run("sleep 30 & echo $! > #{pid_file}; wait", timeout_ms: 500)

      assert result.timed_out?

      grandchild_pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
      # Give signal delivery a moment
      Process.sleep(200)
      refute os_process_alive?(grandchild_pid), "grandchild sleep survived the tree kill"
      File.rm(pid_file)
    end

    test "explicit kill/1 terminates a running command" do
      ref = make_ref()
      {:ok, pid} = Shell.start("sleep 30", stream_to: self(), ref: ref)
      Command.kill(pid)
      assert_receive {:shell_exit, ^ref, %Result{}}, 10_000
    end

    test "closing the port (BEAM-side death) reaps the tree via the lifeline" do
      pid_file = tmp_path()
      {:ok, pid} = Shell.start("sleep 30 & echo $! > #{pid_file}; wait")

      # Wait until the grandchild pid file exists
      wait_until(fn -> File.exists?(pid_file) end, 5_000)
      grandchild_pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
      assert os_process_alive?(grandchild_pid)

      # Brutally kill the GenServer - terminate/2 closes the Port, the shim's
      # stdin lifeline must take the tree down.
      Process.exit(pid, :kill)

      wait_until(fn -> not os_process_alive?(grandchild_pid) end, 10_000)
      refute os_process_alive?(grandchild_pid), "tree survived BEAM-side kill"
      File.rm(pid_file)
    end
  end

  describe "output limits" do
    test "truncates huge output, keeps head and tail, reports drop count" do
      # ~1MB of output with a 64KB head limit
      {:ok, result} =
        Shell.run("yes 0123456789 | head -c 1000000", max_output_bytes: 64 * 1024)

      assert result.exit_code == 0
      assert result.dropped_bytes > 0
      assert byte_size(result.output) <= 64 * 1024 + 16 * 1024
      assert is_binary(result.tail) and byte_size(result.tail) > 0
    end

    test "small output is never truncated" do
      {:ok, result} = Shell.run("echo compact", max_output_bytes: 64 * 1024)
      assert result.dropped_bytes == 0
      assert result.tail == nil
    end
  end

  describe "stdin" do
    test "send_input/2 reaches the command through the PTY" do
      ref = make_ref()
      {:ok, pid} = Shell.start("read line; echo got:$line", stream_to: self(), ref: ref)
      Command.send_input(pid, "ping\n")
      assert_receive {:shell_exit, ^ref, %Result{} = result}, 10_000
      assert result.output =~ "got:ping"
    end
  end

  describe "error paths" do
    test "await after completion still returns the result" do
      {:ok, pid} = Shell.start("echo done")
      Process.sleep(500)
      assert {:ok, %Result{exit_code: 0}} = Command.await(pid)
    end

    test "utf8 and binary output survive framing" do
      {:ok, result} = Shell.run("printf '中文✓\\n'; printf '\\x00\\x01\\x02'")
      assert result.output =~ "中文✓"
    end
  end

  defp wait_until(fun, timeout_ms, interval \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      cond do
        fun.() -> :done
        System.monotonic_time(:millisecond) > deadline -> :timeout
        true -> Process.sleep(interval) && :continue
      end
    end)
    |> Enum.find(&(&1 != :continue))
  end
end
