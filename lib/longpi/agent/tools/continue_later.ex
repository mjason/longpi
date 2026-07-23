defmodule Longpi.Agent.Tools.ContinueLater do
  @moduledoc """
  Lets the model schedule its own next turn: when a task is too large to finish
  in one turn, it calls this with a note, finishes the turn normally, and the
  session immediately wakes it with that note as the next user message.

  This is the implicit counterpart of the explicit `/loop` command — same
  continuation engine in `Longpi.Agent.Session`, same runaway protection (a
  consecutive-auto-turn cap that only a real user message resets).
  """

  @behaviour Longpi.Agent.Tool

  @impl true
  def name, do: "continue_later"

  @impl true
  def description do
    "Schedule your own next turn for work that doesn't fit in this one: pass a " <>
      "note describing exactly where to pick up, finish this turn with a short " <>
      "status, and you will be woken with the note. Consecutive auto-turns are " <>
      "capped, so keep each turn's progress concrete."
  end

  @impl true
  def parameter_schema do
    [
      note: [
        type: :string,
        required: true,
        doc:
          "Self-reminder for the next turn: what is done, what to do next, and " <>
            "any state worth carrying over (paths, decisions, remaining items)."
      ]
    ]
  end

  @impl true
  def run(%{note: note}, ctx) do
    case GenServer.call(ctx.session, {:schedule_continuation, note}) do
      :ok ->
        {:ok, "Continuation scheduled. Finish this turn; you'll be woken with your note."}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
