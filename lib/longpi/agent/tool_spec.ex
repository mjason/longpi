defmodule Longpi.Agent.ToolSpec do
  @moduledoc """
  A uniform tool the agent can call — whether a built-in Elixir module or a
  tool contributed by an extension (native QuickJS host).

  `schema` is either a NimbleOptions keyword list (built-ins, validated before
  `run`) or a raw JSON Schema map (extension tools, whose own handler validates
  and which we pass string-keyed args through to). `run` returns the model-facing
  `{:ok, text}` / `{:error, text}`.
  """

  @enforce_keys [:name, :description, :schema, :run]
  defstruct [:name, :description, :schema, :run, source: :builtin, model: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: (map(), Longpi.Agent.Tool.ctx() -> {:ok, binary()} | {:error, binary()}),
          source: :builtin | :extension,
          # A model tier ("J") or spec the tool prefers: after this tool runs,
          # the REST of the turn's LLM calls switch to it (session model is
          # untouched). nil = no preference.
          model: String.t() | nil
        }

  @doc "Wraps a built-in tool module (implementing `Longpi.Agent.Tool`) as a spec."
  @spec from_module(module()) :: t()
  def from_module(module) do
    %__MODULE__{
      name: module.name(),
      description: module.description(),
      schema: module.parameter_schema(),
      run: &module.run/2,
      source: :builtin
    }
  end
end
