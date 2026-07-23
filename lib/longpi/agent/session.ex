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

  require Logger

  # Slash commands the app handles itself (channel routes compact/rename/reload;
  # the client handles model/help). An extension command with one of these names
  # can never be reached, so it's dropped with a warning rather than shown dead.
  @builtin_commands ~w(compact model reload rename help)

  alias Longpi.Agent.{
    Compactor,
    ConversationMessage,
    Message,
    PromptAssembly,
    Subagents,
    Toolbox,
    Turn
  }

  # Client

  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Starts a turn. Returns `{:error, :busy}` if one is already running."
  def send_message(session, text, attachments \\ []),
    do: GenServer.call(session, {:send_message, text, attachments})

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

  @doc """
  Registers a live watcher (a channel process). The session won't idle-reap
  while any watcher is connected; the watcher is dropped automatically when its
  process dies (tab closed / socket lost).
  """
  def watch(session, pid), do: GenServer.call(session, {:watch, pid})

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

  @doc "Sets the reasoning effort (nil | \"minimal\" | \"low\" | \"medium\" | \"high\")."
  def set_reasoning(session, effort), do: GenServer.call(session, {:set_reasoning, effort})

  @doc "Renames the conversation (the /rename command)."
  def rename(session, title), do: GenServer.call(session, {:rename, title})

  @doc """
  Replaces the LAST user message with new text and re-runs from there —
  the graphical edit-and-resend. Everything after (and including) the old
  message is dropped, mirroring `regenerate` semantics.
  """
  def edit_last(session, text, attachments \\ []),
    do: GenServer.call(session, {:edit_last, text, attachments})

  @doc "The conversation's current reasoning effort (nil = model default)."
  def reasoning_effort(session), do: GenServer.call(session, :reasoning_effort)

  @doc "Children this session has spawned: %{handle => info}."
  def subagents(session), do: GenServer.call(session, :subagent_snapshot)

  @doc "Tool approvals bubbled up from children, awaiting the user's decision."
  def subagent_approvals(session), do: GenServer.call(session, :subagent_approvals)

  # Server

  @impl true
  def init(opts) do
    {conversation, history} = load_conversation(opts[:conversation_id])
    agent_def = opts[:agent_def]
    depth = opts[:subagent_depth] || 0

    ctx = %{
      cwd: (conversation && conversation.cwd) || opts[:cwd] || File.cwd!(),
      session: self(),
      conversation_id: opts[:conversation_id],
      subagent_depth: depth
    }

    # The ingredients the prompt is (re)assembled from each turn — see
    # `Longpi.Agent.PromptAssembly`. Nothing model-facing is frozen here; this
    # is only the initial snapshot for display before the first turn.
    prompt_inputs = %{
      system_prompt_override: opts[:system_prompt],
      conversation_override: conversation && conversation.system_prompt,
      ctx: ctx,
      agent_def: agent_def
    }

    builtin_toolbox = builtin_toolbox(opts, agent_def)
    spawns_subagents? = depth < subagent_max_depth()

    {:ok,
     %{
       messages: [PromptAssembly.system_message(prompt_inputs) | history],
       status: :idle,
       task: nil,
       partial: [],
       ctx: ctx,
       llm: opts[:llm] || Application.fetch_env!(:longpi, :llm_client),
       model:
         (conversation && conversation.model) || opts[:model] ||
           Application.fetch_env!(:longpi, :llm_model),
       # Reasoning effort ("minimal"|"low"|"medium"|"high") or nil for the
       # model's default; passed to the LLM per turn.
       reasoning_effort: (conversation && conversation.reasoning_effort) || opts[:reasoning_effort],
       # Prompt-assembly ingredients. `builtin_toolbox` (role-narrowed
       # built-ins) is fixed; `extension_specs` update on load/reload;
       # `spawns_subagents?` gates the agent tool family. The assembled
       # `toolbox` is a cache refreshed on each assembly (turn + ext events) —
       # only its count is read between turns.
       prompt_inputs: prompt_inputs,
       builtin_toolbox: builtin_toolbox,
       spawns_subagents?: spawns_subagents?,
       extension_specs: [],
       toolbox:
         PromptAssembly.toolbox(%{
           builtin_toolbox: builtin_toolbox,
           extension_specs: [],
           spawns_subagents?: spawns_subagents?,
           ctx: ctx
         }),
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
       # Extension host (QuickJS/rquickjs) for this cwd (nil until loaded),
       # and the slash commands its extensions registered.
       ext_host: nil,
       ext_commands: [],
       # Debounce timer for auto-reloading extensions after a file change.
       ext_reload_timer: nil,
       # Subagents: children this session spawned (%{handle => info}), the
       # counter feeding handle names, and — when this session IS a subagent —
       # who to notify on completion.
       subagents: %{},
       subagent_counter: 0,
       # Tool approvals a child bubbled up for the user to answer here:
       # %{call_id => child_conversation_id}.
       subagent_approvals: %{},
       agent_def: agent_def,
       parent_session: opts[:parent_session],
       # Subagent sessions skip the extension host unless the role opts in
       # (extensions: true) — starting one per child is wasteful by default.
       ext_enabled: is_nil(agent_def) or agent_def.extensions,
       # Idle-reaping: channels watching this session (ref => pid), and the
       # timer that recycles the process when it's idle with no watchers. The
       # conversation lives in the DB, so a reaped session rebuilds on reopen.
       watchers: %{},
       idle_timer: nil
     }, {:continue, :load_extensions}}
  end

  @doc "Extension slash commands + host pid, for the channel to route `/commands`."
  def ext_info(session), do: GenServer.call(session, :ext_info)

  @doc "A snapshot of this session for the management dashboard."
  def summary(session), do: GenServer.call(session, :summary)

  @doc """
  Hot-reloads the extension host: re-discovers extension files/packages and
  rebuilds the toolbox and command list. Returns `{:ok, %{tools, commands}}`.
  """
  def reload_extensions(session), do: GenServer.call(session, :reload_extensions, 60_000)

  @impl true
  def handle_continue(:load_extensions, state) do
    {:noreply, touch(start_ext_host(state))}
  end

  # Starts the Bun host when this session wants extensions AND the workspace
  # actually has any (start_for is lazy — no extensions, no Bun process).
  # `start_for` returns as soon as the host is spawned; waiting for it to
  # finish loading its modules (Bun cold start + imports) would block the
  # session — and thus the channel join reading history. Do the wait in a
  # task and fold the tools/commands in when they arrive, so opening a
  # conversation is never gated on extension load.
  defp start_ext_host(%{ext_host: nil} = state) do
    if state.ext_enabled and Application.get_env(:longpi, :extensions_enabled, true) do
      case Longpi.Extensions.Host.start_for(state.ctx.cwd) do
        {:ok, host} ->
          load_extensions_async(host, self())
          %{state | ext_host: host}

        :none ->
          state
      end
    else
      state
    end
  end

  defp start_ext_host(state), do: state

  defp load_extensions_async(host, session) do
    Task.start(fn ->
      specs = Longpi.Extensions.Host.tool_specs(host)
      commands = Longpi.Extensions.Host.commands(host)
      send(session, {:extensions_loaded, host, specs, commands})
    end)
  end

  @impl true
  def terminate(_reason, state) do
    if state.ext_host && Process.alive?(state.ext_host) do
      GenServer.stop(state.ext_host, :normal, 1_000)
    end

    # Recycle child subagent sessions this instance spawned — they're tied to
    # this parent and aren't reconnected when the conversation reopens, so
    # leaving them running (e.g. after an idle-reap) would leak processes.
    for {_handle, %{conversation_id: cid}} <- state.subagents do
      Longpi.Agent.Sessions.stop(cid)
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
  def handle_call({:send_message, _text, _attachments}, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text, attachments}, _from, state) do
    user_message = Message.user(text, attachments)
    state = persist(state, [user_message])
    messages = state.messages ++ [user_message]
    {:reply, :ok, run_turn(%{state | messages: messages}, messages)}
  end

  def handle_call({:edit_last, _text, _attachments}, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:edit_last, text, attachments}, _from, state) do
    case truncate_before_last_user(state) do
      {:ok, state} ->
        # Append the replacement FIRST, then broadcast: unlike send (where the
        # client adds the message optimistically), the edit flow's only source
        # of truth is this history push — broadcasting the truncated list
        # would make the new message vanish until a reload.
        user_message = Message.user(text, attachments)
        state = persist(state, [user_message])
        state = %{state | messages: state.messages ++ [user_message]}
        state = notify(state, {:history, broadcast_history(state)})
        {:reply, :ok, run_turn(state, state.messages)}

      :error ->
        {:reply, {:error, :nothing_to_edit}, state}
    end
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
    interrupt_running_subagents(state)

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

  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | watchers: Map.put(state.watchers, ref, pid)}}
  end

  def handle_call(:context_usage, _from, state),
    do: {:reply, context_usage_payload(state), state}

  def handle_call(:ext_info, _from, state),
    do: {:reply, %{commands: state.ext_commands, host: state.ext_host}, state}

  def handle_call(:summary, _from, state) do
    {:reply,
     %{
       status: state.status,
       model: state.model,
       cwd: state.ctx.cwd,
       tools: map_size(state.toolbox),
       extensions?: not is_nil(state.ext_host),
       commands: length(state.ext_commands)
     }, state}
  end

  # No host yet (lazy start found no extensions at init): a manual reload
  # means "look again" — cold-start the host if extensions exist now.
  def handle_call(:reload_extensions, _from, %{ext_host: nil} = state) do
    case start_ext_host(state) do
      %{ext_host: nil} = state -> {:reply, {:error, :no_extensions}, state}
      state -> {:reply, {:ok, :starting}, state}
    end
  end

  def handle_call(:reload_extensions, _from, state) do
    specs = Longpi.Extensions.Host.reload(state.ext_host)
    commands = sanitize_commands(Longpi.Extensions.Host.commands(state.ext_host))
    state = %{state | extension_specs: specs, ext_commands: commands}
    state = %{state | toolbox: assemble_toolbox(state)}
    # Push the fresh command list so the composer's slash menu updates live.
    state = notify(state, {:commands, commands})
    {:reply, {:ok, %{tools: length(specs), commands: length(commands)}}, state}
  end

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

  def handle_call({:rename, title}, _from, state) do
    title = title |> to_string() |> String.trim()

    if title == "" do
      {:reply, {:error, :empty}, state}
    else
      persist_title(state.conversation_id, title)
      # A manual rename wins: don't let the first-turn auto-title overwrite it.
      state = %{state | needs_title: false}
      {:reply, {:ok, title}, notify(state, {:titled, title})}
    end
  end

  def handle_call(:reasoning_effort, _from, state),
    do: {:reply, state.reasoning_effort, state}

  def handle_call({:set_reasoning, effort}, _from, state) do
    # Normalize "" / unknown to nil (= model default); store the string.
    effort = if effort in ["minimal", "low", "medium", "high", "xhigh"], do: effort, else: nil
    persist_reasoning(state.conversation_id, effort)
    state = %{state | reasoning_effort: effort}
    {:reply, {:ok, effort}, notify(state, {:reasoning_changed, effort})}
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

  # ── Subagents (parent side) ─────────────────────────────────────────
  # Called by the agent-tool family from within the Turn task (ctx.session).

  def handle_call(:subagent_snapshot, _from, state), do: {:reply, state.subagents, state}

  def handle_call(:subagent_approvals, _from, state),
    do: {:reply, Map.values(state.subagent_approvals), state}

  def handle_call({:spawn_subagent, args}, _from, state) do
    with :ok <- check_subagent_limit(state),
         {:ok, agent_def} <- lookup_subagent_role(state, args[:agent]),
         {:ok, child} <- create_child_conversation(state, agent_def, args),
         {:ok, pid} <-
           Longpi.Agent.Sessions.ensure_started(child.id,
             agent_def: agent_def,
             parent_session: self(),
             subagent_depth: state.ctx.subagent_depth + 1
           ),
         :ok <- __MODULE__.send_message(pid, args[:task]) do
      Process.monitor(pid)
      counter = state.subagent_counter + 1
      handle = "#{agent_def.name}-#{counter}"

      info = %{
        conversation_id: child.id,
        role: agent_def.name,
        status: :running,
        task: args[:task],
        started_at: System.system_time(:second),
        pid: pid,
        collected: false,
        detail: nil
      }

      state = %{
        state
        | subagent_counter: counter,
          subagents: Map.put(state.subagents, handle, info)
      }

      {:reply, {:ok, handle}, notify_subagents(state)}
    else
      {:error, %Ash.Error.Invalid{} = error} ->
        {:reply, {:error, "could not create subagent conversation: #{Exception.message(error)}"},
         state}

      {:error, reason} when is_binary(reason) ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, "could not start subagent: #{inspect(reason)}"}, state}
    end
  end

  def handle_call({:subagent_send, args}, _from, state) do
    handle = args[:agent]

    with {:ok, info} <- fetch_subagent(state, handle),
         {:ok, pid} <- live_subagent_pid(info) do
      busy? = __MODULE__.status(pid) == :running

      cond do
        busy? and not args[:interrupt] ->
          {:reply,
           {:error,
            "#{handle} is still working. Pass interrupt: true to redirect it, " <>
              "or wait_agent for it to finish."}, state}

        busy? ->
          :ok = __MODULE__.interrupt(pid)
          :ok = __MODULE__.send_message(pid, args[:message])
          {:reply, {:ok, handle}, mark_subagent(state, handle, :running)}

        true ->
          :ok = __MODULE__.send_message(pid, args[:message])
          {:reply, {:ok, handle}, mark_subagent(state, handle, :running)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subagent_close, handle}, _from, state) do
    case fetch_subagent(state, handle) do
      {:ok, info} ->
        Longpi.Agent.Sessions.stop(info.conversation_id)

        state =
          if info.status in [:done, :failed],
            do: mark_subagent(state, handle, info.status),
            else: mark_subagent(state, handle, :closed)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subagent_collect, handles}, _from, state) do
    subagents =
      Enum.reduce(handles, state.subagents, fn handle, acc ->
        case acc do
          %{^handle => info} -> Map.put(acc, handle, %{info | collected: true})
          _ -> acc
        end
      end)

    {:reply, :ok, %{state | subagents: subagents}}
  end

  @impl true
  def handle_info({:extensions_loaded, host, specs, commands}, %{ext_host: host} = state) do
    state = %{state | extension_specs: specs, ext_commands: sanitize_commands(commands)}
    state = %{state | toolbox: assemble_toolbox(state)}

    # Push the now-available slash commands to any connected channel.
    {:noreply, notify(state, {:commands, commands})}
  end

  # A stale load (the host was replaced by a reload) — ignore it.
  def handle_info({:extensions_loaded, _host, _specs, _commands}, state), do: {:noreply, state}

  # The agent wrote/edited an extension file this turn — hot-reload the host so
  # the new tool is live on the next turn, with no manual /reload. Debounced so
  # a burst of edits triggers one reload.
  def handle_info({:turn_event, :extensions_changed}, state) do
    {:noreply, schedule_ext_reload(state)}
  end

  # The agent just wrote into an extensions dir but no host is running (lazy
  # start skipped it when the workspace had none) — this is the FIRST
  # extension, so cold-start the host now.
  def handle_info(:auto_reload_extensions, %{ext_host: nil} = state),
    do: {:noreply, start_ext_host(%{state | ext_reload_timer: nil})}

  def handle_info(:auto_reload_extensions, state) do
    reload_extensions_async(state.ext_host, self())
    {:noreply, %{state | ext_reload_timer: nil}}
  end

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

  # A tool needs approval: remember who's waiting and prompt the user. A
  # subagent has no one watching its own conversation, so it ALSO bubbles the
  # request to its parent, which surfaces it in the parent's view.
  def handle_info({:approval_request, task_pid, ref, call}, state) do
    pending = Map.put(state.pending_approvals, call.id, {task_pid, ref})
    state = notify(%{state | pending_approvals: pending}, {:approval_request, call})

    if state.parent_session do
      send(
        state.parent_session,
        {:subagent_approval_request, state.conversation_id, agent_role(state), call}
      )
    end

    {:noreply, state}
  end

  # The user's decision, forwarded from the channel; unblock the waiting task.
  # A subagent's own pending approval may instead be one the PARENT is holding
  # on its behalf — route those to the child before checking our own.
  def handle_info({:approval_response, call_id, approved?}, %{subagent_approvals: approvals} = state)
      when is_map_key(approvals, call_id) do
    %{conversation_id: child_id} = approvals[call_id]

    case Longpi.Agent.Sessions.whereis(child_id) do
      nil -> :ok
      pid -> __MODULE__.respond_approval(pid, call_id, approved?)
    end

    state = %{state | subagent_approvals: Map.delete(approvals, call_id)}
    {:noreply, notify(state, {:subagent_approval_resolved, call_id})}
  end

  def handle_info({:approval_response, call_id, approved?}, state) do
    # A subagent that resolved its own approval tells its parent to clear the
    # bubbled prompt.
    if state.parent_session do
      send(state.parent_session, {:subagent_approval_resolved, state.conversation_id, call_id})
    end

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
    state = touch(%{state | status: :idle, task: nil, partial: []})

    case result do
      {:ok, new_messages} ->
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        # Broadcast the committed history BEFORE turn_ended so any client —
        # including one that reloaded mid-turn and missed the streamed deltas —
        # converges to the correct, complete messages. (Order matters: the
        # `history` event forces status "running"; the following `turn_ended`
        # settles items and flips to idle.)
        state = notify(state, {:history, broadcast_history(state)})
        state = notify(state, {:turn_ended, :complete})
        fire_ext_event(state, "turn_end", %{reason: "complete"})
        notify_parent_done(state, :done)
        state = maybe_start_titling(state)
        {:noreply, maybe_start_compaction(state)}

      {:error, reason, new_messages} ->
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = notify(state, {:history, broadcast_history(state)})
        state = notify(state, {:turn_failed, reason})
        fire_ext_event(state, "turn_end", %{reason: "failed"})
        notify_parent_done(state, {:failed, reason})
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
    state = notify(state, {:history, broadcast_history(state)})
    state = notify(state, {:turn_failed, {:crashed, reason}})
    notify_parent_done(state, {:failed, {:crashed, reason}})
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

  # A child bubbled a tool approval — track it and surface it in this
  # conversation's view (attributed to the subagent).
  def handle_info({:subagent_approval_request, child_id, role, call}, state) do
    entry = %{conversation_id: child_id, role: role, handle: subagent_handle_for(state, child_id), call: call}
    approvals = Map.put(state.subagent_approvals, call.id, entry)
    {:noreply, notify(%{state | subagent_approvals: approvals}, {:subagent_approval, entry})}
  end

  # A child's approval was answered (here or on the child's own page) — clear
  # the bubbled prompt.
  def handle_info({:subagent_approval_resolved, _child_id, call_id}, state) do
    if Map.has_key?(state.subagent_approvals, call_id) do
      approvals = Map.delete(state.subagent_approvals, call_id)
      {:noreply, notify(%{state | subagent_approvals: approvals}, {:subagent_approval_resolved, call_id})}
    else
      {:noreply, state}
    end
  end

  # A subagent finished a turn (child sessions send this to parent_session).
  def handle_info({:subagent_update, conversation_id, status}, state) do
    case Enum.find(state.subagents, fn {_h, info} -> info.conversation_id == conversation_id end) do
      nil ->
        {:noreply, state}

      {handle, info} ->
        {new_status, detail} =
          case status do
            :done -> {:done, nil}
            {:failed, reason} -> {:failed, inspect(reason)}
          end

        info = %{info | status: new_status, detail: detail}
        state = %{state | subagents: Map.put(state.subagents, handle, info)}
        state = clear_subagent_approvals_for(state, conversation_id)
        state = notify_subagents(state)
        {:noreply, maybe_inject_subagent_notice(state, handle, info)}
    end
  end

  # A watching channel died (tab closed / socket lost) — drop it. When the last
  # watcher leaves, the idle timer may now find the session reapable.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{watchers: watchers} = state)
      when is_map_key(watchers, ref) do
    {:noreply, %{state | watchers: Map.delete(watchers, ref)}}
  end

  # A subagent session died. Normal completion keeps the child alive (idle),
  # so an unexpected DOWN on a non-terminal child means it crashed.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.subagents, fn {_h, info} -> info.pid == pid end) do
      {handle, %{status: :running} = info} ->
        info = %{info | status: :failed, detail: "session down: #{inspect(reason)}"}
        state = %{state | subagents: Map.put(state.subagents, handle, info)}
        state = notify_subagents(state)
        {:noreply, maybe_inject_subagent_notice(state, handle, info)}

      _ ->
        {:noreply, state}
    end
  end

  # Idle-reap tick: recycle the process if it's genuinely idle with nobody
  # watching, otherwise re-arm and keep waiting. Stopping is transparent — the
  # conversation is persisted and rebuilt from the DB on the next open.
  def handle_info(:idle_reap, state) do
    if reapable?(state) do
      {:stop, :normal, state}
    else
      {:noreply, touch(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Idle reaping ────────────────────────────────────────────────────

  # 0 / nil disables reaping (set in tests that assert liveness).
  defp idle_timeout, do: Application.get_env(:longpi, :session_idle_timeout_ms, 30 * 60_000)

  defp touch(state) do
    case idle_timeout() do
      ms when is_integer(ms) and ms > 0 ->
        if ref = state.idle_timer, do: Process.cancel_timer(ref)
        %{state | idle_timer: Process.send_after(self(), :idle_reap, ms)}

      _ ->
        state
    end
  end

  # Only recycle a persisted, top-level session that is doing nothing and has no
  # connected client, no pending approvals, and no live children/background work.
  defp reapable?(state) do
    state.status == :idle and
      not is_nil(state.conversation_id) and
      is_nil(state.parent_session) and
      is_nil(state.compaction_task) and
      is_nil(state.title_task) and
      map_size(state.watchers) == 0 and
      map_size(state.pending_approvals) == 0 and
      map_size(state.subagent_approvals) == 0 and
      not Enum.any?(state.subagents, fn {_h, info} -> info.status == :running end)
  end

  # ── Subagent helpers ────────────────────────────────────────────────

  @subagent_max_children 6

  defp subagent_max_depth, do: Application.get_env(:longpi, :subagent_max_depth, 1)

  # The fixed part of the toolbox: default (or opt-supplied) built-ins,
  # narrowed to a subagent role's allowlist. The subagent tool family and
  # extension tools are layered on at assembly time (PromptAssembly), so this
  # never changes over the session's life.
  defp builtin_toolbox(opts, agent_def) do
    toolbox = Toolbox.new(opts[:tools] || Toolbox.default_modules())

    case agent_def do
      %Subagents.Def{tools: allow} when is_list(allow) -> Map.take(toolbox, allow)
      _ -> toolbox
    end
  end

  # Re-derive the model-facing prompt (system message + toolbox) from current
  # state, and fold the fresh system message back into `messages` so both the
  # LLM context and the stored history stay current.
  defp assemble_prompt(state) do
    [_stale_system | history] = state.messages

    # Assemble the toolbox first so the system message can list the full,
    # current inventory (built-ins + subagent family + extensions).
    toolbox = assemble_toolbox(state)
    inputs = Map.put(state.prompt_inputs, :tools, PromptAssembly.tool_summaries(toolbox))
    system = PromptAssembly.system_message(inputs)
    %{state | messages: [system | history], toolbox: toolbox}
  end

  # Drop extension slash commands whose names collide with built-in commands —
  # routing would shadow them, so they'd be dead entries in the menu. Warn so
  # the extension author knows to rename.
  defp sanitize_commands(commands) do
    Enum.reject(commands, fn cmd ->
      name = cmd["name"] || cmd[:name]

      if name in @builtin_commands do
        Logger.warning(
          "extension command #{inspect(name)} collides with a built-in command; ignoring it"
        )

        true
      else
        false
      end
    end)
  end

  defp assemble_toolbox(state) do
    PromptAssembly.toolbox(%{
      builtin_toolbox: state.builtin_toolbox,
      extension_specs: state.extension_specs,
      spawns_subagents?: state.spawns_subagents?,
      ctx: state.ctx
    })
  end

  # Stopping the parent stops its running children — otherwise they'd keep
  # working (and spending tokens) after the user hit interrupt.
  defp interrupt_running_subagents(state) do
    for {_handle, %{status: :running, conversation_id: cid}} <- state.subagents do
      case Longpi.Agent.Sessions.whereis(cid) do
        nil -> :ok
        pid -> __MODULE__.interrupt(pid)
      end
    end
  end

  defp check_subagent_limit(state) do
    running = Enum.count(state.subagents, fn {_h, info} -> info.status == :running end)

    if running < @subagent_max_children do
      :ok
    else
      {:error,
       "Subagent limit reached (#{@subagent_max_children} running). " <>
         "wait_agent for some to finish, or close_agent ones you no longer need."}
    end
  end

  defp lookup_subagent_role(state, name) do
    case Subagents.get(state.ctx.cwd, name) do
      {:ok, agent_def} ->
        {:ok, agent_def}

      :error ->
        available =
          state.ctx.cwd |> Subagents.discover() |> Enum.map_join(", ", & &1.name)

        {:error, "Unknown agent role \"#{name}\". Available: #{available}"}
    end
  end

  defp create_child_conversation(state, agent_def, args) do
    title = args[:task] |> String.split("\n") |> hd() |> String.slice(0, 80)

    Longpi.Agent.create_conversation(%{
      cwd: args[:cwd] || state.ctx.cwd,
      model: args[:model] || agent_def.model || state.model,
      reasoning_effort: agent_def.reasoning_effort || state.reasoning_effort,
      agent_role: agent_def.name,
      parent_id: state.conversation_id,
      title: title
    })
  end

  defp fetch_subagent(state, handle) do
    case state.subagents do
      %{^handle => info} ->
        {:ok, info}

      _ ->
        known = state.subagents |> Map.keys() |> Enum.join(", ")
        {:error, "Unknown agent handle \"#{handle}\". Known: #{known}"}
    end
  end

  defp live_subagent_pid(info) do
    case Longpi.Agent.Sessions.whereis(info.conversation_id) do
      nil -> {:error, "#{info.role} session is no longer running (closed or crashed)."}
      pid -> {:ok, pid}
    end
  end

  defp mark_subagent(state, handle, status) do
    subagents =
      Map.update!(state.subagents, handle, &%{&1 | status: status, collected: false})

    notify_subagents(%{state | subagents: subagents})
  end

  # UI event: the current children snapshot, serializable for the channel.
  defp agent_role(%{agent_def: %Subagents.Def{name: name}}), do: name
  defp agent_role(_state), do: "agent"

  # A terminal child can't answer a pending bubbled approval — drop it (and
  # clear the parent's prompt) so it doesn't linger.
  defp clear_subagent_approvals_for(state, child_id) do
    {stale, kept} =
      Map.split_with(state.subagent_approvals, fn {_call_id, %{conversation_id: cid}} ->
        cid == child_id
      end)

    state = %{state | subagent_approvals: kept}

    Enum.reduce(stale, state, fn {call_id, _}, acc ->
      notify(acc, {:subagent_approval_resolved, call_id})
    end)
  end

  # The parent's handle ("scout-1") for a child conversation id.
  defp subagent_handle_for(state, child_id) do
    Enum.find_value(state.subagents, "agent", fn
      {handle, %{conversation_id: ^child_id}} -> handle
      _ -> false
    end)
  end

  defp notify_subagents(state) do
    snapshot =
      Map.new(state.subagents, fn {handle, info} ->
        {handle,
         %{
           conversation_id: info.conversation_id,
           role: info.role,
           status: info.status,
           task: info.task |> String.split("\n") |> hd() |> String.slice(0, 120),
           started_at: info.started_at
         }}
      end)

    notify(state, {:subagents, snapshot})
  end

  # Child sessions tell their parent when a turn ends.
  defp notify_parent_done(%{parent_session: nil}, _status), do: :ok

  defp notify_parent_done(state, status) do
    send(state.parent_session, {:subagent_update, state.conversation_id, status})
    :ok
  end

  # Codex V1's pattern: when a child finishes while the parent is idle (its
  # turn already ended), inject a notification message so the user sees it and
  # the model learns of it next turn. Skipped when wait_agent already returned
  # this child's output (collected) or the parent is mid-turn (wait/list will
  # pick it up live).
  defp maybe_inject_subagent_notice(%{status: :running} = state, _handle, _info), do: state
  defp maybe_inject_subagent_notice(state, _handle, %{collected: true}), do: state

  defp maybe_inject_subagent_notice(state, handle, info) do
    verb =
      case info.status do
        :done -> "finished"
        :failed -> "failed (#{info.detail})"
        other -> to_string(other)
      end

    message =
      Message.user(
        "[subagent] #{handle} (#{info.role}) #{verb}. " <>
          "Ask me to collect its result if you want it."
      )

    state = persist(state, [message])
    state = %{state | messages: state.messages ++ [message]}
    notify(state, {:history, broadcast_history(state)})
  end

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

  # Debounce: coalesce a burst of extension writes into one reload ~400ms later.
  defp schedule_ext_reload(state) do
    if t = state.ext_reload_timer, do: Process.cancel_timer(t)
    %{state | ext_reload_timer: Process.send_after(self(), :auto_reload_extensions, 400)}
  end

  # Reload off the session process so the 15s host-call can't block it.
  defp reload_extensions_async(host, session) do
    Task.start(fn ->
      specs = Longpi.Extensions.Host.reload(host)
      commands = Longpi.Extensions.Host.commands(host)
      send(session, {:extensions_loaded, host, specs, commands})
    end)
  end

  defp persist_reasoning(nil, _effort), do: :ok

  defp persist_reasoning(conversation_id, effort) do
    with {:ok, conversation} <- Longpi.Agent.get_conversation(conversation_id) do
      Longpi.Agent.update_conversation(conversation, %{reasoning_effort: effort})
    end

    :ok
  rescue
    _ -> :ok
  end

  # Whitelist string -> atom for the LLM option (never String.to_atom on input).
  defp reasoning_effort_atom("minimal"), do: :minimal
  defp reasoning_effort_atom("low"), do: :low
  defp reasoning_effort_atom("medium"), do: :medium
  defp reasoning_effort_atom("high"), do: :high
  defp reasoning_effort_atom("xhigh"), do: :xhigh
  defp reasoning_effort_atom(_), do: nil

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

    # Reassemble the prompt from current state so this turn's system message
    # and tool set reflect the latest settings, subagent roles, and extensions.
    state = assemble_prompt(state)

    toolbox = state.toolbox

    config = %{
      llm: state.llm,
      model: state.model,
      reasoning_effort: reasoning_effort_atom(state.reasoning_effort),
      toolbox: toolbox,
      ctx: state.ctx,
      sink: fn event -> send(session, {:turn_event, event}) end,
      authorize: fn call -> authorize(session, tool_source(toolbox, call.name), call) end
    }

    # The LLM sees the compacted context ([system, summary, recent]); the full
    # history stays in state.messages for the UI and future compactions.
    context = llm_context(state)

    task =
      Task.Supervisor.async_nolink(Longpi.Agent.TaskSupervisor, fn ->
        Turn.run(config, context)
      end)

    fire_ext_event(state, "turn_start", %{})
    touch(%{state | status: :running, task: task, partial: []})
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
  # A tool's source (:builtin | :extension) gates it differently under :auto.
  defp tool_source(toolbox, name) do
    case toolbox do
      %{^name => %{source: source}} -> source
      _ -> :builtin
    end
  end

  defp authorize(session, source, call) do
    case Longpi.Agent.Permissions.mode(call.name, source) do
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
  # Like truncate_to_last_user, but drops the last user message TOO — the
  # edit flow replaces it with fresh text.
  defp truncate_before_last_user(state) do
    [system | rest] = state.messages

    case last_index(rest, &(&1.role == :user)) do
      nil ->
        :error

      idx ->
        kept = Enum.take(rest, idx)
        delete_persisted_after(state, idx - 1)
        {:ok, %{state | messages: [system | kept], persisted_count: idx}}
    end
  end

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
