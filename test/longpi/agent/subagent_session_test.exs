defmodule Longpi.Agent.SubagentSessionTest do
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.Session
  alias Longpi.Agent.LLM.Mock, as: LLMMock
  alias Longpi.Agent.Tools.{ListAgents, WaitAgent}

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})

    {:ok, parent} =
      Session.start_link(llm: LLMMock, conversation_id: conversation.id, stream_to: self())

    on_exit(fn ->
      for {id, _pid} <- Longpi.Agent.Sessions.list_active(), do: Longpi.Agent.Sessions.stop(id)
    end)

    %{conversation: conversation, parent: parent, dir: dir}
  end

  defp tool_ctx(parent), do: %{session: parent, cwd: "/tmp", conversation_id: nil, subagent_depth: 0}

  test "spawn → child runs with role toolbox → wait returns its final output", %{
    parent: parent,
    conversation: conversation
  } do
    test_pid = self()

    # Only the CHILD calls the LLM in this test (we drive the parent's tools
    # directly). Capture what the child was configured with.
    stub(LLMMock, :stream, fn model, messages, tools, _opts, _sink ->
      send(test_pid, {:child_llm, model, messages, Enum.map(tools, & &1.name)})
      {:ok, %{text: "REPORT: 3 modules, entry at lib/app.ex", tool_calls: []}}
    end)

    assert {:ok, "scout-1"} =
             GenServer.call(parent, {:spawn_subagent, %{agent: "scout", task: "map the codebase"}})

    # Child session got the role's system prompt, restricted tools, no spawn.
    assert_receive {:child_llm, "test:model", [%{role: :system, content: system} | _], tool_names},
                   5_000

    assert system =~ "codebase scout"
    assert Enum.sort(tool_names) == ["bash", "find", "grep", "ls", "read"]
    refute "spawn_agent" in tool_names

    # The child conversation is persisted under the parent with its role.
    {:ok, "scout-1"} = wait_until_done(parent, "scout-1")
    [child] = Longpi.Agent.list_conversations!() |> Enum.filter(&(&1.parent_id == conversation.id))
    assert child.agent_role == "scout"

    # wait_agent returns the child's final answer.
    assert {:ok, output} = WaitAgent.run(%{timeout_ms: 10_000}, tool_ctx(parent))
    assert output =~ "### scout-1 (scout) — done"
    assert output =~ "REPORT: 3 modules"
  end

  test "list_agents shows status; unknown role errors with the available list", %{parent: parent} do
    assert {:ok, "No subagents spawned yet."} = ListAgents.run(%{}, tool_ctx(parent))

    assert {:error, msg} =
             GenServer.call(parent, {:spawn_subagent, %{agent: "ghost", task: "x"}})

    assert msg =~ "Unknown agent role"
    assert msg =~ "scout"
    assert msg =~ "worker"
  end

  test "a child finishing while the parent is idle injects a notification message", %{
    parent: parent
  } do
    stub(LLMMock, :stream, fn _, _, _, _, _ ->
      {:ok, %{text: "done quietly", tool_calls: []}}
    end)

    {:ok, handle} =
      GenServer.call(parent, {:spawn_subagent, %{agent: "worker", task: "fix the thing"}})

    {:ok, ^handle} = wait_until_done(parent, handle)

    # Parent is idle and nobody collected → a "[subagent] … finished" user
    # message is appended and broadcast.
    assert Enum.any?(Session.messages(parent), fn m ->
             m.role == :user and is_binary(m.content) and m.content =~ "[subagent] #{handle}"
           end)
  end

  test "wait_agent with no children errors; unknown handle errors", %{parent: parent} do
    assert {:error, msg} = WaitAgent.run(%{}, tool_ctx(parent))
    assert msg =~ "No subagents"

    stub(LLMMock, :stream, fn _, _, _, _, _ -> {:ok, %{text: "ok", tool_calls: []}} end)
    {:ok, _} = GenServer.call(parent, {:spawn_subagent, %{agent: "scout", task: "t"}})

    assert {:error, msg} = WaitAgent.run(%{agents: ["nope-9"], timeout_ms: 1}, tool_ctx(parent))
    assert msg =~ "Unknown agent handle"
  end

  test "subagent sessions do not get the agent tool family (depth limit)", %{dir: dir} do
    # Simulate what spawn does: a session started at depth 1.
    {:ok, def} = Longpi.Agent.Subagents.get(dir, "worker")

    {:ok, child} =
      Session.start_link(
        llm: LLMMock,
        cwd: dir,
        model: "test:model",
        agent_def: def,
        subagent_depth: 1
      )

    test_pid = self()

    stub(LLMMock, :stream, fn _, _, tools, _, _ ->
      send(test_pid, {:tools, Enum.map(tools, & &1.name)})
      {:ok, %{text: "hi", tool_calls: []}}
    end)

    :ok = Session.send_message(child, "hello")
    assert_receive {:tools, tool_names}, 5_000
    refute "spawn_agent" in tool_names
    refute "wait_agent" in tool_names
    GenServer.stop(child)
  end

  defp wait_until_done(parent, handle, tries \\ 50)
  defp wait_until_done(_parent, _handle, 0), do: :timeout

  defp wait_until_done(parent, handle, tries) do
    case GenServer.call(parent, :subagent_snapshot) do
      %{^handle => %{status: :done}} -> {:ok, handle}
      _ -> Process.sleep(100) && wait_until_done(parent, handle, tries - 1)
    end
  end

  test "a subagent tool approval bubbles to the parent, routes back on response", %{
    parent: parent
  } do
    call = %{id: "call-1", name: "bash", args: %{"command" => "ls"}}

    # The child bubbles an approval request up to the parent.
    send(parent, {:subagent_approval_request, "child-abc", "scout", call})

    assert_receive {:agent_event, {:subagent_approval, entry}}, 2_000
    assert entry.call.id == "call-1"
    assert entry.conversation_id == "child-abc"
    assert entry.role == "scout"

    # The parent surfaces it for a re-joining client.
    assert [%{call: %{id: "call-1"}}] = Session.subagent_approvals(parent)

    # The user answers in the parent view → the parent clears it and broadcasts
    # the resolution (and forwards to the child, a no-op here since it isn't live).
    send(parent, {:approval_response, "call-1", true})

    assert_receive {:agent_event, {:subagent_approval_resolved, "call-1"}}, 2_000
    assert Session.subagent_approvals(parent) == []
  end

  test "a subagent going terminal clears its pending bubbled approval", %{parent: parent} do
    stub(LLMMock, :stream, fn _, _, _, _, _ -> {:ok, %{text: "done", tool_calls: []}} end)
    {:ok, handle} = GenServer.call(parent, {:spawn_subagent, %{agent: "scout", task: "t"}})
    %{^handle => %{conversation_id: child_id}} = GenServer.call(parent, :subagent_snapshot)

    send(parent, {:subagent_approval_request, child_id, "scout", %{id: "c2", name: "bash", args: %{}}})
    assert_receive {:agent_event, {:subagent_approval, _}}, 2_000

    # Child failing/finishing must not leave a stuck approval prompt.
    send(parent, {:subagent_update, child_id, {:failed, :boom}})
    assert_receive {:agent_event, {:subagent_approval_resolved, "c2"}}, 2_000
    assert Session.subagent_approvals(parent) == []
  end
end
