defmodule Longpi.Agent.Session do
  @moduledoc """
  One agent conversation: holds the message history and runs turns.

  A turn executes in a supervised task (`Longpi.Agent.TaskSupervisor`) so the
  session stays responsive for `status/1`, `interrupt/1`, and event fan-out
  while the LLM streams. Streaming events are forwarded to `:stream_to` as
  `{:agent_event, event}` messages - the Phoenix Channel will subscribe the
  same way later.

  ## Options

    * `:cwd` - workspace directory (default: BEAM cwd)
    * `:model` - model spec (default: `:longpi, :llm_model` app env)
    * `:llm` - `Longpi.Agent.LLM` implementation (default: app env)
    * `:tools` - tool modules (default: the four built-ins)
    * `:stream_to` - pid receiving `{:agent_event, event}` messages
    * `:system_prompt` - override the default system prompt
  """

  use GenServer, restart: :temporary

  alias Longpi.Agent.{ConversationMessage, Message, SystemPrompt, Toolbox, Turn}

  # Client

  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Starts a turn. Returns `{:error, :busy}` if one is already running."
  def send_message(session, text), do: GenServer.call(session, {:send_message, text})

  @doc "Aborts the running turn, keeping any partial assistant text."
  def interrupt(session), do: GenServer.call(session, :interrupt)

  @doc """
  Re-runs the last turn: drops the previous assistant response (and its tool
  calls) back to the last user message and generates a fresh reply.
  """
  def regenerate(session), do: GenServer.call(session, :regenerate)

  def messages(session), do: GenServer.call(session, :messages)

  def status(session), do: GenServer.call(session, :status)

  # Server

  @impl true
  def init(opts) do
    {conversation, history} = load_conversation(opts[:conversation_id])
    ctx = %{cwd: (conversation && conversation.cwd) || opts[:cwd] || File.cwd!()}
    system_prompt = opts[:system_prompt] || SystemPrompt.default(ctx)

    {:ok,
     %{
       messages: [Message.system(system_prompt) | history],
       status: :idle,
       task: nil,
       partial: [],
       ctx: ctx,
       llm: opts[:llm] || Application.fetch_env!(:longpi, :llm_client),
       model:
         (conversation && conversation.model) || opts[:model] ||
           Application.fetch_env!(:longpi, :llm_model),
       toolbox: Toolbox.new(opts[:tools] || Toolbox.default_modules()),
       stream_to: opts[:stream_to],
       conversation_id: opts[:conversation_id],
       persisted_count: length(history),
       seq: 0
     }}
  end

  defp load_conversation(nil), do: {nil, []}

  defp load_conversation(conversation_id) do
    conversation = Longpi.Agent.get_conversation!(conversation_id)

    history =
      conversation_id
      |> Longpi.Agent.list_messages!()
      |> Enum.map(&ConversationMessage.to_message/1)

    {conversation, history}
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    user_message = Message.user(text)
    state = persist(state, [user_message])
    messages = state.messages ++ [user_message]
    {:reply, :ok, run_turn(%{state | messages: messages}, messages)}
  end

  def handle_call(:regenerate, _from, %{status: :running} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:regenerate, _from, state) do
    case truncate_to_last_user(state) do
      {:ok, state} ->
        # Tell clients to rebuild their view from the truncated history before
        # the new turn streams in.
        state = notify(state, {:history, broadcast_history(state)})
        {:reply, :ok, run_turn(state, state.messages)}

      :error ->
        {:reply, {:error, :nothing_to_regenerate}, state}
    end
  end

  def handle_call(:interrupt, _from, %{status: :running} = state) do
    Task.shutdown(state.task, :brutal_kill)

    state =
      state
      |> keep_partial_text()
      |> Map.merge(%{status: :idle, task: nil, partial: []})

    state = notify(state, {:turn_ended, :interrupted})
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, :ok, state}

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_info({:turn_event, event}, state) do
    state = notify(state, event)

    case event do
      {:text_delta, text} -> {:noreply, %{state | partial: [state.partial | text]}}
      _ -> {:noreply, state}
    end
  end

  # Turn task finished
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | status: :idle, task: nil, partial: []}

    case result do
      {:ok, new_messages} ->
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = notify(state, {:turn_ended, :complete})
        {:noreply, state}

      {:error, reason, new_messages} ->
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = notify(state, {:turn_failed, reason})
        {:noreply, state}
    end
  end

  # Turn task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = keep_partial_text(state)
    state = %{state | status: :idle, task: nil, partial: []}
    state = notify(state, {:turn_failed, {:crashed, reason}})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp keep_partial_text(state) do
    case IO.iodata_to_binary(state.partial) do
      "" ->
        state

      text ->
        message = Message.assistant(text)
        state = persist(state, [message])
        %{state | messages: state.messages ++ [message]}
    end
  end

  defp run_turn(state, messages) do
    session = self()

    config = %{
      llm: state.llm,
      model: state.model,
      toolbox: state.toolbox,
      ctx: state.ctx,
      sink: fn event -> send(session, {:turn_event, event}) end
    }

    task =
      Task.Supervisor.async_nolink(Longpi.Agent.TaskSupervisor, fn ->
        Turn.run(config, messages)
      end)

    %{state | status: :running, task: task, partial: []}
  end

  # Drops everything after the last user message, in memory and in storage, so
  # the next turn regenerates from that point.
  defp truncate_to_last_user(state) do
    [system | rest] = state.messages

    case last_index(rest, &(&1.role == :user)) do
      nil ->
        :error

      idx ->
        kept = Enum.take(rest, idx + 1)
        delete_persisted_after(state, idx)
        {:ok, %{state | messages: [system | kept], persisted_count: idx + 1}}
    end
  end

  defp last_index(list, fun) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {item, idx}, acc -> if fun.(item), do: idx, else: acc end)
  end

  defp delete_persisted_after(%{conversation_id: nil}, _keep_index), do: :ok

  defp delete_persisted_after(state, keep_index) do
    state.conversation_id
    |> Longpi.Agent.list_messages!()
    |> Enum.filter(&(&1.position > keep_index))
    |> Enum.each(&Ash.destroy!/1)
  end

  defp broadcast_history(state) do
    state.messages
    |> Enum.reject(&(&1.role == :system))
  end

  defp persist(%{conversation_id: nil} = state, _new_messages), do: state

  defp persist(state, new_messages) do
    new_messages
    |> Enum.with_index(state.persisted_count)
    |> Enum.each(fn {message, position} ->
      message
      |> ConversationMessage.from_message(state.conversation_id, position)
      |> Longpi.Agent.append_message!()
    end)

    %{state | persisted_count: state.persisted_count + length(new_messages)}
  end

  # Every broadcast event carries a monotonically increasing sequence number
  # so clients can drop duplicates. A browser can briefly end up with two
  # channel processes subscribed to the same topic (socket reconnects), and
  # without dedup each streamed delta would be applied twice.
  defp notify(state, event) do
    seq = state.seq + 1
    if is_pid(state.stream_to), do: send(state.stream_to, {:agent_event, event})

    if state.conversation_id do
      Phoenix.PubSub.broadcast(
        Longpi.PubSub,
        topic(state.conversation_id),
        {:agent_event, seq, event}
      )
    end

    %{state | seq: seq}
  end

  @doc "PubSub topic carrying `{:agent_event, event}` messages for a conversation."
  def topic(conversation_id), do: "conversation:#{conversation_id}"
end
