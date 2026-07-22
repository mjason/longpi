defmodule Longpi.Agent.PromptAssembly do
  @moduledoc """
  The single point where the model-facing prompt is assembled.

  Everything the model receives — the system message AND the tool set (each
  tool's name/description/schema is part of the prompt the model reads) — is
  re-derived here from the current session state, not frozen when the session
  started. `Longpi.Agent.Session` calls this at the start of every turn, so:

    * a change to the global system-prompt setting,
    * a new subagent role dropped into `.longpi/agents/`,
    * an extension that just loaded or reloaded,

  all take effect on the next turn, and the system text stays coherent with the
  tools alongside it. The alternative — caching an assembled prompt at init —
  drifts the moment any input changes (extension tools would update live while
  the system text and the spawn_agent role list went stale).

  These functions are pure given their inputs (the only side effects are reads:
  the global setting via `SystemPrompt.resolve`, subagent roles via a directory
  scan), which is what makes the behaviour straightforward to test.
  """

  alias Longpi.Agent.{Message, Subagents, SystemPrompt, ToolSpec, Toolbox}

  @subagent_tool_modules [
    Longpi.Agent.Tools.WaitAgent,
    Longpi.Agent.Tools.ListAgents,
    Longpi.Agent.Tools.SendAgent,
    Longpi.Agent.Tools.CloseAgent
  ]

  @typedoc "Inputs for `system_message/1`."
  @type system_inputs :: %{
          # A hard, fixed override (e.g. `opts[:system_prompt]` in tests); when
          # set it wins over everything and no template resolution happens.
          required(:system_prompt_override) => String.t() | nil,
          # The conversation's own prompt override (captured at session start).
          required(:conversation_override) => String.t() | nil,
          required(:ctx) => map(),
          # A subagent role whose instructions append to the resolved base.
          required(:agent_def) => Subagents.Def.t() | nil,
          # Currently-loaded extension tools, so the model can answer "what
          # extensions do I have?" authoritatively instead of guessing at the
          # filesystem. Optional; defaults to none.
          optional(:extension_tools) => [%{name: String.t(), description: String.t()}]
        }

  @typedoc "Inputs for `toolbox/1`."
  @type toolbox_inputs :: %{
          # Role-narrowed built-in tools (fixed for the session).
          required(:builtin_toolbox) => Toolbox.t(),
          # Extension-contributed specs (updated on load/reload; [] when none).
          required(:extension_specs) => [ToolSpec.t()],
          # Whether this session may still spawn subagents (depth < limit).
          required(:spawns_subagents?) => boolean(),
          required(:ctx) => map()
        }

  @doc "The system `Message`, re-resolved from the current template/settings."
  @spec system_message(system_inputs()) :: Message.t()
  def system_message(inputs) do
    base = inputs.system_prompt_override || SystemPrompt.resolve(inputs.ctx, inputs.conversation_override)

    base
    |> append_extensions(Map.get(inputs, :extension_tools, []))
    |> append_role(inputs.agent_def)
    |> Message.system()
  end

  # Tell the model exactly which extension tools are loaded right now, so a
  # question like "what extensions do I have?" is answered from fact rather
  # than a fragile filesystem scan (which the model was getting wrong — it
  # globbed `*.js` and missed `.ts` extensions). Nothing is appended when no
  # extensions are loaded.
  defp append_extensions(base, tools) when is_list(tools) and tools != [] do
    list = Enum.map_join(tools, "\n", &"- #{&1.name}: #{&1.description}")

    base <>
      "\n\n# Loaded extensions\n\n" <>
      "You currently have these extension tools available (already loaded — call " <>
      "them directly). When asked what extensions or custom tools you have, answer " <>
      "from this list; do not go looking through the filesystem:\n\n" <> list
  end

  defp append_extensions(base, _tools), do: base

  # A subagent role extends (not replaces) the base prompt — pi's
  # --append-system-prompt model.
  defp append_role(base, %Subagents.Def{system_prompt: extra}) when is_binary(extra) and extra != "",
    do: base <> "\n\n# Your role\n\n" <> extra

  defp append_role(base, _agent_def), do: base

  @doc """
  The toolbox for a turn: built-ins, plus the subagent tool family (when this
  session may spawn), plus extension tools. Extensions win on name, matching
  pi. The subagent tools are rebuilt here so `spawn_agent`'s advertised role
  list is always current.
  """
  @spec toolbox(toolbox_inputs()) :: Toolbox.t()
  def toolbox(inputs) do
    with_subagents =
      if inputs.spawns_subagents? do
        Toolbox.with_extensions(inputs.builtin_toolbox, subagent_specs(inputs.ctx.cwd))
      else
        inputs.builtin_toolbox
      end

    Toolbox.with_extensions(with_subagents, inputs.extension_specs)
  end

  @doc """
  The subagent tool family, with `spawn_agent`'s description carrying the roles
  discoverable from `cwd` at this moment.
  """
  @spec subagent_specs(String.t()) :: [ToolSpec.t()]
  def subagent_specs(cwd) do
    roles =
      cwd
      |> Subagents.discover()
      |> Enum.map_join("\n", &"- #{&1.name}: #{&1.description}")

    spawn_spec = ToolSpec.from_module(Longpi.Agent.Tools.SpawnAgent)
    spawn_spec = %{spawn_spec | description: spawn_spec.description <> "\nAvailable agent roles:\n" <> roles}

    [spawn_spec | Enum.map(@subagent_tool_modules, &ToolSpec.from_module/1)]
  end
end
