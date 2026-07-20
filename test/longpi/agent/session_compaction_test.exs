defmodule Longpi.Agent.SessionCompactionTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.{ContextWindow, Session, Settings}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  # A long message so the older turn exceeds keep_tokens (window*0.3 = 30).
  @long_msg String.duplicate("word ", 40)

  setup %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    # Small window: keep_tokens = 30, threshold = 80.
    Longpi.Agent.create_model!(%{spec: "test:model", context_window: 100})
    Settings.put("compaction_ratio", "0.8")

    {:ok, session} =
      Session.start_link(llm: LLMMock, conversation_id: conversation.id, stream_to: self())

    %{session: session, conversation: conversation}
  end

  test "compacts after a turn crosses the threshold and shrinks the LLM context", %{
    session: session,
    conversation: conversation
  } do
    # First turn: report high usage (over 80 threshold) so compaction triggers.
    expect(LLMMock, :stream, fn _model, _messages, _tools, _opts, sink ->
      sink.({:usage, %{input_tokens: 900}})
      {:ok, %{text: "first reply", tool_calls: []}}
    end)

    # Compaction summarization call.
    expect(LLMMock, :stream, fn _model, messages, [], [], _sink ->
      assert Enum.any?(messages, &(&1[:content] == @long_msg))
      {:ok, %{text: "## Goal\ncompacted summary", tool_calls: []}}
    end)

    :ok = Session.send_message(session, @long_msg)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    assert_receive {:agent_event, {:compaction_started}}, 2_000
    assert_receive {:agent_event, {:compacted, %{covered_through: covered}}}, 2_000
    assert covered >= 1

    # A checkpoint row was written; original messages are untouched.
    assert {:ok, [%{summary: summary}]} = Longpi.Agent.latest_compaction(conversation.id)
    assert summary =~ "compacted summary"
    assert length(Longpi.Agent.list_messages!(conversation.id)) == 2

    # Next turn must see the compacted context: a summary message, not the long one.
    expect(LLMMock, :stream, fn _model, messages, _tools, _opts, _sink ->
      contents = Enum.map(messages, & &1[:content])
      assert Enum.any?(contents, &(&1 && String.contains?(&1, "compacted summary")))
      refute Enum.any?(contents, &(&1 == @long_msg))
      {:ok, %{text: "second reply", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "again")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "does not compact below the threshold", %{session: session, conversation: conversation} do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:usage, %{input_tokens: 100}})
      {:ok, %{text: "reply", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "hi")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    refute_received {:agent_event, {:compaction_started}}
    assert Longpi.Agent.latest_compaction(conversation.id) == {:ok, []}
  end

  test "summarization failure falls back to a truncation checkpoint", %{
    session: session,
    conversation: conversation
  } do
    LLMMock
    |> expect(:stream, fn _, _, _, _, sink ->
      sink.({:usage, %{input_tokens: 900}})
      {:ok, %{text: "reply", tool_calls: []}}
    end)
    |> expect(:stream, fn _, _, _, _, _ -> {:error, :summarizer_down} end)

    :ok = Session.send_message(session, @long_msg)
    assert_receive {:agent_event, {:compacted, %{covered_through: _}}}, 2_000

    assert {:ok, [%{summary: summary}]} = Longpi.Agent.latest_compaction(conversation.id)
    assert summary =~ "dropped to fit"
  end

  test "a resumed session loads the latest compaction", %{conversation: conversation} do
    Longpi.Agent.create_compaction!(%{
      conversation_id: conversation.id,
      summary: "prior summary",
      covered_through: 5
    })

    {:ok, session} = Session.start_link(llm: LLMMock, conversation_id: conversation.id)
    assert :sys.get_state(session).compaction == %{summary: "prior summary", covered_through: 5}
  end

  test "context_window resolution: metadata for known model", %{conversation: _c} do
    assert ContextWindow.for_model("openai:gpt-4o") == 128_000
  end
end
