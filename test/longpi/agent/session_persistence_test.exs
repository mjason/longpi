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

    # The user message survives for a retry, and the persisted failure note
    # explains the silence to anyone who reloads.
    assert [%{role: :user, content: "will fail"}, %{role: :assistant, content: note}] =
             conversation.id
             |> Longpi.Agent.list_messages!()
             |> Enum.map(&Map.take(&1, [:role, :content]))

    assert note =~ "Turn failed"
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
    # Drain the first turn's convergence broadcast so the post-edit assertion
    # below matches the EDIT's history event, not this one.
    assert_receive {:agent_event, {:history, _first, _status1, _pending1}}, 2_000
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000

    # Edit: the LLM must see ONLY the replacement text, not the old wording.
    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      texts = Enum.map(messages, & &1[:content])
      assert "second wording" in texts
      refute "first wording" in texts
      {:ok, %{text: "new reply", tool_calls: []}}
    end)

    :ok = Session.edit_last(session, "second wording")

    # The history broadcast must ALREADY include the replacement message —
    # the edit flow has no optimistic client add, so broadcasting the
    # truncated list would make the message vanish from the UI.
    assert_receive {:agent_event, {:history, history, _status2, _pending2}}, 1_000
    assert Enum.any?(history, &(&1.content == "second wording"))

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

  test "a crashed run leaves the turn marker; resume continues from the checkpointed history",
       %{conversation: conversation} do
    session = start_session(conversation)

    # A turn that checkpoints one iteration and then dies hard (task crash —
    # the VM-restart case behaves the same: the marker survives in the DB).
    call = %{id: "rz1", name: "ls", args: %{}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> raise "gateway process died" end)

    :ok = Session.send_message(session, "long job")
    assert_receive {:agent_event, {:turn_failed, {:crashed, _}}}, 3_000
    # The DOWN handler clears the marker AFTER notifying — a sync call
    # guarantees it finished before we plant the crash-leftover marker below.
    :idle = Session.status(session)

    # Simulate the crash having killed the whole session BEFORE it could
    # clear the marker (a real crash/deploy skips clear_turn_inflight).
    {:ok, record} = Longpi.Agent.get_conversation(conversation.id)

    record
    |> Ash.Changeset.for_update(:set_turn_started, %{turn_started_at: DateTime.utc_now()})
    |> Ash.update!()

    GenServer.stop(session)

    # The fresh incarnation sees the leftover marker and offers resume.
    revived = start_session(conversation)
    assert Session.interrupted_turn?(revived)

    expect(LLMMock, :stream, fn _, messages, _, _, _ ->
      # The checkpointed iteration (assistant + tool result) IS the context.
      assert Enum.any?(messages, &(&1.role == :tool))
      {:ok, %{text: "picked up where we left off", tool_calls: []}}
    end)

    assert :ok = Session.resume(revived)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 3_000

    refute Session.interrupted_turn?(revived)
    # The marker is cleared once the resumed turn settles.
    {:ok, settled} = Longpi.Agent.get_conversation(conversation.id)
    assert settled.turn_started_at == nil

    GenServer.stop(revived)
  end

  test "resume with nothing to run refuses cleanly", %{conversation: conversation} do
    session = start_session(conversation)
    assert {:error, :nothing_to_resume} = Session.resume(session)
    GenServer.stop(session)
  end

  test "a subagent's bubbled approval flags the parent's badge", %{
    conversation: conversation
  } do
    session = start_session(conversation)

    # The child is excluded from badges (parent_session guard), so the
    # parent's bubble handler is the only place this can become visible.
    send(
      session,
      {:subagent_approval_request, Ecto.UUID.generate(), "scout",
       %{id: "sa1", name: "bash", args: %{"command" => "ls"}}}
    )

    :idle = Session.status(session)
    {:ok, flagged} = Longpi.Agent.get_conversation(conversation.id)
    assert flagged.unseen_kind == "approval"

    GenServer.stop(session)
  end

  test "closing the last watcher re-flags a still-pending approval", %{
    conversation: conversation
  } do
    session = start_session(conversation)

    watcher =
      spawn(fn ->
        receive do
          :die -> :ok
        end
      end)

    :ok = Session.watch(session, watcher)

    # Approval arrives WHILE watched → correctly no badge.
    :sys.replace_state(session, fn state ->
      %{state | pending_approvals: Map.put(state.pending_approvals, "w1", {self(), make_ref()})}
    end)

    {:ok, unflagged} = Longpi.Agent.get_conversation(conversation.id)
    assert unflagged.unseen_kind == nil

    # Tab closes without answering — the badge must appear now, or the
    # approval times out with zero traces anywhere. (The DOWN is async; the
    # status call after it serializes the handler.)
    send(watcher, :die)
    Process.sleep(20)
    :idle = Session.status(session)

    {:ok, reflagged} = Longpi.Agent.get_conversation(conversation.id)
    assert reflagged.unseen_kind == "approval"

    GenServer.stop(session)
  end

  test "badge writes do not bump updated_at (mobile list order is activity, not views)", %{
    conversation: conversation
  } do
    session = start_session(conversation)
    {:ok, before} = Longpi.Agent.get_conversation(conversation.id)

    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)
    :ok = Session.send_message(session, "[scheduled] work")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    :idle = Session.status(session)

    {:ok, flagged} = Longpi.Agent.get_conversation(conversation.id)
    assert flagged.unseen_kind == "done"
    # The marker/badge writes went through update_all — no timestamp churn.
    assert DateTime.compare(flagged.updated_at, before.updated_at) == :eq

    GenServer.stop(session)
  end

  test "stopping during a pending continuation clears the turn marker (no bogus resume)", %{
    conversation: conversation
  } do
    session = start_session(conversation)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(LLMMock, :stream, fn _, _, _, _, _ ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, %{status: 502, reason: "Bad Gateway"}}
        _ -> {:ok, %{text: "never reached", tool_calls: []}}
      end
    end)

    :ok = Session.send_message(session, "go")
    assert_receive {:agent_event, {:turn_retrying, _}}, 2_000

    # Mid-backoff (idle + retry pending) the user hits Stop: the marker must
    # come off — this run is deliberately settled, not crash-interrupted.
    :ok = Session.interrupt(session)
    :idle = Session.status(session)

    {:ok, settled} = Longpi.Agent.get_conversation(conversation.id)
    assert settled.turn_started_at == nil
    refute Session.interrupted_turn?(session)

    GenServer.stop(session)
  end

  test "an unwatched settle flags the unseen badge; watching clears it", %{
    conversation: conversation
  } do
    session = start_session(conversation)

    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      {:ok, %{text: "scheduled work done", tool_calls: []}}
    end)

    # Nobody is watching (no Session.watch) — the scheduled-task shape.
    :ok = Session.send_message(session, "[scheduled 0 23 * * *] do the thing")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    :idle = Session.status(session)

    {:ok, flagged} = Longpi.Agent.get_conversation(conversation.id)
    assert flagged.unseen_kind == "done"
    assert %DateTime{} = flagged.unseen_at

    # Opening the conversation (a channel joins → watch) clears the dot.
    # The clear is a self-message (off the join path) — the status call
    # serializes behind it before we read the row.
    :ok = Session.watch(session, self())
    :idle = Session.status(session)
    {:ok, seen} = Longpi.Agent.get_conversation(conversation.id)
    assert seen.unseen_kind == nil
    assert seen.unseen_at == nil

    # A WATCHED settle never flags — the user saw it live.
    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:ok, %{text: "seen live", tool_calls: []}} end)
    :ok = Session.send_message(session, "again")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    :idle = Session.status(session)

    {:ok, watched} = Longpi.Agent.get_conversation(conversation.id)
    assert watched.unseen_kind == nil

    GenServer.stop(session)
  end
end
