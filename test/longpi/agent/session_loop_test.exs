defmodule Longpi.Agent.SessionLoopTest do
  use ExUnit.Case, async: false

  import Mox

  alias Longpi.Agent.Session
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    session =
      start_supervised!({Session, llm: LLMMock, model: "test:model", cwd: dir, stream_to: self()})

    %{session: session}
  end

  defp await_idle(session) do
    assert_receive {:agent_event, {:turn_ended, _}}, 3_000
    # The continuation fires via the session's own mailbox; give it a beat.
    Process.sleep(50)
    Session.status(session)
  end

  test "an explicit loop re-feeds the task until LOOP_DONE", %{session: session} do
    # Turn 1: not done yet. Turn 2: declares completion.
    expect(LLMMock, :stream, 2, fn _, messages, _, _, _sink ->
      loop_turns =
        Enum.count(messages, fn
          %{role: :user, content: content} -> is_binary(content) and content =~ "[loop "
          _ -> false
        end)

      if loop_turns >= 2 do
        # The marker must stand on its own line (see settle_loop).
        {:ok, %{text: "All finished.\nLOOP_DONE", tool_calls: []}}
      else
        {:ok, %{text: "made some progress", tool_calls: []}}
      end
    end)

    assert {:ok, 5} = Session.start_loop(session, "polish the README", 5)

    # Turn 1 completes, loop injects turn 2, which declares LOOP_DONE.
    await_idle(session)
    await_idle(session)
    Process.sleep(100)

    assert Session.loop_status(session) == nil

    user_texts =
      session
      |> Session.messages()
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(& &1.content)

    assert Enum.count(user_texts, &(&1 =~ "[loop ")) == 2
    assert hd(user_texts) =~ "polish the README"
  end

  test "the loop stops when iterations run out", %{session: session} do
    expect(LLMMock, :stream, 2, fn _, _, _, _, _sink ->
      {:ok, %{text: "still going", tool_calls: []}}
    end)

    assert {:ok, 2} = Session.start_loop(session, "endless task", 2)

    await_idle(session)
    await_idle(session)
    Process.sleep(100)

    assert Session.loop_status(session) == nil
    assert Session.status(session) == :idle
  end

  test "/loop stop clears the loop", %{session: session} do
    # stub (not expect): the next self-continued turn may already be in flight
    # when stop arrives — stopping prevents FURTHER turns, it doesn't abort one.
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      {:ok, %{text: "working", tool_calls: []}}
    end)

    assert {:ok, 10} = Session.start_loop(session, "long task", 10)
    assert_receive {:agent_event, {:turn_ended, _}}, 3_000

    assert {:ok, true} = Session.stop_loop(session)
    assert Session.loop_status(session) == nil
  end

  test "a timed loop waits the interval between turns", %{session: session} do
    expect(LLMMock, :stream, 2, fn _, _, _, _, _sink ->
      {:ok, %{text: "checked", tool_calls: []}}
    end)

    # 150ms interval: turn 1 runs immediately; turn 2 only after the wait.
    assert {:ok, 2} = Session.start_loop(session, "poll the queue", 2, 150)

    assert_receive {:agent_event, {:turn_ended, _}}, 3_000
    t1 = System.monotonic_time(:millisecond)

    # Second turn must not start before the interval has passed.
    assert_receive {:agent_event, {:turn_ended, _}}, 3_000
    assert System.monotonic_time(:millisecond) - t1 >= 140

    Process.sleep(50)
    assert Session.status(session) == :idle
  end

  test "delayed continue_later parses human intervals" do
    alias Longpi.Agent.Tools.ContinueLater

    assert {:ok, 30_000} = ContinueLater.parse_delay("30s")
    assert {:ok, 600_000} = ContinueLater.parse_delay("10m")
    assert {:ok, 7_200_000} = ContinueLater.parse_delay("2h")
    assert {:ok, 90_000} = ContinueLater.parse_delay("90")
    assert {:ok, 0} = ContinueLater.parse_delay(nil)
    # Capped at 24h.
    assert {:ok, 86_400_000} = ContinueLater.parse_delay("48h")
    assert {:error, _} = ContinueLater.parse_delay("soon")
  end

  # ── Safety behaviors (the loop must never run away or fight the user) ──

  test "a failed turn stops the loop instead of retrying into the failure", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:error, :boom} end)

    assert {:ok, 5} = Session.start_loop(session, "doomed task", 5)
    assert_receive {:agent_event, {:turn_failed, :boom}}, 3_000
    Process.sleep(50)

    assert Session.loop_status(session) == nil
    assert Session.status(session) == :idle
  end

  test "interrupt stops the loop (the user takes the wheel)", %{session: session} do
    # A slow turn so the interrupt lands mid-flight.
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      Process.sleep(500)
      {:ok, %{text: "slow work", tool_calls: []}}
    end)

    assert {:ok, 10} = Session.start_loop(session, "long task", 10)
    wait_for(fn -> Session.status(session) == :running end)

    assert :ok = Session.interrupt(session)
    assert Session.loop_status(session) == nil
    assert Session.status(session) == :idle
  end

  test "a stray continue_now during a running turn injects nothing", %{session: session} do
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      Process.sleep(300)
      {:ok, %{text: "busy", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "work on it")
    wait_for(fn -> Session.status(session) == :running end)

    before = length(Session.messages(session))
    send(session, :continue_now)
    Process.sleep(50)

    # Still exactly the same messages — no self-driven injection mid-turn.
    assert length(Session.messages(session)) == before
  end

  test "a crashed turn clears the loop too (no unreapable stranded state)", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, _ -> raise "tool exploded" end)

    assert {:ok, 5} = Session.start_loop(session, "doomed", 5)
    assert_receive {:agent_event, {:turn_failed, {:crashed, _}}}, 3_000
    Process.sleep(50)

    assert Session.loop_status(session) == nil
    assert Session.status(session) == :idle
  end

  test "mentioning LOOP_DONE mid-sentence does not end the loop; its own line does", %{
    session: session
  } do
    expect(LLMMock, :stream, 2, fn _, messages, _, _, _sink ->
      loop_turns =
        Enum.count(messages, fn
          %{role: :user, content: c} -> is_binary(c) and c =~ "[loop "
          _ -> false
        end)

      if loop_turns >= 2 do
        {:ok, %{text: "Everything passes now.\nLOOP_DONE", tool_calls: []}}
      else
        # The marker appears mid-sentence — must NOT terminate the loop.
        {:ok, %{text: "Not finished; I will reply LOOP_DONE when it's all green.", tool_calls: []}}
      end
    end)

    assert {:ok, 5} = Session.start_loop(session, "fix the tests", 5)

    # Final state proves both directions: exactly TWO assistant turns means the
    # mid-sentence mention did NOT stop the loop (a second turn ran), and the
    # own-line marker DID stop it (no third turn ever started).
    wait_for(fn -> Session.loop_status(session) == nil and Session.status(session) == :idle end)
    Process.sleep(100)

    assistant_count =
      session |> Session.messages() |> Enum.count(&(&1.role == :assistant))

    assert assistant_count == 2
    assert Session.loop_status(session) == nil
  end

  test "interrupt during a timed loop's idle wait cancels the pending wake-up", %{
    session: session
  } do
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      {:ok, %{text: "polled", tool_calls: []}}
    end)

    # Long interval: after turn 1 the session idles with a pending timer.
    assert {:ok, 5} = Session.start_loop(session, "poll something", 5, 60_000)
    assert_receive {:agent_event, {:turn_ended, _}}, 3_000
    Process.sleep(50)
    assert Session.loop_status(session) != nil

    assert :ok = Session.interrupt(session)
    assert Session.loop_status(session) == nil
  end

  test "running out of iterations announces loop_ended", %{session: session} do
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      {:ok, %{text: "never done", tool_calls: []}}
    end)

    assert {:ok, 1} = Session.start_loop(session, "one shot", 1)
    assert_receive {:agent_event, {:turn_ended, _}}, 3_000
    assert_receive {:agent_event, {:loop_ended, :exhausted}}, 2_000
  end

  test "the auto-turn fuse halts a loop that never declares done", %{session: session} do
    stub(LLMMock, :stream, fn _, _, _, _, _sink ->
      {:ok, %{text: "still going, never done", tool_calls: []}}
    end)

    # 50 requested iterations > the 30-turn fuse: the fuse must win.
    assert {:ok, 50} = Session.start_loop(session, "endless", 50)

    # Drain turn_ended events until the fuse trips and the loop dies.
    wait_for(
      fn ->
        # Drain the mailbox so it doesn't overflow assert_receive patterns.
        receive do
          {:agent_event, _} -> nil
        after
          0 -> nil
        end

        Session.loop_status(session) == nil and Session.status(session) == :idle
      end,
      400
    )

    loop_marks =
      session
      |> Session.messages()
      |> Enum.count(fn
        %{role: :user, content: content} -> is_binary(content) and content =~ "[loop "
        _ -> false
      end)

    # The fuse (30 consecutive self-driven turns) capped it below the asked-for 50.
    assert loop_marks == 30
  end

  defp wait_for(fun, tries \\ 60) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(50)
        wait_for(fun, tries - 1)
    end
  end

  test "continue_later schedules exactly one self-driven follow-up turn", %{session: session} do
    # Turn 1 schedules a continuation via the session call (as the tool would);
    # turn 2 is the injected wake-up and schedules nothing.
    expect(LLMMock, :stream, 2, fn _, messages, _, _, _sink ->
      last = List.last(messages)

      if is_binary(last.content) and last.content =~ "[auto-continue" do
        {:ok, %{text: "picked up where I left off", tool_calls: []}}
      else
        {:ok, %{text: "big task, splitting", tool_calls: []}}
      end
    end)

    assert :ok = Session.send_message(session, "do something huge")
    assert :ok = GenServer.call(session, {:schedule_continuation, "continue step 2 of 3", 0})

    await_idle(session)
    await_idle(session)
    Process.sleep(100)

    user_texts =
      session
      |> Session.messages()
      |> Enum.filter(&(&1.role == :user))
      |> Enum.map(& &1.content)

    assert [_, auto] = user_texts
    assert auto =~ "[auto-continue 1]"
    assert auto =~ "continue step 2 of 3"
    assert Session.status(session) == :idle
  end
end
