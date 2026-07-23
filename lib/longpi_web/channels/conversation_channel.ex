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
        # Keep the session alive while this channel is connected (and let it
        # idle-reap once every tab closes).
        Session.watch(session, self())

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
          subagents: serialize_subagents(Session.subagents(session)),
          subagent_approvals: Enum.map(Session.subagent_approvals(session), &serialize_approval/1)
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

  # /loop [N] [every <interval>] <task> — run the task in a self-continuing
  # loop (N iterations, default 10). `every 30m` waits between turns (a timed
  # polling loop). /loop stop cancels; /loop reports status.
  def handle_in("command", %{"name" => "loop"} = payload, socket) do
    session = socket.assigns.session
    arg = String.trim(payload["arg"] || "")

    cond do
      arg == "" ->
        case Session.loop_status(session) do
          nil ->
            {:reply,
             {:ok, %{content: "Usage: /loop [N] [every 30m] <task> — or /loop stop."}}, socket}

          %{remaining: remaining, total: total} ->
            {:reply,
             {:ok, %{content: "Loop running: #{total - remaining}/#{total} turns used."}}, socket}
        end

      arg == "stop" ->
        {:ok, stopped?} = Session.stop_loop(session)
        message = if stopped?, do: "Loop stopped.", else: "No loop running."
        {:reply, {:ok, %{content: message}}, socket}

      true ->
        {iterations, rest} =
          case Integer.parse(arg) do
            {n, " " <> rest} when n > 0 -> {n, String.trim_leading(rest)}
            _ -> {10, arg}
          end

        {every_ms, task} =
          case Regex.run(~r/^every\s+(\S+)\s+(.+)$/s, rest) do
            [_, interval, task] ->
              case Longpi.Agent.Tools.ContinueLater.parse_delay(interval) do
                {:ok, ms} when ms > 0 -> {ms, task}
                _ -> {:error, interval}
              end

            nil ->
              {0, rest}
          end

        case every_ms do
          :error ->
            {:reply,
             {:error, %{reason: "invalid interval #{inspect(task)} — use 30s / 10m / 2h"}},
             socket}

          _ ->
            case Session.start_loop(session, task, iterations, every_ms) do
              {:ok, n} ->
                suffix = if every_ms > 0, do: ", every #{div(every_ms, 1000)}s", else: ""
                {:reply, {:ok, %{content: "Loop started (up to #{n} turns#{suffix})."}}, socket}

              {:error, reason} ->
                {:reply, {:error, %{reason: to_string(reason)}}, socket}
            end
        end
    end
  end

  # /schedule <cron> <task> — cron-fire the task into THIS conversation.
  # Also: /schedule list, /schedule rm <n>, and a "HH:MM <task>" daily shortcut.
  def handle_in("command", %{"name" => "schedule"} = payload, socket) do
    conversation_id = socket.assigns.conversation_id
    arg = String.trim(payload["arg"] || "")

    cond do
      arg == "" or arg == "list" ->
        {:reply, {:ok, %{content: schedule_list(conversation_id)}}, socket}

      String.starts_with?(arg, "rm ") ->
        {:reply, schedule_remove(conversation_id, String.trim_leading(arg, "rm ")), socket}

      true ->
        {:reply, schedule_add(conversation_id, arg), socket}
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

  # Extension-registered slash commands run in the QuickJS host; the handler's text
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
      subagents: serialize_subagents(Session.subagents(session)),
      subagent_approvals: Enum.map(Session.subagent_approvals(session), &serialize_approval/1)
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
    do: {"tool_result", %{id: call.id, name: call.name, content: safe_text(content), error: error?}}

  defp serialize_event({:tool_output, %{id: id, chunk: chunk}}),
    do: {"tool_output", %{id: id, chunk: safe_text(chunk)}}

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

  # A child's tool approval bubbled up for the user to answer here.
  defp serialize_event({:subagent_approval, entry}),
    do: {"subagent_approval", serialize_approval(entry)}

  defp serialize_event({:subagent_approval_resolved, call_id}),
    do: {"subagent_approval_resolved", %{id: call_id}}

  defp serialize_event({:commands, commands}), do: {"commands", %{commands: commands}}

  defp serialize_event({:history, messages}),
    do: {"history", %{messages: Enum.map(messages, &serialize_message/1)}}

  defp serialize_event({:turn_ended, reason}), do: {"turn_ended", %{reason: to_string(reason)}}

  defp serialize_event({:turn_failed, reason}),
    do: {"turn_failed", %{reason: inspect(reason)}}

  defp serialize_event({:loop_ended, reason}), do: {"loop_ended", %{reason: to_string(reason)}}

  defp serialize_event(_event), do: nil

  # ── /schedule helpers (thin wrappers over Longpi.Agent.Schedules) ───

  defp schedule_list(conversation_id) do
    case Longpi.Agent.Schedules.list_text(conversation_id) do
      "No schedules" <> _ ->
        "No schedules. Usage: /schedule <cron> <task> (e.g. /schedule 0 23 * * * 每日总结), " <>
          "/schedule 23:00 <task> (daily shortcut), /schedule rm <n>."

      text ->
        text
    end
  end

  defp schedule_remove(conversation_id, index_text) do
    with {n, ""} <- Integer.parse(String.trim(index_text)),
         {:ok, message} <- Longpi.Agent.Schedules.remove(conversation_id, n) do
      {:ok, %{content: message}}
    else
      _ -> {:error, %{reason: "Usage: /schedule rm <n> — see /schedule list for numbers"}}
    end
  end

  defp schedule_add(conversation_id, arg) do
    with {:ok, cron, task} <- split_cron(arg),
         {:ok, message} <- Longpi.Agent.Schedules.add(conversation_id, cron, task) do
      {:ok, %{content: message}}
    else
      {:error, reason} -> {:error, %{reason: to_string(reason)}}
    end
  end

  # "23:00 <task>" daily shortcut, or the first five tokens as a cron expression.
  defp split_cron(arg) do
    case Regex.run(~r/^(\d{1,2}):(\d{2})\s+(.+)$/s, arg) do
      [_, hh, mm, task] ->
        {:ok, "#{String.to_integer(mm)} #{String.to_integer(hh)} * * *", String.trim(task)}

      nil ->
        case String.split(arg, ~r/\s+/, parts: 6) do
          [m, h, dom, mon, dow, task] -> {:ok, Enum.join([m, h, dom, mon, dow], " "), String.trim(task)}
          _ -> {:error, "Usage: /schedule <5-field cron> <task>, or /schedule HH:MM <task>"}
        end
    end
  end

  defp serialize_approval(%{call: call, conversation_id: cid, role: role, handle: handle}) do
    %{
      id: call.id,
      name: call.name,
      args: call.args,
      conversationId: cid,
      role: role,
      handle: handle
    }
  end

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

  defp serialize_message(message) do
    %{
      role: message.role,
      # Scrub invalid UTF-8: a tool result persisted before it was sanitized
      # (e.g. raw GBK/binary output) would otherwise crash JSON encoding of this
      # push and brick the conversation on every join.
      content: safe_text(message[:content] || ""),
      attachments: message[:attachments] || [],
      tool_calls: message[:tool_calls] || [],
      tool_call_id: message[:tool_call_id],
      name: message[:name],
      error: message[:error?] || false
    }
  end

  defp safe_text(text) when is_binary(text), do: String.replace_invalid(text)
  defp safe_text(text), do: text

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
