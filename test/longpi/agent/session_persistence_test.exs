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

  test "session uses the conversation's system_prompt override", %{dir: dir} do
    conversation =
      Longpi.Agent.create_conversation!(%{
        cwd: dir,
        model: "test:model",
        system_prompt: "Be terse. Workspace: {{cwd}}"
      })

    session = start_session(conversation)

    expect(LLMMock, :stream, fn _model, messages, _, _, _ ->
      system = hd(messages)
      assert system.role == :system
      assert system.content == "Be terse. Workspace: #{dir}"
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

  test "regenerate drops the last reply and re-runs the turn", %{conversation: conversation} do
    session = start_session(conversation)

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "first answer", tool_calls: []}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      # The regenerated turn must NOT include the dropped assistant reply.
      texts = Enum.map(messages, & &1[:content])
      assert "hello" in texts
      refute "first answer" in texts
      {:ok, %{text: "second answer", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "hello")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    :ok = Session.regenerate(session)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    roles = session |> Session.messages() |> Enum.map(& &1.role)
    assert roles == [:system, :user, :assistant]

    stored = Longpi.Agent.list_messages!(conversation.id)

    assert [%{role: :user, content: "hello"}, %{role: :assistant, content: "second answer"}] =
             Enum.map(stored, &Map.take(&1, [:role, :content]))
  end

  test "regenerate with no messages is a no-op error", %{conversation: conversation} do
    session = start_session(conversation)
    assert {:error, :nothing_to_regenerate} = Session.regenerate(session)
  end

  test "/rename persists the title, broadcasts it, and beats auto-title",
       %{conversation: conversation} do
    session = start_session(conversation)

    assert {:ok, "部署调优"} = Session.rename(session, "  部署调优  ")
    assert_receive {:agent_event, {:titled, "部署调优"}}, 1_000

    # Persisted for the sidebar / next load.
    assert Longpi.Agent.get_conversation!(conversation.id).title == "部署调优"

    # Empty titles are rejected.
    assert {:error, :empty} = Session.rename(session, "   ")

    GenServer.stop(session)
  end


  test "edit_last replaces the last user message and re-runs", %{conversation: conversation} do
    session = start_session(conversation)

    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      {:ok, %{text: "old reply", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "first wording")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    # Edit: the LLM must see ONLY the replacement text, not the old wording.
    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      texts = Enum.map(messages, & &1[:content])
      assert "second wording" in texts
      refute "first wording" in texts
      {:ok, %{text: "new reply", tool_calls: []}}
    end)

    :ok = Session.edit_last(session, "second wording")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    # Persisted history holds exactly the edited turn.
    contents =
      conversation.id |> Longpi.Agent.list_messages!() |> Enum.map(& &1.content)

    assert "second wording" in contents
    assert "new reply" in contents
    refute "first wording" in contents
    refute "old reply" in contents

    GenServer.stop(session)
  end

  test "edit_last with no user message errors", %{conversation: conversation} do
    session = start_session(conversation)
    assert {:error, :nothing_to_edit} = Session.edit_last(session, "anything")
    GenServer.stop(session)
  end

end
