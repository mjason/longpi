defmodule LongpiWeb.ConversationChannelTest do
  use LongpiWeb.ChannelCase, async: false

  import Mox

  alias Longpi.Agent.LLM.Mock, as: LLMMock
  alias Longpi.Agent.Sessions

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    on_exit(fn -> Sessions.stop(conversation.id) end)

    {:ok, _, socket} =
      LongpiWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(LongpiWeb.ConversationChannel, "conversation:#{conversation.id}")

    %{socket: socket, conversation: conversation}
  end

  test "join replies with existing history", %{conversation: conversation, socket: socket} do
    Process.unlink(socket.channel_pid)
    leave(socket)

    Longpi.Agent.append_message!(%{
      conversation_id: conversation.id,
      role: :user,
      content: "old message",
      position: 0
    })

    # Session already running without the seeded message - restart it
    Sessions.stop(conversation.id)

    {:ok, reply, _socket} =
      LongpiWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(LongpiWeb.ConversationChannel, "conversation:#{conversation.id}")

    assert %{messages: [%{role: :user, content: "old message"}], status: :idle} = reply
  end

  test "send_message streams deltas and completion to the client", %{socket: socket} do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "streaming"})
      {:ok, %{text: "streaming", tool_calls: []}}
    end)

    ref = push(socket, "send_message", %{"text" => "hello"})
    assert_reply ref, :ok

    assert_push "text_delta", %{text: "streaming"}
    assert_push "turn_ended", %{reason: "complete"}
  end

  test "usage is pushed as context_usage against the model's window", %{socket: socket} do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:usage, %{input_tokens: 4200}})
      {:ok, %{text: "ok", tool_calls: []}}
    end)

    ref = push(socket, "send_message", %{"text" => "hi"})
    assert_reply ref, :ok

    assert_push "context_usage", %{used: 4200, window: window}
    assert is_integer(window) and window > 0
  end

  test "join reply carries the current context usage", %{conversation: conversation} do
    {:ok, reply, _socket} =
      LongpiWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(LongpiWeb.ConversationChannel, "conversation:#{conversation.id}")

    assert %{context_usage: %{used: nil, window: window}} = reply
    assert is_integer(window) and window > 0
  end

  test "tool activity is pushed to the client", %{socket: socket, conversation: conversation} do
    File.write!(Path.join(conversation.cwd, "f.txt"), "channel-sees-this")
    call = %{id: "tc_ch", name: "read", args: %{"path" => "f.txt"}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)

    ref = push(socket, "send_message", %{"text" => "read it"})
    assert_reply ref, :ok

    assert_push "tool_call", %{id: "tc_ch", name: "read"}
    assert_push "tool_result", %{id: "tc_ch", error: false, content: content}
    assert content =~ "channel-sees-this"
    assert_push "turn_ended", %{reason: "complete"}
  end

  test "send_message while busy replies with an error", %{socket: socket} do
    expect(LLMMock, :stream, fn _, _, _, _, _ ->
      Process.sleep(400)
      {:ok, %{text: "slow", tool_calls: []}}
    end)

    ref1 = push(socket, "send_message", %{"text" => "first"})
    assert_reply ref1, :ok

    ref2 = push(socket, "send_message", %{"text" => "second"})
    assert_reply ref2, :error, %{reason: "busy"}

    assert_push "turn_ended", %{reason: "complete"}, 2_000
  end

  test "interrupt stops the running turn", %{socket: socket} do
    expect(LLMMock, :stream, fn _, _, _, _, sink ->
      sink.({:text_delta, "partial"})
      Process.sleep(30_000)
      {:ok, %{text: "never", tool_calls: []}}
    end)

    ref = push(socket, "send_message", %{"text" => "go"})
    assert_reply ref, :ok
    assert_push "text_delta", %{text: "partial"}

    ref2 = push(socket, "interrupt", %{})
    assert_reply ref2, :ok
    assert_push "turn_ended", %{reason: "interrupted"}
  end

  test "the session survives the channel leaving", %{socket: socket, conversation: conversation} do
    session = Sessions.whereis(conversation.id)
    assert is_pid(session)

    Process.unlink(socket.channel_pid)
    leave(socket)
    Process.sleep(50)

    assert Process.alive?(session)
    assert Sessions.whereis(conversation.id) == session
  end
end
