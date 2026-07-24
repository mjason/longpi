defmodule Longpi.Agent.MessageModelRoundtripTest do
  # The model attribution must survive persistence and the channel push —
  # otherwise a reload would lose "which model wrote this".
  use Longpi.DataCase, async: false

  alias Longpi.Agent.ConversationMessage

  test "an assistant message's model survives the DB round-trip" do
    conversation =
      Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

    message = Longpi.Agent.Message.assistant("cheap answer", [], "openai:mini")

    attrs = ConversationMessage.from_message(message, conversation.id, 0)
    record = Longpi.Agent.append_message!(attrs)

    assert %{role: :assistant, content: "cheap answer", model: "openai:mini"} =
             ConversationMessage.to_message(record)
  end

  test "messages without a model stay nil (older rows, user/tool messages)" do
    conversation =
      Longpi.Agent.create_conversation!(%{cwd: System.tmp_dir!(), model: "test:model"})

    attrs = ConversationMessage.from_message(%{role: :user, content: "hi"}, conversation.id, 0)
    record = Longpi.Agent.append_message!(attrs)
    refute Map.has_key?(ConversationMessage.to_message(record), :model)
  end
end
