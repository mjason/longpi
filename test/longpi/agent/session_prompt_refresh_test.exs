defmodule Longpi.Agent.SessionPromptRefreshTest do
  # BDD specs for the promise "the prompt is reassembled every turn from
  # current state" — driven entirely through the public Session API, asserting
  # on what the LLM actually receives (captured via the mock) across two turns.
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.{Session, Settings}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    agents_dir = Path.join(dir, "global-agents")
    File.mkdir_p!(agents_dir)
    old = Application.get_env(:longpi, :subagents_global_dir)
    Application.put_env(:longpi, :subagents_global_dir, agents_dir)
    on_exit(fn -> Application.put_env(:longpi, :subagents_global_dir, old) end)

    conversation = Longpi.Agent.create_conversation!(%{cwd: dir, model: "test:model"})
    {:ok, session} = Session.start_link(llm: LLMMock, conversation_id: conversation.id, stream_to: self())

    %{session: session, dir: dir, agents_dir: agents_dir}
  end

  # Capture the (system message, tool names) the mock is handed, and answer.
  defp capture_turn(reply \\ "ok") do
    test_pid = self()

    expect(LLMMock, :stream, fn _model, messages, tools, _opts, _sink ->
      system = Enum.find(messages, &(&1.role == :system))
      send(test_pid, {:captured, system.content, Enum.map(tools, & &1.name)})
      {:ok, %{text: reply, tool_calls: []}}
    end)
  end

  defp run_turn(session, text) do
    capture_turn()
    :ok = Session.send_message(session, text)
    assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
    assert_receive {:captured, system, tools}
    {system, tools}
  end

  describe "the system prompt is re-resolved each turn" do
    test "a global system_prompt setting change takes effect on the NEXT turn", %{
      session: session
    } do
      {system_before, _} = run_turn(session, "first")
      assert system_before =~ "You are Longpi"

      # The admin edits the global system prompt mid-session.
      Settings.put("system_prompt", "You are a pirate. Workspace: {{cwd}}.")
      on_exit(fn -> Settings.put("system_prompt", "") end)

      {system_after, _} = run_turn(session, "second")
      assert system_after =~ "You are a pirate."
      refute system_after =~ "You are Longpi"
    end
  end

  describe "the tool set is reassembled each turn" do
    test "a subagent role added mid-session appears in spawn_agent NEXT turn", %{
      session: session,
      agents_dir: agents_dir
    } do
      {_, tools_before} = run_turn(session, "first")
      assert "spawn_agent" in tools_before

      # A new role file lands while the session is live.
      File.write!(Path.join(agents_dir, "auditor.md"), """
      ---
      name: auditor
      description: Security auditor
      ---
      Audit for vulnerabilities.
      """)

      # The NEXT turn's spawn_agent description lists it — captured via a probe
      # that reads the tool description the mock received.
      test_pid = self()

      expect(LLMMock, :stream, fn _model, _messages, tools, _opts, _sink ->
        spawn = Enum.find(tools, &(&1.name == "spawn_agent"))
        send(test_pid, {:spawn_desc, spawn.description})
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      :ok = Session.send_message(session, "third")
      assert_receive {:agent_event, {:turn_ended, :complete}}, 2_000
      assert_receive {:spawn_desc, desc}
      assert desc =~ "auditor"
      assert desc =~ "Security auditor"
    end
  end

  describe "loaded extensions are advertised in the system prompt" do
    test "an extension tool the session has loaded is listed for the model", %{session: session} do
      # Simulate the extension host having loaded a tool.
      spec = %Longpi.Agent.ToolSpec{
        name: "web_search",
        description: "Search the web with Tavily.",
        schema: %{"type" => "object"},
        run: fn _args, _ctx -> {:ok, "…"} end,
        source: :extension
      }

      :sys.replace_state(session, fn state -> %{state | extension_specs: [spec]} end)

      {system, tools} = run_turn(session, "现在有什么扩展呢")
      assert system =~ "# Loaded extensions"
      assert system =~ "web_search: Search the web with Tavily."
      assert "web_search" in tools
    end
  end

  describe "history is unaffected by prompt refresh" do
    test "refreshing the system message does not duplicate or drop history rows", %{
      session: session
    } do
      run_turn(session, "hello")
      run_turn(session, "again")

      # system is not part of the visible history; two turns = 2 user + 2 assistant.
      roles = session |> Session.messages() |> Enum.map(& &1.role)
      assert Enum.count(roles, &(&1 == :system)) == 1
      assert Enum.count(roles, &(&1 == :user)) == 2
      assert Enum.count(roles, &(&1 == :assistant)) == 2
    end
  end
end
