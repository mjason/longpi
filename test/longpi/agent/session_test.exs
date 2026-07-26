defmodule Longpi.Agent.SessionTest do
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

  test "runs a turn, streams events, and stores messages", %{session: session} do
    expect(LLMMock, :stream, fn _, messages, _, _, sink ->
      # First message is the system prompt, then the user message
      assert [%{role: :system} | _] = messages
      sink.({:text_delta, "hel"})
      sink.({:text_delta, "lo"})
      {:ok, %{text: "hello", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "hi")

    assert_receive {:agent_event, {:text_delta, "hel"}}
    assert_receive {:agent_event, {:text_delta, "lo"}}
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    assert Session.status(session) == :idle
    roles = session |> Session.messages() |> Enum.map(& &1.role)
    assert roles == [:system, :user, :assistant]
  end

  test "a completed turn broadcasts committed history before turn_ended (refresh-safe)", %{
    session: session
  } do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "answer"})
      {:ok, %{text: "answer", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "q")

    # The committed messages are broadcast (so a client that missed the deltas
    # can converge) and — crucially — BEFORE turn_ended, which flips to idle.
    assert_receive {:agent_event, {:history, history, _status, _pending}}, 2_000
    assert Enum.map(history, & &1.role) == [:user, :assistant]
    assert Enum.find(history, &(&1.role == :assistant)).content == "answer"
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "send_message/3 passes user attachments through to the LLM client", %{session: session} do
    test_pid = self()
    image = %{"type" => "image", "media_type" => "image/png", "data" => "AAAA", "name" => "s.png"}

    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      send(test_pid, {:captured, messages})
      {:ok, %{text: "seen", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "describe this", [image])
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    assert_received {:captured, messages}
    user = Enum.find(messages, &(&1.role == :user))
    assert user.content == "describe this"
    assert user.attachments == [image]
  end

  test "send_message/2 (no attachments) carries no :attachments key", %{session: session} do
    test_pid = self()

    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      send(test_pid, {:captured, messages})
      {:ok, %{text: "ok", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "plain")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    assert_received {:captured, messages}
    user = Enum.find(messages, &(&1.role == :user))
    refute Map.has_key?(user, :attachments)
  end

  test "rejects a message while a turn is running", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      Process.sleep(500)
      {:ok, %{text: "slow", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "first")
    assert {:error, :busy} = Session.send_message(session, "second")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "interrupt kills the turn and keeps partial text", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "partial answer"})
      Process.sleep(30_000)
      {:ok, %{text: "never", tool_calls: []}}
    end)

    assert :ok = Session.send_message(session, "long task")
    assert_receive {:agent_event, {:text_delta, "partial answer"}}, 2_000

    assert :ok = Session.interrupt(session)
    assert_receive {:agent_event, {:turn_ended, :interrupted}}, 2_000

    assert Session.status(session) == :idle
    last = session |> Session.messages() |> List.last()
    assert last.role == :assistant
    assert last.content =~ "partial answer"
  end

  test "interrupt when idle is a no-op", %{session: session} do
    assert :ok = Session.interrupt(session)
    assert Session.status(session) == :idle
  end

  test "the iteration checkpoint resets partial/live — no double text after an interrupt", %{
    session: session
  } do
    # Iteration 1: streams text AND calls a tool (the common tool_use shape);
    # iteration 2: streams more text, then hangs until interrupted.
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    call = %{id: "cp1", name: "ls", args: %{}}

    stub(LLMMock, :stream, fn _, _, _, _, sink ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          sink.({:text_delta, "iteration one text"})
          {:ok, %{text: "iteration one text", tool_calls: [call]}}

        _ ->
          sink.({:text_delta, "iteration two"})
          Process.sleep(30_000)
          {:ok, %{text: "never", tool_calls: []}}
      end
    end)

    assert :ok = Session.send_message(session, "go")
    assert_receive {:agent_event, {:text_delta, "iteration two"}}, 3_000
    # Let the checkpoint (sent before iteration 2's stream) settle.
    Process.sleep(50)

    # The live replay buffer restarted at the checkpoint: a mid-turn joiner
    # gets iteration 1 from HISTORY, so live must only carry iteration 2.
    %{events: live} = Session.live_events(session)
    refute Enum.any?(live, fn e -> e[:text] == "iteration one text" or e[:id] == "cp1" end)

    assert :ok = Session.interrupt(session)
    assert_receive {:agent_event, {:turn_ended, :interrupted}}, 2_000

    texts =
      session
      |> Session.messages()
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.map(& &1.content)

    # Iteration 1's text was checkpointed ONCE; the crash-recovery partial
    # holds only iteration 2 — no duplicate, no out-of-order re-persist.
    assert Enum.count(texts, &(&1 =~ "iteration one text")) == 1
    assert Enum.any?(texts, &(&1 == "iteration two"))
  end

  test "LLM failure emits turn_failed and returns to idle", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:error, :boom} end)

    assert :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_failed, :boom}}, 2_000
    assert Session.status(session) == :idle

    # The user message is kept so the turn can be retried, and a persisted
    # failure note follows it — a reload must show WHY nothing answered.
    assert [%{role: :user, content: "hi"}, %{role: :assistant, content: note}] =
             session |> Session.messages() |> Enum.take(-2)

    assert note =~ "Turn failed"
    assert note =~ "boom"
  end

  test "API failures persist a human-readable note, not an inspect dump", %{session: session} do
    # 401 is a dead-end (a retry can't fix credentials), so the note lands
    # immediately — transient failures retry silently first instead.
    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      {:error, %{status: 401, reason: "invalid api key"}}
    end)

    assert :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_failed, _}}, 2_000

    %{content: note} = session |> Session.messages() |> List.last()
    assert note == "⚠ Turn failed: upstream 401: invalid api key"
  end

  test "a transport-close failure humanizes to a plain message (not a struct dump)", %{
    session: session
  } do
    # A mid-stream gateway drop, as req_llm surfaces it — retries silently,
    # then on give-up the persisted note must read cleanly, never the raw
    # %Finch.TransportError{...} inspect.
    stub(LLMMock, :stream, fn _, _, _, _, _ ->
      {:error, %Finch.TransportError{reason: :closed, source: %Mint.TransportError{reason: :closed}}}
    end)

    assert :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_failed, _}}, 5_000

    %{content: note} = session |> Session.messages() |> List.last()
    assert note == "⚠ Turn failed: the model gateway dropped the connection"
    refute note =~ "TransportError"
  end

  test "a transient failure emits turn_retrying (countdown), not turn_failed", %{
    session: session
  } do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(LLMMock, :stream, fn _, _, _, _, _ ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, %{status: 502, reason: "Bad Gateway"}}
        _ -> {:ok, %{text: "back", tool_calls: []}}
      end
    end)

    assert :ok = Session.send_message(session, "hi")

    assert_receive {:agent_event, {:turn_retrying, retrying}}, 2_000
    assert %{attempt: 1, max: 3, delay_ms: delay} = retrying
    assert is_integer(delay)
    refute_received {:agent_event, {:turn_failed, _}}

    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end
end
