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

  @doc """
  A user message with attachments. `attachments` is a list of string-keyed
  maps (kept as-is from the wire so JSON persistence round-trips cleanly):
  `%{"type" => "image", "media_type" => _, "data" => base64, "name" => _}` or
  `%{"type" => "file", "text" => _, "name" => _}`. Empty list ⇒ plain text.
  """
  def user(text, []), do: user(text)
  def user(text, attachments), do: %{role: :user, content: text, attachments: attachments}

  def assistant(text, tool_calls \\ [], model \\ nil),
    do: %{role: :assistant, content: text, tool_calls: tool_calls, model: model}

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
