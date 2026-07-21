defmodule Longpi.Agent.ConversationTest do
  use Longpi.DataCase, async: true

  alias Longpi.Agent.ConversationMessage

  defp create_conversation! do
    Longpi.Agent.create_conversation!(%{cwd: "/tmp/ws", model: "test:model"})
  end

  test "creates a conversation with cwd and model" do
    conversation = create_conversation!()
    assert conversation.cwd == "/tmp/ws"
    assert conversation.model == "test:model"

    fetched = Longpi.Agent.get_conversation!(conversation.id)
    assert fetched.id == conversation.id
  end

  test "appends and lists messages ordered by position" do
    conversation = create_conversation!()

    for {content, position} <- [{"third", 2}, {"first", 0}, {"second", 1}] do
      Longpi.Agent.append_message!(%{
        conversation_id: conversation.id,
        role: :user,
        content: content,
        position: position
      })
    end

    contents = conversation.id |> Longpi.Agent.list_messages!() |> Enum.map(& &1.content)
    assert contents == ["first", "second", "third"]
  end

  test "destroying a conversation with messages removes the row AND its messages" do
    conversation = create_conversation!()

    for {content, position} <- Enum.with_index(["one", "two", "three"]) do
      Longpi.Agent.append_message!(%{
        conversation_id: conversation.id,
        role: :user,
        content: content,
        position: position
      })
    end

    assert Ash.count!(ConversationMessage) == 3

    # Regression: destroy used to fail (FK, no ON DELETE CASCADE) on any
    # conversation that had messages, leaving the row behind.
    Longpi.Agent.destroy_conversation!(conversation)

    assert {:error, %Ash.Error.Invalid{}} = Longpi.Agent.get_conversation(conversation.id)
    assert Ash.count!(Longpi.Agent.Conversation) == 0
    assert Ash.count!(ConversationMessage) == 0
  end

  test "destroying a conversation with zero messages still works" do
    conversation = create_conversation!()

    Longpi.Agent.destroy_conversation!(conversation)

    assert {:error, %Ash.Error.Invalid{}} = Longpi.Agent.get_conversation(conversation.id)
    assert Ash.count!(Longpi.Agent.Conversation) == 0
  end

  test "destroying a compacted conversation removes the row, messages AND compactions" do
    conversation = create_conversation!()

    Longpi.Agent.append_message!(%{
      conversation_id: conversation.id,
      role: :user,
      content: "hello",
      position: 0
    })

    Longpi.Agent.create_compaction!(%{
      conversation_id: conversation.id,
      summary: "summary so far",
      covered_through: 0,
      input_tokens: 1234
    })

    assert Ash.count!(Longpi.Agent.Compaction) == 1

    # Regression: compactions have their own non-cascading FK, so destroy failed
    # (and the row reappeared on refresh) for any auto-compacted conversation.
    Longpi.Agent.destroy_conversation!(conversation)

    assert Ash.count!(Longpi.Agent.Conversation) == 0
    assert Ash.count!(ConversationMessage) == 0
    assert Ash.count!(Longpi.Agent.Compaction) == 0
  end

  test "message maps roundtrip through persistence, including tool fields" do
    conversation = create_conversation!()
    call = %{id: "tc_9", name: "read", args: %{"path" => "f.txt"}}

    originals = [
      %{role: :user, content: "hi"},
      %{role: :assistant, content: "checking", tool_calls: [call]},
      %{role: :tool, tool_call_id: "tc_9", name: "read", content: "file body", error?: false},
      %{role: :assistant, content: "done", tool_calls: []}
    ]

    for {message, position} <- Enum.with_index(originals) do
      message
      |> ConversationMessage.from_message(conversation.id, position)
      |> Longpi.Agent.append_message!()
    end

    restored =
      conversation.id
      |> Longpi.Agent.list_messages!()
      |> Enum.map(&ConversationMessage.to_message/1)

    assert restored == originals
  end
end
