defmodule Longpi.Agent.TurnModelSwitchTest do
  # Behavior: a tool that declares `model: "J"` switches the REST of the turn's
  # LLM calls to the J tier's profile; the switch is turn-scoped and resolves
  # through the admin-managed alias table.
  use Longpi.DataCase, async: false

  import Mox

  alias Longpi.Agent.{Toolbox, ToolSpec, Turn}
  alias Longpi.Agent.LLM.Mock, as: LLMMock

  setup :set_mox_global
  setup :verify_on_exit!

  defp tool(name, model) do
    %ToolSpec{
      name: name,
      description: "test tool",
      schema: [],
      run: fn _args, _ctx -> {:ok, "done"} end,
      source: :extension,
      model: model
    }
  end

  defp config(toolbox) do
    %{
      llm: LLMMock,
      model: "test:strong",
      reasoning_effort: :high,
      toolbox: toolbox,
      ctx: %{cwd: System.tmp_dir!(), session: self(), conversation_id: nil, subagent_depth: 0},
      sink: fn _event -> :ok end,
      authorize: fn _call -> :allow end
    }
  end

  defp call(name), do: %{id: "c1", name: name, args: %{}}

  test "after a J-declaring tool runs, the next LLM call uses J's model AND effort" do
    Longpi.Agent.create_model!(%{spec: "openai:mini"})
    Longpi.Agent.put_model_alias!(%{name: "J", spec: "openai:mini", reasoning_effort: "low"})

    toolbox = Map.new([tool("cheap_tool", "J"), tool("plain", nil)], &{&1.name, &1})

    expect(LLMMock, :stream, fn "test:strong", _msgs, _tools, opts, _sink ->
      assert opts[:reasoning_effort] == :high
      {:ok, %{text: "", tool_calls: [call("cheap_tool")]}}
    end)

    expect(LLMMock, :stream, fn "openai:mini", _msgs, _tools, opts, _sink ->
      # The tier bundles low effort; it replaced the session's high.
      assert opts[:reasoning_effort] == :low
      {:ok, %{text: "processed cheaply", tool_calls: []}}
    end)

    assert {:ok, messages} = Turn.run(config(toolbox), [%{role: :user, content: "go"}])
    assert List.last(messages).content == "processed cheaply"
  end

  test "a tool without a declaration changes nothing" do
    toolbox = Map.new([tool("plain", nil)], &{&1.name, &1})

    expect(LLMMock, :stream, 2, fn model, _msgs, _tools, opts, _sink ->
      assert model == "test:strong"
      assert opts[:reasoning_effort] == :high

      case Process.get(:turn_count, 0) do
        0 ->
          Process.put(:turn_count, 1)
          {:ok, %{text: "", tool_calls: [call("plain")]}}

        _ ->
          {:ok, %{text: "same model throughout", tool_calls: []}}
      end
    end)

    assert {:ok, _} = Turn.run(config(toolbox), [%{role: :user, content: "go"}])
  end

  test "an unresolvable declaration keeps the current model instead of failing the turn" do
    toolbox = Map.new([tool("broken_pref", "no-such-tier")], &{&1.name, &1})

    expect(LLMMock, :stream, 2, fn model, _msgs, _tools, _opts, _sink ->
      assert model == "test:strong"

      case Process.get(:turn_count, 0) do
        0 ->
          Process.put(:turn_count, 1)
          {:ok, %{text: "", tool_calls: [call("broken_pref")]}}

        _ ->
          {:ok, %{text: "still on the session model", tool_calls: []}}
      end
    end)

    assert {:ok, messages} = Turn.run(config(toolbox), [%{role: :user, content: "go"}])
    assert List.last(messages).content == "still on the session model"
  end
end
