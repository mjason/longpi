defmodule Longpi.Agent.SessionPersistenceTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.Session
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    %{conversation: conversation, dir: dir}
  end

  defp start_session(conversation) do
    {:ok, pid} =
      Session.start_link(llm: LLMMock, conversation_id: conversation.id, stream_to: self())

    pid
  end

  test "persists a completed turn and resumes it after restart", %{conversation: conversation} do
    session = start_session(conversation)

    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      {:ok, %{text: "first reply", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "hello")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    GenServer.stop(session)

    # Fresh process, same conversation: history must be rebuilt from the DB,
    # and the next LLM call must see it.
    resumed = start_session(conversation)
    roles = resumed |> Session.messages() |> Enum.map(& &1.role)
    assert roles == [:system, :user, :assistant]

    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      texts = Enum.map(messages, & &1[:content])
      assert "hello" in texts
      assert "first reply" in texts
      {:ok, %{text: "second reply", tool_calls: []}}
    end)

    :ok = Session.send_message(resumed, "and again")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    stored = Longpi.Agent.list_messages!(conversation.id)
    assert length(stored) == 4
  end

  test "session takes cwd and model from the conversation record", %{
    conversation: conversation,
    dir: dir
  } do
    session = start_session(conversation)

    expect(LLMMock, :stream, fn model, messages, _, _, _ ->
      assert model == "test:model"
      assert hd(messages).content =~ dir
      {:ok, %{text: "ok", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "tool calls and results survive a restart", %{conversation: conversation, dir: dir} do
    File.write!(Path.join(dir, "x.txt"), "tool-payload")
    session = start_session(conversation)
    call = %{id: "tc_p", name: "read", args: %{"path" => "x.txt"}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "saw it", tool_calls: []}} end)

    :ok = Session.send_message(session, "read x.txt")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    GenServer.stop(session)

    resumed = start_session(conversation)
    messages = Session.messages(resumed)

    assert %{role: :assistant, tool_calls: [%{id: "tc_p", name: "read"}]} =
             Enum.find(messages, &(&1[:tool_calls] not in [nil, []]))

    assert %{role: :tool, tool_call_id: "tc_p", content: content} =
             Enum.find(messages, &(&1.role == :tool))

    assert content =~ "tool-payload"
  end

  test "interrupt persists the partial assistant text", %{conversation: conversation} do
    session = start_session(conversation)

    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "half an answer"})
      Process.sleep(30_000)
      {:ok, %{text: "never", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "go")
    assert_receive {:agent_event, {:text_delta, _}}, 2_000
    :ok = Session.interrupt(session)
    assert_receive {:agent_event, {:turn_ended, :interrupted}}, 2_000

    stored = Longpi.Agent.list_messages!(conversation.id)

    assert [%{role: :user}, %{role: :assistant, content: "half an answer"}] =
             Enum.map(stored, &Map.take(&1, [:role, :content]))
  end

  test "failed turn still persists the user message", %{conversation: conversation} do
    session = start_session(conversation)
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:error, :boom} end)

    :ok = Session.send_message(session, "will fail")
    assert_receive {:agent_event, {:turn_failed, :boom}}, 2_000

    assert [%{role: :user, content: "will fail"}] =
             conversation.id
             |> Longpi.Agent.list_messages!()
             |> Enum.map(&Map.take(&1, [:role, :content]))
  end
end
