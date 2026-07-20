defmodule Longpi.Agent.Tool do
  @moduledoc """
  Behaviour for built-in, LLM-callable tools.

  Tools receive validated, atom-keyed args (via `ReqLLM.Tool` / NimbleOptions)
  plus a context map carrying per-session state such as `:cwd`. They return
  LLM-facing strings: `{:ok, text}` on success, `{:error, text}` with a
  message the model can act on.

  `parameter_schema/0` must be a NimbleOptions-compatible keyword schema so it
  plugs straight into `ReqLLM.Tool.new/1`.
  """

  @type ctx :: %{required(:cwd) => String.t(), optional(atom()) => term()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameter_schema() :: keyword()
  @callback run(args :: map(), ctx()) :: {:ok, binary()} | {:error, binary()}

  @doc """
  Expands a possibly-relative path against the session cwd.

      iex> Longpi.Agent.Tool.resolve_path("lib/foo.ex", %{cwd: "/proj"})
      "/proj/lib/foo.ex"

      iex> Longpi.Agent.Tool.resolve_path("/abs/foo.ex", %{cwd: "/proj"})
      "/abs/foo.ex"
  """
  def resolve_path(path, %{cwd: cwd}), do: Path.expand(path, cwd)
end
