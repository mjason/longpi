defmodule Longpi.Agent.Message do
  @moduledoc """
  Internal conversation message format: plain maps, provider-agnostic.

  The req_llm adapter translates these to `ReqLLM.Context` messages at the
  boundary; persistence maps them to Ash resources. Keeping them as plain
  maps means neither dependency leaks into the agent loop.
  """

  @type t :: %{
          required(:role) => :system | :user | :assistant | :tool,
          optional(atom()) => term()
        }

  def system(text), do: %{role: :system, content: text}

  def user(text), do: %{role: :user, content: text}

  def assistant(text, tool_calls \\ []),
    do: %{role: :assistant, content: text, tool_calls: tool_calls}

  def tool_result(call, content, error? \\ false) do
    %{
      role: :tool,
      tool_call_id: call.id,
      name: call.name,
      content: content,
      error?: error?
    }
  end
end
