defmodule Longpi.Agent.Toolbox do
  @moduledoc """
  The set of tools available to a session, keyed by tool name.

  `execute/4` is the single entry point the agent loop uses: it looks up the
  tool, validates raw (string-keyed, JSON-decoded) arguments against the
  tool's NimbleOptions schema, and runs it. All failures come back as
  `{:error, text}` written for the model to read and correct.
  """

  alias Longpi.Agent.Tools

  @default_modules [
    Tools.Read,
    Tools.Write,
    Tools.Edit,
    Tools.Bash,
    Tools.Grep,
    Tools.Find,
    Tools.Ls
  ]

  @type t :: %{String.t() => module()}

  @spec default_modules() :: [module()]
  def default_modules, do: @default_modules

  @spec new([module()]) :: t()
  def new(modules \\ @default_modules) do
    Map.new(modules, &{&1.name(), &1})
  end

  @spec modules(t()) :: [module()]
  def modules(toolbox), do: Map.values(toolbox)

  @spec execute(t(), String.t(), map(), Longpi.Agent.Tool.ctx()) ::
          {:ok, binary()} | {:error, binary()}
  def execute(toolbox, name, raw_args, ctx) do
    case Map.fetch(toolbox, name) do
      {:ok, module} ->
        with {:ok, args} <- validate(module, raw_args) do
          module.run(args, ctx)
        end

      :error ->
        {:error, "unknown tool: #{name}. Available tools: #{Enum.join(Map.keys(toolbox), ", ")}"}
    end
  end

  defp validate(module, raw_args) do
    schema = module.parameter_schema()

    kw =
      for {key, _spec} <- schema,
          {:ok, value} <- [fetch_arg(raw_args, key)],
          do: {key, value}

    case NimbleOptions.validate(kw, schema) do
      {:ok, validated} ->
        {:ok, Map.new(validated)}

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, "invalid arguments for #{module.name()}: #{message}"}
    end
  end

  # Args arrive string-keyed from JSON, atom-keyed from Elixir callers.
  defp fetch_arg(raw_args, key) do
    case raw_args do
      %{^key => value} -> {:ok, value}
      _ -> Map.fetch(raw_args, Atom.to_string(key))
    end
  end
end
