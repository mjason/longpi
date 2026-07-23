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
        {:ok, %{text: "All finished. LOOP_DONE", tool_calls: []}}
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
    assert :ok = GenServer.call(session, {:schedule_continuation, "continue step 2 of 3"})

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
