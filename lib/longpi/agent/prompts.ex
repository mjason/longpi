defmodule Longpi.Agent.Prompts do
  @moduledoc """
  Central place for every hardcoded prompt string that the admin UI can
  override. Overrides live in the `Setting` key/value store; each falls back
  to the code default when unset.

  - system prompt: `Longpi.Agent.SystemPrompt` (`"system_prompt"` key)
  - tool descriptions: `"tool_desc:<name>"` keys
  """

  alias Longpi.Agent.Settings

  @doc "Setting key holding the description override for a tool."
  def tool_desc_key(name), do: "tool_desc:#{name}"

  @doc "Effective description for a tool, honoring an admin override."
  def tool_description(name, default) do
    Settings.get(tool_desc_key(name), default)
  end

  @doc """
  Catalog of the built-in tools with their default and effective descriptions,
  for rendering the admin UI.
  """
  def tool_catalog do
    Longpi.Agent.Toolbox.default_modules()
    |> Enum.map(fn module ->
      name = module.name()
      default = module.description()

      %{
        name: name,
        default_description: default,
        description: tool_description(name, default)
      }
    end)
  end
end
