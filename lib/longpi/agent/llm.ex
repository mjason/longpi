defmodule Longpi.Agent.LLM do
  @moduledoc """
  Boundary behaviour for talking to an LLM provider.

  The agent loop depends only on this contract, so tests mock it with Mox and
  the real adapter (`Longpi.Agent.LLM.ReqLLMClient`) stays a thin translation
  layer over req_llm.

  `stream/5` performs one model call: it pushes streaming events into `sink`
  as they arrive and returns the completed assistant turn. Tool calls are
  returned, never executed - execution belongs to `Longpi.Agent.Turn`.
  """

  alias Longpi.Agent.Message

  @type tool_call :: %{id: String.t(), name: String.t(), args: map()}
  @type completion :: %{text: String.t(), tool_calls: [tool_call()]}

  @typedoc """
  Events pushed into the sink during streaming:
  `{:text_delta, binary}`, `{:thinking_delta, binary}`, `{:usage, map}`.
  """
  @type event :: {:text_delta, binary()} | {:thinking_delta, binary()} | {:usage, map()}
  @type sink :: (event() -> any())

  @callback stream(
              model :: String.t(),
              messages :: [Message.t()],
              tools :: [module()],
              opts :: keyword(),
              sink()
            ) :: {:ok, completion()} | {:error, term()}
end
