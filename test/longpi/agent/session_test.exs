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
    assert_receive {:agent_event, {:history, history}}, 2_000
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

  test "LLM failure emits turn_failed and returns to idle", %{session: session} do
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:error, :boom} end)

    assert :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_failed, :boom}}, 2_000
    assert Session.status(session) == :idle

    # The user message is kept so the turn can be retried
    assert %{role: :user, content: "hi"} = session |> Session.messages() |> List.last()
  end
end
