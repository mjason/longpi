defmodule LongpiWeb.SidebarChannelTest do
  # Wire contract: badge changes reach every sidebar as attention_changed —
  # the push path for users whose window never blurs.
  use LongpiWeb.ChannelCase, async: false

  import Mox

  alias Longpi.Agent.LLM.Mock, as: LLMMock
  alias Longpi.Agent.{Session, Sessions}

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  test "an unwatched settle pushes attention_changed (and it is JSON-safe)", %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    on_exit(fn -> Sessions.stop(conversation.id) end)

    {:ok, _, _socket} =
      LongpiWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(LongpiWeb.SidebarChannel, "sidebar:updates")

    expect(LLMMock, :stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)

    {:ok, session} = Sessions.ensure_started(conversation.id)
    :ok = Session.send_message(session, "[scheduled] work")

    conversation_id = conversation.id
    assert_push "attention_changed", %{id: ^conversation_id, kind: "done"} = payload, 3_000
    assert {:ok, _} = Jason.encode(payload)
  end
end
