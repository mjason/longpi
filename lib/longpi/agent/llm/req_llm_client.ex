defmodule Longpi.Agent.LLM.ReqLLMClient do
  @moduledoc """
  `Longpi.Agent.LLM` adapter backed by req_llm.

  Translation only: internal messages to `ReqLLM.Context`, tool behaviours to
  `ReqLLM.Tool` specs, stream chunks to sink events. Tool calls are collected
  and returned, never auto-executed (the spec callback is a stub - the loop
  in `Longpi.Agent.Turn` owns execution).

  For Anthropic models, prompt caching is always on: breakpoints on tools,
  system prompt, and the last message, so the growing conversation prefix
  stays cached across turns.
  """

  @behaviour Longpi.Agent.LLM

  alias ReqLLM.{Context, StreamResponse, ToolCall}

  @impl true
  def stream(model, messages, tools, opts, sink) do
    context = Context.new(Enum.map(messages, &to_req_llm_message/1))

    stream_opts =
      [tools: Enum.map(tools, &to_req_llm_tool/1)] ++ caching_opts(model) ++ opts

    with {:ok, response} <- ReqLLM.stream_text(model, context, stream_opts) do
      {:ok, consume(response, sink)}
    end
  end

  defp consume(response, sink) do
    initial = %{text: [], calls: %{}, order: []}

    # response.stream yields raw StreamChunk structs; StreamResponse.tokens/1
    # would map them down to bare text and drop tool calls entirely.
    result =
      response.stream
      |> Enum.reduce(initial, fn chunk, acc -> handle_chunk(chunk, acc, sink) end)

    forward_usage(response, sink)

    %{
      text: IO.iodata_to_binary(result.text),
      tool_calls:
        result.order
        |> Enum.reverse()
        |> Enum.map(&finalize_call(result.calls[&1]))
    }
  end

  defp handle_chunk(%{type: :content, text: text}, acc, sink) do
    sink.({:text_delta, text})
    %{acc | text: [acc.text | text]}
  end

  defp handle_chunk(%{type: :thinking, text: text}, acc, sink) do
    sink.({:thinking_delta, text})
    acc
  end

  # Announces a tool call. Arguments may be inline (chunk.arguments) or
  # streamed afterwards as JSON fragments in :meta chunks, keyed by index.
  defp handle_chunk(%{type: :tool_call} = chunk, acc, _sink) do
    index = chunk.metadata[:index] || map_size(acc.calls)

    call = %{
      id: chunk.metadata[:id] || "call_#{System.unique_integer([:positive])}",
      name: chunk.name,
      args: chunk.arguments || %{},
      fragments: []
    }

    %{acc | calls: Map.put(acc.calls, index, call), order: [index | acc.order]}
  end

  defp handle_chunk(
         %{type: :meta, metadata: %{tool_call_args: %{index: index, fragment: fragment}}},
         acc,
         _sink
       ) do
    case acc.calls do
      %{^index => call} ->
        call = %{call | fragments: [fragment | call.fragments]}
        %{acc | calls: Map.put(acc.calls, index, call)}

      _ ->
        acc
    end
  end

  defp handle_chunk(%{type: :meta} = chunk, acc, sink) do
    if usage = chunk.metadata[:usage], do: sink.({:usage, usage})
    acc
  end

  defp handle_chunk(_chunk, acc, _sink), do: acc

  defp finalize_call(%{fragments: []} = call), do: Map.delete(call, :fragments)

  defp finalize_call(call) do
    json = call.fragments |> Enum.reverse() |> IO.iodata_to_binary()

    args =
      case Jason.decode(json) do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> call.args
      end

    call |> Map.delete(:fragments) |> Map.put(:args, args)
  end

  defp forward_usage(response, sink) do
    case StreamResponse.usage(response) do
      usage when is_map(usage) -> sink.({:usage, usage})
      _ -> :ok
    end
  rescue
    # Usage metadata is best-effort; never fail a completed stream over it.
    _ -> :ok
  end

  defp to_req_llm_message(%{role: :system, content: content}), do: Context.system(content)
  defp to_req_llm_message(%{role: :user, content: content}), do: Context.user(content)

  defp to_req_llm_message(%{role: :assistant, tool_calls: calls} = message)
       when is_list(calls) and calls != [] do
    req_calls =
      Enum.map(calls, fn call ->
        ToolCall.new(call.id, call.name, Jason.encode!(call.args))
      end)

    Context.assistant(message.content || "", tool_calls: req_calls)
  end

  defp to_req_llm_message(%{role: :assistant, content: content}), do: Context.assistant(content)

  defp to_req_llm_message(%{role: :tool} = message) do
    Context.tool_result(message.tool_call_id, message.name, message.content)
  end

  defp to_req_llm_tool(module) do
    ReqLLM.Tool.new!(
      name: module.name(),
      description: module.description(),
      parameter_schema: module.parameter_schema(),
      # Execution happens in Longpi.Agent.Turn; req_llm never calls this.
      callback: fn _args -> {:ok, ""} end
    )
  end

  defp caching_opts("anthropic:" <> _rest) do
    [anthropic_prompt_cache: true, anthropic_cache_messages: true]
  end

  defp caching_opts(_model), do: []
end
