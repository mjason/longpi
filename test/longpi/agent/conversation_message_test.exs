defmodule Longpi.Agent.ConversationMessageTest do
  use Longpi.DataCase, async: true

  alias Longpi.Agent.ConversationMessage

  defp create_conversation! do
    Longpi.Agent.create_conversation!(%{cwd: "/tmp/ws", model: "test:model"})
  end

  @image %{"type" => "image", "media_type" => "image/png", "data" => "AAAA", "name" => "s.png"}

  test "from_message/3 includes attachments from the message map" do
    attrs =
      ConversationMessage.from_message(
        %{role: :user, content: "hi", attachments: [@image]},
        "cid",
        0
      )

    assert attrs.attachments == [@image]
  end

  test "from_message/3 defaults attachments to [] when absent" do
    attrs = ConversationMessage.from_message(%{role: :user, content: "hi"}, "cid", 0)
    assert attrs.attachments == []
  end

  test "to_message/1 for a user record omits :attachments when empty" do
    record = %{role: :user, content: "hi", attachments: []}
    message = ConversationMessage.to_message(record)
    assert message == %{role: :user, content: "hi"}
    refute Map.has_key?(message, :attachments)
  end

  test "to_message/1 for a user record includes :attachments when present" do
    record = %{role: :user, content: "look", attachments: [@image]}

    assert ConversationMessage.to_message(record) ==
             %{role: :user, content: "look", attachments: [@image]}
  end

  test "to_message/1 scrubs invalid UTF-8 in stored content (all roles)" do
    bad = "page" <> <<0xE5>> <> "上海"
    refute String.valid?(bad)

    user = ConversationMessage.to_message(%{role: :user, content: bad, attachments: []})
    assert String.valid?(user.content)

    tool =
      ConversationMessage.to_message(%{
        role: :tool,
        content: bad,
        tool_call_id: "c1",
        tool_name: "bash",
        error: false
      })

    assert String.valid?(tool.content)
  end

  test "attachments survive a persist + reload cycle as string-keyed maps" do
    conversation = create_conversation!()

    %{role: :user, content: "with pic", attachments: [@image]}
    |> ConversationMessage.from_message(conversation.id, 0)
    |> Longpi.Agent.append_message!()

    [reloaded] = Longpi.Agent.list_messages!(conversation.id)

    assert [attachment] = reloaded.attachments
    assert is_map(attachment)
    assert attachment["type"] == "image"
    assert attachment["media_type"] == "image/png"
    assert attachment["data"] == "AAAA"
    # keys stay strings across the JSON roundtrip
    assert Enum.all?(Map.keys(attachment), &is_binary/1)

    # and to_message rebuilds the agent-loop map with attachments intact
    assert %{role: :user, content: "with pic", attachments: [^attachment]} =
             ConversationMessage.to_message(reloaded)
  end

  test "a persisted user message with no attachments round-trips without the key" do
    conversation = create_conversation!()

    %{role: :user, content: "plain"}
    |> ConversationMessage.from_message(conversation.id, 0)
    |> Longpi.Agent.append_message!()

    [reloaded] = Longpi.Agent.list_messages!(conversation.id)
    assert reloaded.attachments == []
    assert ConversationMessage.to_message(reloaded) == %{role: :user, content: "plain"}
  end
end
