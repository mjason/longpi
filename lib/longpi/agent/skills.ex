defmodule Longpi.Agent.Skills do
  @moduledoc """
  Discovery of Agent Skills — `SKILL.md` files with frontmatter, in Claude's
  skills convention (`<skills-dir>/<name>/SKILL.md`):

      ---
      name: pdf-forms
      description: Fill and extract PDF form fields
      ---
      (body = the full instructions, loaded on demand)

  Sources: global `~/.longpi/skills/` (app env `:skills_global_dir`) and project
  `<cwd>/.longpi/skills/`, project winning on a name collision. The prompt lists
  each skill's name, description, and file path; the model reads the file for
  the full body when a skill is relevant. Discovery runs fresh on each prompt
  assembly, so a newly added skill applies on the next turn.
  """

  defmodule Skill do
    @moduledoc "One discovered skill."
    @enforce_keys [:name, :description, :path]
    defstruct [:name, :description, :path]

    @type t :: %__MODULE__{name: String.t(), description: String.t(), path: String.t()}
  end

  @doc "Available skills for a workspace, sorted by name (project wins on name)."
  @spec discover(String.t()) :: [Skill.t()]
  def discover(cwd) do
    (load_dir(global_dir()) ++ load_dir(Path.join(cwd, ".longpi/skills")))
    |> Enum.reduce(%{}, fn skill, acc -> Map.put(acc, skill.name, skill) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp global_dir do
    Application.get_env(:longpi, :skills_global_dir) || Path.expand("~/.longpi/skills")
  end

  defp load_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          skill_md = Path.join([dir, entry, "SKILL.md"])
          if File.regular?(skill_md), do: parse(skill_md), else: []
        end)

      {:error, _} ->
        []
    end
  end

  defp parse(path) do
    with {:ok, content} <- File.read(path),
         ["", front, _body] <- String.split(content, ~r/^---\s*$/m, parts: 3),
         %{"name" => name, "description" => description} when name != "" <- parse_fields(front) do
      [%Skill{name: name, description: description, path: path}]
    else
      _ -> []
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
end
