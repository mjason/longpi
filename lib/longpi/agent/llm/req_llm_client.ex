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
  alias ReqLLM.Message.ContentPart

  @doc """
  Translates internal message maps to a `ReqLLM.Context`. Exposed so the
  message-to-context mapping (including multimodal attachments) is testable
  without a live provider call.
  """
  def build_context(messages), do: Context.new(Enum.map(messages, &to_req_llm_message/1))

  @impl true
  def stream(model, messages, tools, opts, sink) do
    context = build_context(messages)

    # Admin-configured provider credentials take priority; falling back to
    # req_llm's own env/config lookup when a provider isn't set in the db.
    stream_opts =
      [tools: Enum.map(tools, &to_req_llm_tool/1)] ++
        caching_opts(model) ++ Longpi.Agent.Providers.request_opts(model) ++ opts

    # Retry transient failures (rate limits, 5xx, network) with backoff — but
    # only while no tokens have reached the sink yet, since the stream is lazy
    # and re-running after partial output would duplicate it.
    emitted = :counters.new(1, [])

    guarded_sink = fn event ->
      :counters.add(emitted, 1, 1)
      sink.(event)
    end

    Longpi.Agent.Retry.with_backoff(
      fn -> run_stream(model, context, stream_opts, guarded_sink) end,
      retryable?: fn reason ->
        :counters.get(emitted, 1) == 0 and Longpi.Agent.Retry.transient?(reason)
      end
    )
  end

  defp run_stream(model, context, stream_opts, sink) do
    with {:ok, response} <- ReqLLM.stream_text(model, context, stream_opts) do
      {:ok, consume(response, sink)}
    end
  rescue
    # The lazy stream raises on a non-200 (e.g. 429) once consumed; surface it
    # as an error so Retry can classify and back off.
    exception -> {:error, exception}
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

  defp to_req_llm_message(%{role: :user, attachments: [_ | _] = attachments} = message) do
    text = normalize_directives(message[:content] || "")

    # Images are numbered to match the composer's inline "[Image #N]" markers
    # (pi-style): each image part is preceded by a text label so the model can
    # tie "[Image #2]" in the prose to the actual second image.
    {parts, _n} =
      Enum.reduce(attachments, {[], 0}, fn attachment, {acc, n} ->
        case attachment_part(attachment) do
          nil ->
            {acc, n}

          part ->
            if attachment["type"] == "image" do
              label = ContentPart.text(image_label(n + 1, attachment["name"]))
              {[part, label | acc], n + 1}
            else
              {[part | acc], n}
            end
        end
      end)

    parts = Enum.reverse(parts)
    parts = if text == "", do: parts, else: [ContentPart.text(text) | parts]
    Context.user(parts)
  end

  defp to_req_llm_message(%{role: :user, content: content}),
    do: Context.user(safe(normalize_directives(content)))

  defp to_req_llm_message(%{role: :assistant, tool_calls: calls} = message)
       when is_list(calls) and calls != [] do
    req_calls =
      Enum.map(calls, fn call ->
        ToolCall.new(call.id, call.name, Jason.encode!(call.args))
      end)

    Context.assistant(safe(message.content || ""), tool_calls: req_calls)
  end

  defp to_req_llm_message(%{role: :assistant, content: content}), do: Context.assistant(safe(content))

  defp to_req_llm_message(%{role: :tool} = message) do
    # A tool that returned a `longpi.ui({text, view})` envelope stores both (the
    # client renders `view`); the model gets the author-provided `text`, never
    # the vdom.
    content =
      case Longpi.Agent.ExtensionUI.model_text(message.content) do
        {:ok, text} -> text
        :passthrough -> safe(message.content)
      end

    Context.tool_result(message.tool_call_id, message.name, content)
  end

  # Never let non-UTF-8 bytes reach the provider request builder — a JSON encode
  # error there fails the whole turn.
  defp safe(content) when is_binary(content), do: String.replace_invalid(content)
  defp safe(content), do: content

  defp image_label(n, name) when is_binary(name) and name != "", do: "[Image ##{n}: #{name}]"
  defp image_label(n, _name), do: "[Image ##{n}]"

  # The composer's "@" file mentions are stored as assistant-ui directives
  # (`:file[label]{name=path}`) so the UI can render chips. The MODEL gets the
  # pi convention instead: a plain `@path` — the path itself is the signal, and
  # the agent opens it with its read tool.
  @doc false
  def normalize_directives(text) when is_binary(text) do
    Regex.replace(~r/:file\[[^\]]*\]\{name=([^}]*)\}/, text, "@\\1")
  end

  def normalize_directives(other), do: other

  # Attachments are string-keyed maps straight off the wire (see Message.user/2).
  defp attachment_part(%{"type" => "image", "data" => data, "media_type" => media_type}) do
    case Base.decode64(data) do
      {:ok, bytes} -> ContentPart.image(bytes, media_type)
      :error -> nil
    end
  end

  defp attachment_part(%{"type" => "file", "text" => text}), do: ContentPart.text(text)
  defp attachment_part(_), do: nil

  defp to_req_llm_tool(%Longpi.Agent.ToolSpec{} = spec) do
    ReqLLM.Tool.new!(
      name: spec.name,
      # Admin-overridable via the "tool_desc:<name>" setting.
      description: Longpi.Agent.Prompts.tool_description(spec.name, spec.description),
      # NimbleOptions keyword (built-ins) or a raw JSON Schema map (extensions).
      parameter_schema: spec.schema,
      # Execution happens in Longpi.Agent.Turn; req_llm never calls this.
      callback: fn _args -> {:ok, ""} end
    )
  end

  defp caching_opts("anthropic:" <> _rest) do
    [anthropic_prompt_cache: true, anthropic_cache_messages: true]
  end

  defp caching_opts(_model), do: []
end
