defmodule Longpi.Agent.PromptAssemblyTest do
  # TDD unit specs for the single prompt-assembly point. Everything the model
  # sees (system text + tool set) is (re)derived from the passed-in state here,
  # so these are pure and fast.
  use Longpi.DataCase, async: false

  alias Longpi.Agent.{PromptAssembly, Subagents, Toolbox}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Isolate subagent role discovery to this test's dirs.
    global = Path.join(dir, "global-agents")
    File.mkdir_p!(global)
    old = Application.get_env(:longpi, :subagents_global_dir)
    Application.put_env(:longpi, :subagents_global_dir, global)
    on_exit(fn -> Application.put_env(:longpi, :subagents_global_dir, old) end)

    %{ctx: %{cwd: dir, session: self(), conversation_id: nil, subagent_depth: 0}, dir: dir}
  end

  defp system_inputs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        system_prompt_override: nil,
        conversation_override: nil,
        ctx: ctx,
        agent_def: nil
      },
      overrides
    )
  end

  defp toolbox_inputs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        builtin_toolbox: Toolbox.new(),
        extension_specs: [],
        spawns_subagents?: true,
        ctx: ctx
      },
      overrides
    )
  end

  describe "system_message/1" do
    test "uses the built-in default template, interpolating cwd", %{ctx: ctx} do
      msg = PromptAssembly.system_message(system_inputs(ctx))
      assert msg.role == :system
      assert msg.content =~ "You are Longpi"
      assert msg.content =~ ctx.cwd
    end

    test "reflects the global system_prompt setting (live source)", %{ctx: ctx} do
      Longpi.Agent.Settings.put("system_prompt", "Custom global prompt in {{cwd}}.")
      on_exit(fn -> Longpi.Agent.Settings.put("system_prompt", "") end)

      msg = PromptAssembly.system_message(system_inputs(ctx))
      assert msg.content == "Custom global prompt in #{ctx.cwd}."
    end

    test "a per-conversation override wins over the global setting", %{ctx: ctx} do
      Longpi.Agent.Settings.put("system_prompt", "GLOBAL")
      on_exit(fn -> Longpi.Agent.Settings.put("system_prompt", "") end)

      msg =
        PromptAssembly.system_message(
          system_inputs(ctx, %{conversation_override: "Per-conversation prompt."})
        )

      assert msg.content == "Per-conversation prompt."
    end

    test "a hard override (opts[:system_prompt]) wins over everything", %{ctx: ctx} do
      msg =
        PromptAssembly.system_message(
          system_inputs(ctx, %{
            system_prompt_override: "HARD",
            conversation_override: "conv"
          })
        )

      assert msg.content == "HARD"
    end

    test "lists loaded extension tools so the model answers from fact", %{ctx: ctx} do
      tools = [
        %{name: "web_search", description: "Search the web with Tavily."},
        %{name: "jira", description: "Query Jira issues."}
      ]

      msg = PromptAssembly.system_message(system_inputs(ctx, %{extension_tools: tools}))
      assert msg.content =~ "# Loaded extensions"
      assert msg.content =~ "web_search: Search the web with Tavily."
      assert msg.content =~ "jira: Query Jira issues."
      assert msg.content =~ "do not go looking through the filesystem"
    end

    test "no extensions section when none are loaded", %{ctx: ctx} do
      msg = PromptAssembly.system_message(system_inputs(ctx, %{extension_tools: []}))
      refute msg.content =~ "Loaded extensions"

      # Also absent when the key is omitted entirely.
      msg2 = PromptAssembly.system_message(system_inputs(ctx))
      refute msg2.content =~ "Loaded extensions"
    end

    test "a subagent role appends its instructions to the resolved base", %{ctx: ctx} do
      agent_def = %Subagents.Def{
        name: "scout",
        description: "d",
        source: :builtin,
        system_prompt: "You are a scout."
      }

      msg = PromptAssembly.system_message(system_inputs(ctx, %{agent_def: agent_def}))
      assert msg.content =~ "You are Longpi"
      assert msg.content =~ "# Your role"
      assert msg.content =~ "You are a scout."
    end
  end

  describe "toolbox/1" do
    test "includes the built-in tools", %{ctx: ctx} do
      names = ctx |> toolbox_inputs() |> PromptAssembly.toolbox() |> Toolbox.specs() |> names()
      assert "read" in names
      assert "bash" in names
    end

    test "includes the subagent tool family when spawning is enabled", %{ctx: ctx} do
      names = ctx |> toolbox_inputs() |> PromptAssembly.toolbox() |> Toolbox.specs() |> names()
      assert "spawn_agent" in names
      assert "wait_agent" in names
    end

    test "omits the subagent family when spawning is disabled (depth limit)", %{ctx: ctx} do
      names =
        ctx
        |> toolbox_inputs(%{spawns_subagents?: false})
        |> PromptAssembly.toolbox()
        |> Toolbox.specs()
        |> names()

      refute "spawn_agent" in names
    end

    test "spawn_agent's description reflects roles discovered RIGHT NOW", %{ctx: ctx, dir: dir} do
      # No custom roles yet: only the built-ins are listed.
      before = spawn_description(ctx)
      refute before =~ "researcher"

      # Drop a new role in mid-flight…
      File.write!(Path.join(dir, "global-agents/researcher.md"), """
      ---
      name: researcher
      description: Deep research specialist
      ---
      Research things.
      """)

      # …and a fresh assembly lists it, with no session restart.
      after_add = spawn_description(ctx)
      assert after_add =~ "researcher"
      assert after_add =~ "Deep research specialist"
    end

    test "extension specs merge in under new names", %{ctx: ctx} do
      ext = %Longpi.Agent.ToolSpec{
        name: "web_search",
        description: "Search the web.",
        schema: %{"type" => "object"},
        run: fn _args, _ctx -> {:ok, "ext"} end,
        source: :extension
      }

      toolbox = PromptAssembly.toolbox(toolbox_inputs(ctx, %{extension_specs: [ext]}))
      assert %{source: :extension} = toolbox["web_search"]
    end

    test "an extension may not shadow a built-in tool", %{ctx: ctx} do
      ext = %Longpi.Agent.ToolSpec{
        name: "read",
        description: "Extension override of read.",
        schema: %{"type" => "object"},
        run: fn _args, _ctx -> {:ok, "ext"} end,
        source: :extension
      }

      toolbox = PromptAssembly.toolbox(toolbox_inputs(ctx, %{extension_specs: [ext]}))
      # The built-in read is kept; the extension's shadowing version is ignored.
      assert %{source: :builtin} = toolbox["read"]
    end
  end

  defp names(specs), do: Enum.map(specs, & &1.name)

  defp spawn_description(ctx) do
    ctx
    |> toolbox_inputs()
    |> PromptAssembly.toolbox()
    |> Map.fetch!("spawn_agent")
    |> Map.fetch!(:description)
  end
end
