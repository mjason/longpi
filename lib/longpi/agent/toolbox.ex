defmodule Longpi.Agent.Toolbox do
  @moduledoc """
  The set of tools available to a session, keyed by tool name.

  Each entry is a `Longpi.Agent.ToolSpec` — built-in modules and
  extension-contributed tools are normalized to the same shape. `execute/4` is
  the single entry point the agent loop uses: it looks up the tool, validates
  raw (string-keyed, JSON-decoded) arguments, and runs it. All failures come
  back as `{:error, text}` written for the model to read and correct.
  """

  alias Longpi.Agent.{Tools, ToolSpec}

  @default_modules [
    Tools.Read,
    Tools.Write,
    Tools.Edit,
    Tools.Bash,
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
  Merges extension-provided specs in, extension winning on name (matching pi:
  an extension tool overrides a built-in of the same name).
  """
  @spec with_extensions(t(), [ToolSpec.t()]) :: t()
  def with_extensions(toolbox, specs), do: Map.merge(toolbox, index(specs))

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
