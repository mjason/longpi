defmodule Longpi.Agent.SystemPrompt do
  @moduledoc """
  Resolves a session's system prompt.

  Priority: per-conversation override → global `"system_prompt"` setting →
  the built-in default. Stored prompts may use `{{cwd}}` interpolation.
  """

  alias Longpi.Agent.Settings

  @doc "Resolves the prompt for `ctx`, honoring an optional conversation override."
  def resolve(ctx, conversation_override \\ nil) do
    cond do
      present?(conversation_override) -> interpolate(conversation_override, ctx)
      present?(Settings.get("system_prompt")) -> interpolate(Settings.get("system_prompt"), ctx)
      true -> default(ctx)
    end
  end

  @doc "The built-in default prompt (also the seed value for the admin editor)."
  def default(ctx), do: interpolate(default_template(), ctx)

  @doc "The raw default template, with `{{cwd}}` placeholders left in."
  def default_template do
    """
    You are Longpi, a coding agent operating in a real workspace.

    Working directory: {{cwd}}

    Use the available tools to read, search, write, and edit files and to run
    shell commands. Prefer inspecting the workspace over guessing. Make the
    smallest change that accomplishes the task, then verify it (run tests or
    the relevant command) before declaring success. Report failures honestly,
    including the actual output.
    """
  end

  defp interpolate(template, ctx) do
    String.replace(template, "{{cwd}}", ctx.cwd)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
