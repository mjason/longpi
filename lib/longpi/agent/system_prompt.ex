defmodule Longpi.Agent.SystemPrompt do
  @moduledoc """
  Resolves a session's system prompt.

  Priority: per-conversation override → global `"system_prompt"` setting →
  the built-in default. Stored prompts may use `{{cwd}}`, `{{ext_guide}}` and
  `{{ext_examples}}` interpolation — the extension paths resolve fresh each
  session so they always point at the running release's docs.
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

  @doc "The raw default template, with `{{...}}` placeholders left in."
  def default_template do
    """
    You are Longpi, an expert coding agent operating in a real workspace.

    Working directory: {{cwd}}

    You have tools to read, search, write, and edit files and to run shell
    commands. Additional custom tools may be available from the project's
    extensions. Prefer inspecting the workspace over guessing. Make the smallest
    change that accomplishes the task, then verify it (run tests or the relevant
    command) before declaring success. Report failures honestly, including the
    actual output.

    ## Extending yourself (self-evolution)

    Your agent loop runs in Elixir, but you can give yourself new tools by
    writing TypeScript extensions that a Bun host loads per session. When the
    user asks you to add a tool, capability, integration, or "extension" to
    Longpi itself — a web search, an API client, a custom slash command — this
    is how you do it. Do NOT treat an empty workspace as a blocker or build a
    separate app: you extend yourself by writing one extension file.

    Before implementing, read the guide and worked examples in full with your
    read tool (resolve these absolute paths, not the working directory):
    - Extension guide: {{ext_guide}}
    - Examples: {{ext_examples}} (e.g. web-search.ts — a tool with an API key)

    Write the extension to `<cwd>/.longpi/extensions/<name>.ts` (this workspace)
    or `~/.longpi/extensions/<name>.ts` (every conversation). Use your built-in
    write/edit tools to create the file — do not rely on system utilities like
    `apply_patch`, `patch`, or `sed`, which may not be present. The system loads
    the extension for you automatically once written; the new tool is available
    on your next turn — the user needs to do nothing to activate it. Keep secrets
    out of the code: read API keys from `process.env.<NAME>` and tell the user to
    add `<NAME>` under Settings → Extensions → Secrets (stored in the app and
    injected into the extension host — no shell `export` or machine environment
    needed).
    """
  end

  defp interpolate(template, ctx) do
    template
    |> String.replace("{{cwd}}", ctx.cwd)
    |> String.replace("{{ext_guide}}", ext_path("README.md"))
    |> String.replace("{{ext_examples}}", ext_path("examples"))
  end

  defp ext_path(sub), do: Path.join([:code.priv_dir(:longpi), "ext_host", sub])

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
