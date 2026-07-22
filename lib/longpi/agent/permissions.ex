defmodule Longpi.Agent.Permissions do
  @moduledoc """
  A single approval level governs tool execution, in the style of Codex/Claude
  Code:

    * `:read_only` - only read-type tools run automatically; anything that
      writes or executes asks for approval
    * `:auto` - reads and workspace edits run automatically; `bash` AND any
      extension tool (arbitrary code via the QuickJS host / `longpi.run`) ask
    * `:full` - everything runs automatically, no prompts

  Stored in the `"approval_level"` setting; defaults to `:auto`.

  A tool's `source` (`:builtin` | `:extension`) is part of the decision: under
  `:auto`, extension tools are treated like `bash` — they can fetch, write, and
  run programs, so they get the same approval gate rather than auto-running.
  """

  alias Longpi.Agent.Settings

  @levels ~w(read_only auto full)a
  @read_tools ~w(read grep find ls)
  @default_level :auto

  @doc "Valid approval levels."
  def levels, do: @levels

  @doc "The setting key holding the approval level."
  def level_key, do: "approval_level"

  @doc "Current approval level."
  def level do
    case Settings.get(level_key()) do
      "read_only" -> :read_only
      "auto" -> :auto
      "full" -> :full
      _ -> @default_level
    end
  end

  @doc "Sets the approval level."
  def put_level(level) when level in @levels do
    Settings.put(level_key(), Atom.to_string(level))
  end

  @doc """
  Permission for a tool under the current level: `:allow` or `:ask`.

  `source` (`:builtin` | `:extension`) matters under `:auto`, where extension
  tools are gated like `bash`.
  """
  def mode(tool_name, source \\ :builtin), do: mode_at(level(), tool_name, source)

  defp mode_at(:full, _tool, _source), do: :allow
  defp mode_at(:auto, "bash", _source), do: :ask
  defp mode_at(:auto, _tool, :extension), do: :ask
  defp mode_at(:auto, _tool, _source), do: :allow
  defp mode_at(:read_only, tool, _source) when tool in @read_tools, do: :allow
  defp mode_at(:read_only, _tool, _source), do: :ask
end
