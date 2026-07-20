defmodule Longpi.Agent.SessionApprovalTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.{Permissions, Session}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "f.txt"), "file-body")

    session =
      start_supervised!({Session, llm: LLMMock, model: "test:model", cwd: dir, stream_to: self()})

    %{session: session, dir: dir}
  end

  defp bash_call, do: %{id: "tc_1", name: "bash", args: %{"command" => "echo hi"}}

  test "an :ask tool prompts for approval and runs when approved", %{session: session} do
    Permissions.put_level(:auto)
    call = bash_call()

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      assert List.last(messages).content =~ "hi"
      {:ok, %{text: "ran it", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "run echo")
    assert_receive {:agent_event, {:approval_request, ^call}}, 2_000

    :ok = Session.respond_approval(session, "tc_1", true)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "a denied tool is not executed", %{session: session} do
    Permissions.put_level(:auto)
    call = bash_call()

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [call]}} end)
    |> expect(:stream, fn _, messages, _, _, _ ->
      last = List.last(messages)
      assert last.error? == true
      assert last.content =~ "Permission denied"
      {:ok, %{text: "ok", tool_calls: []}}
    end)

    :ok = Session.send_message(session, "run echo")
    assert_receive {:agent_event, {:approval_request, ^call}}, 2_000

    :ok = Session.respond_approval(session, "tc_1", false)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
  end

  test "full level runs :ask tools without prompting", %{session: session} do
    Permissions.put_level(:full)

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [bash_call()]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)

    :ok = Session.send_message(session, "run echo")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    refute_received {:agent_event, {:approval_request, _}}
  end

  test "read-only tools run without prompting under auto", %{session: session} do
    Permissions.put_level(:auto)
    read = %{id: "tc_r", name: "read", args: %{"path" => "f.txt"}}

    LLMMock
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "", tool_calls: [read]}} end)
    |> expect(:stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)

    :ok = Session.send_message(session, "read it")
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    refute_received {:agent_event, {:approval_request, _}}
  end
end
