defmodule Longpi.Agent.Subagents do
  @moduledoc """
  Discovery of subagent role definitions — markdown files with YAML-ish
  frontmatter, in the style of pi and `.claude/agents`:

      ---
      name: scout
      description: Fast read-only codebase reconnaissance
      tools: read, grep, find, ls, bash
      model: J
      reasoning_effort: low
      extensions: true
      ---
      (body = system prompt appended to the child session's base prompt)

  `model` accepts a tier alias — J (light/fast), Q (balanced), K (strongest),
  mapped in the admin UI — or a full spec like `anthropic:claude-haiku-4-5`.
  A tier bundles a model AND a reasoning level, and the bundle wins over the
  role's own `reasoning_effort`. Tiers keep role files portable across
  provider/gateway changes.

  Sources, later winning on name collisions:

    1. built-ins (`scout`, `worker`)
    2. user level  — `~/.longpi/agents/*.md` (app env `:subagents_global_dir`)
    3. project level — `<cwd>/.longpi/agents/*.md`

  Discovery runs fresh on every call so edits apply mid-session.
  """

  defmodule Def do
    @moduledoc "One subagent role definition."
    @enforce_keys [:name, :description, :system_prompt, :source]
    defstruct [
      :name,
      :description,
      :system_prompt,
      :source,
      tools: nil,
      model: nil,
      reasoning_effort: nil,
      extensions: false
    ]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            system_prompt: String.t(),
            source: :builtin | :user | :project,
            tools: [String.t()] | nil,
            model: String.t() | nil,
            reasoning_effort: String.t() | nil,
            extensions: boolean()
          }
  end

  @doc "All available role definitions for a workspace, sorted by name."
  @spec discover(String.t()) :: [Def.t()]
  def discover(cwd) do
    builtins()
    |> index()
    |> Map.merge(index(load_dir(global_dir(), :user)))
    |> Map.merge(index(load_dir(Path.join(cwd, ".longpi/agents"), :project)))
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc "Looks up one role by name."
  @spec get(String.t(), String.t()) :: {:ok, Def.t()} | :error
  def get(cwd, name) do
    case Enum.find(discover(cwd), &(&1.name == name)) do
      nil -> :error
      def -> {:ok, def}
    end
  end

  defp index(defs), do: Map.new(defs, &{&1.name, &1})

  defp global_dir do
    Application.get_env(:longpi, :subagents_global_dir) || Path.expand("~/.longpi/agents")
  end

  defp load_dir(dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(fn file ->
          case parse(File.read!(Path.join(dir, file)), source) do
            {:ok, def} -> [def]
            :error -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Frontmatter is deliberately minimal: `key: value` lines between `---`
  # fences. name + description are required; the body becomes the prompt.
  defp parse(content, source) do
    with ["", front, body] <- String.split(content, ~r/^---\s*$/m, parts: 3),
         %{"name" => name, "description" => description} = fields when name != "" <-
           parse_fields(front) do
      {:ok,
       %Def{
         name: name,
         description: description,
         system_prompt: String.trim(body),
         source: source,
         tools: parse_tools(fields["tools"]),
         model: fields["model"],
         reasoning_effort: fields["reasoning_effort"],
         extensions: fields["extensions"] in ["true", "yes"]
       }}
    else
      _ -> :error
    end
  end

  defp parse_fields(front) do
    front
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        _ -> acc
      end
    end)
  end

  defp parse_tools(nil), do: nil
  defp parse_tools(""), do: nil

  defp parse_tools(value),
    do: value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  # ── Built-in roles ──────────────────────────────────────────────────

  defp builtins do
    [
      %Def{
        name: "scout",
        description:
          "Fast, read-only codebase reconnaissance. Answers well-scoped questions about " <>
            "where things live and how they work. Cannot edit files.",
        tools: ["read", "grep", "find", "ls", "bash"],
        source: :builtin,
        system_prompt: """
        You are a codebase scout. Your job is to explore quickly and report back.

        Your output goes to an agent who has not seen the files you explored, so be
        self-contained: include file paths (with line numbers where useful), the key
        code excerpts, and how the pieces connect. Answer exactly the question you
        were given, as reported facts — the caller decides what to do with them.
        """
      },
      %Def{
        name: "worker",
        description:
          "Executes a well-scoped implementation task: writes code, edits files, runs " <>
            "commands and tests. Owns the files it is given.",
        tools: nil,
        source: :builtin,
        system_prompt: """
        You are an implementation worker. Complete the task you were given end to end:
        make the changes, run the relevant tests, and fix what breaks.

        You may not be alone in the codebase — stick strictly to the files and scope
        in your task, and leave everything else exactly as you found it.
        Finish with a concise report: what changed (files), how you verified it, and
        anything the caller must know. That final message is all the caller sees.
        """
      }
    ]
  end
end
