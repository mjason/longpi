defmodule Longpi.Agent.Scheduler do
  @moduledoc """
  Fires cron-scheduled tasks: one global process ticks at every minute
  boundary, matches each enabled `ScheduledTask`'s cron expression against
  server-local time, and injects the due tasks into their conversations
  (rebuilding reaped sessions from the DB on demand).

  Schedules live in the DB, so they survive restarts; a tick that finds the
  session busy skips this occurrence — cron semantics, the next match fires
  again. Each task is isolated: one failure never sinks the tick.
  """

  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Validates a 5-field cron expression, returning a human summary or an error.

  Exactly five fields are required: the parser would silently read a 6-field
  (seconds-style) expression's extra field as a YEAR, firing at the wrong
  time — a mistake models make often, so it must be a loud error.
  """
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(cron) do
    cond do
      length(String.split(cron)) != 5 ->
        {:error,
         "invalid cron #{inspect(cron)}: exactly 5 fields required " <>
           "(minute hour day month weekday), e.g. \"0 23 * * *\""}

      true ->
        case Crontab.CronExpression.Parser.parse(cron) do
          {:ok, _} -> {:ok, cron}
          {:error, reason} -> {:error, "invalid cron #{inspect(cron)}: #{reason}"}
        end
    end
  end

  @doc "True when `cron` matches the given minute (a NaiveDateTime)."
  @spec due?(String.t(), NaiveDateTime.t()) :: boolean()
  def due?(cron, now) do
    case Crontab.CronExpression.Parser.parse(cron) do
      {:ok, expression} -> Crontab.DateChecker.matches_date?(expression, now)
      {:error, _} -> false
    end
  end

  @doc "The next local run time for `cron`, for display."
  @spec next_run(String.t()) :: {:ok, NaiveDateTime.t()} | :error
  def next_run(cron) do
    with {:ok, expression} <- Crontab.CronExpression.Parser.parse(cron),
         {:ok, at} <- Crontab.Scheduler.get_next_run_date(expression, local_now()) do
      {:ok, at}
    else
      _ -> :error
    end
  end

  # ── Server ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Disabled in tests (config :longpi, scheduler_enabled: false) — the tick
    # would fight the DB sandbox.
    if Application.get_env(:longpi, :scheduler_enabled, true), do: schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick()
    run_due_tasks(local_now())
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def run_due_tasks(now) do
    for task <- list_enabled(), due?(task.cron, now) do
      fire(task)
    end

    :ok
  end

  defp list_enabled do
    Longpi.Agent.list_enabled_scheduled_tasks!()
  rescue
    error ->
      Logger.warning("scheduler: could not list tasks: #{Exception.message(error)}")
      []
  end

  defp fire(task) do
    case Longpi.Agent.Sessions.ensure_started(task.conversation_id, []) do
      {:ok, session} ->
        message = "[scheduled #{task.cron}] #{task.task}"

        case Longpi.Agent.Session.send_message(session, message) do
          :ok ->
            mark_ran(task)

          {:error, :busy} ->
            Logger.info("scheduler: #{task.conversation_id} busy; skipping this occurrence")
        end

      {:error, reason} ->
        disable_if_orphaned(task)
        Logger.warning("scheduler: cannot start session #{task.conversation_id}: #{inspect(reason)}")
    end
  rescue
    error ->
      disable_if_orphaned(task)
      Logger.warning("scheduler: task #{task.id} failed: #{Exception.message(error)}")
  end

  # A schedule whose conversation was deleted would otherwise warn on every
  # matching minute forever; disable it once so the noise stops.
  defp disable_if_orphaned(task) do
    case Longpi.Agent.get_conversation(task.conversation_id) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning("scheduler: disabling orphaned schedule #{task.id} (conversation gone)")
        Longpi.Agent.update_scheduled_task!(task, %{enabled: false})
    end
  rescue
    _ -> :ok
  end

  defp mark_ran(task) do
    Longpi.Agent.update_scheduled_task!(task, %{last_run_at: DateTime.utc_now()})
  rescue
    _ -> :ok
  end

  # Align ticks to minute boundaries so each cron minute fires exactly once.
  defp schedule_tick do
    now = System.system_time(:millisecond)
    Process.send_after(self(), :tick, 60_000 - rem(now, 60_000) + 50)
  end

  # Cron runs on server-local wall-clock time — "0 23 * * *" means 23:00 where
  # the server lives, which is what a human writing the schedule expects.
  defp local_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()
    NaiveDateTime.new!(y, mo, d, h, mi, s)
  end
end
