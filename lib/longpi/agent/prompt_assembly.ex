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

  alias Longpi.Agent.{Message, ProjectContext, Subagents, SystemPrompt, ToolSpec, Toolbox}

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
          # The full tool inventory for this turn (built-ins + subagent family +
          # extensions), as `%{name, description, source}`. Rendered as an
          # itemized "Available tools" list so the model has a clear, current
          # inventory — and answers "what extensions do I have?" from fact
          # rather than scanning the filesystem. Optional; defaults to none.
          optional(:tools) => [%{name: String.t(), description: String.t(), source: atom()}]
        }

  # Preferred ordering for the itemized tool list: exploration, then mutation,
  # then bash, then the subagent family. Anything else (extensions) comes after,
  # alphabetically.
  @tool_order ~w(read grep find ls edit write bash spawn_agent wait_agent list_agents send_agent close_agent)

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
    # A hard override (tests) or a user's custom prompt (conversation/global) is
    # used verbatim; only the built-in default is augmented with the tool list.
    {kind, base} =
      case inputs.system_prompt_override do
        override when is_binary(override) and override != "" -> {:custom, override}
        _ -> SystemPrompt.resolve_tagged(inputs.ctx, inputs.conversation_override)
      end

    base
    |> maybe_append_tools(kind, Map.get(inputs, :tools, []))
    |> append_role(inputs.agent_def)
    |> append_project_context(ProjectContext.load(inputs.ctx.cwd))
    |> Message.system()
  end

  # Repo/directory instruction files (AGENTS.md / CLAUDE.md), pi's project_context.
  # Applied to custom prompts too — the user's prompt and the project's rules are
  # separate concerns.
  defp append_project_context(base, []), do: base

  defp append_project_context(base, files) do
    blocks =
      Enum.map_join(files, "\n\n", fn f ->
        "<project_instructions path=\"#{f.path}\">\n#{f.content}\n</project_instructions>"
      end)

    base <>
      "\n\n<project_context>\n\nProject-specific instructions and guidelines " <>
      "(follow these for work in this workspace):\n\n" <> blocks <> "\n\n</project_context>"
  end

  defp maybe_append_tools(base, :default, tools), do: append_tools(base, tools)
  defp maybe_append_tools(base, :custom, _tools), do: base

  @doc """
  Ordered `%{name, description, source}` summaries for a toolbox — the input to
  the itemized "Available tools" list in the system message.
  """
  @spec tool_summaries(Toolbox.t()) :: [%{name: String.t(), description: String.t(), source: atom()}]
  def tool_summaries(toolbox) do
    toolbox
    |> Toolbox.specs()
    |> Enum.map(&%{name: &1.name, description: &1.description, source: &1.source})
    |> Enum.sort_by(&tool_rank/1)
  end

  defp tool_rank(%{name: name}) do
    case Enum.find_index(@tool_order, &(&1 == name)) do
      nil -> {1, name}
      idx -> {0, idx}
    end
  end

  # An itemized inventory of every tool available this turn — pi's model: the
  # model reads a clear list of what it has (name + one-line snippet), so it
  # reaches for the right tool instead of a shell utility that may be absent.
  # The list is re-derived each turn, so extensions that load/unload stay
  # current, and "what extensions do I have?" is answered from fact.
  defp append_tools(base, tools) when is_list(tools) and tools != [] do
    list = Enum.map_join(tools, "\n", &"- #{&1.name}: #{snippet(&1.description)}")
    base <> "\n\n## Available tools\n\nCall these directly by name:\n\n" <> list <> ext_note(tools)
  end

  defp append_tools(base, _tools), do: base

  defp ext_note(tools) do
    if Enum.any?(tools, &(Map.get(&1, :source) == :extension)) do
      "\n\nSome of the tools above come from extensions. When asked what " <>
        "extensions or custom tools you have, answer from this list rather than " <>
        "scanning the filesystem."
    else
      ""
    end
  end

  # A concise one-liner for the list — the first sentence of the tool's full
  # description (the full text still rides in the API tool schema).
  defp snippet(description) do
    description
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.。])\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
  end

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
