defmodule Longpi.Agent.TurnTest do
  use ExUnit.Case, async: true

  import Mox

  alias Longpi.Agent.{Message, Toolbox, Turn}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    test_pid = self()

    config = %{
      llm: LLMMock,
      model: "test:model",
      toolbox: Toolbox.new(),
      ctx: %{cwd: dir},
      sink: fn event -> send(test_pid, {:ev, event}) end
    }

    %{config: config, dir: dir}
  end

  test "text-only completion ends the turn", %{config: config} do
    expect(LLMMock, :stream, fn "test:model", messages, _tools, _opts, sink ->
      assert [%{role: :user, content: "hey"}] = messages
      sink.({:text_delta, "hi there"})
      {:ok, %{text: "hi there", tool_calls: []}}
    end)

    assert {:ok, [assistant]} = Turn.run(config, [Message.user("hey")])
    assert %{role: :assistant, content: "hi there", tool_calls: []} = assistant
    assert_received {:ev, {:text_delta, "hi there"}}
  end

  test "tool call round trip feeds the result back to the LLM", %{config: config, dir: dir} do
    File.write!(Path.join(dir, "data.txt"), "secret-payload")
    call = %{id: "tc_1", name: "read", args: %{"path" => "data.txt"}}

    LLMMock
    |> expect(:stream, fn _model, _messages, _tools, _opts, _sink ->
      {:ok, %{text: "", tool_calls: [call]}}
    end)
    |> expect(:stream, fn _model, messages, _tools, _opts, _sink ->
      assert %{role: :tool, tool_call_id: "tc_1", content: content} = List.last(messages)
      assert content =~ "secret-payload"
      {:ok, %{text: "the file says secret-payload", tool_calls: []}}
    end)

    assert {:ok, new_messages} = Turn.run(config, [Message.user("read data.txt")])

    assert [%{role: :assistant, tool_calls: [_]}, %{role: :tool}, %{role: :assistant}] =
             new_messages

    assert_received {:ev, {:tool_call, ^call}}
    assert_received {:ev, {:tool_result, %{content: result_text}}}
    assert result_text =~ "secret-payload"
  end

  test "unknown tool becomes an error result and the loop continues", %{config: config} do
    call = %{id: "tc_x", name: "teleport", args: %{}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      assert %{role: :tool, content: content} = List.last(messages)
      assert content =~ "teleport"
      {:ok, %{text: "sorry", tool_calls: []}}
    end)

    assert {:ok, _} = Turn.run(config, [Message.user("go")])
    assert_received {:ev, {:tool_result, %{error?: true}}}
  end

  test "LLM error propagates with messages so far", %{config: config} do
    call = %{id: "tc_1", name: "bash", args: %{"command" => "true"}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> {:error, :rate_limited} end)

    assert {:error, :rate_limited, partial} = Turn.run(config, [Message.user("go")])
    assert [%{role: :assistant}, %{role: :tool}] = partial
  end

  test "stops after max_iterations of tool calls", %{config: config} do
    call = %{id: "tc_loop", name: "bash", args: %{"command" => "true"}}

    expect(LLMMock, :stream, 3, fn _, _, _, _, _ ->
      {:ok, %{text: "", tool_calls: [call]}}
    end)

    assert {:error, :max_iterations, _messages} =
             Turn.run(config, [Message.user("loop forever")], max_iterations: 3)
  end

  test "a denied tool call is not executed and returns a denial", %{config: config, dir: dir} do
    File.write!(Path.join(dir, "secret.txt"), "should-not-be-read")
    call = %{id: "tc_d", name: "read", args: %{"path" => "secret.txt"}}
    config = Map.put(config, :authorize, fn _call -> :deny end)

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      tool_result = List.last(messages)
      assert tool_result.role == :tool
      assert tool_result.error? == true
      assert tool_result.content =~ "Permission denied"
      refute tool_result.content =~ "should-not-be-read"
      {:ok, %{text: "understood", tool_calls: []}}
    end)

    assert {:ok, _} = Turn.run(config, [Message.user("read it")])
    assert_received {:ev, {:tool_result, %{error?: true}}}
  end

  test "authorize receives the tool call and allow runs it", %{config: config, dir: dir} do
    File.write!(Path.join(dir, "ok.txt"), "readable")
    call = %{id: "tc_a", name: "read", args: %{"path" => "ok.txt"}}
    test_pid = self()

    config =
      Map.put(config, :authorize, fn c ->
        send(test_pid, {:asked, c.name})
        :allow
      end)

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      assert List.last(messages).content =~ "readable"
      {:ok, %{text: "done", tool_calls: []}}
    end)

    assert {:ok, _} = Turn.run(config, [Message.user("read")])
    assert_received {:asked, "read"}
  end
end
