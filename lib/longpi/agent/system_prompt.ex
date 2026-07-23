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
  def resolve(ctx, conversation_override \\ nil), do: elem(resolve_tagged(ctx, conversation_override), 1)

  @doc """
  Like `resolve/2`, but tags the source: `{:default, text}` when the built-in
  template is used, `{:custom, text}` when a conversation or global override
  wins. The caller uses this to decide whether to augment the prompt (e.g. the
  itemized tool list is added only to the default — a custom prompt is the
  user's own and is used verbatim).
  """
  def resolve_tagged(ctx, conversation_override \\ nil) do
    cond do
      present?(conversation_override) -> {:custom, interpolate(conversation_override, ctx)}
      present?(Settings.get("system_prompt")) -> {:custom, interpolate(Settings.get("system_prompt"), ctx)}
      true -> {:default, default(ctx)}
    end
  end

  @doc "The built-in default prompt (also the seed value for the admin editor)."
  def default(ctx), do: interpolate(default_template(), ctx)

  @doc "The raw default template, with `{{...}}` placeholders left in."
  def default_template do
    """
    You are Longpi, an expert coding agent operating in a real workspace.

    Working directory: {{cwd}}

    Your available tools are listed below. Search file contents with the grep
    tool and file names with the find tool; read files with the read tool;
    create and modify files with the write and edit tools; use bash for
    building, running tests, git, and executing programs. Prefer inspecting the
    workspace over guessing. Make the smallest change that accomplishes the
    task, then verify it (run tests or the relevant command) before declaring
    success. Report failures honestly, including the actual output.

    ## Extending yourself (self-evolution)

    Your agent loop runs in Elixir, but you can give yourself new tools by
    writing TypeScript extensions that an embedded QuickJS host runs per
    session. When the user asks you to add a tool, capability, integration, or
    "extension" to Longpi itself — a web search, an API client, a custom slash
    command — this is how you do it: one extension file, even in an otherwise
    empty workspace.

    Before implementing, read the guide and worked examples in full with your
    read tool (resolve these absolute paths, not the working directory):
    - Extension guide: {{ext_guide}} — it defines exactly the APIs the sandbox
      provides (fetch, process.env, longpi.run); the code runs in QuickJS. Author
      in TypeScript (`.ts`) — type annotations are stripped automatically before
      running; plain JavaScript also works. A tool returns plain text, OR
      `longpi.ui({ text, view })` to give the model `text` and the user a small
      TSX UI as `view` (a table/card/stat — name the file `.tsx`); the guide's
      "Custom result UI" section lists the components
    - Examples: {{ext_examples}} (e.g. web-search.ts — a tool with an API key;
      ui-dashboard.tsx — a tool returning `longpi.ui({ text, view })`)

    Create the extension with your built-in write/edit tools, at
    `<cwd>/.longpi/extensions/<name>.ts` (this workspace) or
    `~/.longpi/extensions/<name>.ts` (every conversation). The system loads it
    for you automatically once written; the new tool is available on your next
    turn. After writing or editing an extension, run the `check_extension` tool
    on its path to confirm it parses (there is no `tsc`/`npx` — this uses the
    same engine that loads extensions). Read API keys from `process.env.<NAME>`
    and tell the user to add `<NAME>` under Settings → Extensions → Secrets —
    the app stores it and injects it into the extension host on every call.
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
