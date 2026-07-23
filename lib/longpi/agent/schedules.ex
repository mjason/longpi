defmodule Longpi.Agent.Schedules do
  @moduledoc """
  Shared operations behind BOTH schedule entry points — the `/schedule` slash
  command and the model-facing `schedule` tool ("每天晚上11点总结" in natural
  language becomes a tool call). One implementation, two front doors.
  """

  alias Longpi.Agent.Scheduler

  @doc "Creates a schedule after validating the cron; returns a confirmation line."
  @spec add(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def add(conversation_id, cron, task) do
    task = String.trim(to_string(task))

    with {:ok, _} <- Scheduler.validate(cron),
         true <- task != "" || {:error, "schedule task must not be empty"} do
      Longpi.Agent.create_scheduled_task!(%{conversation_id: conversation_id, cron: cron, task: task})

      next =
        case Scheduler.next_run(cron) do
          {:ok, at} -> " First run: #{NaiveDateTime.to_string(at)}."
          :error -> ""
        end

      {:ok, "Scheduled [#{cron}] #{task}.#{next}"}
    else
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  @doc "Human-readable numbered list of this conversation's schedules."
  @spec list_text(String.t()) :: String.t()
  def list_text(conversation_id) do
    case Longpi.Agent.scheduled_tasks_for!(conversation_id) do
      [] ->
        "No schedules for this conversation."

      tasks ->
        tasks
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {t, i} ->
          next =
            case Scheduler.next_run(t.cron) do
              {:ok, at} -> " — next #{NaiveDateTime.to_string(at)}"
              :error -> ""
            end

          "#{i}. [#{t.cron}] #{t.task}#{next}"
        end)
    end
  end

  @doc "Removes the n-th schedule (1-based, as shown by `list_text/1`)."
  @spec remove(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def remove(conversation_id, index) do
    tasks = Longpi.Agent.scheduled_tasks_for!(conversation_id)

    if is_integer(index) and index >= 1 and index <= length(tasks) do
      task = Enum.at(tasks, index - 1)

      # Non-bang: a concurrent remove (another tab, or tool + command at once)
      # may have deleted the row already — that's a stale list, not a crash.
      case Longpi.Agent.destroy_scheduled_task(task) do
        :ok ->
          {:ok, "Removed schedule #{index}: [#{task.cron}] #{task.task}"}

        {:error, _} ->
          {:error, "schedule ##{index} was already removed — list schedules for current numbers"}
      end
    else
      {:error, "no schedule ##{inspect(index)} — list schedules to see valid numbers"}
    end
  end
end
