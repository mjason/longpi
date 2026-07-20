defmodule Longpi.Agent.Titler do
  @moduledoc """
  Generates a short conversation title from the first user message with a small
  LLM call. Best-effort: any failure leaves the conversation on its default
  label (the working directory).
  """

  alias Longpi.Agent.Message

  @max_length 60

  @system """
  You write terse titles for coding-assistant conversations. Reply with a
  plain title of 3-6 words that captures the task. No quotes, no punctuation
  at the end, no prefixes like "Title:". Use the language of the request.
  """

  @doc """
  Returns `{:ok, title}` (sanitized) or `{:error, reason}`. `first_message` is
  the user's opening message.
  """
  def title(llm, model, first_message) when is_binary(first_message) do
    messages = [
      Message.system(@system),
      Message.user("Write a title for a conversation that starts with:\n\n#{first_message}")
    ]

    noop = fn _event -> :ok end

    case llm.stream(model, messages, [], [], noop) do
      {:ok, %{text: text}} when is_binary(text) and text != "" -> {:ok, sanitize(text)}
      {:ok, _} -> {:error, :empty_title}
      {:error, reason} -> {:error, reason}
    end
  end

  # First non-empty line, stripped of surrounding quotes/backticks and capped.
  defp sanitize(text) do
    text
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> String.trim(~s("))
    |> String.trim("`")
    |> String.trim()
    |> truncate()
  end

  defp truncate(title) when byte_size(title) <= @max_length, do: title

  defp truncate(title) do
    title |> String.slice(0, @max_length) |> String.trim_trailing()
  end
end
