defmodule Longpi.Agent.Turn do
  @moduledoc """
  One agent turn: repeated LLM calls and tool executions until the model
  answers without requesting tools (or a guard trips).

  Pure orchestration - no processes, no state. `Longpi.Agent.Session` runs
  this inside a supervised task; tests drive it directly with a mocked LLM.

  The `config` map carries the collaborators:

    * `:llm` - module implementing `Longpi.Agent.LLM`
    * `:model` - model spec string (e.g. `"anthropic:claude-sonnet-4-5"`)
    * `:toolbox` - `Longpi.Agent.Toolbox.t()`
    * `:ctx` - tool context (`%{cwd: ...}`)
    * `:sink` - function receiving streaming events

  Returns `{:ok, new_messages}` or `{:error, reason, new_messages}` where
  `new_messages` are the messages produced during this turn, in order.
  """

  alias Longpi.Agent.{Message, Toolbox}

  @default_max_iterations 25

  @spec run(map(), [Message.t()], keyword()) ::
          {:ok, [Message.t()]} | {:error, term(), [Message.t()]}
  def run(config, messages, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    iterate(config, messages, [], max_iterations)
  end

  defp iterate(_config, _history, produced, 0) do
    {:error, :max_iterations, Enum.reverse(produced)}
  end

  defp iterate(config, history, produced, remaining) do
    %{llm: llm, model: model, toolbox: toolbox, sink: sink} = config
    conversation = history ++ Enum.reverse(produced)

    case llm.stream(model, conversation, Toolbox.specs(toolbox), stream_opts(config), sink) do
      {:ok, %{tool_calls: []} = completion} ->
        {:ok, Enum.reverse([Message.assistant(completion.text) | produced])}

      {:ok, %{tool_calls: calls} = completion} ->
        assistant = Message.assistant(completion.text, calls)
        results = Enum.map(calls, &execute_call(config, &1))
        produced = Enum.reverse(results) ++ [assistant | produced]
        iterate(config, history, produced, remaining - 1)

      {:error, reason} ->
        {:error, reason, Enum.reverse(produced)}
    end
  end

  # req_llm's unified reasoning control; only sent when the conversation sets a
  # level, so non-reasoning models are unaffected. Providers translate it
  # (OpenAI reasoning_effort, Anthropic thinking budget, Google thinking level).
  defp stream_opts(config) do
    case config[:reasoning_effort] do
      effort when effort in [:minimal, :low, :medium, :high, :xhigh] ->
        [reasoning_effort: effort]

      _ ->
        []
    end
  end

  defp execute_call(config, call) do
    %{toolbox: toolbox, ctx: ctx, sink: sink} = config
    sink.({:tool_call, call})

    # Per-call progress channel: tools (e.g. bash) stream output live to the UI.
    ctx =
      Map.put(ctx, :progress, fn chunk -> sink.({:tool_output, %{id: call.id, chunk: chunk}}) end)

    {content, error?} =
      case authorize(config, call) do
        :allow -> invoke(toolbox, call, ctx)
        :deny -> {"Permission denied: the user did not approve running #{call.name}.", true}
      end

    sink.({:tool_result, %{call: call, content: content, error?: error?}})
    Message.tool_result(call, content, error?)
  end

  defp invoke(toolbox, call, ctx) do
    case Toolbox.execute(toolbox, call.name, call.args, ctx) do
      {:ok, content} -> {content, false}
      {:error, content} -> {content, true}
    end
  end

  # `authorize` is injected by the caller (the Session). Absent, everything is
  # allowed - keeps Turn usable standalone and in tests.
  defp authorize(config, call) do
    case Map.get(config, :authorize) do
      fun when is_function(fun, 1) -> fun.(call)
      _ -> :allow
    end
  end
end
