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
