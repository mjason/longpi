defmodule Longpi.Agent.Permissions do
  @moduledoc """
  A single approval level governs tool execution, in the style of Codex/Claude
  Code:

    * `:read_only` - only read-type tools run automatically; anything that
      writes or executes asks for approval
    * `:auto` - reads and workspace edits run automatically; `bash` (arbitrary
      commands) asks
    * `:full` - everything runs automatically, no prompts

  Stored in the `"approval_level"` setting; defaults to `:auto`.
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

  @doc "Permission for a tool under the current level: `:allow` or `:ask`."
  def mode(tool_name), do: mode(level(), tool_name)

  def mode(:full, _tool), do: :allow
  def mode(:auto, "bash"), do: :ask
  def mode(:auto, _tool), do: :allow
  def mode(:read_only, tool) when tool in @read_tools, do: :allow
  def mode(:read_only, _tool), do: :ask
end
