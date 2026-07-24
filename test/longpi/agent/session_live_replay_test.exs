defmodule Longpi.Agent.SessionLiveReplayTest do
  # Behavior: a client that joins MID-TURN (refresh, second tab, mobile shell)
  # gets the streamed-so-far events from Session.live_events and can rebuild
  # the exact live view. The buffer folds deltas and clears when the turn ends.
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

  test "mid-turn joiners see folded text and tool events; the buffer clears at turn end",
       %{session: session} do
    test_pid = self()

    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "Let me "})
      sink.({:text_delta, "check that."})
      sink.({:tool_call, %{id: "t1", name: "bash", args: %{"command" => "ls"}}})
      sink.({:tool_output, %{id: "t1", chunk: "file-a\n"}})
      sink.({:tool_output, %{id: "t1", chunk: "file-b\n"}})
      sink.({:tool_result, %{call: %{id: "t1", name: "bash"}, content: "file-a\nfile-b\n", error?: false}})
      # Hold the turn open until the test has sampled the buffer.
      send(test_pid, {:streamed, self()})
      receive do
        :finish -> :ok
      end

      {:ok, %{text: "Let me check that. Done.", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "看看目录")
    assert_receive {:streamed, task_pid}, 3_000
    # Let the session drain the sink events from its mailbox.
    Process.sleep(50)

    # This is exactly what a fresh channel join replays — plus the seq
    # watermark that lets the client drop pushes already inside the replay.
    assert %{seq: seq, events: events} = Session.live_events(session)
    assert is_integer(seq) and seq > 0

    assert [
             %{type: "text_delta", text: "Let me check that."},
             %{type: "tool_call", id: "t1", name: "bash", args: %{"command" => "ls"}},
             %{type: "tool_output", id: "t1", chunk: "file-a\nfile-b\n"},
             %{type: "tool_result", id: "t1", name: "bash", content: "file-a\nfile-b\n", error: false}
           ] = events

    # Turn finishes → the buffer is gone (history carries the final truth).
    send(task_pid, :finish)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 3_000
    assert %{events: []} = Session.live_events(session)
  end

end
