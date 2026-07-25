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
  @builtin_commands ~w(compact model reload rename help loop schedule)

  # Runaway fuse for self-driven turns (/loop + continue_later combined):
  # after this many consecutive auto-turns the session stops and waits for a
  # real user message, which resets the count.
  @auto_turns_max 30
  # Ceiling for an explicit /loop's requested iteration count.
  @loop_max 50
  # Hard ceiling on TOTAL automatic retries between user interactions. The
  # per-streak counter resets on any progress by design, so a gateway that
  # reliably fails one iteration in would otherwise retry forever (streak
  # stuck at 1) while bypassing the auto_turns fuse.
  @turn_retry_budget 10

  @loop_done_marker "LOOP_DONE"

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
  Starts an explicit loop: the task is re-fed to the model every turn until it
  answers with LOOP_DONE, `stop_loop/1` is called, or `iterations` run out.
  Kicks off the first turn immediately when idle. `every_ms` > 0 waits that
  long between turns (a timed/polling loop) instead of continuing straight
  away — the session stays alive while a timed wake-up is pending.
  """
  def start_loop(session, task, iterations, every_ms \\ 0),
    do: GenServer.call(session, {:start_loop, task, iterations, every_ms})

  @doc "Stops the loop and clears any scheduled continuation."
  def stop_loop(session), do: GenServer.call(session, :stop_loop)

  @doc "The running loop as `%{task, remaining, total}`, or nil."
  def loop_status(session), do: GenServer.call(session, :loop_status)

  @doc """
  The RUNNING turn's streamed events so far, in wire format (oldest first),
  plus the session's event-seq watermark covering them — a client joining
  mid-turn replays the events and uses the watermark to drop pushes that are
  already contained in the replay. Events are empty when idle.
  """
  def live_events(session), do: GenServer.call(session, :live_events)

  @doc """
  Re-runs the last turn: drops the previous assistant response (and its tool
  calls) back to the last user message and generates a fresh reply.
  """
  def regenerate(session), do: GenServer.call(session, :regenerate)

  def messages(session), do: GenServer.call(session, :messages)

  def status(session), do: GenServer.call(session, :status)

  @doc "Pending clean-retry countdown (`%{attempt, max, delay_ms, until_ms, reason}`) or nil."
  def retrying(session), do: GenServer.call(session, :retrying)

  @doc "One-call state snapshot for the channel's join/get_state reply."
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @doc "True when the previous incarnation died mid-turn (resume is available)."
  def interrupted_turn?(session), do: GenServer.call(session, :interrupted_turn?)

  @doc "Continues an interrupted turn from the checkpointed history (no new message)."
  def resume(session), do: GenServer.call(session, :resume)

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
       # Live-turn replay buffer: the streamed events of the RUNNING turn,
       # folded (adjacent deltas merged, tool output accumulated per call) so
       # a client that joins mid-turn — a refresh, another tab, the mobile
       # shell — replays them and lands on the exact live view instead of a
       # blank pane until the turn ends. Newest first; capped by live_bytes.
       live: [],
       live_bytes: 0,
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
       # A leftover turn-in-flight marker means the previous incarnation died
       # mid-turn (crash/deploy/power) — the checkpointed history is intact,
       # so the client can offer "resume".
       interrupted_turn?:
         not is_nil(conversation && conversation.turn_started_at) and history != [],
       # Mirrors the conversation's unseen_kind so watch-clears skip the DB
       # write when there is nothing to clear.
       attention: conversation && conversation.unseen_kind,
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
       idle_timer: nil,
       # Continuation engine. `loop` = the explicit /loop task (nil when off;
       # `every_ms` > 0 makes it a timed loop); `auto_continue` = a
       # {note, delay_ms} the model scheduled via continue_later; `auto_turns`
       # counts CONSECUTIVE self-driven turns (either kind) and only a real
       # user message resets it — the runaway fuse for both paths.
       # `continue_timer` is the pending delayed wake-up (also blocks reaping).
       loop: nil,
       auto_continue: nil,
       auto_turns: 0,
       continue_timer: nil,
       # Consecutive ZERO-PROGRESS transient failures — drives auto-retry with
       # backoff; any run that produced messages (and any user message) resets
       # it, so only a genuinely dead gateway exhausts the budget.
       turn_retries: 0,
       # Messages of the CURRENT turn already persisted via the per-iteration
       # checkpoint — the turn-end handlers drop this many before persisting.
       turn_persisted: 0,
       # Pending clean retry: %{attempt, max, delay_ms, until_ms, reason} while
       # a :retry_turn timer is in flight (surfaced on join for the countdown).
       retrying: nil,
       retry_timer: nil,
       # TOTAL retries since the last user interaction / clean completion —
       # the @turn_retry_budget ceiling (the streak counter alone can't bound
       # a fail-with-progress loop).
       retry_total: 0
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

  # Let extensions observe tool activity (`longpi.on("tool_call"|"tool_result")`).
  # Fired after the fact — off the tool-execution hot path, fire-and-forget —
  # so an extension can log/telemeter without gating the turn. (Modify/block
  # hooks would need synchronous interception; deliberately not offered here.)
  defp fire_tool_hook(state, {:tool_call, call}),
    do: fire_ext_event(state, "tool_call", %{id: call.id, name: call.name, args: call.args})

  defp fire_tool_hook(state, {:tool_result, %{call: call, content: content, error?: error?}}),
    do:
      fire_ext_event(state, "tool_result", %{
        id: call.id,
        name: call.name,
        content: content,
        error: error?
      })

  defp fire_tool_hook(_state, _event), do: :ok

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
    # A real user message resets the self-driven-turn fuse, takes over any
    # pending timed wake-up (a surviving loop re-arms after this turn), and
    # clears a stale continuation note — re-arming an "[auto-retry] previous
    # attempt failed" after the USER's successful turn would gaslight the model.
    state =
      state
      |> cancel_continue_timer()
      |> cancel_retry()
      |> Map.merge(%{auto_turns: 0, turn_retries: 0, retry_total: 0, auto_continue: nil})
    user_message = Message.user(text, attachments)
    state = persist(state, [user_message])
    messages = state.messages ++ [user_message]
    {:reply, :ok, run_turn(%{state | messages: messages}, messages)}
  end

  def handle_call({:schedule_continuation, note, delay_ms}, _from, state) do
    cond do
      state.auto_turns >= @auto_turns_max ->
        {:reply,
         {:error,
          "auto-turn limit reached (#{@auto_turns_max} consecutive self-driven turns); " <>
            "summarize where you are and wait for the user"}, state}

      true ->
        {:reply, :ok, %{state | auto_continue: {note, delay_ms}}}
    end
  end

  def handle_call({:start_loop, task, iterations, every_ms}, _from, state) do
    task = String.trim(to_string(task))
    n = iterations |> max(1) |> min(@loop_max)

    if task == "" do
      {:reply, {:error, "loop task must not be empty"}, state}
    else
      state = cancel_continue_timer(state)

      # A fresh loop replaces any leftover continue_later note — otherwise the
      # stale note would hijack the loop's first turn.
      state = %{
        state
        | loop: %{task: task, remaining: n, total: n, every_ms: every_ms},
          auto_continue: nil,
          auto_turns: 0
      }
      # The first turn starts immediately even for a timed loop — the interval
      # applies BETWEEN turns.
      if state.status == :idle, do: send(self(), :continue_now)
      {:reply, {:ok, n}, state}
    end
  end

  def handle_call(:stop_loop, _from, state) do
    stopped? =
      state.loop != nil or state.auto_continue != nil or state.continue_timer != nil

    state = cancel_continue_timer(state)
    # Only when nothing is RUNNING: /loop stop during a live iteration keeps
    # the turn going by design, and its marker must survive a crash so the
    # checkpointed progress still offers Resume.
    state =
      if stopped? and state.status != :running, do: clear_turn_inflight(state), else: state

    {:reply, {:ok, stopped?}, touch(%{state | loop: nil, auto_continue: nil})}
  end

  def handle_call(:loop_status, _from, state), do: {:reply, state.loop, state}

  def handle_call(:live_events, _from, state),
    do: {:reply, %{seq: state.seq, events: serialize_live(state.live)}, state}

  def handle_call({:edit_last, _text, _attachments}, _from, %{status: status} = state)
      when status in [:running, :compacting] do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:edit_last, text, attachments}, _from, state) do
    # Editing takes over like a fresh user message: cancel a pending timed
    # wake-up and drop any stale continuation note (the loop re-arms after
    # this turn).
    state = %{cancel_retry(cancel_continue_timer(state)) | auto_continue: nil, turn_retries: 0, retry_total: 0}

    # The edit composer only lets the user change TEXT — when the client sends
    # no attachments, carry the original message's over instead of silently
    # dropping its images/files from the re-run.
    original = Enum.reverse(state.messages) |> Enum.find(&(&1.role == :user))

    attachments =
      case {attachments, original} do
        {[], %{attachments: kept}} when is_list(kept) -> kept
        _ -> attachments
      end

    case truncate_before_last_user(state) do
      {:ok, state} ->
        # Append the replacement FIRST, then broadcast: unlike send (where the
        # client adds the message optimistically), the edit flow's only source
        # of truth is this history push — broadcasting the truncated list
        # would make the new message vanish until a reload.
        user_message = Message.user(text, attachments)
        state = persist(state, [user_message])
        state = %{state | messages: state.messages ++ [user_message]}
        state = notify(state, history_event(state))
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
    state = %{cancel_retry(cancel_continue_timer(state)) | auto_continue: nil, turn_retries: 0, retry_total: 0}

    case truncate_to_last_user(state) do
      {:ok, state} ->
        # Tell clients to rebuild their view from the truncated history before
        # the new turn streams in.
        state = notify(state, history_event(state))
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
      # Interrupting also stops self-continuation — the user wants the wheel.
      |> cancel_continue_timer()
      |> Map.merge(%{status: :idle, task: nil, partial: [], live: [], live_bytes: 0, loop: nil, auto_continue: nil, pending_approvals: %{}, turn_persisted: 0})

    state = notify(state, {:turn_ended, :interrupted})
    fire_ext_event(state, "turn_end", %{reason: "interrupted"})
    state = clear_turn_inflight(state)
    {:reply, :ok, state}
  end

  # Idle interrupt: nothing is running, but a timed loop may be waiting for
  # its next wake-up — or a retry backoff may be counting down. "Stop" must
  # stop those too, not just a live turn.
  def handle_call(:interrupt, _from, state) do
    had_retry? = state.retrying != nil

    stopped_pending? =
      had_retry? or state.loop != nil or state.auto_continue != nil or
        state.continue_timer != nil

    state = state |> cancel_continue_timer() |> cancel_retry()
    # Settle the client's retry countdown the same way a stopped turn settles.
    state = if had_retry?, do: notify(state, {:turn_ended, :interrupted}), else: state
    # Stop during a self-continue/retry window is a deliberate settle — the
    # turn marker must come off or a later session rebuild offers a bogus
    # Resume for work the user chose to stop.
    state = if stopped_pending?, do: clear_turn_inflight(state), else: state
    {:reply, :ok, touch(%{state | loop: nil, auto_continue: nil})}
  end

  def handle_call(:messages, _from, state), do: {:reply, state.messages, state}

  def handle_call(:retrying, _from, state), do: {:reply, state.retrying, state}

  def handle_call(:interrupted_turn?, _from, state), do: {:reply, state.interrupted_turn?, state}

  def handle_call(:resume, _from, %{status: :idle} = state) do
    # More than just the system message — otherwise there is nothing to run.
    if length(state.messages) > 1 do
      {:reply, :ok, run_turn(state, state.messages)}
    else
      {:reply, {:error, :nothing_to_resume}, state}
    end
  end

  def handle_call(:resume, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:pending_approvals, _from, state),
    do: {:reply, Map.keys(state.pending_approvals), state}

  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    # Someone is looking now — the sidebar's unseen dot comes off. The DB
    # write happens AFTER this reply (self-message): watch sits on the
    # channel-join critical path with a 5s timeout, and a contended SQLite
    # write here would fail the whole join.
    if state.attention, do: send(self(), :clear_attention)
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

  # Everything the channel's join/get_state reply needs, in ONE call — the
  # per-field getters remain for targeted reads, but twelve sequential
  # GenServer round-trips on the join path were pure overhead (and each one
  # queued behind whatever the session was doing).
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       messages: state.messages,
       live: %{seq: state.seq, events: serialize_live(state.live)},
       status: state.status,
       pending_approvals: Map.keys(state.pending_approvals),
       retrying: state.retrying,
       interrupted: state.interrupted_turn?,
       context_usage: context_usage_payload(state),
       reasoning_effort: state.reasoning_effort,
       ext: %{commands: state.ext_commands, host: state.ext_host},
       subagents: state.subagents,
       subagent_approvals: Map.values(state.subagent_approvals)
     }, state}
  end

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

  # A completed iteration (assistant + its tool results): checkpoint it to the
  # DB immediately — pi's per-message persistence. Whatever kills the rest of
  # the turn (stream failure, task crash, VM restart), this work is kept, and
  # the turn-end handlers drop the already-persisted head via turn_persisted.
  def handle_info({:turn_event, {:iteration_messages, msgs}}, %{status: :running} = state) do
    state = persist(state, msgs)

    # The checkpoint is a boundary like turn start/end: this iteration's text
    # now lives in `messages`, so the crash-recovery buffers must restart.
    # Leaving `partial` full would double-persist the text on a later
    # interrupt (keep_partial_text), and leaving `live` full would replay
    # this iteration's events ON TOP of the checkpointed history to a
    # mid-turn joiner (duplicated tool items).
    {:noreply,
     %{
       state
       | messages: state.messages ++ msgs,
         turn_persisted: state.turn_persisted + length(msgs),
         partial: [],
         live: [],
         live_bytes: 0
     }}
  end

  # After an interrupt the turn is settled — a straggler checkpoint would
  # append out of order (keep_partial_text already ran).
  def handle_info({:turn_event, {:iteration_messages, _msgs}}, state), do: {:noreply, state}

  def handle_info({:turn_event, event}, %{status: :running} = state) do
    fire_tool_hook(state, event)
    state = notify(state, event)
    state = buffer_live(state, event)

    case event do
      {:text_delta, text} -> {:noreply, %{state | partial: [state.partial | text]}}
      _ -> {:noreply, state}
    end
  end

  # Events already queued when an interrupt landed: the buffers were just
  # cleared — folding ghosts back in would replay them to the next joiner.
  # Extension hooks still fire (the tool genuinely ran); only the UI stream
  # and replay buffer skip the stale event.
  def handle_info({:turn_event, event}, state) do
    fire_tool_hook(state, event)
    {:noreply, state}
  end

  # A tool needs approval: remember who's waiting and prompt the user. A
  # subagent has no one watching its own conversation, so it ALSO bubbles the
  # request to its parent, which surfaces it in the parent's view.
  def handle_info({:approval_request, task_pid, ref, call}, state) do
    pending = Map.put(state.pending_approvals, call.id, {task_pid, ref})
    state = notify(%{state | pending_approvals: pending}, {:approval_request, call})
    # An unwatched approval is the urgent badge: it auto-denies in 5 minutes.
    state = flag_attention(state, "approval")

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

  def handle_info({:approval_timed_out, call_id}, state) do
    state = notify(state, {:approval_resolved, call_id})
    {:noreply, %{state | pending_approvals: Map.delete(state.pending_approvals, call_id)}}
  end

  # Turn task finished
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = touch(%{state | status: :idle, task: nil, partial: [], live: [], live_bytes: 0, pending_approvals: %{}})

    # Completed iterations were already checkpointed as they happened — only
    # the tail past turn_persisted is new here.
    already_persisted = state.turn_persisted
    state = %{state | turn_persisted: 0}

    case result do
      {:ok, all_messages} ->
        new_messages = Enum.drop(all_messages, already_persisted)
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        # Broadcast the committed history BEFORE turn_ended so any client —
        # including one that reloaded mid-turn and missed the streamed deltas —
        # converges to the correct, complete messages. (Order matters: the
        # `history` event forces status "running"; the following `turn_ended`
        # settles items and flips to idle.)
        state = notify(state, history_event(state))
        state = notify(state, {:turn_ended, :complete})
        fire_ext_event(state, "turn_end", %{reason: "complete"})
        report_gateway(state, :ok)
        state = clear_turn_inflight(state)
        notify_parent_done(state, :done)
        state = maybe_start_titling(state)
        state = settle_loop(state, all_messages)
        state = schedule_continue(%{state | turn_retries: 0, retry_total: 0})

        # "Done" only when the CHAIN is done: a /loop or continuation still
        # has work queued — badging "finished while you were away" after
        # iteration 1 of 10 would be a lie (failures still flag immediately).
        state =
          if state.loop == nil and state.auto_continue == nil and state.continue_timer == nil,
            do: flag_attention(state, "done"),
            else: state

        {:noreply, maybe_start_compaction(state)}

      {:error, :max_iterations, all_messages} when state.auto_turns < @auto_turns_max ->
        # NOT a failure: the model was mid-task and ran out of the per-turn
        # tool budget. Persist the progress and self-continue — regenerate
        # would throw away 25 turns of tool work; picking up where it left
        # off is what a human would do. The auto-turn fuse still bounds the
        # total, so a genuinely stuck task ends at the fuse (below clause).
        new_messages = Enum.drop(all_messages, already_persisted)
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = notify(state, history_event(state))
        state = notify(state, {:turn_ended, :complete})
        fire_ext_event(state, "turn_end", %{reason: "max_iterations"})

        state = %{
          state
          | turn_retries: 0,
            # A full turn of tool work IS progress — the retry budget refills
            # here the same as on a clean settle (the auto_turns fuse bounds
            # the chain itself).
            retry_total: 0,
            auto_continue:
              {"[continue] You hit the per-turn tool-call budget. Pick up exactly " <>
                 "where you left off and finish the task.", 0}
        }

        state = schedule_continue(state)
        {:noreply, maybe_start_compaction(state)}

      {:error, reason, all_messages} ->
        # Keep whatever the turn produced — but no failure note yet: a retry
        # is pending, and the failed attempt must stay invisible to the model
        # (history simply ends at the last completed iteration, so re-running
        # is a natural continuation — nothing to clean up, unlike pi which
        # strips the errored message from context).
        new_messages = Enum.drop(all_messages, already_persisted)
        state = persist(state, new_messages)
        state = %{state | messages: state.messages ++ new_messages}
        state = if new_messages == [], do: state, else: notify(state, history_event(state))
        fire_ext_event(state, "turn_end", %{reason: "failed"})

        # The retry counter only counts CONSECUTIVE ZERO-PROGRESS failures:
        # a run that got anything done proves the gateway breathes, so the
        # streak restarts (pi resets on any successful assistant message).
        progressed? = already_persisted > 0 or new_messages != []
        streak = if progressed?, do: 0, else: state.turn_retries
        attempt = streak + 1
        delays = retry_delays()

        if retryable_turn?(reason) and attempt <= length(delays) and
             state.retry_total < @turn_retry_budget do
          report_gateway(state, :error)
          delay = retry_delay_for(state, Enum.at(delays, attempt - 1))
          timer = Process.send_after(self(), :retry_turn, delay)

          retrying = %{
            attempt: attempt,
            max: length(delays),
            delay_ms: delay,
            until_ms: System.system_time(:millisecond) + delay,
            reason: humanize_reason(reason)
          }

          state = %{
            state
            | turn_retries: attempt,
              retry_total: state.retry_total + 1,
              retrying: retrying,
              retry_timer: timer
          }
          {:noreply, notify(state, {:turn_retrying, retrying})}
        else
          # Out of budget or a dead-end error: NOW the failure becomes
          # visible — persisted note (survives reloads) + turn_failed (the
          # Retry button). Self-continuation stops; looping onto it repeats it.
          {:noreply, settle_failed_turn(state, reason)}
        end
    end
  end

  # The clean retry: re-run the turn on the checkpointed history — no injected
  # user message, no failure note; the model sees a context that simply ends
  # at the last completed iteration. Superseded silently if the user took over
  # (send_message/edit/regenerate cancel the timer and clear `retrying`).
  def handle_info(:retry_turn, %{status: :idle, retrying: %{}} = state) do
    state = %{state | retrying: nil, retry_timer: nil}
    {:noreply, run_turn(state, state.messages)}
  end

  def handle_info(:retry_turn, state), do: {:noreply, %{state | retry_timer: nil}}


  # Self-driven continuation: fires after a completed turn (immediately, or
  # via the delayed timer for timed loops / delayed continue_later). Skipped
  # (with everything preserved) if the user got a message in first.
  def handle_info(:continue_now, %{status: status} = state) when status != :idle,
    do: {:noreply, %{state | continue_timer: nil}}

  def handle_info(:continue_now, state) do
    state = %{state | continue_timer: nil}

    cond do
      state.auto_turns >= @auto_turns_max ->
        state = notify(state, {:loop_ended, :limit})
        # The continuation chain is over — nothing in flight to resume.
        state = clear_turn_inflight(state)
        {:noreply, touch(%{state | loop: nil, auto_continue: nil})}

      state.auto_continue != nil ->
        {{note, _delay}, state} = {state.auto_continue, %{state | auto_continue: nil}}
        inject(state, "[auto-continue #{state.auto_turns + 1}] #{note}")

      match?(%{remaining: r} when r > 0, state.loop) ->
        %{task: task, remaining: remaining, total: total} = state.loop
        k = total - remaining + 1

        state = %{state | loop: %{state.loop | remaining: remaining - 1}}

        inject(
          state,
          "[loop #{k}/#{total}] Continue working on this task. When it is fully " <>
            "complete, put #{@loop_done_marker} on its own line in your reply:\n\n#{task}"
        )

      true ->
        # Iterations ran out without LOOP_DONE — tell the UI it's over.
        state = notify(state, {:loop_ended, :exhausted})
        {:noreply, touch(%{state | loop: nil})}
    end
  end

  # Compaction task finished. Re-arm any pending continuation afterwards: a
  # `:continue_now` that arrived while status was :compacting was dropped, so
  # without this an active loop would sit forever (unrunnable AND unreapable).
  def handle_info({ref, result}, %{compaction_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = apply_compaction(%{state | compaction_task: nil, status: :idle}, result)
    {:noreply, schedule_continue(state)}
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

  # Turn task crashed. Like the error branch, self-continuation stops — looping
  # onto a crash would repeat it, and a stranded loop would block reaping.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = keep_partial_text(state)
    state = cancel_continue_timer(state)
    # Iterations checkpointed before the crash are already in state.messages —
    # a crash loses only the in-flight iteration, same as a stream failure.
    state = %{state | status: :idle, task: nil, partial: [], live: [], live_bytes: 0, loop: nil, auto_continue: nil, pending_approvals: %{}, turn_persisted: 0}
    {:noreply, settle_failed_turn(state, {:crashed, reason})}
  end

  # Compaction task crashed: fall back to a truncation checkpoint so context
  # still shrinks and the session isn't wedged.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{compaction_task: %Task{ref: ref}} = state
      ) do
    state = apply_compaction(%{state | compaction_task: nil, status: :idle}, :fallback)
    {:noreply, schedule_continue(state)}
  end

  # A child bubbled a tool approval — track it and surface it in this
  # conversation's view (attributed to the subagent). The badge matters here
  # too: the child session is excluded from badges (parent_session guard),
  # so an unwatched parent is the ONLY place this approval can become
  # visible before it auto-denies.
  def handle_info({:subagent_approval_request, child_id, role, call}, state) do
    entry = %{conversation_id: child_id, role: role, handle: subagent_handle_for(state, child_id), call: call}
    approvals = Map.put(state.subagent_approvals, call.id, entry)
    state = flag_attention(%{state | subagent_approvals: approvals}, "approval")
    {:noreply, notify(state, {:subagent_approval, entry})}
  end

  def handle_info(:clear_attention, state), do: {:noreply, clear_attention(state)}

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
  # watcher leaves, the idle timer may now find the session reapable — and any
  # approval that arrived WHILE watched (so it never flagged) must badge now,
  # or closing the tab makes it silently time out.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{watchers: watchers} = state)
      when is_map_key(watchers, ref) do
    state = %{state | watchers: Map.delete(watchers, ref)}

    state =
      if map_size(state.watchers) == 0 and
           (map_size(state.pending_approvals) > 0 or map_size(state.subagent_approvals) > 0),
         do: flag_attention(state, "approval"),
         else: state

    {:noreply, state}
  end

  # A subagent session died. Normal completion keeps the child alive (idle),
  # so an unexpected DOWN on a non-terminal child means it crashed.
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.subagents, fn {_h, info} -> info.pid == pid end) do
      {handle, %{status: :running} = info} ->
        info = %{info | status: :failed, detail: "session down: #{inspect(reason)}"}
        state = %{state | subagents: Map.put(state.subagents, handle, info)}
        # A crashed child can never answer its bubbled approval — clearing it
        # here keeps the parent reapable and retracts the ghost prompt.
        state = clear_subagent_approvals_for(state, info.conversation_id)
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
  # An active loop / pending continuation (incl. a timed wake-up) counts as
  # work — reaping would silently kill the timer.
  defp reapable?(state) do
    state.status == :idle and
      not is_nil(state.conversation_id) and
      is_nil(state.parent_session) and
      is_nil(state.compaction_task) and
      is_nil(state.title_task) and
      is_nil(state.loop) and
      is_nil(state.auto_continue) and
      is_nil(state.continue_timer) and
      is_nil(state.retry_timer) and
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

    # The model reference may be a tier alias (J/Q/K, admin-mapped) or a full
    # spec; nil falls through to the role's pin, then the parent's model. A
    # tier is a complete profile, so its bundled reasoning effort wins over the
    # role's — picking "K" means the whole K configuration.
    with {:ok, resolved} <- Longpi.Agent.ModelResolver.resolve(args[:model] || agent_def.model) do
      Longpi.Agent.create_conversation(%{
        cwd: args[:cwd] || state.ctx.cwd,
        model: resolved.spec || state.model,
        reasoning_effort:
          resolved.reasoning_effort || agent_def.reasoning_effort || state.reasoning_effort,
        agent_role: agent_def.name,
        parent_id: state.conversation_id,
        title: title
      })
    end
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
    notify(state, history_event(state))
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

  # ── Live-turn replay buffer ─────────────────────────────────────────

  # Cap the buffer so a pathological turn can't balloon the session process;
  # past it, text-ish accumulation stops (structure events still recorded) and
  # the eventual history broadcast fills the gap.
  @live_max_bytes 2_000_000

  defp buffer_live(state, event) do
    case fold_live(state.live, event) do
      nil ->
        state

      {live, added} when state.live_bytes + added <= @live_max_bytes ->
        %{state | live: live, live_bytes: state.live_bytes + added}

      {_live, _added} ->
        # Over the cap: keep recording STRUCTURE (tool calls/results — a late
        # joiner must not see a stuck spinner) but with truncated content;
        # the history broadcast carries the full truth at turn end.
        case event do
          {:tool_call, _} = ev ->
            {live, added} = fold_live(state.live, ev)
            %{state | live: live, live_bytes: state.live_bytes + added}

          {:tool_result, %{call: call, content: content, error?: error?}} ->
            truncated = String.slice(content, 0, 2_048) <> "\n[truncated — full result on turn end]"
            {live, added} = fold_live(state.live, {:tool_result, %{call: call, content: truncated, error?: error?}})
            %{state | live: live, live_bytes: state.live_bytes + added}

          _ ->
            state
        end
    end
  end

  # Newest-first fold: adjacent deltas merge into one entry, tool output
  # accumulates per call id. Returns {new_live, bytes_added} or nil to skip.
  defp fold_live([{:text, io} | rest], {:text_delta, text}),
    do: {[{:text, [io | text]} | rest], byte_size(text)}

  defp fold_live(live, {:text_delta, text}), do: {[{:text, [text]} | live], byte_size(text)}

  defp fold_live([{:thinking, io} | rest], {:thinking_delta, text}),
    do: {[{:thinking, [io | text]} | rest], byte_size(text)}

  defp fold_live(live, {:thinking_delta, text}),
    do: {[{:thinking, [text]} | live], byte_size(text)}

  defp fold_live(live, {:tool_call, call}), do: {[{:tool_call, call} | live], 200}

  defp fold_live([{:tool_output, id, io} | rest], {:tool_output, %{id: id, chunk: chunk}}),
    do: {[{:tool_output, id, [io | chunk]} | rest], byte_size(chunk)}

  defp fold_live(live, {:tool_output, %{id: id, chunk: chunk}}),
    do: {[{:tool_output, id, [chunk]} | live], byte_size(chunk)}

  defp fold_live(live, {:tool_result, %{call: call, content: content, error?: error?}}),
    do: {[{:tool_result, call.id, call.name, content, error?} | live], byte_size(content)}

  defp fold_live(_live, _event), do: nil

  # Oldest-first wire format — the exact shapes the channel already pushes, so
  # the client replays them through the same reducer paths as live events.
  defp serialize_live(live) do
    live
    |> Enum.reverse()
    |> Enum.map(fn
      {:text, io} -> %{type: "text_delta", text: IO.iodata_to_binary(io)}
      {:thinking, io} -> %{type: "thinking_delta", text: IO.iodata_to_binary(io)}
      {:tool_call, call} -> %{type: "tool_call", id: call.id, name: call.name, args: call.args}
      {:tool_output, id, io} -> %{type: "tool_output", id: id, chunk: IO.iodata_to_binary(io)}
      {:tool_result, id, name, content, error?} ->
        %{type: "tool_result", id: id, name: name, content: content, error: error?}
    end)
  end

  # ── Continuation engine (/loop + continue_later) ────────────────────

  # Failures worth retrying without the user: upstream/gateway trouble, not
  # logic errors. Crashes and unknown atoms stay manual.
  defp retryable_turn?(%{status: status}) when is_integer(status) and (status >= 500 or status == 429), do: true
  defp retryable_turn?(%{reason: nested}) when is_map(nested), do: retryable_turn?(nested)

  defp retryable_turn?(%{reason: text}) when is_binary(text),
    do: text =~ ~r/status: (5\d\d|429)/ or text =~ "timeout"

  defp retryable_turn?(reason), do: Longpi.Agent.Retry.transient?(reason)

  # Backoff schedule for clean turn retries: fast first probes (blips), long
  # tail (real gateway outages). ~7 minutes of total patience by default.
  defp retry_delays,
    do: Application.get_env(:longpi, :turn_retry_delays, [2_000, 8_000, 30_000, 90_000, 300_000])

  # The circuit breaker knows how long the gateway has been down ACROSS all
  # sessions — never probe earlier than it advises.
  defp retry_delay_for(state, schedule_delay) do
    max(schedule_delay, Longpi.Agent.GatewayHealth.delay_for(state.model))
  end

  defp report_gateway(state, verdict) do
    Longpi.Agent.GatewayHealth.report(state.model, verdict)
  catch
    # Health tracking must never take a turn down with it.
    _, _ -> :ok
  end

  defp cancel_retry(%{retry_timer: nil, retrying: nil} = state), do: state

  defp cancel_retry(state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    %{state | retry_timer: nil, retrying: nil}
  end

  # The shared "this turn is dead" tail: persisted note, turn_failed (the
  # Retry button), marker/badge bookkeeping, and stopping self-continuation.
  # Used by both the retry give-up branch and the task-crash DOWN handler.
  defp settle_failed_turn(state, reason) do
    note = failure_note(reason)
    state = persist(state, [note])
    state = %{state | messages: state.messages ++ [note]}
    state = notify(state, history_event(state))
    state = notify(state, {:turn_failed, reason})
    state = clear_turn_inflight(state)
    state = flag_attention(state, "failed")
    notify_parent_done(state, {:failed, reason})
    %{state | loop: nil, auto_continue: nil, retrying: nil}
  end

  # A compact, persisted record of why the turn died — honest context for both
  # the user (after a reload) and the model (on the next turn).
  defp failure_note(reason) do
    Message.assistant("⚠ Turn failed: #{humanize_reason(reason)}")
  end

  # Pull the human-readable core out of nested LLM errors: an upstream 503
  # should read "upstream 503: No available accounts", not a page of inspect'd
  # %ReqLLM.Error.API.Stream{} structs.
  defp humanize_reason(%{status: status, reason: message})
       when is_integer(status) and is_binary(message),
       do: "upstream #{status}: #{message}"

  defp humanize_reason(%{reason: nested}) when is_map(nested) or is_binary(nested),
    do: humanize_reason(nested)

  defp humanize_reason(reason) when is_binary(reason) do
    # Stream errors stringify their cause; dig the status/message back out.
    with [_, status] <- Regex.run(~r/status: (\d+)/, reason),
         [_, message] <- Regex.run(~r/reason: \\?"([^"\\]+)/, reason) do
      "upstream #{status}: #{message}"
    else
      _ -> String.slice(reason, 0, 300)
    end
  end

  defp humanize_reason(reason) when is_exception(reason),
    do: Exception.message(reason) |> String.slice(0, 300)

  defp humanize_reason(reason), do: reason |> inspect() |> String.slice(0, 300)


  # After a completed turn, arm the next self-driven wake-up: immediately, or
  # after the continuation's delay / the timed loop's interval. Cancels any
  # previous timer first so no path can end up with two live timers.
  defp schedule_continue(state) do
    state = cancel_continue_timer(state)

    delay =
      cond do
        match?({_note, ms} when ms > 0, state.auto_continue) -> elem(state.auto_continue, 1)
        state.auto_continue != nil -> 0
        match?(%{remaining: r, every_ms: ms} when r > 0 and ms > 0, state.loop) -> state.loop.every_ms
        state.loop != nil -> 0
        true -> nil
      end

    case delay do
      nil -> state
      0 -> send(self(), :continue_now) && state
      ms -> %{state | continue_timer: Process.send_after(self(), :continue_now, ms)}
    end
  end

  defp cancel_continue_timer(%{continue_timer: nil} = state), do: state

  defp cancel_continue_timer(state) do
    Process.cancel_timer(state.continue_timer)
    %{state | continue_timer: nil}
  end

  # Ends the loop when the assistant declared the task complete: the marker
  # must stand on its own line in the LAST assistant message — "I'll reply
  # LOOP_DONE when finished" mid-work must not end the loop.
  defp settle_loop(%{loop: nil} = state, _new_messages), do: state

  defp settle_loop(state, new_messages) do
    last_assistant =
      new_messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{role: :assistant, content: text} when is_binary(text) -> text
        _ -> nil
      end)

    done? =
      is_binary(last_assistant) and
        Regex.match?(~r/^\s*#{@loop_done_marker}\b/m, last_assistant)

    if done? do
      state = notify(state, {:loop_ended, :done})
      %{state | loop: nil}
    else
      state
    end
  end

  # Persists and broadcasts a self-driven user message, then starts the turn.
  # Unlike send_message (where the client renders its own message optimistically)
  # nobody typed this, so the history push is the client's only source of truth.
  defp inject(state, text) do
    state = %{state | auto_turns: state.auto_turns + 1}
    user_message = Message.user(text, [])
    state = persist(state, [user_message])
    state = %{state | messages: state.messages ++ [user_message]}
    state = notify(state, history_event(state))
    {:noreply, run_turn(state, state.messages)}
  end

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
    state = mark_turn_inflight(%{state | interrupted_turn?: false})
    touch(%{state | status: :running, task: task, partial: [], live: [], live_bytes: 0, turn_persisted: 0})
  end

  # ── Unseen-activity badge (sidebar dot) ──────────────────────────────

  # Activity nobody is watching — the scheduled-task-ran-while-you-were-away
  # case: mark the conversation so the sidebar shows a dot until someone
  # opens it. Kind: "done" | "failed" | "approval" (approval is the urgent
  # one — the prompt auto-denies after 5 minutes).
  defp flag_attention(%{watchers: watchers} = state, _kind) when map_size(watchers) > 0,
    do: state

  defp flag_attention(%{conversation_id: nil} = state, _kind), do: state
  defp flag_attention(%{parent_session: parent} = state, _kind) when not is_nil(parent), do: state

  # Already flagged with the same kind — N approval-gated calls in one turn
  # must not do N identical writes.
  defp flag_attention(%{attention: kind} = state, kind), do: state

  defp flag_attention(state, kind) do
    case write_conversation_marks(state, unseen_at: DateTime.utc_now(), unseen_kind: kind) do
      :ok ->
        broadcast_attention(state.conversation_id, kind)
        %{state | attention: kind}

      :error ->
        state
    end
  end

  defp clear_attention(%{attention: nil} = state), do: state

  defp clear_attention(state) do
    # The mirror only advances when the row actually changed — a swallowed
    # write failure must not wedge the badge on forever (the next watch
    # retries because `attention` is still set).
    case write_conversation_marks(state, unseen_at: nil, unseen_kind: nil) do
      :ok ->
        broadcast_attention(state.conversation_id, nil)
        %{state | attention: nil}

      :error ->
        state
    end
  end

  # Live sidebar updates: a focused client never blurs, so polling on
  # focus/visibility alone would miss every badge (the 5-minute approval
  # window in particular). SidebarChannel relays this to all sidebars.
  defp broadcast_attention(conversation_id, kind) do
    Phoenix.PubSub.broadcast(
      Longpi.PubSub,
      "sidebar",
      {:conversation_attention, conversation_id, kind}
    )
  catch
    _, _ -> :ok
  end

  # ── Turn-in-flight marker (crash/restart resume) ─────────────────────

  defp mark_turn_inflight(state), do: put_turn_marker(state, DateTime.utc_now())
  defp clear_turn_inflight(state), do: put_turn_marker(state, nil)

  defp put_turn_marker(state, value) do
    write_conversation_marks(state, turn_started_at: value)
    state
  end

  # Shared bookkeeping writer for the marker columns (turn_started_at,
  # unseen_*): one UPDATE by id — no read-modify-write, no updated_at bump
  # (these are metadata, not activity; bumping reordered the mobile list on
  # every watch-clear). Best-effort: any failure reports :error and must
  # never take the turn down. Subagents skip it: their parent coordination
  # dies with the VM, so standalone resume/badges are meaningless.
  defp write_conversation_marks(%{conversation_id: nil}, _sets), do: :error

  defp write_conversation_marks(%{parent_session: parent}, _sets) when not is_nil(parent),
    do: :error

  defp write_conversation_marks(state, sets) do
    import Ecto.Query, only: [from: 2]

    {count, _} =
      Longpi.Repo.update_all(
        from(c in Longpi.Agent.Conversation, where: c.id == ^state.conversation_id),
        set: sets
      )

    if count == 1, do: :ok, else: :error
  catch
    _, _ -> :error
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
          @approval_timeout ->
            # Unblock as deny AND tell the session to drop the pending entry —
            # a stranded entry blocks reaping forever and ghosts the prompt.
            send(session, {:approval_timed_out, call.id})
            :deny
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

  # History pushes carry the session status and pending approvals so a client
  # rebuilding its view mid-approval (or right after a compaction while idle)
  # lands in the correct state instead of assuming "running, nothing pending".
  defp history_event(state) do
    {:history, broadcast_history(state), state.status, Map.keys(state.pending_approvals)}
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
