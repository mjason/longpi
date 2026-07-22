defmodule LongpiWeb.ConversationChannel do
  @moduledoc """
  Realtime bridge between a browser and one agent session.

  Joining `conversation:<id>` gets-or-starts the session process and replies
  with the message history; agent events arrive via PubSub and are pushed as
  `text_delta` / `thinking_delta` / `tool_call` / `tool_result` / `usage` /
  `turn_ended` / `turn_failed`. The session outlives the channel - closing
  the tab never kills a running turn.
  """

  use LongpiWeb, :channel

  alias Longpi.Agent.{Session, Sessions}

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    case Sessions.ensure_started(conversation_id) do
      {:ok, session} ->
        Phoenix.PubSub.subscribe(Longpi.PubSub, Session.topic(conversation_id))

        history =
          session
          |> Session.messages()
          |> Enum.reject(&(&1.role == :system))
          |> Enum.map(&serialize_message/1)

        ext = Session.ext_info(session)

        socket =
          assign(socket, conversation_id: conversation_id, session: session, ext_host: ext.host)

        reply = %{
          messages: history,
          status: Session.status(session),
          pending_approvals: Session.pending_approvals(session),
          context_usage: Session.context_usage(session),
          reasoning_effort: Session.reasoning_effort(session),
          commands: ext.commands,
          subagents: serialize_subagents(Session.subagents(session))
        }

        {:ok, reply, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("send_message", %{"text" => text} = payload, socket) do
    attachments = sanitize_attachments(payload["attachments"])

    case Session.send_message(socket.assigns.session, text, attachments) do
      :ok -> {:reply, :ok, socket}
      {:error, :busy} -> {:reply, {:error, %{reason: "busy"}}, socket}
    end
  end

  def handle_in("interrupt", _payload, socket) do
    :ok = Session.interrupt(socket.assigns.session)
    {:reply, :ok, socket}
  end

  def handle_in("edit_last", %{"text" => text} = payload, socket) do
    attachments = sanitize_attachments(payload["attachments"])

    case Session.edit_last(socket.assigns.session, text, attachments) do
      :ok -> {:reply, :ok, socket}
      {:error, :busy} -> {:reply, {:error, %{reason: "busy"}}, socket}
      {:error, :nothing_to_edit} -> {:reply, {:error, %{reason: "nothing to edit"}}, socket}
    end
  end

  def handle_in("regenerate", _payload, socket) do
    case Session.regenerate(socket.assigns.session) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("permission_response", %{"id" => id, "approved" => approved}, socket) do
    Session.respond_approval(socket.assigns.session, id, approved == true)
    {:reply, :ok, socket}
  end

  def handle_in("set_model", %{"spec" => spec}, socket) when is_binary(spec) do
    case Session.set_model(socket.assigns.session, String.trim(spec)) do
      {:ok, model} -> {:reply, {:ok, %{model: model}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("set_reasoning", %{"effort" => effort}, socket) do
    # nil / "" / "auto" all mean "let the model decide".
    effort = if is_binary(effort), do: String.trim(effort), else: nil
    {:ok, effort} = Session.set_reasoning(socket.assigns.session, effort)
    {:reply, {:ok, %{reasoning_effort: effort}}, socket}
  end

  def handle_in("command", %{"name" => "compact"}, socket) do
    case Session.compact(socket.assigns.session) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("command", %{"name" => "rename"} = payload, socket) do
    case Session.rename(socket.assigns.session, payload["arg"] || "") do
      {:ok, title} ->
        {:reply, {:ok, %{content: "Renamed to “#{title}”."}}, socket}

      {:error, :empty} ->
        {:reply, {:error, %{reason: "Usage: /rename <new title>"}}, socket}
    end
  end

  def handle_in("command", %{"name" => "reload"}, socket) do
    case Session.reload_extensions(socket.assigns.session) do
      {:ok, %{tools: tools, commands: commands}} ->
        {:reply,
         {:ok, %{content: "Extensions reloaded — #{tools} tool(s), #{commands} command(s)."}},
         socket}

      {:error, :no_extensions} ->
        {:reply, {:error, %{reason: "No extension host for this conversation."}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  # Extension-registered slash commands run in the Bun host; the handler's text
  # comes back as `content` for the client to surface as a notice.
  def handle_in("command", %{"name" => name} = payload, socket) do
    case socket.assigns[:ext_host] do
      nil ->
        {:reply, {:error, %{reason: "unknown command: #{name}"}}, socket}

      host ->
        case Longpi.Extensions.Host.call_command(host, name, payload["arg"] || "") do
          {:ok, content} -> {:reply, {:ok, %{content: content}}, socket}
          {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
        end
    end
  end

  # Current history snapshot, for a client that re-attached to an
  # already-joined channel and needs to rebuild its view.
  def handle_in("get_state", _payload, socket) do
    session = socket.assigns.session

    history =
      session
      |> Session.messages()
      |> Enum.reject(&(&1.role == :system))
      |> Enum.map(&serialize_message/1)

    reply = %{
      messages: history,
      status: Session.status(session),
      pending_approvals: Session.pending_approvals(session),
      context_usage: Session.context_usage(session),
      reasoning_effort: Session.reasoning_effort(session),
      commands: Session.ext_info(session).commands,
      subagents: serialize_subagents(Session.subagents(session))
    }

    {:reply, {:ok, reply}, socket}
  end

  @impl true
  def handle_info({:agent_event, seq, event}, socket) do
    case serialize_event(event) do
      {name, payload} -> push(socket, name, Map.put(payload, :seq, seq))
      nil -> :ok
    end

    {:noreply, socket}
  end

  defp serialize_event({:text_delta, text}), do: {"text_delta", %{text: text}}
  defp serialize_event({:thinking_delta, text}), do: {"thinking_delta", %{text: text}}

  defp serialize_event({:tool_call, call}),
    do: {"tool_call", %{id: call.id, name: call.name, args: call.args}}

  defp serialize_event({:tool_result, %{call: call, content: content, error?: error?}}),
    do: {"tool_result", %{id: call.id, name: call.name, content: content, error: error?}}

  defp serialize_event({:tool_output, %{id: id, chunk: chunk}}),
    do: {"tool_output", %{id: id, chunk: chunk}}

  defp serialize_event({:approval_request, call}),
    do: {"approval_request", %{id: call.id, name: call.name, args: call.args}}

  defp serialize_event({:compaction_started}), do: {"compaction_started", %{}}
  defp serialize_event({:compaction_ended}), do: {"compaction_ended", %{}}

  defp serialize_event({:compacted, %{covered_through: covered}}),
    do: {"compacted", %{covered_through: covered}}

  defp serialize_event({:context_usage, %{used: used, window: window}}),
    do: {"context_usage", %{used: used, window: window}}

  defp serialize_event({:model_changed, model}), do: {"model_changed", %{model: model}}

  defp serialize_event({:reasoning_changed, effort}),
    do: {"reasoning_changed", %{reasoning_effort: effort}}

  defp serialize_event({:titled, title}), do: {"titled", %{title: title}}

  # Subagent snapshot: %{handle => %{conversation_id, role, status, task, started_at}}
  defp serialize_event({:subagents, snapshot}),
    do: {"subagents", %{agents: serialize_subagents(snapshot)}}

  defp serialize_subagents(snapshot) do
    Map.new(snapshot, fn {handle, info} ->
      {handle,
       %{
         conversationId: info.conversation_id,
         role: info.role,
         status: info.status,
         task: info.task |> String.split("\n") |> hd() |> String.slice(0, 120),
         startedAt: info.started_at
       }}
    end)
  end

  defp serialize_event({:commands, commands}), do: {"commands", %{commands: commands}}

  defp serialize_event({:history, messages}),
    do: {"history", %{messages: Enum.map(messages, &serialize_message/1)}}

  defp serialize_event({:turn_ended, reason}), do: {"turn_ended", %{reason: to_string(reason)}}

  defp serialize_event({:turn_failed, reason}),
    do: {"turn_failed", %{reason: inspect(reason)}}

  defp serialize_event(_event), do: nil

  defp serialize_message(message) do
    %{
      role: message.role,
      content: message[:content] || "",
      attachments: message[:attachments] || [],
      tool_calls: message[:tool_calls] || [],
      tool_call_id: message[:tool_call_id],
      name: message[:name],
      error: message[:error?] || false
    }
  end

  # Keep only well-formed attachments, capped, with just the fields we use — the
  # payload is untrusted browser input that gets persisted and sent to the model.
  @max_attachments 10
  # ~6MB image decoded; 512KB inlined text. Bounds untrusted payloads that get
  # persisted to SQLite and forwarded to the model.
  @max_image_bytes 8_000_000
  @max_text_bytes 512_000

  defp sanitize_attachments(list) when is_list(list) do
    list
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_attachments)
  end

  defp sanitize_attachments(_), do: []

  defp normalize_attachment(%{"type" => "image", "data" => data, "media_type" => media_type} = a)
       when is_binary(data) and is_binary(media_type) do
    if String.starts_with?(media_type, "image/") and byte_size(data) <= @max_image_bytes and
         match?({:ok, _}, Base.decode64(data)) do
      %{
        "type" => "image",
        "name" => to_string(a["name"] || "image"),
        "media_type" => media_type,
        "data" => data
      }
    end
  end

  defp normalize_attachment(%{"type" => "file", "text" => text} = attachment)
       when is_binary(text) do
    if byte_size(text) <= @max_text_bytes do
      %{"type" => "file", "name" => to_string(attachment["name"] || "file"), "text" => text}
    end
  end

  defp normalize_attachment(_), do: nil
end
