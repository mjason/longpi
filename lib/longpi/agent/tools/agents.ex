defmodule Longpi.Agent.Tools.Agents do
  @moduledoc """
  Shared plumbing for the subagent tool family (`spawn_agent`, `wait_agent`,
  `list_agents`, `send_agent`, `close_agent`).

  All five talk to the owning `Longpi.Agent.Session` (via `ctx.session`), which
  holds the registry of children this conversation has spawned. They run inside
  the Turn task, so blocking (wait's poll loop) never blocks the session.
  """

  alias Longpi.Agent.ConversationMessage

  @output_cap 50_000

  @doc "Current children snapshot from the owning session: %{handle => info}."
  def snapshot(ctx), do: GenServer.call(ctx.session, :subagent_snapshot)

  @doc "True once a child status can no longer change."
  def terminal?(%{status: status}), do: status in [:done, :failed, :closed]

  @doc "One status line for a child, used by list/wait output."
  def status_line({handle, info}) do
    elapsed = System.system_time(:second) - info.started_at
    "- #{handle} (#{info.role}) — #{info.status}, #{elapsed}s, task: #{summarize(info.task)}"
  end

  @doc """
  The child's final answer: its last assistant message with text. Reads from
  the live session when possible, falling back to the persisted rows.
  """
  def final_output(conversation_id) do
    messages =
      case Longpi.Agent.Sessions.whereis(conversation_id) do
        nil ->
          conversation_id
          |> Longpi.Agent.list_messages!()
          |> Enum.map(&ConversationMessage.to_message/1)

        pid ->
          Longpi.Agent.Session.messages(pid)
      end

    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, content: text} when is_binary(text) and text != "" -> text
      _ -> nil
    end)
    |> case do
      nil -> "(no output)"
      text -> truncate(text)
    end
  end

  defp truncate(text) when byte_size(text) <= @output_cap, do: text

  defp truncate(text) do
    String.slice(text, 0, @output_cap) <>
      "\n\n[output truncated at #{div(@output_cap, 1000)}KB]"
  end

  defp summarize(task) do
    task |> String.split("\n") |> hd() |> String.slice(0, 80)
  end
end

defmodule Longpi.Agent.Tools.SpawnAgent do
  @moduledoc false
  @behaviour Longpi.Agent.Tool

  @impl true
  def name, do: "spawn_agent"

  @impl true
  def description do
    """
    Spawn a subagent to work on a well-scoped task in the background. Returns a
    handle immediately; the subagent runs concurrently with you. Collect results
    with wait_agent.

    Subagents have an ISOLATED context: they see none of your conversation, so the
    task must be fully self-contained (relevant paths, constraints, expected output
    format). They inherit your model and working directory unless the agent role
    pins its own.

    Delegate when work is parallelizable (e.g. several independent scouts) or a
    self-contained implementation task; do the work yourself when it needs your
    conversation context or back-and-forth decisions. Spawn all subagents first,
    then call wait_agent once — don't wait after each spawn.
    """
  end

  @impl true
  def parameter_schema do
    [
      agent: [
        type: :string,
        required: true,
        doc: "Agent role name (see the role list in this tool's description)"
      ],
      task: [
        type: :string,
        required: true,
        doc: "Self-contained task description; the subagent sees nothing else"
      ],
      model: [type: :string, doc: "Override the model spec for this subagent"],
      cwd: [type: :string, doc: "Working directory (defaults to yours)"]
    ]
  end

  @impl true
  def run(args, ctx) do
    case GenServer.call(ctx.session, {:spawn_subagent, args}, 30_000) do
      {:ok, handle} ->
        {:ok, "Spawned #{handle}. It is working in the background — " <>
                "use wait_agent to collect its result."}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule Longpi.Agent.Tools.WaitAgent do
  @moduledoc false
  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tools.Agents

  @poll_ms 1_000
  @default_timeout_ms 900_000
  @max_timeout_ms 3_600_000

  @impl true
  def name, do: "wait_agent"

  @impl true
  def description do
    """
    Block until the listed subagents (default: all running ones) finish, then
    return each one's final output. On timeout it returns current statuses
    instead — the subagents keep running and you can wait again.
    """
  end

  @impl true
  def parameter_schema do
    [
      agents: [
        type: {:list, :string},
        doc: "Handles to wait for (from spawn_agent). Default: all non-closed"
      ],
      timeout_ms: [
        type: :integer,
        doc: "Max wait in ms (default #{@default_timeout_ms}, max #{@max_timeout_ms})"
      ]
    ]
  end

  @impl true
  def run(args, ctx) do
    timeout = args |> Map.get(:timeout_ms, @default_timeout_ms) |> min(@max_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    case resolve_handles(args[:agents], Agents.snapshot(ctx)) do
      {:error, msg} -> {:error, msg}
      {:ok, []} -> {:error, "No subagents to wait for. Spawn one with spawn_agent first."}
      {:ok, handles} -> poll(handles, ctx, deadline)
    end
  end

  defp resolve_handles(nil, snapshot) do
    {:ok, for({handle, info} <- snapshot, info.status != :closed, do: handle)}
  end

  defp resolve_handles(requested, snapshot) do
    case Enum.reject(requested, &Map.has_key?(snapshot, &1)) do
      [] ->
        {:ok, requested}

      unknown ->
        {:error,
         "Unknown agent handle(s): #{Enum.join(unknown, ", ")}. " <>
           "Known: #{snapshot |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  defp poll(handles, ctx, deadline) do
    snapshot = Agents.snapshot(ctx)
    watched = Map.take(snapshot, handles)
    all_terminal? = Enum.all?(watched, fn {_handle, info} -> Agents.terminal?(info) end)

    cond do
      all_terminal? ->
        GenServer.call(ctx.session, {:subagent_collect, handles})
        {:ok, format_results(watched)}

      System.monotonic_time(:millisecond) >= deadline ->
        {:ok,
         "Timed out waiting. Current status (subagents keep running):\n" <>
           Enum.map_join(watched, "\n", &Agents.status_line/1)}

      true ->
        Process.sleep(@poll_ms)
        poll(handles, ctx, deadline)
    end
  end

  defp format_results(watched) do
    Enum.map_join(watched, "\n\n", fn {handle, info} ->
      output =
        case info.status do
          :done -> Agents.final_output(info.conversation_id)
          :failed -> "(failed: #{info.detail || "unknown error"})"
          :closed -> "(closed before completion)"
        end

      "### #{handle} (#{info.role}) — #{info.status}\n\n#{output}"
    end)
  end
end

defmodule Longpi.Agent.Tools.ListAgents do
  @moduledoc false
  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Tools.Agents

  @impl true
  def name, do: "list_agents"

  @impl true
  def description,
    do: "List this conversation's subagents and their statuses (running/done/failed/closed)."

  @impl true
  def parameter_schema, do: []

  @impl true
  def run(_args, ctx) do
    case Agents.snapshot(ctx) do
      empty when map_size(empty) == 0 -> {:ok, "No subagents spawned yet."}
      snapshot -> {:ok, Enum.map_join(snapshot, "\n", &Agents.status_line/1)}
    end
  end
end

defmodule Longpi.Agent.Tools.SendAgent do
  @moduledoc false
  @behaviour Longpi.Agent.Tool

  @impl true
  def name, do: "send_agent"

  @impl true
  def description do
    """
    Send a follow-up message to a subagent. If it already finished, this starts
    a new turn with your message; if it is still working, pass interrupt: true
    to redirect it (otherwise this fails so you don't derail it mid-task).
    """
  end

  @impl true
  def parameter_schema do
    [
      agent: [type: :string, required: true, doc: "Subagent handle (from spawn_agent)"],
      message: [type: :string, required: true, doc: "Message to deliver"],
      interrupt: [
        type: :boolean,
        default: false,
        doc: "Interrupt the current work before delivering"
      ]
    ]
  end

  @impl true
  def run(args, ctx) do
    case GenServer.call(ctx.session, {:subagent_send, args}, 30_000) do
      {:ok, handle} -> {:ok, "Delivered to #{handle}; it is working on it. wait_agent to collect."}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Longpi.Agent.Tools.CloseAgent do
  @moduledoc false
  @behaviour Longpi.Agent.Tool

  @impl true
  def name, do: "close_agent"

  @impl true
  def description,
    do:
      "Stop a subagent and mark it closed. Use when its work is no longer needed; " <>
        "running work is aborted."

  @impl true
  def parameter_schema do
    [
      agent: [type: :string, required: true, doc: "Subagent handle (from spawn_agent)"]
    ]
  end

  @impl true
  def run(args, ctx) do
    case GenServer.call(ctx.session, {:subagent_close, args[:agent]}, 30_000) do
      :ok -> {:ok, "Closed #{args[:agent]}."}
      {:error, reason} -> {:error, reason}
    end
  end
end
