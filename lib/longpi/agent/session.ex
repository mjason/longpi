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

  alias Longpi.Agent.{Compactor, ConversationMessage, Message, SystemPrompt, Toolbox, Turn}

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

  @doc "Answers a pending tool-approval prompt (`call_id`, approved?)."
  def respond_approval(session, call_id, approved?) do
    send(session, {:approval_response, call_id, approved?})
    :ok
  end

  @doc "Tool-call ids currently awaiting approval (so a joining client can show them)."
  def pending_approvals(session), do: GenServer.call(session, :pending_approvals)

  @doc "Manually compacts the conversation now, ignoring the token threshold."
  def compact(session), do: GenServer.call(session, :compact)

  @doc """
  The last turn's prompt-token usage against the model's context window, as
  `%{used: integer | nil, window: integer}`. `used` is nil until a turn reports
  usage.
  """
  def context_usage(session), do: GenServer.call(session, :context_usage)

  @doc """
  Switches the model used for subsequent turns (and persists it on the
  conversation). Refuses while a turn or compaction is running.
  """
  def set_model(session, spec), do: GenServer.call(session, {:set_model, spec})

  # Server

  @impl true
  def init(opts) do
    {conversation, history} = load_conversation(opts[:conversation_id])
    ctx = %{cwd: (conversation && conversation.cwd) || opts[:cwd] || File.cwd!()}

    system_prompt =
      opts[:system_prompt] ||
        SystemPrompt.resolve(ctx, conversation && conversation.system_prompt)

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
       seq: 0,
       pending_approvals: %{},
       # Context compaction: the latest checkpoint (nil = none), the last
       # turn's prompt-token usage, and the running compaction task.
       compaction: load_compaction(opts[:conversation_id]),
       last_input_tokens: nil,
       compaction_task: nil,
       # Auto-title the conversation after its first turn if it has no title yet.
       needs_title:
         not is_nil(opts[:conversation_id]) and is_nil(conversation && conversation.title),
       title_task: nil,
       # Bun extension host for this cwd (nil until loaded / if unavailable),
       # and the slash commands its extensions registered.
       ext_host: nil,
       ext_commands: []
     }, {:continue, :load_extensions}}
  end

  @doc "Extension slash commands + host pid, for the channel to route `/commands`."
  def ext_info(session), do: GenServer.call(session, :ext_info)

  @impl true
  def handle_continue(:load_extensions, state) do
    if Application.get_env(:longpi, :extensions_enabled, true) do
      case Longpi.Extensions.Host.start_for(state.ctx.cwd) do
        {:ok, host} ->
          specs = Longpi.Extensions.Host.tool_specs(host)
          commands = Longpi.Extensions.Host.commands(host)

          {:noreply,
           %{
             state
             | toolbox: Toolbox.with_extensions(state.toolbox, specs),
               ext_host: host,
               ext_commands: commands
           }}

        :none ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.ext_host && Process.alive?(state.ext_host) do
      GenServer.stop(state.ext_host, :normal, 1_000)
    end

    :ok
  end

  # Fires a lifecycle hook to the extension host (no-op without one).
  defp fire_ext_event(%{ext_host: nil}, _event, _payload), do: :ok

  defp fire_ext_event(%{ext_host: host}, event, payload),
    do: Longpi.Extensions.Host.fire_event(host, event, payload)

  defp load_conversation(nil), do: {nil, []}

  defp load_conversation(conversation_id) do
    conversation = Longpi.Agent.get_conversation!(conversation_id)

    history =
      conversation_id
      |> Longpi.Agent.list_messages!()
      |> Enum.map(&ConversationMessage.to_message/1)

    {conversation, history}
  end

  defp load_compaction(nil), do: nil

  defp load_compaction(conversation_id) do
    case Longpi.Agent.latest_compaction(conversation_id) do
      {:ok, [%{summary: summary, covered_through: covered}]} ->
        %{summary: summary, covered_through: covered}

      _ ->
        nil
    end
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    user_message = Message.user(text)
    state = persist(state, [user_message])
    messages = state.messages ++ [user_message]
    {:reply, :ok, run_turn(%{state | messages: messages}, messages)}
  end

  def handle_call(:regenerate, _from, %{status: status} = state)
      when status in [:running, :compacting] do
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
    fire_ext_event(state, "turn_end", %{reason: "interrupted"})
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, :ok, state}

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:pending_approvals, _from, state),
    do: {:reply, Map.keys(state.pending_approvals), state}

  def handle_call(:context_usage, _from, state),
    do: {:reply, context_usage_payload(state), state}

  def handle_call(:ext_info, _from, state),
    do: {:reply, %{commands: state.ext_commands, host: state.ext_host}, state}

  def handle_call({:set_model, _spec}, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:set_model, spec}, _from, state) do
    persist_model(state.conversation_id, spec)
    state = %{state | model: spec}
    state = notify(state, {:model_changed, spec})
    # Push the new window immediately so the usage meter reflects it.
    {:reply, {:ok, spec}, notify(state, {:context_usage, context_usage_payload(state)})}
  end

  def handle_call(:compact, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:compact, _from, %{conversation_id: nil} = state) do
    {:reply, {:error, :not_persisted}, state}
  end

  def handle_call(:compact, _from, state) do
    covered = covered_through(state)
    [_system | history] = state.messages
    coverable = Enum.drop(history, covered)

    if length(coverable) < 2 do
      {:reply, {:error, :nothing_to_compact}, state}
    else
      {:reply, :ok, start_compaction(state, coverable, covered)}
    end
  end

  @impl true
  def handle_info({:turn_event, {:usage, usage}}, state) do
    state = %{state | last_input_tokens: input_tokens(usage)}
    {:noreply, notify(state, {:context_usage, context_usage_payload(state)})}
  end

  def handle_info({:turn_event, event}, state) do
    state = notify(state, event)

    case event do
      {:text_delta, text} -> {:noreply, %{state | partial: [state.partial | text]}}
      _ -> {:noreply, state}
    end
  end

  # A tool needs approval: remember who's waiting and prompt the user.
  def handle_info({:approval_request, task_pid, ref, call}, state) do
    pending = Map.put(state.pending_approvals, call.id, {task_pid, ref})
    state = notify(%{state | pending_approvals: pending}, {:approval_request, call})
    {:noreply, state}
  end

  # The user's decision, forwarded from the channel; unblock the waiting task.
  def handle_info({:approval_response, call_id, approved?}, state) do
    case Map.pop(state.pending_approvals, call_id) do
      {{task_pid, ref}, pending} ->
        decision = if approved?, do: :allow, else: :deny
        send(task_pid, {:approval_decision, ref, decision})
        {:noreply, %{state | pending_approvals: pending}}

      {nil, _} ->
        {:noreply, state}
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
        fire_ext_event(state, "turn_end", %{reason: "complete"})
        state = maybe_start_titling(state)
        {:noreply, maybe_start_compaction(state)}

      {:error, reason, new_messages} ->
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = notify(state, {:turn_failed, reason})
        fire_ext_event(state, "turn_end", %{reason: "failed"})
        {:noreply, state}
    end
  end

  # Compaction task finished
  def handle_info({ref, result}, %{compaction_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_compaction(%{state | compaction_task: nil, status: :idle}, result)}
  end

  # Title task finished: persist and broadcast the generated title.
  def handle_info({ref, result}, %{title_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | title_task: nil}

    case result do
      {:ok, title} when is_binary(title) and title != "" ->
        persist_title(state.conversation_id, title)
        {:noreply, notify(state, {:titled, title})}

      _ ->
        {:noreply, state}
    end
  end

  # Title task crashed: harmless, the conversation just keeps its default label.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{title_task: %Task{ref: ref}} = state) do
    {:noreply, %{state | title_task: nil}}
  end

  # Turn task crashed
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = keep_partial_text(state)
    state = %{state | status: :idle, task: nil, partial: []}
    state = notify(state, {:turn_failed, {:crashed, reason}})
    {:noreply, state}
  end

  # Compaction task crashed: fall back to a truncation checkpoint so context
  # still shrinks and the session isn't wedged.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{compaction_task: %Task{ref: ref}} = state
      ) do
    {:noreply, apply_compaction(%{state | compaction_task: nil, status: :idle}, :fallback)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp input_tokens(usage) when is_map(usage) do
    usage[:input_tokens] || usage["input_tokens"] || usage[:total_tokens] || usage["total_tokens"]
  end

  defp input_tokens(_), do: nil

  # Kicks off async title generation from the first user message, once.
  defp maybe_start_titling(%{needs_title: false} = state), do: state
  defp maybe_start_titling(%{title_task: %Task{}} = state), do: state

  defp maybe_start_titling(state) do
    if Application.get_env(:longpi, :auto_title, true) do
      start_titling(state)
    else
      state
    end
  end

  defp start_titling(state) do
    [_system | history] = state.messages

    case Enum.find(history, &(&1.role == :user)) do
      %{content: content} when is_binary(content) and content != "" ->
        llm = state.llm
        model = state.model

        task =
          Task.Supervisor.async_nolink(Longpi.Agent.TaskSupervisor, fn ->
            Longpi.Agent.Titler.title(llm, model, content)
          end)

        %{state | needs_title: false, title_task: task}

      _ ->
        state
    end
  end

  defp persist_title(nil, _title), do: :ok

  defp persist_title(conversation_id, title) do
    with {:ok, conversation} <- Longpi.Agent.get_conversation(conversation_id) do
      Longpi.Agent.update_conversation(conversation, %{title: title})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp persist_model(nil, _spec), do: :ok

  defp persist_model(conversation_id, spec) do
    with {:ok, conversation} <- Longpi.Agent.get_conversation(conversation_id) do
      Longpi.Agent.update_conversation(conversation, %{model: spec})
    end

    :ok
  rescue
    _ -> :ok
  end

  # How full the model's context window is, as of the last turn's usage report.
  defp context_usage_payload(state) do
    %{used: state.last_input_tokens, window: Longpi.Agent.ContextWindow.for_model(state.model)}
  end

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

  @approval_timeout 5 * 60_000

  defp run_turn(state, _messages) do
    session = self()

    config = %{
      llm: state.llm,
      model: state.model,
      toolbox: state.toolbox,
      ctx: state.ctx,
      sink: fn event -> send(session, {:turn_event, event}) end,
      authorize: fn call -> authorize(session, call) end
    }

    # The LLM sees the compacted context ([system, summary, recent]); the full
    # history stays in state.messages for the UI and future compactions.
    context = llm_context(state)

    task =
      Task.Supervisor.async_nolink(Longpi.Agent.TaskSupervisor, fn ->
        Turn.run(config, context)
      end)

    fire_ext_event(state, "turn_start", %{})
    %{state | status: :running, task: task, partial: []}
  end

  # ── Context compaction ────────────────────────────────────────────────

  defp llm_context(%{messages: [system | history], compaction: nil}), do: [system | history]

  defp llm_context(%{messages: [system | history], compaction: %{summary: s, covered_through: c}}) do
    kept = Enum.drop(history, min(c, length(history)))
    [system, Compactor.summary_message(s) | kept]
  end

  defp maybe_start_compaction(%{conversation_id: nil} = state), do: state

  defp maybe_start_compaction(state) do
    covered = covered_through(state)
    [_system | history] = state.messages
    coverable = Enum.drop(history, covered)

    cond do
      not Longpi.Agent.ContextWindow.enabled?() -> state
      not over_threshold?(state) -> state
      length(coverable) < 2 -> state
      true -> start_compaction(state, coverable, covered)
    end
  end

  defp over_threshold?(%{last_input_tokens: nil}), do: false

  defp over_threshold?(state) do
    state.last_input_tokens > Longpi.Agent.ContextWindow.compaction_threshold(state.model)
  end

  defp covered_through(%{compaction: %{covered_through: c}}), do: c
  defp covered_through(_state), do: 0

  defp start_compaction(state, coverable, covered) do
    llm = state.llm
    model = state.model
    keep = Longpi.Agent.ContextWindow.keep_tokens(model)
    prev = state.compaction && state.compaction.summary
    input = state.last_input_tokens

    task =
      Task.Supervisor.async_nolink(Longpi.Agent.TaskSupervisor, fn ->
        case Compactor.plan(coverable, keep) do
          {[], _} ->
            :skip

          {to_summarize, _keep} ->
            new_covered = covered + length(to_summarize)

            case Compactor.summarize(llm, model, to_summarize, prev) do
              {:ok, summary} -> {:ok, summary, new_covered, input}
              {:error, _} -> {:fallback, new_covered, input}
            end
        end
      end)

    state = notify(state, {:compaction_started})
    %{state | status: :compacting, compaction_task: task}
  end

  @fallback_summary "[Earlier messages were dropped to fit the model's context window.]"

  defp apply_compaction(state, :skip), do: notify(state, {:compaction_ended})

  defp apply_compaction(state, {:ok, summary, covered, input}),
    do: do_compact(state, summary, covered, input)

  defp apply_compaction(state, {:fallback, covered, input}),
    do: do_compact(state, @fallback_summary, covered, input)

  # Crash fallback: recompute a cut point and truncate without a summary.
  defp apply_compaction(state, :fallback) do
    covered = covered_through(state)
    [_system | history] = state.messages
    coverable = Enum.drop(history, covered)

    case Compactor.plan(coverable, Longpi.Agent.ContextWindow.keep_tokens(state.model)) do
      {[], _} ->
        notify(state, {:compaction_ended})

      {to_summarize, _} ->
        do_compact(state, @fallback_summary, covered + length(to_summarize), nil)
    end
  end

  defp do_compact(state, summary, covered, input) do
    Longpi.Agent.create_compaction!(%{
      conversation_id: state.conversation_id,
      summary: summary,
      covered_through: covered,
      input_tokens: input
    })

    state = %{state | compaction: %{summary: summary, covered_through: covered}}
    notify(state, {:compacted, %{covered_through: covered}})
  end

  # Runs in the Turn task. For `:ask` tools it asks the Session to broadcast an
  # approval request, then blocks until the user (or a timeout) decides.
  defp authorize(session, call) do
    case Longpi.Agent.Permissions.mode(call.name) do
      :allow ->
        :allow

      :ask ->
        ref = make_ref()
        send(session, {:approval_request, self(), ref, call})

        receive do
          {:approval_decision, ^ref, decision} -> decision
        after
          @approval_timeout -> :deny
        end
    end
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
