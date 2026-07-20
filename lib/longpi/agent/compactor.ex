defmodule Longpi.Agent.Compactor do
  @moduledoc """
  Context compaction, in the style of pi: when a conversation's prompt grows
  past a threshold, summarize the older messages into a structured checkpoint
  and keep only the recent messages verbatim.

  The pure functions here (token estimate, cut-point planning) are testable in
  isolation; `summarize/4` performs the one LLM call, driven through the
  `Longpi.Agent.LLM` behaviour so it stays mockable.
  """

  alias Longpi.Agent.Message

  @doc "Rough token estimate for a message (chars/4, like pi's heuristic)."
  def estimate_tokens(message) do
    text = message[:content] || ""
    tool = message |> Map.get(:tool_calls, []) |> inspect()
    div(String.length(text) + String.length(tool), 4)
  end

  @doc """
  Splits `messages` (the non-system history not yet covered by a prior
  summary) into `{to_summarize, to_keep}`: the tail whose estimated tokens fit
  in `keep_tokens` is kept verbatim, the rest is summarized. Returns
  `{[], messages}` when there is nothing worth summarizing.
  """
  def plan(messages, keep_tokens) do
    {kept, _acc} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn msg, {kept, acc} ->
        acc = acc + estimate_tokens(msg)
        if acc <= keep_tokens, do: {[msg | kept], acc}, else: {kept, acc}
      end)

    # Always keep at least the most recent message, so we never fold everything.
    kept = if kept == [], do: Enum.take(messages, -1), else: kept
    to_summarize = Enum.take(messages, length(messages) - length(kept))

    if to_summarize == [], do: {[], messages}, else: {to_summarize, kept}
  end

  @doc """
  Produces a structured summary of `to_summarize`, optionally updating a
  `previous_summary`. Returns `{:ok, summary_text}` or `{:error, reason}`.
  """
  def summarize(llm, model, to_summarize, previous_summary \\ nil) do
    instruction =
      if previous_summary do
        Message.user(
          "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n" <> update_prompt()
        )
      else
        Message.user(summarize_prompt())
      end

    messages = [Message.system(system_prompt()) | to_summarize] ++ [instruction]
    noop = fn _event -> :ok end

    case llm.stream(model, messages, [], [], noop) do
      {:ok, %{text: text}} when is_binary(text) and text != "" -> {:ok, text}
      {:ok, _} -> {:error, :empty_summary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Builds the LLM context after compaction: summary framed as a user message."
  def summary_message(summary) do
    Message.user(
      "Summary of the earlier conversation (older messages were compacted):\n\n#{summary}"
    )
  end

  defp system_prompt do
    "You compress coding-agent conversations into structured checkpoints that " <>
      "another model uses to continue the work. Preserve exact file paths, " <>
      "function names, and error messages. Be concise."
  end

  defp summarize_prompt do
    """
    The messages above are a conversation to summarize. Produce a structured
    context checkpoint using this exact format:

    ## Goal
    [What the user is trying to accomplish.]

    ## Constraints & Preferences
    - [Constraints/preferences the user stated, or "(none)".]

    ## Progress
    ### Done
    - [x] [Completed changes]
    ### In Progress
    - [ ] [Current work]
    ### Blocked
    - [Blockers, if any]

    ## Key Decisions
    - **[Decision]**: [Rationale]

    ## Next Steps
    1. [What should happen next]

    ## Critical Context
    - [Data, paths, or references needed to continue, or "(none)".]
    """
  end

  defp update_prompt do
    """
    The messages above are NEW messages to fold into the existing summary in
    <previous-summary>. Preserve all existing information, add new progress,
    decisions, and context, move finished items to Done, and update Next Steps.
    Keep the same section format as the previous summary.
    """
  end
end
