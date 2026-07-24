defmodule Longpi.Agent.Toolbox do
  @moduledoc """
  The set of tools available to a session, keyed by tool name.

  Each entry is a `Longpi.Agent.ToolSpec` — built-in modules and
  extension-contributed tools are normalized to the same shape. `execute/4` is
  the single entry point the agent loop uses: it looks up the tool, validates
  raw (string-keyed, JSON-decoded) arguments, and runs it. All failures come
  back as `{:error, text}` written for the model to read and correct.
  """

  require Logger

  alias Longpi.Agent.{Tools, ToolSpec}

  @default_modules [
    Tools.Read,
    Tools.Write,
    Tools.Edit,
    Tools.ApplyPatch,
    Tools.Bash,
    Tools.ContinueLater,
    Tools.Schedule,
    Tools.NameSecret,
    Tools.Grep,
    Tools.Find,
    Tools.Ls
  ]

  @type t :: %{String.t() => ToolSpec.t()}

  @spec default_modules() :: [module()]
  def default_modules, do: @default_modules

  @spec new([module()]) :: t()
  def new(modules \\ @default_modules) do
    modules |> Enum.map(&ToolSpec.from_module/1) |> index()
  end

  @doc """
  Merges more specs into the toolbox with a collision policy:

    * an extension tool may NOT shadow a built-in (or subagent) tool — the
      built-in is kept and the collision is logged. This stops an extension
      (especially a global one) from silently replacing `bash`/`edit`/`read`
      etc. with arbitrary code that would then run under the built-in's name.
    * a later extension tool overriding an earlier extension of the same name
      wins (last loaded), but the duplicate is logged.
    * non-extension specs (the subagent tool family) merge as before.
  """
  @spec with_extensions(t(), [ToolSpec.t()]) :: t()
  def with_extensions(toolbox, specs) do
    Enum.reduce(specs, toolbox, fn %ToolSpec{name: name} = spec, acc ->
      case acc do
        %{^name => %ToolSpec{source: :builtin}} when spec.source == :extension ->
          Logger.warning(
            "extension tool #{inspect(name)} shadows a built-in tool; ignoring the extension's version"
          )

          acc

        %{^name => %ToolSpec{source: :extension}} when spec.source == :extension ->
          Logger.warning("duplicate extension tool #{inspect(name)}; the last one loaded wins")
          Map.put(acc, name, spec)

        _ ->
          Map.put(acc, name, spec)
      end
    end)
  end

  @spec specs(t()) :: [ToolSpec.t()]
  def specs(toolbox), do: Map.values(toolbox)

  @spec execute(t(), String.t(), map(), Longpi.Agent.Tool.ctx()) ::
          {:ok, binary()} | {:error, binary()}
  def execute(toolbox, name, raw_args, ctx) do
    case Map.fetch(toolbox, name) do
      {:ok, spec} ->
        with {:ok, args} <- validate(spec, raw_args) do
          spec.run.(args, ctx)
        end

      :error ->
        {:error, "unknown tool: #{name}. Available tools: #{Enum.join(Map.keys(toolbox), ", ")}"}
    end
  end

  defp index(specs), do: Map.new(specs, &{&1.name, &1})

  # Built-ins carry a NimbleOptions keyword schema and get validated + atom-keyed.
  defp validate(%ToolSpec{schema: schema, name: name}, raw_args) when is_list(schema) do
    kw =
      for {key, _spec} <- schema,
          {:ok, value} <- [fetch_arg(raw_args, key)],
          do: {key, value}

    case NimbleOptions.validate(kw, schema) do
      {:ok, validated} ->
        {:ok, Map.new(validated)}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, "invalid arguments for #{name}: #{message}"}
    end
  end

  # Extension tools carry a JSON Schema map; the extension's own handler
  # validates, so we forward the raw (string-keyed) args untouched.
  defp validate(%ToolSpec{}, raw_args), do: {:ok, raw_args}

  # Args arrive string-keyed from JSON, atom-keyed from Elixir callers.
  defp fetch_arg(raw_args, key) do
    case raw_args do
      %{^key => value} -> {:ok, value}
      _ -> Map.fetch(raw_args, Atom.to_string(key))
    end
  end
end
