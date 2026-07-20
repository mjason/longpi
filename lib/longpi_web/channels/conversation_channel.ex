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

        socket = assign(socket, conversation_id: conversation_id, session: session)

        reply = %{
          messages: history,
          status: Session.status(session),
          pending_approvals: Session.pending_approvals(session),
          context_usage: Session.context_usage(session)
        }

        {:ok, reply, socket}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_in("send_message", %{"text" => text}, socket) do
    case Session.send_message(socket.assigns.session, text) do
      :ok -> {:reply, :ok, socket}
      {:error, :busy} -> {:reply, {:error, %{reason: "busy"}}, socket}
    end
  end

  def handle_in("interrupt", _payload, socket) do
    :ok = Session.interrupt(socket.assigns.session)
    {:reply, :ok, socket}
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
      {:ok, model} ->
        broadcast!(socket, "model_changed", %{model: model})
        {:reply, {:ok, %{model: model}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("command", %{"name" => "compact"}, socket) do
    case Session.compact(socket.assigns.session) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("command", %{"name" => name}, socket) do
    {:reply, {:error, %{reason: "unknown command: #{name}"}}, socket}
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
      context_usage: Session.context_usage(session)
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

  defp serialize_event({:approval_request, call}),
    do: {"approval_request", %{id: call.id, name: call.name, args: call.args}}

  defp serialize_event({:compaction_started}), do: {"compaction_started", %{}}
  defp serialize_event({:compaction_ended}), do: {"compaction_ended", %{}}

  defp serialize_event({:compacted, %{covered_through: covered}}),
    do: {"compacted", %{covered_through: covered}}

  defp serialize_event({:context_usage, %{used: used, window: window}}),
    do: {"context_usage", %{used: used, window: window}}

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
      tool_calls: message[:tool_calls] || [],
      tool_call_id: message[:tool_call_id],
      name: message[:name],
      error: message[:error?] || false
    }
  end
end
