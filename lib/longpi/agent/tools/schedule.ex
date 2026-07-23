defmodule Longpi.Agent.Tools.Schedule do
  @moduledoc """
  Model-facing entry to cron schedules: when the user says "每天晚上11点总结
  当天工作" in plain language, the model translates it to a cron expression
  and calls this tool — no slash command needed. Backed by the same
  `Longpi.Agent.Schedules` the `/schedule` command uses.
  """

  @behaviour Longpi.Agent.Tool

  alias Longpi.Agent.Schedules

  @impl true
  def name, do: "schedule"

  @impl true
  def description do
    "Manage recurring cron schedules for THIS conversation. When the user asks " <>
      "for something periodic in natural language (every day at 23:00, every " <>
      "15 minutes, weekday mornings), translate it to a standard 5-field cron " <>
      "expression (server-local time) and add it. The task text is injected " <>
      "into this conversation at every match, and you act on it then. " <>
      "Schedules persist across restarts."
  end

  @impl true
  def parameter_schema do
    [
      action: [
        type: :string,
        required: true,
        doc: "One of: add, list, remove"
      ],
      cron: [
        type: :string,
        doc: "For add: a 5-field cron, e.g. \"0 23 * * *\" (daily 23:00), \"*/15 * * * *\", \"30 9 * * 1-5\""
      ],
      task: [
        type: :string,
        doc: "For add: what to do at each match — written as an instruction to your future self"
      ],
      index: [
        type: :pos_integer,
        doc: "For remove: the schedule's number as shown by list"
      ]
    ]
  end

  @impl true
  def run(_args, %{conversation_id: nil}),
    do: {:error, "schedules need a persisted conversation"}

  def run(%{action: "add", cron: cron, task: task}, ctx) when is_binary(cron) and is_binary(task),
    do: Schedules.add(ctx.conversation_id, cron, task)

  def run(%{action: "add"}, _ctx),
    do: {:error, "add needs both cron and task"}

  def run(%{action: "list"}, ctx),
    do: {:ok, Schedules.list_text(ctx.conversation_id)}

  def run(%{action: "remove", index: index}, ctx) when is_integer(index),
    do: Schedules.remove(ctx.conversation_id, index)

  def run(%{action: "remove"}, _ctx),
    do: {:error, "remove needs index (see list)"}

  def run(%{action: other}, _ctx),
    do: {:error, "unknown action #{inspect(other)} — use add, list, or remove"}
end
